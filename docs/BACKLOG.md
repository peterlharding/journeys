# Backlog

## Backend: move off mongo-api

The app signs in to fastapi-api (`https://fast-api.performiq.com`) and uploads there from 1.6.0, with rotating refresh tokens (90 days, reuse detection) and 15-minute access tokens.
The data already in MongoDB moves with fastapi-api's `scripts/mongo-export-journeys.sh` and `scripts/import_mongo_journeys.py`.

* Mongo's times are UTC, including those from before `POST /sync` (checked 2026-11-20 against the trips' known local times, e.g. a Bunnings trip at 23:14 UTC, 10:14 am local); the import keeps them as they are.
* The phone uploads only to fastapi-api from 1.6.0, so export and import once more after installing it, to catch anything synced to mongo-api after the first export.
* Security issues found in `fastapi/mongo-api` (mongo-api.performiq.com), to fix or retire with it: `GET /api-credentials` returns all `ApplicationUser` records unauthenticated (`app/routes/test.py:37`); journeys/waypoints endpoints have no auth; `/v3/authenticate` reportedly never checks the Basic password and logs passwords; the MongoDB password is committed in `app/CONFIG.py` (private repo).

## Multiple location records (cause found 2026-11-20)

PLH saw more than one location record for some minutes, and once three records with the same timestamp.
Causes found and fixed, oldest first:

* The same cached fix recorded and posted twice; `LocationManager.record` ignores a fix identical to the last one.
* `LocationManager` / `TimerManager` recreated by `ContentView`, leaving leaked timers behind; replaced by `CLLocationUpdate.liveUpdates` with no Timer.
* A retried upload stored a second copy on the server (`POST /waypoints` and `POST /journeys` are not idempotent); uploads now go through `POST /sync`, which stores each record once by the phone's id.
* One Check Location tap recorded every fix iOS delivered for the request, and iOS can deliver more than one (two, 17 s apart, in the simulator on 2026-11-20).
  A tap now records only the first fresh fix (`LocationRecordingTests`, `SyncUITests`).

Still worth watching on the device: the server may hold duplicates from before these fixes (`bin/chk_waypoints.py` and `bin/ls_waypoints.py` in mongo-api can find them).

## Tracker behaviour on a real device (2026-11-19)

Seen with diagnostic logging on an iPhone 16 Pro Max lying still on a desk:

* `CLLocationUpdate.stationary` stayed false and updates kept arriving every few seconds, so a still device recorded one fix per minute.
  Fixed: the tracker now records only after moving 25 m; a still phone's fixes drift by about a metre.
* The first update after Start Tracker can be a cached fix (24 s and 100 s old in two tests), which was recorded as the journey's first waypoint.
  Fixed: the tracker skips fixes older than 10 s.
* Both fixes checked on the device: one record while still for several minutes, a new one after walking, no duplicates.
* Still open: updates keep arriving every few seconds while still, so the energy saving depends on iOS pausing them; check over a longer still period in the background without a debugger attached.
* Indoors the tracker recorded a few times an hour while stopped: on 2026-11-19 (1.2.0) a phone at a club for an hour recorded 12 waypoints, the fixes drifting 25 to 36 m with accuracies of 12 to 20 m, and once jumping 160 m and straight back.
  PLH pointed out that some of those moves were real: the club is large, and he walked from the entrance to the restaurant and to the bar and back.
  Fixed in 1.5.0: the motion sensors (`MotionMonitor`) decide when they have a reading; stationary means no record at all, and on foot any confirmed move of 25 m counts.
  Without a motion reading (no permission, low confidence) or in a vehicle, the threshold is twice the worse of the two fixes' accuracies when that exceeds 25 m.
  Movement must always be confirmed by the next fix; replaying the stop (`testTrackerIgnoresIndoorDrift`) gives one record instead of 11.
  Still to check on the phone: a walk across a large building with the tracker on.

## API errors are hidden behind a redirect

NGINX in front of mongo-api answers every failing request with a 302 to `https://devel.performiq.com/error`, so the app cannot tell a missing journey (404), a bad body (422) or a backend that is down (502) apart; `APIClient` refuses the redirect and reports "HTTP 302".
On 2026-11-19 the FastAPI backend was down (even `/hello-world` returned the 302) until PLH restarted it.
Fix on the server side (return the API's own status and JSON error body for the API host).
