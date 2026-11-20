# Changelog

All notable changes to Journeys are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version is `MARKETING_VERSION` in the Xcode project; the About sheet shows it with the build number.

## [Unreleased]

## [1.6.0] - 2026-11-20

### Added

- Signing in to the PerformIQ API: a Sign In sheet, opened from the status line or the About sheet, and the signed-in account with Sign Out in the About sheet.
- The sign-in lasts while the app uploads at least every 90 days: a refresh token, rotated on every use, is kept in the Keychain (never the password), and the 15-minute access token is refreshed before it expires, including in the background while the phone is locked.

### Changed

- Journeys upload to fastapi-api (`https://fast-api.performiq.com/api/v1/journeys/sync`) as the signed-in account, instead of to mongo-api's `POST /sync`.
  Journeys already in MongoDB are moved across with fastapi-api's import scripts.
- Nothing uploads while signed out; the status line says "Sign in to upload", and the records wait on the phone.
- An upload whose token expired while it waited for Wi-Fi is sent again at once with a fresh token.

## [1.5.0] - 2026-11-20

### Changed

- Indoor drift is no longer recorded as movement: a move must be at least 25 m, or twice the worse of the two fixes' accuracies if that is larger, and the next fix must confirm it.
- The tracker reads the motion sensors: nothing is recorded while they say the phone is still, and on foot 25 m is enough, so walks across a large building still count.
  The app asks for Motion & Fitness permission.

## [1.4.0] - 2026-11-20

### Added

- The Journeys screen: every journey with its waypoint count and upload state, opening to its waypoints and any reason the server gave for rejecting one.

### Changed

- Automatic uploads go through iOS's background transfer service on Wi-Fi only, even while the app is suspended; Sync now still uploads straight away on any network.
- A failed upload is retried after 30 seconds, doubling to at most 30 minutes; opening the app or joining a network retries at once.

## [1.3.0] - 2026-11-20

### Added

- A status line saying what is waiting to upload and why, with Sync now.

### Changed

- Journeys and waypoints upload in batches of up to 500 through mongo-api's `POST /sync`, which recognises a batch sent twice, so a lost reply never stores anything twice.

### Fixed

- One Check Location tap could record two fixes; it now records exactly one.

## [1.2.0] - 2026-11-20

### Added

- Journeys and waypoints are kept on the phone (Core Data) before anything is uploaded, so a journey can be created and recorded with no network and survives the app being closed.
  The current journey saved by earlier versions is carried over.

## [1.1.0] - 2026-11-19

### Changed

- Renamed from LocationDemo to Journeys.
- Tracking skips stale cached fixes and drift while standing still.

## [1.0.0] - 2026-11-19

### Added

- The app's version, and an About sheet showing it with the API host.

### Fixed

- Duplicate ids in the recorded locations list.
- A journey is kept only once the API has stored it.

[Unreleased]: https://github.com/peterlharding/journeys/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/peterlharding/journeys/releases/tag/v1.6.0
