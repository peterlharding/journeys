//
//  SignedInSyncTests.swift
//  JourneysTests
//
//  Uploads need a sign-in, and survive the access token expiring while they wait for Wi-Fi.
//

import CoreData
import XCTest
@testable import Journeys

@MainActor
final class SignedInSyncTests: XCTestCase {

    private var store: Store!
    private var server: FakeSyncServer!
    private var uploader: FakeUploader!
    private var auth: FakeAuth!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        StubURLProtocol.reset()
        store = Store.inMemory()
        server = FakeSyncServer()
        let server = server!
        uploader = FakeUploader()
        uploader.respond = { body in try server.respond(to: body) }
    }

    private func makeEngine(signedIn: Bool = true) -> SyncEngine {
        auth = FakeAuth(signedIn: signedIn)
        return SyncEngine(store: store, api: makeStubAPI(), uploader: uploader, network: FakeNetwork(wifi: true),
                          auth: auth, defaults: makeTestDefaults(), debounce: .zero)
    }

    @discardableResult
    private func addJourney(waypoints count: Int = 1) -> Journey {
        let journey = store.addJourney(name: "Commute", notes: "", createdAt: start, syncState: .pending)
        for minute in 0..<count {
            store.addWaypoint(makeFix(at: start.addingTimeInterval(Double(minute) * 60)), source: .tracker,
                              journey: journey)
        }
        return journey
    }

    // MARK: - Signed out

    func testNothingIsUploadedWhileSignedOut() async {
        addJourney()
        let engine = makeEngine(signedIn: false)

        await engine.syncAutomatically()
        await engine.syncNow()

        XCTAssertTrue(uploader.queued.isEmpty)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertEqual(engine.status, .signedOut)
        XCTAssertEqual(engine.pendingCount, 2, "The records wait on the phone")
    }

    func testSigningInUploadsWhatIsWaiting() async {
        let journey = addJourney()
        let engine = makeEngine(signedIn: false)
        await engine.syncAutomatically()

        auth.isSignedIn = true
        await waitUntil { self.uploader.queued.count == 1 }
        uploader.deliverNext()

        await waitUntil { journey.syncState == .synced }
        XCTAssertEqual(engine.status, .idle)
    }

    func testSigningOutStopsQueuedUploads() async {
        addJourney()
        let engine = makeEngine()
        await engine.syncAutomatically()
        XCTAssertEqual(uploader.queued.count, 1)

        auth.isSignedIn = false

        await waitUntil { engine.status == .signedOut }
        XCTAssertTrue(uploader.queued.isEmpty)
    }

    // MARK: - Tokens

    func testBackgroundUploadsCarryTheAccessToken() async {
        addJourney()
        let engine = makeEngine()

        await engine.syncAutomatically()

        XCTAssertEqual(uploader.queued.first?.token, "token-1")
    }

    func testATokenThatExpiredWhileWaitingIsReplacedAndTheBatchSentAgain() async {
        let journey = addJourney()
        let engine = makeEngine()
        uploader.acceptsToken = { $0 != "token-1" }
        await engine.syncAutomatically()

        uploader.deliverNext()
        await waitUntil { self.uploader.queued.count == 1 }

        let retry = uploader.queued[0]
        XCTAssertEqual(retry.token, "token-2")
        XCTAssertNil(retry.notBefore, "Sent again at once, not after a failure's delay")
        XCTAssertNotEqual(engine.status, .failed(APIError.unexpectedStatus(401).localizedDescription))
        uploader.deliverNext()
        await waitUntil { journey.syncState == .synced }
    }

    func testRefusedTwiceInARowIsAFailureWithBackoff() async {
        addJourney()
        let engine = makeEngine()
        uploader.acceptsToken = { _ in false }
        await engine.syncAutomatically()

        uploader.deliverNext()
        await waitUntil { self.uploader.queued.count == 1 }
        uploader.deliverNext()
        await waitUntil { self.uploader.queued.count == 1 }

        XCTAssertEqual(engine.status, .failed(APIError.unexpectedStatus(401).localizedDescription))
        XCTAssertNotNil(uploader.queued[0].notBefore, "Retried after a delay")
    }

    func testASignInEndedByTheServerStopsUploads() async {
        let journey = addJourney()
        let engine = makeEngine()
        uploader.acceptsToken = { _ in false }
        await engine.syncAutomatically()
        auth.signInEnded = true

        uploader.deliverNext()

        await waitUntil { engine.status == .signedOut }
        XCTAssertTrue(uploader.queued.isEmpty)
        XCTAssertEqual(journey.syncState, .pending)
    }

    func testSyncNowRetriesOnceWithAFreshToken() async throws {
        let journey = addJourney()
        let engine = makeEngine()
        let server = server!
        StubURLProtocol.responder = { body in
            guard StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") != "Bearer token-1" else {
                return (401, Data("{}".utf8))
            }
            return try server.respond(to: body)
        }

        await engine.syncNow()

        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer token-2")
        XCTAssertEqual(journey.syncState, .synced)
        XCTAssertEqual(engine.status, .idle)
    }
}
