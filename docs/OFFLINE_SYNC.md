# Offline storage and Wi-Fi sync

Plan for keeping journeys and waypoints on the phone and uploading them later, written 2026-11-19.

## Goal

Recording must never depend on the network.
Every fix is saved on the phone first and uploaded later, automatically when on Wi-Fi, or straight away when PLH taps Sync now.
Nothing is lost to a dead zone, a server outage, a crash or a relaunch, and nothing is stored twice on the server.

## Decisions

* Local store: Core Data on SQLite.
  Chosen over SwiftData for its mature background contexts (the tracker writes while the app is in the background) and well-understood migrations.
* Server: add an idempotent batch endpoint to the Mongo API (mongo-api) now.
  The planned PostgreSQL API (`docs/BACKLOG.md`, Backend) will implement the same contract later, so the app does not change when the backend moves.
* Network: automatic sync only on networks iOS does not flag as expensive (mobile data, personal hotspot) or constrained (Low Data Mode), in practice Wi-Fi.
  A Sync now button can also upload over mobile data.
* Retention: everything stays on the phone after it is synced; past journeys remain viewable offline.
  At one waypoint a minute, 8 hours a day for a year is about 175,000 rows, roughly 20 MB.
* Direction: upload only.
  Each phone is the source of truth for what it records; there is no download and no conflict resolution.

## Where things stand

* Recorded locations live only in memory and are lost on relaunch; only the current journey is kept, in `UserDefaults`.
* Each fix is posted once, when recorded; if that fails, the waypoint is lost.
* A journey becomes current only after `POST /journeys` succeeds, so a journey cannot be started offline.
* The server cannot take retries safely: `POST /waypoints` has no waypoint id and appends a new record to the journey's chain on every call, and `POST /journeys` creates a new journey on every call.
  A retry after a lost reply therefore stores a duplicate, which may explain some of the duplicates PLH has seen on the server.
* Waypoints are chained (`previous`/`next`) in arrival order, and several `bin/` scripts in mongo-api walk that chain.
* NGINX turns every API error into a 302 to an HTML page, so the app cannot tell a rejected request (4xx) from an outage (5xx); see `docs/BACKLOG.md`.

## Design

### Local store

Two entities, in a versioned `.xcdatamodeld` so later changes migrate automatically.

`Journey`:

* `id` (UUID, unique), `name`, `notes`, `createdAt`
* `syncState` (pending, synced, rejected), `syncedAt`, `syncError`
* `waypoints`: to-many, cascade delete

`Waypoint`:

* `id` (UUID, unique, generated on the phone), `recordedAt`, `latitude`, `longitude`, `horizontalAccuracy`, `speed`, `course`
* `source` (tracker or Check Location)
* `syncState`, `syncedAt`, `syncError`
* `journey`: to-one, optional; a Check Location fix taken with no current journey is kept on the phone but never uploaded

Indexes on `syncState` and `recordedAt`.
The current journey is remembered by id in `UserDefaults`.

A `Store` type owns an `NSPersistentContainer`.
The screens read through the view context (`@FetchRequest`).
Recording also writes through the view context: `LocationManager` runs on the main actor and saves at most one small row a minute, which takes about a millisecond (decided while building phase 1).
The sync engine uses its own background context, so uploads never block the UI.
The SQLite file uses the default file protection (readable after first unlock), so background tracking can write while the phone is locked.
Unit tests use an in-memory store.

### Recording

* The tracker's rules stay as they are (at most once a minute, after moving 25 m, no fix older than 10 s); `record` saves a `Waypoint` (pending) instead of posting it.
* Check Location saves a `Waypoint` the same way.
* New Journey saves a `Journey` (pending) and makes it current at once, online or not.
  This replaces the current rule that a journey becomes current only after the server accepts it.
* On first launch of the new version, a current journey found in `UserDefaults` is imported as a pending journey; the idempotent endpoint makes re-sending it harmless.

### Sync engine

An actor, `SyncEngine`, with its own background context.

* Uploads oldest first, in batches of up to 500 records, each journey before its waypoints.
* Marks records synced only from the server's per-record answer, so a lost reply just means the batch is sent again and the server recognises it.
* Network errors and 5xx: retried with backoff (30 s, doubling to 30 minutes), reset when the network changes.
* 4xx for a record: that record is marked rejected with the server's message, shown in the UI, and not retried automatically.
* Runs one sync at a time.

Triggers:

* A record is saved (debounced by a few seconds, so a burst becomes one batch).
* The network becomes allowed (Wi-Fi joins).
* The app comes to the foreground.
* Automatic uploads go through a background `URLSession` (phase 4): iOS performs them on Wi-Fi even while the app is suspended or has been terminated by the system, then wakes the app to record the answers and queue the next batch.
  Retries after a failure use the upload's `earliestBeginDate`, so iOS waits out the delay itself.
  A user force-quitting the app cancels them; they are queued again when it next opens.
* A background app refresh task (`BGAppRefreshTask`), scheduled when the app goes to the background with records pending, as a backstop.
  `Info.plist` declares the `fetch` and `location` background modes and the task identifier; the unused `processing` and `external-accessory` modes were removed.
* Sync now.

### Network policy

* `NWPathMonitor` decides when automatic sync is allowed: the path is satisfied and neither expensive nor constrained.
* Automatic uploads use a `URLSession` with `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` off, so iOS itself refuses mobile data even if the network changes mid-request.
* Sync now uses a session that allows them.
* `APIClient` keeps refusing redirects and counting only 2xx as success; it gains the batch call.

### Server contract

`POST /sync`, one batch per call, idempotent by the phone's ids:

```json
{
  "journeys": [{"id": "UUID", "name": "...", "notes": "...", "createdAt": "ISO 8601"}],
  "waypoints": [{"id": "UUID", "journeyId": "UUID", "recordedAt": "ISO 8601",
                 "latitude": 0.0, "longitude": 0.0, "horizontalAccuracy": 5.0,
                 "speed": 1.2, "course": 90.0, "source": "tracker"}]
}
```

Response 200, with an answer for every record:

```json
{
  "journeys":  {"UUID": "stored" | "duplicate" | "rejected: <reason>"},
  "waypoints": {"UUID": "stored" | "duplicate" | "rejected: <reason>"}
}
```

* Journeys are upserted by `ref` (the phone's id); a repeat is `duplicate`.
* Waypoints get a `ref` field with a unique index; a repeat is `duplicate`.
  A waypoint whose journey is neither in the database nor in the batch is `rejected`.
* Waypoints are linked into their journey's chain in `recordedAt` order, not arrival order, so the `bin/` scripts keep working when an older batch arrives late.
* The whole call is 4xx only when the body is malformed, and 401 once JWT login exists.
* The existing `POST /journeys` and `POST /waypoints` stay for now and are removed once the app no longer uses them.
* NGINX must pass the API's own status codes and JSON error bodies through for the API host, so the app can tell rejections from outages.

### Screens

* Main screen: a sync status line ("12 waypoints waiting, last synced 10:42", or "Waiting for Wi-Fi") with a Sync now button.
  The location list reads the current journey's waypoints from the store and survives relaunches.
* Journeys screen: past journeys with their waypoint count and sync state; a journey opens to its waypoints.
* Rejected records are shown with the server's reason.

## Phases

Each phase ends with every test passing and is checked on the phone before the next starts.

1. **Local store** (app 1.2.0).
   Core Data model and `Store`; the tracker, Check Location and New Journey save locally; the screens read from the store.
   Uploads still go through today's endpoints once per record, but the outcome is now recorded in `syncState`, so nothing is lost even though nothing is retried yet.
   Tests: store unit tests (in-memory), recording tests moved onto the store, a UI test that relaunches the app and finds its records again.
2. **Server endpoint** (mongo-api).
   `POST /sync` as above, the `ref` unique index, time-ordered chain insertion, the NGINX change, and a first pytest suite for the endpoint (idempotent repeats, late batches, unknown journey).
   Deployed and checked with `curl` before the app uses it.
3. **Sync engine** (app 1.3.0).
   `SyncEngine`, the network policy, Sync now, the status line, offline journey creation, and the `UserDefaults` import.
   Tests: engine unit tests with a stub `URLProtocol` and an injected network path (batching, ordering, lost reply then retry, 4xx, 5xx backoff, Wi-Fi only); a UI test against a small local mock of `/sync` that starts offline, records, then syncs.
   Phone check: airplane mode, mobile data only, then Wi-Fi.
4. **Background sync and history** (app 1.4.0).
   Background uploads, the refresh task and the Journeys screen.
   Phone check: record with Wi-Fi off, lock the phone, turn Wi-Fi on, and confirm the upload happens without opening the app.

## Progress

* Phase 1 (1.2.0): done 2026-11-20.
* Phase 2: done 2026-11-20; `POST /sync` is live on vega (mongo-api `devel`, `doc/SYNC.md` there), and NGINX now passes the API's own status codes through.
* Phase 3 (1.3.0): done 2026-11-20.
  Building it showed that one Check Location tap could record two fixes, because iOS can deliver more than one per request.
  A tap now records exactly one fix: it starts continuous updates and records the first fresh fix (10 s old or less), or, if none comes within 5 s, the newest fix under 2 minutes old (iOS may only ever send an older fix indoors or in the simulator), then stops.
  The UI test uses `scripts/mock_sync_server.py`, which `scripts/run-tests.sh` starts on port 8765.

* Phase 4 (1.4.0): built 2026-11-20.
  Automatic syncs use a background `URLSession` rather than the `BGProcessingTask` first planned, which iOS runs only when it chooses (typically overnight while charging) and so could not upload promptly on joining Wi-Fi.
  Opening the app cancels an upload still waiting out a retry delay and tries at once.

## Open questions

* How mongo-api is deployed and restarted on the server, so phase 2 can be released and the outage seen today can be avoided.
* Whether anything other than the `bin/` scripts reads the waypoint chain.
* JWT login (`docs/BACKLOG.md`) will add a 401 path to the sync engine; it fits the design but is not part of these phases.
