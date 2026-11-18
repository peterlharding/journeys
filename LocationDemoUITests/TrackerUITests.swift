//
//  TrackerUITests.swift
//  LocationDemoUITests
//
//  These tests depend on the simulator's simulated location, which a test cannot set itself.
//  Run them through scripts/run-ui-tests.sh, which sets a moving route for MovingTrackerUITests
//  and a fixed location for StationaryTrackerUITests.
//

import XCTest

class TrackerUITestCase: XCTestCase {
    let app = XCUIApplication()

    /// Visible list rows; the list is lazy, so rows scrolled off screen are not included.
    var records: XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Timestamp:'"))
    }

    /// Number of recorded locations, read from the "N locations recorded" label.
    var recordCount: Int {
        let label = app.staticTexts["recordCount"].label
        return Int(label.prefix(while: \.isNumber)) ?? -1
    }

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        allowLocationPermissionIfPrompted()
    }

    func startTracker() {
        let startButton = app.buttons["Start Tracker"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()
        XCTAssertTrue(app.buttons["Stop Tracker"].waitForExistence(timeout: 5))
    }

    func logRecords(_ title: String) {
        let text = (["\(title): \(recordCount) recorded"] + records.allElementsBoundByIndex.map(\.label)).joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
        print(text)
    }

    private func allowLocationPermissionIfPrompted() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }
    }
}

final class MovingTrackerUITests: TrackerUITestCase {

    /// While moving, the tracker records the first fix and then one location per minute.
    func testRecordsOneLocationPerMinuteWhileMoving() throws {
        startTracker()
        let minutes = 3
        sleep(UInt32(minutes * 60 + 15))
        logRecords("FOREGROUND RECORDS")

        XCTAssertGreaterThanOrEqual(recordCount, minutes)
        XCTAssertLessThanOrEqual(recordCount, minutes + 1)
    }

    /// The tracker keeps recording while the app is in the background.
    func testKeepsRecordingInBackground() throws {
        startTracker()
        XCTAssertTrue(records.firstMatch.waitForExistence(timeout: 15))
        let before = recordCount

        XCUIDevice.shared.press(.home)
        let minutes = 3
        sleep(UInt32(minutes * 60 + 15))
        app.activate()
        XCTAssertTrue(app.buttons["Stop Tracker"].waitForExistence(timeout: 10))
        logRecords("BACKGROUND RECORDS (before backgrounding: \(before))")

        XCTAssertGreaterThanOrEqual(recordCount - before, minutes, "Expected one record per minute while in the background")
    }
}

final class StationaryTrackerUITests: TrackerUITestCase {

    /// When the device does not move, nothing is recorded after the first fix.
    func testRecordsNothingMoreWhileStationary() throws {
        startTracker()
        sleep(2 * 60 + 15)
        logRecords("STATIONARY RECORDS")

        XCTAssertLessThanOrEqual(recordCount, 1)
    }
}
