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

    /// Driving at 15 m/s with a fix every second: one record a minute. Each record waits for the
    /// next fix to confirm the movement, so it comes a second after the minute.
    func testTrackerRecordsOncePerMinuteWhileDriving() {
        let manager = makeManager()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for second in 0...185 {
            let time = start.addingTimeInterval(Double(second))
            // 15 m/s north; about 111,320 m per degree of latitude.
            let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: -33.8688 + Double(second) * 15 / 111_320,
                                                                   longitude: 151.2093),
                                 altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: time)
            manager.trackerReceived(fix, now: time)
        }

        XCTAssertEqual(recorded(by: manager).map { $0.recordedAt.timeIntervalSince(start) }, [0, 61, 122, 183])
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

        // Moving 30 m is recorded, once the next fix confirms it.
        for second in [390.0, 391.0] {
            let time = start.addingTimeInterval(second)
            manager.trackerReceived(makeFix(latitude: -33.8688 + 0.000_27, at: time), now: time)
        }
        XCTAssertEqual(recorded(by: manager).count, 2)
    }

    /// An hour stopped indoors at a club, replayed from what an iPhone recorded on 2026-11-19
    /// (time in seconds, latitude, longitude, accuracy in metres). Indoor fixes jumped 25 to 36 m,
    /// and once 160 m, so the old 25 m rule recorded 12 times; the stop should give one record.
    /// Between these the phone sent fixes every few seconds near the middle of the stop.
    func testTrackerIgnoresIndoorDrift() {
        let manager = makeManager()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        struct Logged {
            let seconds: TimeInterval, latitude: Double, longitude: Double, accuracy: Double
        }
        let logged = [
            Logged(seconds: 0, latitude: -35.352917, longitude: 149.236531, accuracy: 19.2),
            Logged(seconds: 108, latitude: -35.352743, longitude: 149.236707, accuracy: 11.9),
            Logged(seconds: 1079, latitude: -35.352775, longitude: 149.236425, accuracy: 13.7),
            Logged(seconds: 1709, latitude: -35.352711, longitude: 149.236693, accuracy: 13.8),
            Logged(seconds: 1769, latitude: -35.352844, longitude: 149.234937, accuracy: 9.6),
            Logged(seconds: 2013, latitude: -35.352735, longitude: 149.236681, accuracy: 9.8),
            Logged(seconds: 2412, latitude: -35.352755, longitude: 149.236401, accuracy: 16.5),
            Logged(seconds: 2651, latitude: -35.352756, longitude: 149.236683, accuracy: 19.7),
            Logged(seconds: 3255, latitude: -35.352834, longitude: 149.236952, accuracy: 5.2),
            Logged(seconds: 3395, latitude: -35.352715, longitude: 149.236691, accuracy: 14.1),
            Logged(seconds: 3675, latitude: -35.352974, longitude: 149.236452, accuracy: 19.1)
        ]
        func deliver(_ fix: Logged) {
            let time = start.addingTimeInterval(fix.seconds)
            let coordinate = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
            let location = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: fix.accuracy,
                                      verticalAccuracy: -1, timestamp: time)
            manager.trackerReceived(location, now: time)
        }

        for fix in logged {
            deliver(fix)
            deliver(Logged(seconds: fix.seconds + 3, latitude: -35.352756, longitude: 149.236683, accuracy: 15))
        }

        XCTAssertEqual(recorded(by: manager).count, 1)
    }

    /// One wild fix (160 m away, then straight back) is not movement.
    func testTrackerIgnoresASingleWildFix() {
        let manager = makeManager()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for (second, longitude) in [(0.0, 149.236531), (70, 149.234737), (73, 149.236531), (200, 149.236540)] {
            let time = start.addingTimeInterval(second)
            manager.trackerReceived(makeFix(latitude: -35.352917, longitude: longitude, at: time), now: time)
        }

        XCTAssertEqual(recorded(by: manager).count, 1)
    }

    // MARK: - Motion sensors

    /// Walking back and forth between two spots 30 m apart indoors (restaurant and bar), crossing every
    /// 65 s, with 16 m accuracy; each crossing is followed by a second fix that confirms it.
    private func walkIndoors(_ manager: LocationManager, crossings: Int) {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for crossing in 0...crossings {
            let latitude = -35.352917 + Double(crossing % 2) * 30 / 111_320
            for second in [0.0, 2.0] {
                let time = start.addingTimeInterval(Double(crossing) * 65 + second)
                let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 149.236531),
                                     altitude: 0, horizontalAccuracy: 16, verticalAccuracy: -1, timestamp: time)
                manager.trackerReceived(fix, now: time)
            }
        }
    }

    /// Walking across a large building (entrance, restaurant, bar): the motion sensors say the user is
    /// on foot, so 30 m moves count even though indoor accuracy alone would call them drift.
    func testWalkingIndoorsIsRecorded() {
        let manager = makeManager(motion: FakeMotion(.onFoot))

        walkIndoors(manager, crossings: 3)

        XCTAssertEqual(recorded(by: manager).count, 4)
    }

    /// The same moves without motion data (no permission, or none available) are under twice the
    /// accuracy (32 m), so they look like drift.
    func testWithoutMotionDataIndoorMovesNeedTwiceTheAccuracy() {
        let manager = makeManager(motion: FakeMotion(.unknown))

        walkIndoors(manager, crossings: 3)

        XCTAssertEqual(recorded(by: manager).count, 1)
    }

    /// While the motion sensors say the user is still, nothing is recorded, not even a confirmed jump.
    func testNothingIsRecordedWhileStationary() {
        let motion = FakeMotion(.onFoot)
        let manager = makeManager(motion: motion)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        manager.trackerReceived(makeFix(latitude: -35.352917, at: start), now: start)
        motion.state = .stationary

        for second in [70.0, 72.0, 140.0, 142.0] {
            let time = start.addingTimeInterval(second)
            manager.trackerReceived(makeFix(latitude: -35.354, at: time), now: time)
        }
        XCTAssertEqual(recorded(by: manager).count, 1)

        // Moving again: the same fixes are recorded.
        motion.state = .onFoot
        for second in [210.0, 212.0] {
            let time = start.addingTimeInterval(second)
            manager.trackerReceived(makeFix(latitude: -35.354, at: time), now: time)
        }
        XCTAssertEqual(recorded(by: manager).count, 2)
    }

    /// In a vehicle the accuracy-based rule still applies: being in a car says nothing about indoor drift.
    func testInAVehicleIndoorMovesNeedTwiceTheAccuracy() {
        let manager = makeManager(motion: FakeMotion(.vehicle))

        walkIndoors(manager, crossings: 3)

        XCTAssertEqual(recorded(by: manager).count, 1)
    }
}
