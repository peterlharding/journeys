# Journeys

A SwiftUI iOS app that records named journeys, keeps them and their waypoints in an on-device Core Data store, and uploads them in batches to the PerformIQ Mongo API's `POST /sync` (`https://mongo-api.performiq.com`, contract in mongo-api's `doc/SYNC.md`), automatically on Wi-Fi.
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
* `Journeys/JourneysApp.swift` - app entry point: `RootView` injects the services, syncs when the app becomes active and schedules the refresh task when it goes to the background; inert when hosting unit tests (so they never upload)
* `Journeys/AppServices.swift` - `AppServices` (store, uploader, sync engine, location manager, created at launch including background launches; the `BGAppRefreshTask` backstop) and `AppDelegate` (registers the task, hands background-session wake-ups to the uploader)
* `Journeys/BackgroundUploader.swift` - `SyncUploading` and its background `URLSession` implementation: iOS uploads on Wi-Fi even while the app is suspended, then wakes it with the answer
* `Journeys/ContentView.swift` - main screen: About (info) button, current journey, New Journey, Check Location and Start/Stop Tracker buttons, Journeys and About buttons, `SyncStatusView` (what is waiting, Sync now); `RecordedLocationsView` shows the current journey's waypoints (or fixes with no journey) from the store
* `Journeys/Store.swift` - Core Data stack (`Store`), the `Journey` and `Waypoint` model classes and `SyncState`; `Journeys.xcdatamodeld` is the versioned model (add a new model version for any schema change)
* `Journeys/AboutView.swift` - About sheet: app name, version and build, API host
* `Journeys/JourneysView.swift` - Journeys screen: journeys newest first with waypoint count and sync state; a journey opens to its waypoints, with any rejection reason
* `Journeys/NewJourneyModal.swift` - sheet to create a journey; it is saved and becomes current at once, online or not
* `Journeys/SyncEngine.swift` - uploads pending journeys and waypoints to `POST /sync`, oldest first, up to 500 per batch; marks each record from the server's answer; automatic syncs are handed to the `SyncUploading` (Wi-Fi only, even while suspended), one batch at a time, each answer queueing the next; failures retry with backoff (30 s doubling to 30 min) through the upload's start delay; opening the app retries at once; Sync now uploads in the foreground on any network. `SyncEngine+Records.swift` builds batches and records answers on background contexts
* `Journeys/SyncPayload.swift` - the `/sync` request and response; `Journeys/NetworkMonitor.swift` - `NWPathMonitor` behind `NetworkStatusProviding`, so tests can fake the network
* `Journeys/APIClient.swift` - JSON POSTs to the API; only 2xx counts as success and redirects are refused; two sessions, one that iOS keeps off mobile data and Low Data Mode (automatic sync) and one for any network; `API_BASE_URL` in the environment overrides the base URL
* `Journeys/LocationManager.swift` - location state; tracking via `CLLocationUpdate.liveUpdates` plus a `CLBackgroundActivitySession`, one-off fixes via `CLLocationManager`; saves each recorded fix as a `Waypoint` and tells the `SyncEngine`; a Check Location tap records exactly one fix (the first fresh one, else after 5 s the newest under 2 minutes old) using continuous updates that stop once it is recorded; remembers the current journey by id in `UserDefaults` (key `currentJourneyID`) and imports the JSON `currentJourney` saved by versions before 1.2.0
* `Journeys/JourneyData.swift` - the JSON current journey saved by versions before 1.2.0, decoded once on upgrade
* `JourneysTests/` - unit tests (hosted in the app, `@testable import Journeys`); `TestSupport.swift` gives each test an in-memory store, a stubbed API (`StubURLProtocol`), a `FakeNetwork`, a `FakeUploader` (stands in for iOS's transfer service), a `FakeSyncServer` and its own `UserDefaults`
* `JourneysUITests/` - XCUITest tests: the tracker, grouped by the simulated location they need (moving or stationary), offline journey creation, records surviving a relaunch, offline records syncing to the mock server (through the real background session), the Journeys screen, and the About sheet; UI tests point `API_BASE_URL` at an unreachable local port unless a test sets it, so they never upload to the real API
* `scripts/run-tests.sh` - runs the unit tests, then each UI test class with the simulated location it needs, with `scripts/mock_sync_server.py` (an in-memory `/sync`) on port 8765
* `Journeys/Info.plist` - background modes (`location`, `fetch`), `BGTaskSchedulerPermittedIdentifiers` (the refresh task) and `NSAllowsLocalNetworking` (plain HTTP to local addresses, for the mock server); the location usage strings live in the build settings as `INFOPLIST_KEY_*`

## Conventions

* iOS 18.0 deployment target, iPhone and iPad, Swift 5 language mode, bundle id `com.performiq.Journeys`.
* The version is set once, at project level: `MARKETING_VERSION` (semantic, e.g. 1.4.0) and `CURRENT_PROJECT_VERSION` (build number); targets inherit them, and the About sheet and its UI test show them.
* Tracking records at most once per `LocationManager.trackingRecordInterval` (60 s), only after moving `minTrackedDistance` (25 m, or the fix's accuracy if larger) from the last recorded fix, and skips cached fixes older than `maxTrackedFixAge` (10 s).
  On a device iOS does not reliably report a still phone as stationary, so the distance check is what stops a still phone recording.
* Timestamps are sent as ISO 8601 with fractional seconds; `journeyId` is the journey's UUID string.
* Everything recorded is saved to the store before any upload; a waypoint's `syncState` says whether the API has it (pending, synced, rejected).
  The UI and `LocationManager` use the store's main-actor `viewContext`; the `SyncEngine` reads and writes on its own background contexts.

## Gotchas

* API requests currently carry no authentication; the old Basic Auth was removed and JWT login (access + refresh tokens) is planned; a 401 will need handling in `SyncEngine`.
  Never put credentials or tokens in source; tokens belong in the Keychain.
* Background tracking needs only "While Using" authorization because of the background activity session; iOS shows the location indicator while it runs.
  Simulator tests cover it, but real background behaviour (suspension, energy) should still be checked on a device.
* UI tests depend on the simulator's simulated location, which a test cannot set itself, so run them through `scripts/run-tests.sh` rather than plain `xcodebuild test`.
  A fixed simulated location keeps the timestamp it was set with and is delivered once, so the script sets it afresh before each class that uses Check Location (which ignores fixes over 2 minutes old).
* Background uploads survive the app being suspended or terminated by the system, but a user force-quitting it cancels them; they are queued again when it next opens.
* SourceKit needs `buildServer.json` (machine-specific, gitignored) to know this is an iOS project; without it, it checks files as standalone macOS code and reports false errors such as "unavailable in macOS" or "Cannot find 'LocationManager' in scope".
  Create it with `xcode-build-server config -project Journeys.xcodeproj -scheme Journeys` after one `xcodebuild ... build` into the default DerivedData, and trust the `xcodebuild` output over SourceKit.
