//
//  StoreTests.swift
//  JourneysTests
//

import CoreData
import CoreLocation
import XCTest
@testable import Journeys

@MainActor
final class StoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "StoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Journeys and waypoints written to disk are all there after the database is reopened,
    /// as after the app is relaunched.
    func testDataSurvivesReopening() throws {
        let url = directory.appending(path: "Journeys.sqlite")
        let journeyID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        do {
            let store = Store(url: url)
            let journey = store.addJourney(id: journeyID, name: "Commute", notes: "Bus", syncState: .synced)
            store.addWaypoint(makeFix(at: start), source: .tracker, journey: journey)
            store.addWaypoint(makeFix(latitude: -33.87, at: start.addingTimeInterval(60)), source: .tracker,
                              journey: journey)
            store.addWaypoint(makeFix(at: start.addingTimeInterval(5)), source: .checkLocation, journey: nil)
            try store.container.persistentStoreCoordinator.persistentStores.forEach {
                try store.container.persistentStoreCoordinator.remove($0)
            }
        }

        let reopened = Store(url: url)
        let journey = try XCTUnwrap(reopened.journey(id: journeyID))
        XCTAssertEqual(journey.name, "Commute")
        XCTAssertEqual(journey.notes, "Bus")
        XCTAssertEqual(journey.syncState, .synced)
        XCTAssertEqual(reopened.waypoints(of: journey).map(\.recordedAt),
                       [start, start.addingTimeInterval(60)])
        XCTAssertEqual(reopened.waypoints(of: nil).map(\.source), [.checkLocation])
    }

    /// A waypoint keeps everything needed to upload it later.
    func testWaypointKeepsTheFix() throws {
        let store = Store.inMemory()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: -35.3227, longitude: 149.1748),
                             altitude: 600, horizontalAccuracy: 8, verticalAccuracy: 4,
                             course: 90, speed: 1.5, timestamp: time)

        let waypoint = store.addWaypoint(fix, source: .tracker, journey: nil)

        XCTAssertEqual(waypoint.latitude, -35.3227)
        XCTAssertEqual(waypoint.longitude, 149.1748)
        XCTAssertEqual(waypoint.horizontalAccuracy, 8)
        XCTAssertEqual(waypoint.course, 90)
        XCTAssertEqual(waypoint.speed, 1.5)
        XCTAssertEqual(waypoint.recordedAt, time)
        XCTAssertEqual(waypoint.syncState, .pending)
        XCTAssertNil(waypoint.syncedAt)
    }

    /// A journey's id is unique: saving the same id again updates the one journey.
    func testJourneyIDIsUnique() {
        let store = Store.inMemory()
        let id = UUID()

        store.addJourney(id: id, name: "First", notes: "", syncState: .pending)
        store.addJourney(id: id, name: "Second", notes: "", syncState: .pending)

        let journeys = (try? store.viewContext.fetch(Journey.fetchRequest())) ?? []
        XCTAssertEqual(journeys.count, 1)
        XCTAssertEqual(store.journey(id: id)?.name, "Second")
    }

    /// Each journey's list shows only its own waypoints.
    func testWaypointsAreListedPerJourney() {
        let store = Store.inMemory()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let first = store.addJourney(name: "First", notes: "", syncState: .synced)
        let second = store.addJourney(name: "Second", notes: "", syncState: .synced)

        store.addWaypoint(makeFix(at: time), source: .tracker, journey: first)
        store.addWaypoint(makeFix(at: time.addingTimeInterval(60)), source: .tracker, journey: second)
        store.addWaypoint(makeFix(at: time.addingTimeInterval(120)), source: .tracker, journey: first)

        XCTAssertEqual(store.waypoints(of: first).count, 2)
        XCTAssertEqual(store.waypoints(of: second).count, 1)
        XCTAssertEqual(store.waypoints(of: nil).count, 0)
    }
}
