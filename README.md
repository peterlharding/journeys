# Journeys

A SwiftUI app for iPhone and iPad that records named journeys and posts the device's location to the PerformIQ API as waypoints.

* Start Tracker records the location at most once a minute, only after moving 25 m, and keeps recording in the background.
* Check Location records a single fix.
* The About sheet shows the version and the API host.

Build, test and project conventions are in [CLAUDE.md](CLAUDE.md); known issues and planned work are in [docs/BACKLOG.md](docs/BACKLOG.md).

Formerly LocationDemo (github.com/peterlharding/LocationDemo); its history is included in this repo.
