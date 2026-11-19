//
//  SyncEngineTests.swift
//  JourneysTests
//

import CoreData
import XCTest
@testable import Journeys

/// A stand-in for POST /sync with the real server's rules (mongo-api doc/SYNC.md): records are
/// stored once by id, a waypoint needs its journey, and a journey named "Reject me" is refused.
private final class FakeSyncServer {
    private(set) var journeys: [String: [String: Any]] = [:]
    private(set) var waypoints: [String: [String: Any]] = [:]
    /// Each request's body, decoded.
    private(set) var batches: [[String: Any]] = []
    /// When set, the next request is processed but its reply is lost.
    var loseNextReply = false

    func respond(to body: Data) throws -> (Int, Data) {
        let batch = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        batches.append(batch)
        var journeyAnswers: [String: String] = [:]
        var waypointAnswers: [String: String] = [:]
        for journey in batch["journeys"] as? [[String: Any]] ?? [] {
            let id = (journey["id"] as? String ?? "").uppercased()
            if journey["name"] as? String == "Reject me" {
                journeyAnswers[id] = "rejected: name not allowed"
            } else {
                journeyAnswers[id] = journeys[id] == nil ? "stored" : "duplicate"
                journeys[id] = journeys[id] ?? journey
            }
        }
        for waypoint in batch["waypoints"] as? [[String: Any]] ?? [] {
            let id = (waypoint["id"] as? String ?? "").uppercased()
            let journeyID = (waypoint["journeyId"] as? String ?? "").uppercased()
            if waypoints[id] != nil {
                waypointAnswers[id] = "duplicate"
            } else if journeys[journeyID] == nil {
                waypointAnswers[id] = "rejected: no journey with id \(journeyID)"
            } else {
                waypoints[id] = waypoint
                waypointAnswers[id] = "stored"
            }
        }
        if loseNextReply {
            loseNextReply = false
            throw URLError(.networkConnectionLost)
        }
        let reply = try JSONSerialization.data(withJSONObject: ["journeys": journeyAnswers,
                                                                "waypoints": waypointAnswers])
        return (200, reply)
    }
}

@MainActor
final class SyncEngineTests: XCTestCase {

    private var store: Store!
    private var server: FakeSyncServer!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        StubURLProtocol.reset()
        store = Store.inMemory()
        server = FakeSyncServer()
        let server = server!
        StubURLProtocol.responder = { body in try server.respond(to: body) }
    }

    private func makeEngine(wifi: Bool = true) -> SyncEngine {
        SyncEngine(store: store, api: makeStubAPI(), network: FakeNetwork(wifi: wifi),
                   defaults: makeTestDefaults(), debounce: .zero)
    }

    @discardableResult
    private func addJourney(_ name: String = "Commute", state: SyncState = .pending,
                            waypoints count: Int = 0) -> Journey {
        let journey = store.addJourney(name: name, notes: "", createdAt: start, syncState: state)
        for minute in 0..<count {
            let fix = makeFix(latitude: -35 - Double(minute) / 1000, at: start.addingTimeInterval(Double(minute) * 60))
            store.addWaypoint(fix, source: .tracker, journey: journey)
        }
        return journey
    }

    private func states(_ journey: Journey) -> [SyncState] {
        store.waypoints(of: journey).map(\.syncState)
    }

    // MARK: - Uploading

    func testJourneyAndItsWaypointsAreUploadedTogetherAndMarkedSynced() async throws {
        let journey = addJourney(waypoints: 2)
        let engine = makeEngine()

        await engine.syncNow()

        XCTAssertEqual(server.batches.count, 1)
        let batch = try XCTUnwrap(server.batches.first)
        let sentJourneys = try XCTUnwrap(batch["journeys"] as? [[String: Any]])
        let sentWaypoints = try XCTUnwrap(batch["waypoints"] as? [[String: Any]])
        XCTAssertEqual(sentJourneys.first?["id"] as? String, journey.id.uuidString)
        XCTAssertEqual(sentJourneys.first?["createdAt"] as? String, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(sentWaypoints.map { $0["recordedAt"] as? String },
                       ["2027-01-15T08:00:00.000Z", "2027-01-15T08:01:00.000Z"])
        XCTAssertEqual(sentWaypoints.first?["journeyId"] as? String, journey.id.uuidString)
        XCTAssertEqual(sentWaypoints.first?["source"] as? String, "tracker")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path(), "/sync")

        XCTAssertEqual(journey.syncState, .synced)
        XCTAssertEqual(states(journey), [.synced, .synced])
        XCTAssertEqual(engine.status, .idle)
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertNotNil(engine.lastSyncedAt)
    }

    /// The server stored the batch but the reply was lost: the phone sends it again and the server
    /// answers "duplicate", so nothing is stored twice and everything ends up synced.
    func testLostReplyIsResentWithoutDuplicates() async {
        let journey = addJourney(waypoints: 3)
        let engine = makeEngine()
        server.loseNextReply = true

        await engine.syncNow()

        guard case .failed = engine.status else { return XCTFail("Expected a failure, got \(engine.status)") }
        XCTAssertEqual(journey.syncState, .pending)
        XCTAssertEqual(engine.pendingCount, 4)

        await engine.syncNow()

        XCTAssertEqual(server.batches.count, 2)
        XCTAssertEqual(server.journeys.count, 1)
        XCTAssertEqual(server.waypoints.count, 3)
        XCTAssertEqual(journey.syncState, .synced)
        XCTAssertEqual(states(journey), [.synced, .synced, .synced])
        XCTAssertEqual(engine.status, .idle)
    }

    /// A rejected journey and its waypoints are marked with the reason and never sent again.
    func testRejectedRecordsAreMarkedAndNotResent() async throws {
        let rejected = addJourney("Reject me", waypoints: 2)
        let accepted = addJourney("Commute", waypoints: 1)
        let engine = makeEngine()

        await engine.syncNow()

        XCTAssertEqual(rejected.syncState, .rejected)
        XCTAssertEqual(rejected.syncError, "name not allowed")
        XCTAssertEqual(states(rejected), [.rejected, .rejected])
        let rejectedWaypoint = try XCTUnwrap(store.waypoints(of: rejected).first)
        XCTAssertEqual(rejectedWaypoint.syncError, "Its journey was rejected: name not allowed")
        XCTAssertEqual(accepted.syncState, .synced)
        XCTAssertEqual(engine.rejected, 3)
        XCTAssertEqual(engine.pendingCount, 0)

        let requests = server.batches.count
        await engine.syncNow()
        XCTAssertEqual(server.batches.count, requests, "Nothing is left to send")
    }

    func testServerErrorKeepsRecordsPending() async {
        let journey = addJourney(waypoints: 1)
        let engine = makeEngine()
        StubURLProtocol.responder = nil
        StubURLProtocol.status = 502

        await engine.syncNow()

        XCTAssertEqual(engine.status, .failed(APIError.unexpectedStatus(502).localizedDescription))
        XCTAssertEqual(journey.syncState, .pending)
        XCTAssertEqual(states(journey), [.pending])
        XCTAssertEqual(engine.pendingCount, 2)
    }

    func testRetryDelayDoublesUpToThirtyMinutes() {
        XCTAssertEqual((1...8).map { SyncEngine.retryDelay(afterFailures: $0) },
                       [30, 60, 120, 240, 480, 960, 1800, 1800])
    }

    /// A long backlog goes up in batches of at most 500, oldest first.
    func testBacklogIsSentInBatchesOldestFirst() async throws {
        let journey = addJourney(waypoints: 1201)
        let engine = makeEngine()

        await engine.syncNow()

        let sizes = server.batches.map { ($0["waypoints"] as? [[String: Any]])?.count ?? 0 }
        XCTAssertEqual(sizes, [500, 500, 201])
        let sent = server.batches.flatMap { $0["waypoints"] as? [[String: Any]] ?? [] }
            .compactMap { $0["recordedAt"] as? String }
        XCTAssertEqual(sent, sent.sorted())
        XCTAssertEqual(Set(states(journey)), [.synced])
        XCTAssertEqual(engine.pendingCount, 0)
    }

    /// Once a journey is synced, later waypoints go up on their own.
    func testWaypointsOfASyncedJourneyAreSentWithoutIt() async throws {
        let journey = addJourney(waypoints: 1)
        let engine = makeEngine()
        await engine.syncNow()

        store.addWaypoint(makeFix(at: start.addingTimeInterval(600)), source: .tracker, journey: journey)
        await engine.syncNow()

        let last = try XCTUnwrap(server.batches.last)
        XCTAssertEqual((last["journeys"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((last["waypoints"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(Set(states(journey)), [.synced])
    }

    func testFixesWithoutAJourneyAreNeverSent() async {
        store.addWaypoint(makeFix(at: start), source: .checkLocation, journey: nil)
        let engine = makeEngine()

        await engine.syncNow()

        XCTAssertTrue(server.batches.isEmpty)
        XCTAssertEqual(store.waypoints(of: nil).first?.syncState, .pending)
        XCTAssertEqual(engine.status, .idle)
    }

    /// A server that answers none of the records is not asked again and again.
    func testUnansweredRecordsStayPendingWithoutLooping() async {
        let journey = addJourney(waypoints: 1)
        let engine = makeEngine()
        StubURLProtocol.responder = { _ in (200, Data(#"{"journeys": {}, "waypoints": {}}"#.utf8)) }

        await engine.syncNow()

        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(journey.syncState, .pending)
    }

    // MARK: - When to sync

    /// Off Wi-Fi, automatic sync waits; joining Wi-Fi uploads without being asked.
    func testAutomaticSyncWaitsForWiFi() async {
        let journey = addJourney(waypoints: 1)
        let network = FakeNetwork(wifi: false)
        let engine = SyncEngine(store: store, api: makeStubAPI(), network: network,
                                defaults: makeTestDefaults(), debounce: .zero)

        engine.recordSaved()
        await waitUntil { engine.status == .waitingForWiFi }
        XCTAssertTrue(server.batches.isEmpty)

        network.allowsAutomaticSync = true
        await waitUntil { journey.syncState == .synced }
        XCTAssertEqual(server.batches.count, 1)
        XCTAssertEqual(engine.status, .idle)
    }

    /// Sync now uploads even off Wi-Fi.
    func testSyncNowUsesAnyNetwork() async {
        let journey = addJourney(waypoints: 1)
        let engine = makeEngine(wifi: false)

        await engine.syncNow()

        XCTAssertEqual(server.batches.count, 1)
        XCTAssertEqual(journey.syncState, .synced)
    }

    /// With nothing to send, no request is made and the last sync time is not touched.
    func testNothingToSendIsNotALastSync() async {
        let engine = makeEngine()

        await engine.syncNow()

        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertNil(engine.lastSyncedAt)
        XCTAssertEqual(engine.status, .idle)
    }

    /// The last sync time survives a relaunch, for the status line.
    func testLastSyncTimeIsRemembered() async {
        addJourney(waypoints: 1)
        let defaults = makeTestDefaults()
        let engine = SyncEngine(store: store, api: makeStubAPI(), network: FakeNetwork(wifi: true),
                                defaults: defaults)

        await engine.syncNow()

        let relaunched = SyncEngine(store: store, api: makeStubAPI(), network: FakeNetwork(wifi: true),
                                    defaults: defaults)
        XCTAssertEqual(relaunched.lastSyncedAt, engine.lastSyncedAt)
        XCTAssertNotNil(relaunched.lastSyncedAt)
    }
}
