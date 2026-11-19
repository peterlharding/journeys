//
//  TrackerUITests.swift
//  JourneysUITests
//
//  These tests depend on the simulator's simulated location, which a test cannot set itself.
//  Run them through scripts/run-tests.sh, which sets a moving route for MovingTrackerUITests
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
        let lines = ["\(title): \(recordCount) recorded"] + records.allElementsBoundByIndex.map(\.label)
        let text = lines.joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
        print(text)
    }

    private func allowLocationPermissionIfPrompted() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        // The prompt can take several seconds to appear after launch on a freshly reset simulator.
        if allow.waitForExistence(timeout: 15) {
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

        XCTAssertGreaterThanOrEqual(recordCount - before, minutes,
                                    "Expected one record per minute while in the background")
    }
}

final class StationaryTrackerUITests: TrackerUITestCase {

    /// When the device does not move, nothing is recorded after the first fix.
    func testRecordsNothingMoreWhileStationary() throws {
        startTracker()
        sleep(2 * 60 + 15)
        logRecords("STATIONARY RECORDS")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Stationary after first fix"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertEqual(recordCount, 1)
        XCTAssertEqual(app.staticTexts["recordCount"].label, "1 location recorded")
    }
}

final class JourneyUITests: TrackerUITestCase {

    /// Points the app at an API path that does not exist, so the server rejects every request.
    override func setUp() {
        app.launchEnvironment["API_BASE_URL"] = "https://mongo-api.performiq.com/does-not-exist"
        super.setUp()
    }

    /// A journey the server rejects is not made current, and the sheet stays open with an error.
    func testRejectedJourneyIsNotSaved() throws {
        XCTAssertTrue(app.staticTexts["No current journey"].waitForExistence(timeout: 10))
        app.buttons["New Journey"].tap()

        let name = app.textFields["journeyName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Rejected trip")
        app.buttons["Save"].tap()

        let error = app.staticTexts["saveError"]
        XCTAssertTrue(error.waitForExistence(timeout: 15), "Expected an error message in the sheet")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Journey save rejected"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["No current journey"].waitForExistence(timeout: 5))
    }
}

final class AboutUITests: TrackerUITestCase {

    /// The About sheet shows the app's version and build number (any version, so bumps need no test change).
    func testAboutShowsVersion() throws {
        let about = app.buttons["About"]
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        about.tap()

        // LabeledContent exposes the row as one element labelled "Version, <value>".
        let version = app.staticTexts["aboutVersion"]
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        // "Version, 1.1.0 (1)": the marketing version, then the build number.
        XCTAssertNotNil(version.label.wholeMatch(of: #/Version, \d+\.\d+\.\d+ \(\d+\)/#),
                        "Unexpected version row: \(version.label)")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "About"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["Done"].tap()
        XCTAssertTrue(about.waitForExistence(timeout: 5))
    }
}
