//
//  LocationManager.swift
//  Journeys
//
//  Created by Peter Harding on 14/10/2024.
//

import Foundation
import CoreLocation

@MainActor
class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Used for authorization and for one-off "Check Location" requests.
    private let locationManager = CLLocationManager()

    /// While tracking, at most one location is recorded per interval.
    /// When the device is stationary, Core Location stops delivering updates, so nothing is recorded.
    static let trackingRecordInterval: TimeInterval = 60

    /// The tracker ignores fixes older than this. The first update after Start Tracker is often
    /// a cached fix from before tracking began (24 s old in a device test).
    static let maxTrackedFixAge: TimeInterval = 10

    /// The tracker records a fix only this far (metres) from the last one it recorded, or further
    /// when the fix is less accurate. iOS does not reliably report a still device as stationary,
    /// and a still phone's fixes drift by a metre or so.
    static let minTrackedDistance: CLLocationDistance = 25

    @Published var permissionDenied: Bool = false
    /// The journey new fixes are added to; remembered by id in `UserDefaults` across relaunches.
    @Published private(set) var currentJourney: Journey?
    @Published private(set) var isTracking: Bool = false

    let store: Store
    private let api: APIClient
    private let defaults: UserDefaults

    private var trackingTask: Task<Void, Never>?
    /// Keeps the app running in the background while tracking (shows the location indicator).
    private var backgroundSession: CLBackgroundActivitySession?
    private var lastTracked: CLLocation?
    /// The last fix recorded, to ignore Core Location handing the same fix over again.
    private var lastRecorded: CLLocation?

    /// Nil arguments mean the app's own store, API and defaults; tests pass an in-memory store,
    /// a stubbed API and their own defaults.
    init(store: Store? = nil, api: APIClient = .shared, defaults: UserDefaults = .standard) {
        self.store = store ?? .shared
        self.api = api
        self.defaults = defaults
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()

        loadCurrentJourney()
    }

    /// Records the current location once, whether or not tracking is running.
    func requestLocation() {
        locationManager.requestLocation()
    }

    /// Starts recording the location while the device is moving, including in the background.
    func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        lastTracked = nil
        backgroundSession = CLBackgroundActivitySession()
        trackingTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.default) {
                    guard let self, !Task.isCancelled else { return }
                    self.handle(update)
                }
            } catch {
                print("Location updates ended with error: \(error.localizedDescription)")
            }
        }
    }

    func stopTracking() {
        trackingTask?.cancel()
        trackingTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        isTracking = false
    }

    private func handle(_ update: CLLocationUpdate) {
        if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
            permissionDenied = true
            return
        }
        guard let location = update.location, !update.stationary else { return }
        trackerReceived(location)
    }

    /// Records a fix delivered while tracking: at most once per `trackingRecordInterval`, only after
    /// moving `minTrackedDistance`, and never a stale cached fix. `now` is injectable for tests.
    func trackerReceived(_ location: CLLocation, now: Date = .now) {
        guard now.timeIntervalSince(location.timestamp) <= Self.maxTrackedFixAge else { return }
        if let lastTracked {
            guard location.timestamp.timeIntervalSince(lastTracked.timestamp) >= Self.trackingRecordInterval
            else { return }
            let threshold = max(Self.minTrackedDistance, location.horizontalAccuracy)
            guard location.distance(from: lastTracked) >= threshold else { return }
        }
        lastTracked = location
        record(location, source: .tracker)
    }

    /// Saves a fix to the current journey (or with no journey), then posts it once.
    /// Core Location can deliver the same cached fix more than once; repeats are ignored.
    private func record(_ location: CLLocation, source: Waypoint.Source) {
        if let lastRecorded, location.isSameFix(as: lastRecorded) {
            return
        }
        lastRecorded = location
        let waypoint = store.addWaypoint(location, source: source, journey: currentJourney)
        if waypoint.journey != nil {
            upload(waypoint)
        }
    }

    // MARK: - CLLocationManagerDelegate
    // The delegate is called on the main thread because the manager was created there.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            permissionDenied = status == .denied || status == .restricted
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated {
            record(location, source: .checkLocation)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Failed to find user's location: \(error.localizedDescription)")
    }

    /// Stores a new journey via the API, then saves it and makes it the current journey.
    /// Throws, leaving the current journey unchanged, if the API does not accept it.
    func createJourney(name: String, notes: String) async throws {
        let payload = JourneyData(id: UUID(), name: name, notes: notes)
        try await api.post("journeys", body: payload)
        let journey = store.addJourney(id: payload.id, name: name, notes: notes, syncState: .synced)
        setCurrentJourney(journey)
    }

    /// Posts a waypoint once and records the outcome on it. Failed uploads stay pending;
    /// retrying them is the sync engine's job (docs/OFFLINE_SYNC.md, phase 3).
    private func upload(_ waypoint: Waypoint) {
        guard let journey = waypoint.journey else { return }
        let payload = LocationData(
            latitude: waypoint.latitude,
            longitude: waypoint.longitude,
            timestamp: Self.timestampFormatter.string(from: waypoint.recordedAt),
            journeyId: journey.id.uuidString
        )
        Task {
            do {
                try await api.post("waypoints", body: payload)
                store.markUploaded(waypoint, error: nil)
            } catch {
                print("Failed to post location data: \(error.localizedDescription)")
                store.markUploaded(waypoint, error: error)
            }
        }
    }

    /// ISO 8601 with fractional seconds, as the API expects.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Current journey

    static let currentJourneyIDKey = "currentJourneyID"
    /// Where versions before 1.2.0 kept the whole current journey, as JSON.
    static let legacyCurrentJourneyKey = "currentJourney"

    private func setCurrentJourney(_ journey: Journey) {
        currentJourney = journey
        defaults.set(journey.id.uuidString, forKey: Self.currentJourneyIDKey)
    }

    private func loadCurrentJourney() {
        importLegacyCurrentJourney()
        guard let idString = defaults.string(forKey: Self.currentJourneyIDKey),
              let id = UUID(uuidString: idString) else { return }
        currentJourney = store.journey(id: id)
    }

    /// Moves a current journey saved by a version before 1.2.0 into the store.
    /// Its upload state is unknown, so it is pending; the sync endpoint makes re-sending it harmless.
    private func importLegacyCurrentJourney() {
        guard let data = defaults.data(forKey: Self.legacyCurrentJourneyKey) else { return }
        defer { defaults.removeObject(forKey: Self.legacyCurrentJourneyKey) }
        guard let legacy = try? JSONDecoder().decode(JourneyData.self, from: data) else { return }
        let journey = store.journey(id: legacy.id)
            ?? store.addJourney(id: legacy.id, name: legacy.name, notes: legacy.notes, syncState: .pending)
        setCurrentJourney(journey)
    }
}
