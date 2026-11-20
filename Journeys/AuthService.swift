//
//  AuthService.swift
//  Journeys
//
//  Signing in to the API: a short-lived access token for each request, and a long-lived refresh
//  token in the Keychain that keeps the phone signed in (fastapi-api's app/auth/refresh.py).
//

import Foundation

enum AuthError: LocalizedError, Equatable {
    /// No sign-in on this phone, or the server ended it (signed out elsewhere, expired, revoked).
    case signedOut
    case wrongCredentials
    /// Too many failed attempts; the server says when to try again.
    case throttled(retryAfter: Int?)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .signedOut:
            return "Sign in to upload."
        case .wrongCredentials:
            return "The username or password is wrong."
        case .throttled(let seconds?):
            let wait = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
            return "Too many attempts. Try again in \(wait)."
        case .throttled(nil):
            return "Too many attempts. Try again later."
        case .unexpectedResponse:
            return "The server sent an unexpected response."
        }
    }
}

/// The API's answer to signing in and refreshing.
private struct IssuedTokens: Decodable {
    let token: String
    let refreshInterval: Int
    let refreshToken: String?
    let user: IssuedUser

    enum CodingKeys: String, CodingKey {
        case token, user
        case refreshInterval = "refresh_interval"
        case refreshToken = "refresh_token"
    }
}

private struct IssuedUser: Decodable {
    let username: String
}

/// What the sync engine needs from signing in. A protocol so tests can stand in for the server.
@MainActor
protocol AccessTokenProviding: AnyObject {
    var isSignedIn: Bool { get }
    /// The latest access token, even if it has expired; for an upload queued while a refresh fails.
    var cachedAccessToken: String? { get }
    /// Called when signing in or out.
    var onChange: (() -> Void)? { get set }
    /// A current access token, refreshed first if it is about to expire.
    /// Throws `AuthError.signedOut` when there is no sign-in or the server has ended it.
    func accessToken() async throws -> String
    /// The server refused `token`, so the next `accessToken()` refreshes.
    func tokenRejected(_ token: String)
}

/// Signs in, keeps the refresh token in the Keychain and hands out access tokens.
///
/// The access token lasts 15 minutes and is kept in memory only. Each refresh spends the refresh
/// token and returns a new one, and the server treats a spent token used again as stolen, ending the
/// sign-in; so only one refresh runs at a time, and the new token is saved before anything else.
@MainActor
final class AuthService: ObservableObject, AccessTokenProviding {
    /// Who is signed in, or nil.
    @Published private(set) var username: String?

    var isSignedIn: Bool { username != nil }
    var cachedAccessToken: String? { access?.token }
    var onChange: (() -> Void)?

    /// Refresh this long before the access token expires, so it does not expire in flight.
    static let expiryMargin: TimeInterval = 60
    static let sessionKey = "session"

    private let api: APIClient
    private let credentials: CredentialStoring
    private let now: () -> Date
    private var access: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?

    /// What the Keychain keeps.
    private struct Session: Codable {
        let username: String
        let refreshToken: String
    }

    init(api: APIClient, credentials: CredentialStoring, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.credentials = credentials
        self.now = now
        username = session?.username
    }

    private var session: Session? {
        get { credentials.data(for: Self.sessionKey).flatMap { try? JSONDecoder().decode(Session.self, from: $0) } }
        set { credentials.set(newValue.flatMap { try? JSONEncoder().encode($0) }, for: Self.sessionKey) }
    }

    // MARK: - Signing in and out

    func signIn(username: String, password: String) async throws {
        let (http, data) = try await api.send(APIClient.Path.authenticate,
                                              body: ["username": username, "password": password])
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw AuthError.wrongCredentials
        case 429:
            throw AuthError.throttled(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) })
        default:
            throw APIError.unexpectedStatus(http.statusCode)
        }
        try accept(data)
        onChange?()
    }

    /// Ends the sign-in on the server if it can, and on this phone regardless.
    func signOut() async {
        if let session, let access, access.expires > now() {
            _ = try? await api.send(APIClient.Path.logout, body: ["refresh_token": session.refreshToken],
                                    bearer: access.token)
        }
        forget()
    }

    /// Clears the sign-in from this phone.
    func forget() {
        refreshing?.cancel()
        refreshing = nil
        access = nil
        session = nil
        guard username != nil else { return }
        username = nil
        onChange?()
    }

    // MARK: - Access tokens

    func accessToken() async throws -> String {
        if let access, access.expires.timeIntervalSince(now()) > Self.expiryMargin {
            return access.token
        }
        if let refreshing {
            return try await refreshing.value
        }
        let task = Task { try await refresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    func tokenRejected(_ token: String) {
        if access?.token == token {
            access = nil
        }
    }

    private func refresh() async throws -> String {
        guard let session else {
            forget()
            throw AuthError.signedOut
        }
        let (http, data) = try await api.send(APIClient.Path.refreshToken,
                                              body: ["refresh_token": session.refreshToken])
        // Signed out while the answer was on its way: do not sign back in with it.
        try Task.checkCancellation()
        if http.statusCode == 401 {
            // Expired, revoked, or spent: only signing in again helps.
            forget()
            throw AuthError.signedOut
        }
        guard (200..<300).contains(http.statusCode) else { throw APIError.unexpectedStatus(http.statusCode) }
        return try accept(data)
    }

    /// Keeps a sign-in or refresh answer: the refresh token in the Keychain, the access token in memory.
    @discardableResult
    private func accept(_ data: Data) throws -> String {
        guard let issued = try? JSONDecoder().decode(IssuedTokens.self, from: data),
              let refreshToken = issued.refreshToken else { throw AuthError.unexpectedResponse }
        session = Session(username: issued.user.username, refreshToken: refreshToken)
        access = (issued.token, now().addingTimeInterval(TimeInterval(issued.refreshInterval)))
        username = issued.user.username
        return issued.token
    }
}
