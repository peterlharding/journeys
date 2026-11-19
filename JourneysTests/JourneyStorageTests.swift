//
//  JourneyStorageTests.swift
//  JourneysTests
//
//  How LocationManager uses the store: creating journeys, saving and uploading fixes,
//  and carrying over the current journey saved by versions before 1.2.0.
//

import CoreLocation
import XCTest
@testable import Journeys

@MainActor
final class JourneyStorageTests: XCTestCase {

    override func setUp() {
        StubURLProtocol.status = 200
        StubURLProtocol.lastRequest = nil
    }

    func testCreatedJourneyIsSavedAndBecomesCurrent() async throws {
        let store = Store.inMemory()
        let defaults = makeTestDefaults()
        let manager = makeManager(store: store, defaults: defaults)

        try await manager.createJourney(name: "Commute", notes: "Bus")

        let journey = try XCTUnwrap(manager.currentJourney)
        XCTAssertEqual(journey.name, "Commute")
        XCTAssertEqual(journey.syncState, .synced)
        XCTAssertEqual(store.journey(id: journey.id), journey)

        // A relaunch picks the same journey up again.
        let relaunched = makeManager(store: store, defaults: defaults)
        XCTAssertEqual(relaunched.currentJourney?.id, journey.id)
    }

    func testRejectedJourneyIsNotSaved() async {
        let store = Store.inMemory()
        let manager = makeManager(store: store)
        StubURLProtocol.status = 404

        do {
            try await manager.createJourney(name: "Commute", notes: "")
            XCTFail("Creating the journey should fail")
        } catch {}

        XCTAssertNil(manager.currentJourney)
        XCTAssertEqual((try? store.viewContext.fetch(Journey.fetchRequest()))?.count, 0)
    }

    /// A tracked fix is saved to the current journey and marked synced once the API accepts it.
    func testTrackedFixIsSavedThenMarkedSynced() async throws {
        let store = Store.inMemory()
        let manager = makeManager(store: store)
        try await manager.createJourney(name: "Commute", notes: "")
        let journey = try XCTUnwrap(manager.currentJourney)

        manager.trackerReceived(makeFix(at: .now))

        let waypoint = try XCTUnwrap(store.waypoints(of: journey).first)
        XCTAssertEqual(waypoint.source, .tracker)
        await waitUntil { waypoint.syncState == .synced }
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path(), "/waypoints")
    }

    /// When the upload fails, the fix is still saved, pending, with the error, ready for the sync engine.
    func testFixIsKeptWhenUploadFails() async throws {
        let store = Store.inMemory()
        let manager = makeManager(store: store)
        try await manager.createJourney(name: "Commute", notes: "")
        let journey = try XCTUnwrap(manager.currentJourney)
        StubURLProtocol.status = 502

        manager.trackerReceived(makeFix(at: .now))

        let waypoint = try XCTUnwrap(store.waypoints(of: journey).first)
        await waitUntil { waypoint.syncError != nil }
        XCTAssertEqual(waypoint.syncState, .pending)
        XCTAssertEqual(waypoint.syncError, APIError.unexpectedStatus(502).localizedDescription)
    }

    /// A Check Location fix taken with no current journey is saved but never uploaded.
    func testFixWithoutJourneyIsSavedButNotUploaded() async throws {
        let store = Store.inMemory()
        let manager = makeManager(store: store)

        manager.locationManager(CLLocationManager(), didUpdateLocations: [makeFix(at: .now)])

        let waypoint = try XCTUnwrap(store.waypoints(of: nil).first)
        XCTAssertEqual(waypoint.source, .checkLocation)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(StubURLProtocol.lastRequest)
        XCTAssertEqual(waypoint.syncState, .pending)
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
