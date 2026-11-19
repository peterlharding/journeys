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

    /// Where nothing listens: UI tests never upload to the real API unless a test points the app elsewhere.
    static let unreachableAPI = "http://127.0.0.1:9"

    override func setUp() {
        continueAfterFailure = false
        if app.launchEnvironment["API_BASE_URL"] == nil {
            app.launchEnvironment["API_BASE_URL"] = Self.unreachableAPI
        }
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

    func createJourney(named name: String) {
        app.buttons["New Journey"].tap()
        let field = app.textFields["journeyName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["Save"].tap()
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
    /// Records persist across launches, so only the ones added during this test are counted.
    func testRecordsOneLocationPerMinuteWhileMoving() throws {
        XCTAssertTrue(app.staticTexts["recordCount"].waitForExistence(timeout: 10))
        let before = recordCount
        startTracker()
        let minutes = 3
        sleep(UInt32(minutes * 60 + 15))
        logRecords("FOREGROUND RECORDS (before: \(before))")

        XCTAssertGreaterThanOrEqual(recordCount - before, minutes)
        XCTAssertLessThanOrEqual(recordCount - before, minutes + 1)
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

    /// With the API unreachable, a new journey is still saved and becomes current at once,
    /// and the status line says it is waiting to upload.
    func testJourneyIsCreatedOffline() throws {
        XCTAssertTrue(app.staticTexts["No current journey"].waitForExistence(timeout: 10))
        createJourney(named: "Offline trip")

        XCTAssertTrue(app.staticTexts["Current Journey: Offline trip"].waitForExistence(timeout: 5))
        let status = app.staticTexts["syncStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "1 journey waiting")
        XCTAssertTrue(app.buttons["Sync now"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Journey created offline"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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

final class PersistenceUITests: TrackerUITestCase {

    /// Recorded locations are kept on the phone: after the app is quit and relaunched they are still listed.
    func testRecordedLocationSurvivesRelaunch() throws {
        let checkLocation = app.buttons["Check Location"]
        XCTAssertTrue(checkLocation.waitForExistence(timeout: 10))
        checkLocation.tap()
        XCTAssertTrue(records.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(recordCount, 1)
        let recorded = records.firstMatch.label

        app.terminate()
        app.launch()

        XCTAssertTrue(records.firstMatch.waitForExistence(timeout: 10), "Expected the record after relaunch")
        XCTAssertEqual(recordCount, 1)
        XCTAssertEqual(records.firstMatch.label, recorded)
        XCTAssertFalse(app.staticTexts["No location yet"].exists, "The header should show the latest record")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "After relaunch"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

/// Records offline, then relaunches against the mock /sync server (scripts/mock_sync_server.py,
/// started by scripts/run-tests.sh) and checks everything is uploaded once.
final class SyncUITests: TrackerUITestCase {
    static let mockAPI = URL(string: "http://127.0.0.1:8765")!

    override func setUp() {
        mock("POST", "reset")
        super.setUp()
    }

    func testRecordsMadeOfflineAreUploadedWhenTheServerIsReachable() throws {
        createJourney(named: "Synced trip")
        XCTAssertTrue(app.staticTexts["Current Journey: Synced trip"].waitForExistence(timeout: 5))
        app.buttons["Check Location"].tap()
        XCTAssertTrue(records.firstMatch.waitForExistence(timeout: 15))

        let status = app.staticTexts["syncStatus"]
        XCTAssertTrue(waitForLabel(of: status, toBe: "1 journey and 1 waypoint waiting", timeout: 15),
                      "Got \(status.label)")
        XCTAssertEqual(mockState()["requests"] as? Int, 0)

        // Relaunch with the server reachable: the app uploads on becoming active.
        app.terminate()
        app.launchEnvironment["API_BASE_URL"] = Self.mockAPI.absoluteString
        app.launch()

        XCTAssertTrue(waitForLabel(of: app.staticTexts["syncStatus"], toBe: "All synced", timeout: 20),
                      "Got \(app.staticTexts["syncStatus"].label)")
        let state = mockState()
        XCTAssertEqual((state["journeys"] as? [String])?.count, 1)
        XCTAssertEqual((state["waypoints"] as? [String])?.count, 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "All synced"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func waitForLabel(of element: XCUIElement, toBe label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                              timeout: timeout) == .completed
    }

    private func mockState() -> [String: Any] {
        let data = mock("GET", "state")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @discardableResult
    private func mock(_ method: String, _ path: String) -> Data {
        var request = URLRequest(url: Self.mockAPI.appending(path: path))
        request.httpMethod = method
        var result = Data()
        let done = expectation(description: "\(method) /\(path)")
        URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error, "Is the mock server running? \(String(describing: error))")
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            result = data ?? Data()
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return result
    }
}
