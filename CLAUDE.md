# Journeys

A SwiftUI iOS app that records named journeys, keeps them and their waypoints in an on-device Core Data store, and uploads them to the PerformIQ Mongo API (`https://mongo-api.performiq.com`).
iPhone and iPad only (never macOS, tvOS or visionOS); an app target, a unit test target and a UI test target, no external dependencies.
Formerly LocationDemo (renamed 2026-11-19, history kept); the old github.com/peterlharding/LocationDemo repo is retired.

## Commands

* Build (simulator): `xcodebuild -project Journeys.xcodeproj -scheme Journeys -destination 'generic/platform=iOS Simulator' build`
* Lint: `swiftlint lint --quiet Journeys JourneysTests JourneysUITests` (no `.swiftlint.yml` yet, so default rules apply; it currently reports no warnings)
* All tests: `scripts/run-tests.sh [simulator-udid]` (about 10 minutes; unit tests first, then UI tests, which wait in real time)
* Unit tests only: `xcodebuild test -project Journeys.xcodeproj -scheme Journeys -destination 'id=<simulator-udid>' -only-testing:JourneysTests` (seconds)
* List simulators: `xcrun simctl list devices available`

## Layout

* `docs/BACKLOG.md` - known issues and work not yet started
* `docs/OFFLINE_SYNC.md` - plan for the local store and Wi-Fi sync (phases 1 to 4)
* `Journeys.xcodeproj/` - Xcode project: app, unit test and UI test targets, and one shared scheme named `Journeys`
* `Journeys/JourneysApp.swift` - app entry point, shows `ContentView`
* `Journeys/ContentView.swift` - main screen: About (info) button, current journey, New Journey, Check Location and Start/Stop Tracker buttons; `RecordedLocationsView` shows the current journey's waypoints (or fixes with no journey) from the store
* `Journeys/Store.swift` - Core Data stack (`Store`), the `Journey` and `Waypoint` model classes and `SyncState`; `Journeys.xcdatamodeld` is the versioned model (add a new model version for any schema change)
* `Journeys/AboutView.swift` - About sheet: app name, version and build, API host
* `Journeys/NewJourneyModal.swift` - sheet to create a journey; it becomes current only after `/journeys` accepts it, otherwise the sheet shows the error
* `Journeys/APIClient.swift` - JSON POSTs to the API; only 2xx counts as success and redirects are refused (the API's NGINX turns errors into a 302 to an HTML page); `API_BASE_URL` in the environment overrides the base URL
* `Journeys/LocationManager.swift` - location state; tracking via `CLLocationUpdate.liveUpdates` plus a `CLBackgroundActivitySession`, one-off fixes via `CLLocationManager`; saves each recorded fix as a `Waypoint`, POSTs it once to `/waypoints` and records the outcome; remembers the current journey by id in `UserDefaults` (key `currentJourneyID`) and imports the JSON `currentJourney` saved by versions before 1.2.0
* `Journeys/JourneyData.swift`, `LocationData.swift` - `Codable` payloads sent to the API
* `JourneysTests/` - unit tests (hosted in the app, `@testable import Journeys`); `TestSupport.swift` gives each test an in-memory store, a stubbed API and its own `UserDefaults`
* `JourneysUITests/` - XCUITest tests: the tracker, grouped by the simulated location they need (moving or stationary), journey creation against a failing API path, records surviving a relaunch, and the About sheet
* `scripts/run-tests.sh` - runs the unit tests, then each UI test class with the simulated location it needs
* `Journeys/Info.plist` - background modes (`location`, `processing`, `external-accessory`); the location usage strings live in the build settings as `INFOPLIST_KEY_*`

## Conventions

* iOS 18.0 deployment target, iPhone and iPad, Swift 5 language mode, bundle id `com.performiq.Journeys`.
* The version is set once, at project level: `MARKETING_VERSION` (semantic, e.g. 1.2.0) and `CURRENT_PROJECT_VERSION` (build number); targets inherit them, and the About sheet and its UI test show them.
* Tracking records at most once per `LocationManager.trackingRecordInterval` (60 s), only after moving `minTrackedDistance` (25 m, or the fix's accuracy if larger) from the last recorded fix, and skips cached fixes older than `maxTrackedFixAge` (10 s).
  On a device iOS does not reliably report a still phone as stationary, so the distance check is what stops a still phone recording.
* Timestamps are sent as ISO 8601 with fractional seconds; `journeyId` is the journey's UUID string.
* Everything recorded is saved to the store before any upload; a waypoint's `syncState` says whether the API has it (pending, synced, rejected).
  The UI and `LocationManager` use the store's main-actor `viewContext`; background work (the phase 3 sync engine) should use its own background context.

## Gotchas

* API requests currently carry no authentication; the old Basic Auth was removed and JWT login (access + refresh tokens) is planned.
  Never put credentials or tokens in source; tokens belong in the Keychain.
* Background tracking needs only "While Using" authorization because of the background activity session; iOS shows the location indicator while it runs.
  Simulator tests cover it, but real background behaviour (suspension, energy) should still be checked on a device.
* UI tests depend on the simulator's simulated location, which a test cannot set itself, so run them through `scripts/run-tests.sh` rather than plain `xcodebuild test`.
* SourceKit needs `buildServer.json` (machine-specific, gitignored) to know this is an iOS project; without it, it checks files as standalone macOS code and reports false errors such as "unavailable in macOS" or "Cannot find 'LocationManager' in scope".
  Create it with `xcode-build-server config -project Journeys.xcodeproj -scheme Journeys` after one `xcodebuild ... build` into the default DerivedData, and trust the `xcodebuild` output over SourceKit.
