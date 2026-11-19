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
}
