//
//  JourneyStorageTests.swift
//  JourneysTests
//
//  How LocationManager uses the store: creating journeys offline, saving fixes and telling the
//  sync engine, and carrying over the current journey saved by versions before 1.2.0.
//

import CoreLocation
import XCTest
@testable import Journeys

@MainActor
final class JourneyStorageTests: XCTestCase {

    override func setUp() {
        StubURLProtocol.reset()
    }

    /// A new journey is saved and becomes current at once, with no network involved.
    func testCreatedJourneyIsSavedPendingAndBecomesCurrent() throws {
        let store = Store.inMemory()
        let defaults = makeTestDefaults()
        let manager = makeManager(store: store, defaults: defaults)

        manager.createJourney(name: "Commute", notes: "Bus")

        let journey = try XCTUnwrap(manager.currentJourney)
        XCTAssertEqual(journey.name, "Commute")
        XCTAssertEqual(journey.notes, "Bus")
        XCTAssertEqual(journey.syncState, .pending)
        XCTAssertEqual(store.journey(id: journey.id), journey)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)

        // A relaunch picks the same journey up again.
        let relaunched = makeManager(store: store, defaults: defaults)
        XCTAssertEqual(relaunched.currentJourney?.id, journey.id)
    }

    /// Saved journeys and fixes are handed to the sync engine, which waits for Wi-Fi to upload them.
    func testSavedRecordsAreQueuedForSync() async throws {
        let store = Store.inMemory()
        let engine = SyncEngine(store: store, api: makeStubAPI(), network: FakeNetwork(wifi: false),
                                defaults: makeTestDefaults(), debounce: .zero)
        let manager = makeManager(store: store, syncEngine: engine)

        manager.createJourney(name: "Commute", notes: "")
        manager.trackerReceived(makeFix(at: .now))

        let waypoint = try XCTUnwrap(store.waypoints(of: manager.currentJourney).first)
        XCTAssertEqual(waypoint.source, .tracker)
        XCTAssertEqual(waypoint.syncState, .pending)
        XCTAssertEqual(engine.pendingJourneys, 1)
        XCTAssertEqual(engine.pendingWaypoints, 1)
        await waitUntil { engine.status == .waitingForWiFi }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// A Check Location fix taken with no current journey is saved but never queued for upload.
    func testFixWithoutJourneyIsSavedButNotQueued() throws {
        let store = Store.inMemory()
        let engine = SyncEngine(store: store, api: makeStubAPI(), network: FakeNetwork(wifi: true),
                                defaults: makeTestDefaults())
        let manager = makeManager(store: store, syncEngine: engine)

        manager.startCheckLocation()
        manager.locationManager(CLLocationManager(), didUpdateLocations: [makeFix(at: .now)])

        let waypoint = try XCTUnwrap(store.waypoints(of: nil).first)
        XCTAssertEqual(waypoint.source, .checkLocation)
        XCTAssertEqual(engine.pendingCount, 0)
    }

    /// The current journey saved as JSON by versions before 1.2.0 is moved into the store, once.
    func testLegacyCurrentJourneyIsImported() throws {
        let store = Store.inMemory()
        let defaults = makeTestDefaults()
        let legacy = JourneyData(id: UUID(), name: "Home", notes: "Old")
        defaults.set(try JSONEncoder().encode(legacy), forKey: LocationManager.legacyCurrentJourneyKey)

        let manager = makeManager(store: store, defaults: defaults)

        let journey = try XCTUnwrap(manager.currentJourney)
        XCTAssertEqual(journey.id, legacy.id)
        XCTAssertEqual(journey.name, "Home")
        XCTAssertEqual(journey.notes, "Old")
        XCTAssertEqual(journey.syncState, .pending, "Whether the API has it is unknown")
        XCTAssertNil(defaults.data(forKey: LocationManager.legacyCurrentJourneyKey))

        // Launching again neither duplicates it nor loses it.
        let relaunched = makeManager(store: store, defaults: defaults)
        XCTAssertEqual(relaunched.currentJourney?.id, legacy.id)
        XCTAssertEqual((try? store.viewContext.fetch(Journey.fetchRequest()))?.count, 1)
    }
}
