//
//  AuthServiceTests.swift
//  JourneysTests
//
//  Signing in, refreshing the access token with a rotating refresh token, and signing out,
//  against a stub of fastapi-api's auth endpoints.
//

import XCTest
@testable import Journeys

/// Keeps "Keychain" items in memory.
final class MemoryCredentials: CredentialStoring {
    private(set) var values: [String: Data] = [:]
    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data?, for key: String) -> Bool {
        values[key] = data
        return true
    }
}

/// fastapi-api's /auth endpoints: password "secret" for anyone; each refresh token works once.
final class FakeAuthServer {
    var validRefreshTokens: Set<String> = []
    private(set) var issued = 0
    private(set) var refreshes = 0
    private(set) var logouts: [[String: String]] = []
    /// Answers sign-ins with 429 and this Retry-After.
    var throttleFor: Int?
    /// Fails refreshes as if the network were down.
    var offline = false

    func respond(path: String, body: Data) throws -> (Int, Data) {
        let fields = (try? JSONSerialization.jsonObject(with: body) as? [String: String]) ?? [:]
        switch path {
        case "/api/v1/auth/authenticate":
            if throttleFor != nil { return (429, Data(#"{"detail": "Too many attempts"}"#.utf8)) }
            guard fields["password"] == "secret" else { return (401, Data(#"{"detail": "no"}"#.utf8)) }
            return try issue(to: fields["username"] ?? "")
        case "/api/v1/auth/refresh-token":
            if offline { throw URLError(.notConnectedToInternet) }
            refreshes += 1
            guard let token = fields["refresh_token"], validRefreshTokens.remove(token) != nil else {
                return (401, Data(#"{"detail": "Refresh token was already used; sign in again"}"#.utf8))
            }
            return try issue(to: "plh")
        case "/api/v1/auth/logout":
            logouts.append(fields)
            validRefreshTokens.remove(fields["refresh_token"] ?? "")
            return (204, Data())
        default:
            return (404, Data())
        }
    }

    private func issue(to username: String) throws -> (Int, Data) {
        issued += 1
        let refreshToken = "refresh-\(issued)"
        validRefreshTokens.insert(refreshToken)
        let body: [String: Any] = ["token": "access-\(issued)", "refresh_interval": 900,
                                   "refresh_token": refreshToken, "user": ["username": username]]
        return (200, try JSONSerialization.data(withJSONObject: body))
    }
}

@MainActor
final class AuthServiceTests: XCTestCase {
    private var server: FakeAuthServer!
    private var credentials: MemoryCredentials!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        StubURLProtocol.reset()
        server = FakeAuthServer()
        credentials = MemoryCredentials()
        let server = server!
        StubURLProtocol.responder = { body in
            try server.respond(path: StubURLProtocol.lastRequest?.url?.path() ?? "", body: body)
        }
    }

    private func makeAuth() -> AuthService {
        AuthService(api: makeStubAPI(), credentials: credentials, now: { [unowned self] in clock })
    }

    private func signedIn() async throws -> AuthService {
        let auth = makeAuth()
        try await auth.signIn(username: "plh", password: "secret")
        return auth
    }

    // MARK: - Signing in

    func testSigningInKeepsTheRefreshTokenButNotThePassword() async throws {
        let auth = makeAuth()
        var changes = 0
        auth.onChange = { changes += 1 }

        try await auth.signIn(username: "plh", password: "secret")

        XCTAssertEqual(auth.username, "plh")
        XCTAssertEqual(changes, 1)
        let stored = try XCTUnwrap(String(bytes: try XCTUnwrap(credentials.values[AuthService.sessionKey]),
                                          encoding: .utf8))
        XCTAssertTrue(stored.contains("refresh-1"))
        XCTAssertFalse(stored.contains("secret"), "The password is never stored")
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "access-1")
        XCTAssertEqual(server.refreshes, 0, "The sign-in's access token is used while it lasts")
    }

    func testAWrongPasswordIsReported() async {
        let auth = makeAuth()

        do {
            try await auth.signIn(username: "plh", password: "guess")
            XCTFail("Signed in with a wrong password")
        } catch {
            XCTAssertEqual(error as? AuthError, .wrongCredentials)
        }
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertTrue(credentials.values.isEmpty)
    }

    func testTooManyAttemptsSaysWhenToTryAgain() async {
        server.throttleFor = 120
        StubURLProtocol.headers = ["Retry-After": "120"]
        let auth = makeAuth()

        do {
            try await auth.signIn(username: "plh", password: "secret")
            XCTFail("Signed in while throttled")
        } catch {
            XCTAssertEqual(error as? AuthError, .throttled(retryAfter: 120))
            XCTAssertEqual(error.localizedDescription, "Too many attempts. Try again in 2 minutes.")
        }
    }

    // MARK: - Refreshing

    func testAnExpiringAccessTokenIsRefreshedAndTheRefreshTokenRotated() async throws {
        let auth = try await signedIn()
        clock += 900 - AuthService.expiryMargin + 1

        let token = try await auth.accessToken()

        XCTAssertEqual(token, "access-2")
        XCTAssertEqual(server.refreshes, 1)
        let stored = try XCTUnwrap(String(bytes: try XCTUnwrap(credentials.values[AuthService.sessionKey]),
                                          encoding: .utf8))
        XCTAssertTrue(stored.contains("refresh-2"), "The new refresh token replaces the spent one")
    }

    func testCallersWaitingTogetherShareOneRefresh() async throws {
        let auth = try await signedIn()
        clock += 3600

        async let first = auth.accessToken()
        async let second = auth.accessToken()
        let tokens = try await [first, second]

        XCTAssertEqual(tokens, ["access-2", "access-2"])
        XCTAssertEqual(server.refreshes, 1, "A second refresh would spend the same token twice")
    }

    func testARejectedTokenIsReplaced() async throws {
        let auth = try await signedIn()

        auth.tokenRejected("access-1")

        let token = try await auth.accessToken()
        XCTAssertEqual(token, "access-2")
    }

    func testTheSignInSurvivesARelaunch() async throws {
        _ = try await signedIn()

        let relaunched = makeAuth()

        XCTAssertEqual(relaunched.username, "plh")
        let token = try await relaunched.accessToken()
        XCTAssertEqual(token, "access-2", "Access tokens are not kept, so the first one comes from a refresh")
    }

    func testARefusedRefreshTokenSignsOut() async throws {
        let auth = try await signedIn()
        server.validRefreshTokens.removeAll()  // revoke-all, or reuse detected
        var changes = 0
        auth.onChange = { changes += 1 }
        clock += 3600

        do {
            _ = try await auth.accessToken()
            XCTFail("Got a token after the server ended the sign-in")
        } catch {
            XCTAssertEqual(error as? AuthError, .signedOut)
        }
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertEqual(changes, 1)
        XCTAssertNil(credentials.values[AuthService.sessionKey])
    }

    func testARefreshWithNoNetworkKeepsTheSignIn() async throws {
        let auth = try await signedIn()
        server.offline = true
        clock += 3600

        do {
            _ = try await auth.accessToken()
            XCTFail("Refreshed with no network")
        } catch {
            XCTAssertNotEqual(error as? AuthError, .signedOut)
        }
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.cachedAccessToken, "access-1")
        server.offline = false
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "access-2", "The kept refresh token still works")
    }

    // MARK: - Signing out

    func testSigningOutEndsTheSignInOnTheServerAndThePhone() async throws {
        let auth = try await signedIn()

        await auth.signOut()

        XCTAssertEqual(server.logouts, [["refresh_token": "refresh-1"]])
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(auth.cachedAccessToken)
        XCTAssertTrue(credentials.values.isEmpty)
    }
}
