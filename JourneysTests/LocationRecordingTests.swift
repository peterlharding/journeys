//
//  LocationRecordingTests.swift
//  JourneysTests
//

import CoreLocation
import XCTest
@testable import Journeys

@MainActor
final class LocationRecordingTests: XCTestCase {

    /// The fixes recorded with no current journey, oldest first.
    private func recorded(by manager: LocationManager) -> [Waypoint] {
        manager.store.waypoints(of: nil)
    }

    private func deliver(_ fix: CLLocation, to manager: LocationManager) {
        manager.locationManager(CLLocationManager(), didUpdateLocations: [fix])
    }

    // MARK: - Check Location

    /// iOS can deliver more than one fix for a single request (17 s apart in the simulator);
    /// one tap of Check Location records exactly one.
    func testCheckLocationRecordsOneFixPerTap() {
        let manager = makeManager()
        let now = Date.now
        let first = makeFix(at: now)

        manager.startCheckLocation()
        deliver(first, to: manager)
        deliver(makeFix(latitude: -33.8689, at: now.addingTimeInterval(17)), to: manager)

        XCTAssertEqual(recorded(by: manager).map(\.recordedAt), [first.timestamp])
    }

    /// Fixes that arrive when nobody asked for one are not recorded.
    func testFixesWithoutATapAreIgnored() {
        let manager = makeManager()

        deliver(makeFix(at: .now), to: manager)

        XCTAssertEqual(recorded(by: manager).count, 0)
    }

    /// A cached fix from before the tap is skipped; the first fresh one is recorded.
    func testCheckLocationSkipsStaleCachedFix() {
        let manager = makeManager()
        let fresh = makeFix(latitude: -33.8700, at: .now)

        manager.startCheckLocation()
        deliver(makeFix(at: .now.addingTimeInterval(-30)), to: manager)
        deliver(fresh, to: manager)

        XCTAssertEqual(recorded(by: manager).map(\.recordedAt), [fresh.timestamp])
    }

    /// When only an older fix arrives (the simulator sends a fixed location once, 13.6 s old in a test run),
    /// it is recorded after a short wait rather than nothing at all.
    func testCheckLocationFallsBackToARecentOlderFix() async {
        let manager = makeManager()
        manager.checkLocationGrace = .milliseconds(100)
        let older = makeFix(at: .now.addingTimeInterval(-14))

        manager.startCheckLocation()
        deliver(older, to: manager)
        XCTAssertEqual(recorded(by: manager).count, 0, "A fresh fix may still come")

        await waitUntil { self.recorded(by: manager).count == 1 }
        XCTAssertEqual(recorded(by: manager).map(\.recordedAt), [older.timestamp])
    }

    /// A fix older than two minutes is not the current location; it is never recorded.
    func testCheckLocationNeverRecordsAVeryOldFix() async throws {
        let manager = makeManager()
        manager.checkLocationGrace = .milliseconds(100)

        manager.startCheckLocation()
        deliver(makeFix(at: .now.addingTimeInterval(-180)), to: manager)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(recorded(by: manager).count, 0)
    }

    /// Each tap records its own fix, with its own identity.
    func testEachTapRecordsItsOwnFix() {
        let manager = makeManager()
        let now = Date.now

        for offset in 0..<3 {
            manager.startCheckLocation()
            deliver(makeFix(latitude: -33.8688 - Double(offset) / 1000, at: now.addingTimeInterval(Double(offset))),
                    to: manager)
        }

        XCTAssertEqual(recorded(by: manager).count, 3)
        XCTAssertEqual(Set(recorded(by: manager).map(\.id)).count, 3)
    }

    /// Two quick taps can be answered with the same cached fix; it is recorded once.
    func testSameFixForTwoTapsIsRecordedOnce() {
        let manager = makeManager()
        let fix = makeFix(at: .now)

        manager.startCheckLocation()
        deliver(fix, to: manager)
        manager.startCheckLocation()
        deliver(fix, to: manager)

        XCTAssertEqual(recorded(by: manager).count, 1)
    }

    // MARK: - Tracker

    /// The first update after Start Tracker can be a cached fix from before tracking started;
    /// it must not become the journey's first waypoint.
    func testTrackerSkipsStaleCachedFix() {
        let manager = makeManager()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        manager.trackerReceived(makeFix(at: now.addingTimeInterval(-24)), now: now)
        XCTAssertEqual(recorded(by: manager).count, 0, "A 24 s old cached fix should be skipped")

        let fresh = makeFix(latitude: -33.8700, at: now.addingTimeInterval(1))
        manager.trackerReceived(fresh, now: now.addingTimeInterval(1))
        XCTAssertEqual(recorded(by: manager).map(\.recordedAt), [fresh.timestamp],
                       "The first fresh fix should be recorded")
    }

    /// After the first fresh fix, the tracker records at most one fix per interval.
    func testTrackerRecordsAtMostOncePerInterval() {
        let manager = makeManager()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = LocationManager.trackingRecordInterval

        for offset in [0, 5, interval - 1, interval, interval + 5, 2 * interval] {
            let time = start.addingTimeInterval(offset)
            manager.trackerReceived(makeFix(latitude: -33.8688 - offset / 10_000, at: time), now: time)
        }

        XCTAssertEqual(recorded(by: manager).map(\.recordedAt),
                       [0, interval, 2 * interval].map { start.addingTimeInterval($0) })
    }

    /// A phone lying still drifts by a metre or so (seen on a device, where iOS never reported it
    /// as stationary); after the first fix nothing more is recorded until it moves.
    func testTrackerIgnoresDriftWhileStill() {
        let manager = makeManager()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // A fix every 30 s for 6 minutes, wandering up to about 1 m.
        for step in 0...12 {
            let time = start.addingTimeInterval(Double(step) * 30)
            let drift = Double(step % 3) * 0.000_005
            manager.trackerReceived(makeFix(latitude: -33.8688 + drift, longitude: 151.2093 - drift, at: time),
                                    now: time)
        }
        XCTAssertEqual(recorded(by: manager).count, 1)

        // Moving 30 m is recorded.
        let moved = start.addingTimeInterval(13 * 30)
        manager.trackerReceived(makeFix(latitude: -33.8688 + 0.000_27, at: moved), now: moved)
        XCTAssertEqual(recorded(by: manager).count, 2)
    }
}
