//
//  LocationRecordingTests.swift
//  LocationDemoTests
//

import CoreLocation
import XCTest
@testable import LocationDemo

@MainActor
final class LocationRecordingTests: XCTestCase {

    private func makeFix(latitude: Double = -33.8688, longitude: Double = 151.2093, at time: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                   altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: time)
    }

    private func deliver(_ fix: CLLocation, to manager: LocationManager) {
        manager.locationManager(CLLocationManager(), didUpdateLocations: [fix])
    }

    /// Core Location can hand back the same cached fix again (e.g. two quick "Check Location" taps).
    /// It must only be recorded (and posted) once.
    func testSameFixDeliveredTwiceIsRecordedOnce() {
        let manager = LocationManager()
        let fix = makeFix(at: Date(timeIntervalSince1970: 1_800_000_000))

        deliver(fix, to: manager)
        deliver(fix, to: manager)

        XCTAssertEqual(manager.locations.count, 1)
    }

    /// Distinct fixes are all recorded, even if they share a timestamp, and each has its own identity.
    func testDistinctFixesAreAllRecordedWithUniqueIDs() {
        let manager = LocationManager()
        let time = Date(timeIntervalSince1970: 1_800_000_000)

        deliver(makeFix(at: time), to: manager)
        deliver(makeFix(latitude: -33.8700, at: time), to: manager)
        deliver(makeFix(at: time.addingTimeInterval(1)), to: manager)

        XCTAssertEqual(manager.locations.count, 3)
        XCTAssertEqual(Set(manager.locations.map(\.id)).count, 3)
    }

    // MARK: - Tracker

    /// The first update after Start Tracker can be a cached fix from before tracking started;
    /// it must not become the journey's first waypoint.
    func testTrackerSkipsStaleCachedFix() {
        let manager = LocationManager()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        manager.trackerReceived(makeFix(at: now.addingTimeInterval(-24)), now: now)
        XCTAssertEqual(manager.locations.count, 0, "A 24 s old cached fix should be skipped")

        let fresh = makeFix(latitude: -33.8700, at: now.addingTimeInterval(1))
        manager.trackerReceived(fresh, now: now.addingTimeInterval(1))
        XCTAssertEqual(manager.locations.map(\.location), [fresh], "The first fresh fix should be recorded")
    }

    /// After the first fresh fix, the tracker records at most one fix per interval.
    func testTrackerRecordsAtMostOncePerInterval() {
        let manager = LocationManager()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = LocationManager.trackingRecordInterval

        for offset in [0, 5, interval - 1, interval, interval + 5, 2 * interval] {
            let time = start.addingTimeInterval(offset)
            manager.trackerReceived(makeFix(latitude: -33.8688 - offset / 10_000, at: time), now: time)
        }

        XCTAssertEqual(manager.locations.map(\.location.timestamp),
                       [0, interval, 2 * interval].map { start.addingTimeInterval($0) })
    }

    /// A phone lying still drifts by a metre or so (seen on a device, where iOS never reported it
    /// as stationary); after the first fix nothing more is recorded until it moves.
    func testTrackerIgnoresDriftWhileStill() {
        let manager = LocationManager()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // A fix every 30 s for 6 minutes, wandering up to about 1 m.
        for step in 0...12 {
            let time = start.addingTimeInterval(Double(step) * 30)
            let drift = Double(step % 3) * 0.000_005
            manager.trackerReceived(makeFix(latitude: -33.8688 + drift, longitude: 151.2093 - drift, at: time),
                                    now: time)
        }
        XCTAssertEqual(manager.locations.count, 1)

        // Moving 30 m is recorded.
        let moved = start.addingTimeInterval(13 * 30)
        manager.trackerReceived(makeFix(latitude: -33.8688 + 0.000_27, at: moved), now: moved)
        XCTAssertEqual(manager.locations.count, 2)
    }
}
