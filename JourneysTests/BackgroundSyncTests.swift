//
//  BackgroundSyncTests.swift
//  JourneysTests
//
//  Automatic syncs, handed to iOS's background transfer service (FakeUploader stands in for it).
//

import CoreData
import XCTest
@testable import Journeys

@MainActor
final class BackgroundSyncTests: XCTestCase {

    private var store: Store!
    private var server: FakeSyncServer!
    private var uploader: FakeUploader!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        StubURLProtocol.reset()
        store = Store.inMemory()
        server = FakeSyncServer()
        let server = server!
        StubURLProtocol.responder = { body in try server.respond(to: body) }
        uploader = FakeUploader()
        uploader.respond = { body in try server.respond(to: body) }
    }

    private func makeEngine(wifi: Bool = true, network: FakeNetwork? = nil,
                            defaults: UserDefaults? = nil) -> SyncEngine {
        SyncEngine(store: store, api: makeStubAPI(), uploader: uploader, network: network ?? FakeNetwork(wifi: wifi),
                   defaults: defaults ?? makeTestDefaults(), debounce: .zero)
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

    /// Off Wi-Fi, a saved record is handed to iOS at once, which uploads it when Wi-Fi appears,
    /// even if the app is suspended by then.
    func testAutomaticSyncIsHandedToIOSToUploadOnWiFi() async {
        let journey = addJourney(waypoints: 1)
        let network = FakeNetwork(wifi: false)
        let engine = makeEngine(network: network)

        engine.recordSaved()
        await waitUntil { engine.status == .waitingForWiFi }
        XCTAssertEqual(uploader.queued.count, 1)
        XCTAssertNil(uploader.queued.first?.notBefore)
        XCTAssertTrue(server.batches.isEmpty, "Nothing is sent until iOS has Wi-Fi")

        network.allowsAutomaticSync = true
        uploader.deliverNext()
        await waitUntil { journey.syncState == .synced }
        XCTAssertEqual(states(journey), [.synced])
        await waitUntil { engine.status == .idle }
        XCTAssertNotNil(engine.lastSyncedAt)
    }

    /// Each answer queues the next batch, so a long backlog drains without the app in the foreground.
    func testEachBackgroundAnswerQueuesTheNextBatch() async {
        let journey = addJourney(waypoints: 1201)
        let engine = makeEngine()

        await engine.syncAutomatically()
        for _ in 0..<3 {
            await waitUntil { self.uploader.queued.count == 1 }
            uploader.deliverNext()
        }

        await waitUntil { engine.pendingCount == 0 }
        XCTAssertEqual(server.batches.count, 3)
        XCTAssertEqual(Set(states(journey)), [.synced])
        XCTAssertTrue(uploader.queued.isEmpty)
    }

    /// Two triggers at once (at launch: the app becoming active and the network's first report)
    /// still hand over only one batch.
    func testSimultaneousTriggersQueueOneUpload() async {
        addJourney(waypoints: 1)
        let engine = makeEngine()

        async let first: Void = engine.syncAutomatically()
        async let second: Void = engine.syncAutomatically()
        _ = await (first, second)

        XCTAssertEqual(uploader.queued.count, 1)
    }

    /// Only one batch is with iOS at a time.
    func testNoSecondUploadWhileOneIsQueued() async {
        addJourney(waypoints: 1)
        let engine = makeEngine()

        await engine.syncAutomatically()
        await engine.syncAutomatically()

        XCTAssertEqual(uploader.queued.count, 1)
    }

    /// A failed background upload is queued again with a start delay, so iOS retries it later on its
    /// own, even if the app is suspended.
    func testFailedBackgroundUploadIsRetriedAfterADelay() async {
        let journey = addJourney(waypoints: 1)
        let engine = makeEngine()
        uploader.respond = { _ in (502, Data()) }

        await engine.syncAutomatically()
        uploader.deliverNext()

        await waitUntil { if case .failed = engine.status { return true } else { return false } }
        XCTAssertEqual(journey.syncState, .pending)
        await waitUntil { self.uploader.queued.count == 1 }
        let retryAt = try? XCTUnwrap(uploader.queued.first?.notBefore)
        XCTAssertEqual(retryAt?.timeIntervalSinceNow ?? 0, 30, accuracy: 2)
    }

    /// Sync now replaces whatever was queued with iOS, and a cancelled upload is not a failure.
    func testSyncNowReplacesAQueuedUpload() async {
        let journey = addJourney(waypoints: 1)
        let engine = makeEngine(wifi: false)
        await engine.syncAutomatically()
        XCTAssertEqual(uploader.queued.count, 1)

        await engine.syncNow()

        XCTAssertEqual(uploader.cancelCount, 1)
        XCTAssertTrue(uploader.queued.isEmpty)
        XCTAssertEqual(journey.syncState, .synced)
        await waitUntil { engine.status == .idle }
    }

    /// When iOS wakes the app to deliver answers, it is let go only once they are recorded.
    func testBackgroundWakeIsReleasedAfterAnswersAreRecorded() async {
        let journey = addJourney(waypoints: 1)
        let engine = makeEngine()
        await engine.syncAutomatically()

        uploader.deliverNext()
        var released = false
        engine.backgroundEventsFinished { released = true }

        await waitUntil { released }
        XCTAssertEqual(journey.syncState, .synced)
    }

    /// Opening the app retries at once instead of waiting out a queued retry's delay.
    func testOpeningTheAppRetriesAtOnce() async {
        let journey = addJourney(waypoints: 1)
        let engine = makeEngine()
        uploader.respond = { _ in throw URLError(.timedOut) }
        await engine.syncAutomatically()
        uploader.deliverNext()
        await waitUntil { self.uploader.queued.first?.notBefore != nil }

        uploader.respond = { [server] body in try server!.respond(to: body) }
        engine.appBecameActive()
        await waitUntil { self.uploader.queued.count == 1 && self.uploader.queued.first?.notBefore == nil }
        uploader.deliverNext()

        await waitUntil { journey.syncState == .synced }
    }

    /// Joining Wi-Fi after failures retries at once instead of waiting out the backoff.
    func testJoiningWiFiRetriesAtOnce() async {
        addJourney(waypoints: 1)
        let network = FakeNetwork(wifi: true)
        let engine = makeEngine(network: network)
        uploader.respond = { _ in throw URLError(.timedOut) }
        await engine.syncAutomatically()
        uploader.deliverNext()
        await waitUntil { self.uploader.queued.first?.notBefore != nil }

        network.allowsAutomaticSync = false
        network.allowsAutomaticSync = true

        await waitUntil { self.uploader.queued.count == 1 && self.uploader.queued.first?.notBefore == nil }
        XCTAssertEqual(uploader.cancelCount, 1)
        _ = engine
    }
}
