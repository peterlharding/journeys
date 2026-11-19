# Backlog

## JWT login (access + refresh tokens)

Replace the removed Basic Auth with the login design used by the HSDB API (`dsto/hsdb/db-api-fastapi`, `app/routes/auth.py`, `app/auth/refresh.py`): a short-lived access JWT (15 min) sent as `Authorization: Bearer`, plus an opaque refresh token (14 days) stored hashed server-side, rotated on every use, with reuse detection revoking the token family.

Decided 2026-11-19:

* iOS uses a body-based refresh variant, not the HttpOnly cookie used by browser clients: login and refresh return the refresh token in the JSON body, and refresh accepts `{"refresh_token": ...}` in the body (no `X-Requested-With` needed, since no cookie is involved).
* The refresh token is stored in the Keychain with "after first unlock" accessibility so background tracking can refresh while the device is locked; the access token stays in memory.
* The client serialises refreshes (one in flight, others wait), retries a request once after a 401, treats a 401 from refresh as logged out, and keeps the session on network errors and 5xx.

Open: which API hosts the endpoints (current Mongo API or api.performiq.com) and the MongoDB to PostgreSQL migration.

## Backend: PostgreSQL and api.performiq.com (on hold)

On hold until PLH has checked out the API repos on this Mac for local development (2026-11-19).
For the time being the app keeps using the MongoDB API (mongo-api.performiq.com), whose journeys/waypoints endpoints need no auth, so the app works without credentials.

* Direction: move journeys/waypoints from MongoDB to PostgreSQL (`journey` 1-N `waypoint(journey_id FK, recorded_at timestamptz)` ordered by time, replacing the Mongo linked list), and serve them from api.performiq.com.
* api.performiq.com is NGINX in front of an old FastAPI implementation that needs refactoring to the conventions of recent projects; which repo holds its source, and which project sets the conventions (HSDB `db-api-fastapi`, `base-api`, or a mix), is still to be confirmed.
* Migration from Mongo must handle legacy journeys missing `ref`/`created`, detached waypoints, and timestamps the API converted to Melbourne local time.
* Security issues found in `fastapi/mongo-api` (mongo-api.performiq.com), to fix or retire with it: `GET /api-credentials` returns all `ApplicationUser` records unauthenticated (`app/routes/test.py:37`); journeys/waypoints endpoints have no auth; `/v3/authenticate` reportedly never checks the Basic password and logs passwords; the MongoDB password is committed in `app/CONFIG.py` (private repo).

## Multiple location records per minute

PLH sees more than one location record for some minutes while the tracker is running.
Not reproduced in the simulator on 2026-11-19: with a fixed simulated location and the app in the foreground, the UI test then in place recorded exactly one location per minute over 3 minutes.

Still to establish:

* Whether the duplicates appear in the in-app list, in the server's `/waypoints` data, or both.
* How far apart the duplicate timestamps are (identical, or seconds apart).
* Conditions: real device, moving or stationary, app in foreground or background.

Candidate causes:

* `requestLocation()` delivering more than one fix per request on a real device.
* (Fixed since) The same cached fix being recorded and posted twice; `LocationManager.record` now ignores a fix identical to the last one (`LocationRecordingTests`).
* (Fixed since) `LocationManager` / `TimerManager` were `@ObservedObject` defaults in `ContentView` and could be recreated, leaving leaked timers behind.

The tracker has since been reworked (`CLLocationUpdate.liveUpdates`, one record per minute while moving, no Timer), so re-check on a device whether duplicates still occur before investigating further.

On 2026-11-19 PLH saw three records with the same timestamp (15:19:48) after tapping Start Tracker on an iPhone 16 Pro Max.
A build with diagnostic logging then recorded exactly one fix per minute, all from the tracker, with no duplicates, over about 6 minutes; the duplicates have not been reproduced since.

## Tracker behaviour on a real device (2026-11-19)

Seen with diagnostic logging on an iPhone 16 Pro Max lying still on a desk:

* `CLLocationUpdate.stationary` stayed false and updates kept arriving every few seconds, so a still device records one fix per minute; "record only while moving" saves less energy on a device than the simulator suggests.
* The first update after Start Tracker can be a cached fix (24 s old in the test), which is recorded as the journey's first waypoint; consider skipping fixes older than a few seconds.

## API errors are hidden behind a redirect

NGINX in front of mongo-api answers every failing request with a 302 to `https://devel.performiq.com/error`, so the app cannot tell a missing journey (404), a bad body (422) or a backend that is down (502) apart; `APIClient` refuses the redirect and reports "HTTP 302".
On 2026-11-19 the FastAPI backend was down (even `/hello-world` returned the 302) until PLH restarted it.
Fix on the server side (return the API's own status and JSON error body for the API host).
