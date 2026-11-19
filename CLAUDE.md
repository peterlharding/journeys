# LocationDemo

A SwiftUI iOS demo app that records named journeys and posts the device's location as waypoints to the PerformIQ Mongo API (`https://mongo-api.performiq.com`).
iPhone and iPad only (never macOS, tvOS or visionOS); an app target, a unit test target and a UI test target, no external dependencies.

## Commands

* Build (simulator): `xcodebuild -project LocationDemo.xcodeproj -scheme LocationDemo -destination 'generic/platform=iOS Simulator' build`
* Lint: `swiftlint lint --quiet LocationDemo` (no `.swiftlint.yml` yet, so default rules apply; it currently reports no warnings)
* All tests: `scripts/run-tests.sh [simulator-udid]` (about 10 minutes; unit tests first, then UI tests, which wait in real time)
* Unit tests only: `xcodebuild test -project LocationDemo.xcodeproj -scheme LocationDemo -destination 'id=<simulator-udid>' -only-testing:LocationDemoTests` (seconds)
* List simulators: `xcrun simctl list devices available`

## Layout

* `docs/BACKLOG.md` - known issues and work not yet started
* `LocationDemo.xcodeproj/` - Xcode project: app, unit test and UI test targets, and one shared scheme named `LocationDemo`
* `LocationDemo/LocationDemoApp.swift` - app entry point, shows `ContentView`
* `LocationDemo/ContentView.swift` - main screen: current journey, New Journey, Check Location and Start/Stop Tracker buttons, location list
* `LocationDemo/NewJourneyModal.swift` - sheet to create a journey; POSTs it to `/journeys`
* `LocationDemo/LocationManager.swift` - location state; tracking via `CLLocationUpdate.liveUpdates` plus a `CLBackgroundActivitySession`, one-off fixes via `CLLocationManager`; POSTs each recorded fix to `/waypoints` and persists the current journey in `UserDefaults` (key `currentJourney`)
* `LocationDemo/JourneyData.swift`, `LocationData.swift` - `Codable` payloads sent to the API
* `LocationDemoTests/` - unit tests (hosted in the app, `@testable import LocationDemo`)
* `LocationDemoUITests/` - XCUITest tests for the tracker, grouped by the simulated location they need (moving or stationary)
* `scripts/run-tests.sh` - runs the unit tests, then each UI test class with the simulated location it needs
* `LocationDemo/Info.plist` - background modes (`location`, `processing`, `external-accessory`); the location usage strings live in the build settings as `INFOPLIST_KEY_*`

## Conventions

* iOS 18.0 deployment target, iPhone and iPad, Swift 5 language mode, bundle id `com.performiq.LocationDemo`.
* Tracking records only while moving, at most once per `LocationManager.trackingRecordInterval` (60 s); Core Location pauses updates when the device is stationary, to save energy.
* Timestamps are sent as ISO 8601 with fractional seconds; `journeyId` is the journey's UUID string.

## Gotchas

* API requests currently carry no authentication; the old Basic Auth was removed and JWT login (access + refresh tokens) is planned.
  Never put credentials or tokens in source; tokens belong in the Keychain.
* Background tracking needs only "While Using" authorization because of the background activity session; iOS shows the location indicator while it runs.
  Simulator tests cover it, but real background behaviour (suspension, energy) should still be checked on a device.
* UI tests depend on the simulator's simulated location, which a test cannot set itself, so run them through `scripts/run-tests.sh` rather than plain `xcodebuild test`.
* SourceKit needs `buildServer.json` (machine-specific, gitignored) to know this is an iOS project; without it, it checks files as standalone macOS code and reports false errors such as "unavailable in macOS" or "Cannot find 'LocationManager' in scope".
  Create it with `xcode-build-server config -project LocationDemo.xcodeproj -scheme LocationDemo` after one `xcodebuild ... build` into the default DerivedData, and trust the `xcodebuild` output over SourceKit.
