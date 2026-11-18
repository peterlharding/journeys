# Backlog

## Multiple location records per minute

PLH sees more than one location record for some minutes while the tracker is running.
Not reproduced in the simulator on 2026-11-19: with a fixed simulated location and the app in the foreground, `TrackerUITests.testTrackerRecordsOneLocationPerMinute` recorded exactly one location per minute over 3 minutes.

Still to establish:

* Whether the duplicates appear in the in-app list, in the server's `/waypoints` data, or both.
* How far apart the duplicate timestamps are (identical, or seconds apart).
* Conditions: real device, moving or stationary, app in foreground or background.

Candidate causes:

* `requestLocation()` delivering more than one fix per request on a real device.
* `LocationManager` / `TimerManager` being recreated because they are `@ObservedObject` defaults in `ContentView`, leaving leaked timers or managers behind.
* Interaction with the background tracking rework (backlog review item #1), which may change this behaviour anyway.
