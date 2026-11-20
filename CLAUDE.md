# Journeys

A SwiftUI iOS app that records named journeys, keeps them and their waypoints in an on-device Core Data store, and uploads them in batches, as the signed-in user, to the PerformIQ API's `POST /api/v1/journeys/sync` (fastapi-api, `https://fast-api.performiq.com`; earlier versions used mongo-api's `POST /sync`), automatically on Wi-Fi.
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
* `Journeys/AboutView.swift` - About sheet: app name, version and build, API host, and who is signed in (Sign In, or Sign Out after a confirmation)
* `Journeys/AuthService.swift` - signing in to fastapi-api: `signIn` (`/api/v1/auth/authenticate`), `accessToken()` (the 15-minute access token, kept in memory, refreshed through `/api/v1/auth/refresh-token` a minute before it expires, one refresh at a time because each spends the rotating refresh token), `signOut` (`/api/v1/auth/logout`); a refused refresh token signs out; `AccessTokenProviding` is what the `SyncEngine` sees
* `Journeys/Keychain.swift` - `CredentialStoring` and its Keychain implementation; the sign-in (username and refresh token, never the password) is one item readable after first unlock, this device only, so background uploads can refresh while the phone is locked
* `Journeys/SignInView.swift` - the Sign In sheet, opened from the status line's Sign In button or the About sheet
* `Journeys/JourneysView.swift` - Journeys screen: journeys newest first with waypoint count and sync state; a journey opens to its waypoints, with any rejection reason
* `Journeys/NewJourneyModal.swift` - sheet to create a journey; it is saved and becomes current at once, online or not
* `Journeys/SyncEngine.swift` - uploads pending journeys and waypoints to the sync endpoint with the access token, oldest first, up to 500 per batch; marks each record from the server's answer; automatic syncs are handed to the `SyncUploading` (Wi-Fi only, even while suspended), one batch at a time, each answer queueing the next; failures retry with backoff (30 s doubling to 30 min) through the upload's start delay; opening the app retries at once; Sync now uploads in the foreground on any network; signed out, nothing uploads and the status is `.signedOut`; a 401 (a token that expired while an upload waited for Wi-Fi) gets a fresh token and sends the batch again at once, and a second 401 in a row counts as a failure; Sync now retries a 401 once. `SyncEngine+Records.swift` builds batches and records answers on background contexts
* `Journeys/MotionMonitor.swift` - `CMMotionActivityManager` behind `MotionStateProviding` (stationary, on foot, vehicle, unknown), read only while tracking; `NSMotionUsageDescription` is in the build settings
* `Journeys/SyncPayload.swift` - the sync request and response; `Journeys/NetworkMonitor.swift` - `NWPathMonitor` behind `NetworkStatusProviding`, so tests can fake the network
* `Journeys/APIClient.swift` - JSON POSTs to the API (`APIClient.Path` lists the endpoints), with an optional bearer token; `post` counts only 2xx as success and `send` returns any status (for signing in); redirects are refused; two sessions, one that iOS keeps off mobile data and Low Data Mode (automatic sync) and one for any network; `API_BASE_URL` in the environment overrides the base URL
* `Journeys/LocationManager.swift` - location state; tracking via `CLLocationUpdate.liveUpdates` plus a `CLBackgroundActivitySession`, one-off fixes via `CLLocationManager`; saves each recorded fix as a `Waypoint` and tells the `SyncEngine`; a Check Location tap records exactly one fix (the first fresh one, else after 5 s the newest under 2 minutes old) using continuous updates that stop once it is recorded; remembers the current journey by id in `UserDefaults` (key `currentJourneyID`) and imports the JSON `currentJourney` saved by versions before 1.2.0
* `Journeys/JourneyData.swift` - the JSON current journey saved by versions before 1.2.0, decoded once on upgrade
* `JourneysTests/` - unit tests (hosted in the app, `@testable import Journeys`); `TestSupport.swift` gives each test an in-memory store, a stubbed API (`StubURLProtocol`), a `FakeNetwork`, a `FakeUploader` (stands in for iOS's transfer service), a `FakeMotion` (unknown unless a test sets it), a `FakeAuth` (signed in with `token-1`; each refresh hands out the next), a `FakeSyncServer` and its own `UserDefaults`; `AuthServiceTests.swift` has `MemoryCredentials` and a `FakeAuthServer`
* `JourneysUITests/` - XCUITest tests: the tracker, grouped by the simulated location they need (moving or stationary), offline journey creation, records surviving a relaunch, offline records waiting while signed out, then syncing to the mock server after signing in through the sheet (through the real background session), the Journeys screen, and the About sheet; UI tests point `API_BASE_URL` at an unreachable local port unless a test sets it, so they never upload to the real API, and launch with `RESET_SIGN_IN=1`, which clears any sign-in left in the simulator's Keychain
* `scripts/run-tests.sh` - runs the unit tests, then each UI test class with the simulated location it needs, with `scripts/mock_sync_server.py` (an in-memory sync endpoint, which needs a token, and sign-in endpoints taking any username with password `secret`) on port 8765
* `Journeys/Info.plist` - background modes (`location`, `fetch`), `BGTaskSchedulerPermittedIdentifiers` (the refresh task) and `NSAllowsLocalNetworking` (plain HTTP to local addresses, for the mock server); the location usage strings live in the build settings as `INFOPLIST_KEY_*`

## Conventions

* iOS 18.0 deployment target, iPhone and iPad, Swift 5 language mode, bundle id `com.performiq.Journeys`.
* The version is set once, at project level: `MARKETING_VERSION` (semantic, e.g. 1.5.0) and `CURRENT_PROJECT_VERSION` (build number); targets inherit them, and the About sheet and its UI test show them.
* Tracking records at most once per `LocationManager.trackingRecordInterval` (60 s), never while the motion sensors say the user is stationary, only after moving `movementThreshold` from the last recorded fix (25 m on foot; otherwise 25 m or twice the worse of the two fixes' accuracies if larger) and only once the next fix confirms it, and skips cached fixes older than `maxTrackedFixAge` (10 s).
  On a device iOS does not reliably report a still phone as stationary, so the distance check is what stops a still phone recording; indoors fixes drift 25 to 36 m and occasionally jump 160 m, hence the accuracy-based threshold and the confirmation; on foot the motion sensors show the moves are real, so walks across a building still count.
* Timestamps are sent as ISO 8601 with fractional seconds; `journeyId` is the journey's UUID string.
* Everything recorded is saved to the store before any upload; a waypoint's `syncState` says whether the API has it (pending, synced, rejected).
  The UI and `LocationManager` use the store's main-actor `viewContext`; the `SyncEngine` reads and writes on its own background contexts.

## Gotchas

* Uploads need a sign-in to fastapi-api; the refresh token lasts 90 days from each refresh and rotates on every use, and the server ends the sign-in if a spent one is used again more than 60 s later, so never refresh from two places at once.
  Never put credentials or tokens in source; tokens belong in the Keychain.
* Background tracking needs only "While Using" authorization because of the background activity session; iOS shows the location indicator while it runs.
  Simulator tests cover it, but real background behaviour (suspension, energy) should still be checked on a device.
* UI tests depend on the simulator's simulated location, which a test cannot set itself, so run them through `scripts/run-tests.sh` rather than plain `xcodebuild test`.
  A fixed simulated location keeps the timestamp it was set with and is delivered once, so the script sets it afresh before each class that uses Check Location (which ignores fixes over 2 minutes old).
* Background uploads survive the app being suspended or terminated by the system, but a user force-quitting it cancels them; they are queued again when it next opens.
* SourceKit needs `buildServer.json` (machine-specific, gitignored) to know this is an iOS project; without it, it checks files as standalone macOS code and reports false errors such as "unavailable in macOS" or "Cannot find 'LocationManager' in scope".
  Create it with `xcode-build-server config -project Journeys.xcodeproj -scheme Journeys` after one `xcodebuild ... build` into the default DerivedData, and trust the `xcodebuild` output over SourceKit.
