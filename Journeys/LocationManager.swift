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
    /// Told about every saved record, so it can upload them; nil in tests that only check recording.
    private let syncEngine: SyncEngine?
    private let defaults: UserDefaults

    private var trackingTask: Task<Void, Never>?
    /// Keeps the app running in the background while tracking (shows the location indicator).
    private var backgroundSession: CLBackgroundActivitySession?
    private var lastTracked: CLLocation?
    /// The last fix recorded, to ignore Core Location handing the same fix over again.
    private var lastRecorded: CLLocation?
    /// Set by a Check Location tap until its fix is recorded: only the first fresh fix is wanted.
    private var awaitingCheckLocation = false
    /// Stops a Check Location that never gets a usable fix, so location updates do not run on.
    private var checkLocationTimeout: Task<Void, Never>?
    static let checkLocationTimeLimit: Duration = .seconds(30)
    /// The newest older-than-fresh fix seen since the tap, recorded if no fresh one arrives in time.
    private var checkLocationFallback: CLLocation?
    private var checkLocationFallbackTask: Task<Void, Never>?
    /// How long to wait for a fresh fix before settling for the fallback (tests shorten it).
    var checkLocationGrace: Duration = .seconds(5)
    /// A fix older than this is not the current location and is never recorded by Check Location.
    static let maxCheckLocationFixAge: TimeInterval = 120

    /// A nil store means the app's own; tests pass an in-memory store and their own defaults.
    init(store: Store? = nil, syncEngine: SyncEngine? = nil, defaults: UserDefaults = .standard) {
        self.store = store ?? .shared
        self.syncEngine = syncEngine
        self.defaults = defaults
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()

        loadCurrentJourney()
    }

    /// Records the current location once, whether or not tracking is running.
    ///
    /// `requestLocation()` was not used: it can answer with a stale cached fix, take 15 s or more to
    /// produce a fresh one, and deliver more than one fix for a single request. Continuous updates give
    /// a fresh fix within a second or two; they stop as soon as it is recorded.
    func requestLocation() {
        startCheckLocation()
        locationManager.startUpdatingLocation()
        checkLocationTimeout?.cancel()
        checkLocationTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.checkLocationTimeLimit)
            guard !Task.isCancelled else { return }
            self?.finishCheckLocation()
        }
    }

    private func finishCheckLocation() {
        awaitingCheckLocation = false
        checkLocationTimeout?.cancel()
        checkLocationTimeout = nil
        checkLocationFallbackTask?.cancel()
        checkLocationFallbackTask = nil
        checkLocationFallback = nil
        locationManager.stopUpdatingLocation()
    }

    /// Marks a Check Location as asked for, so its fix is recorded (tests call this directly).
    func startCheckLocation() {
        checkLocationFallbackTask?.cancel()
        checkLocationFallbackTask = nil
        checkLocationFallback = nil
        awaitingCheckLocation = true
    }

    /// Records one fix per Check Location tap: the first fresh one (`maxTrackedFixAge`) if it comes,
    /// otherwise, after `checkLocationGrace`, the newest fix seen that is under two minutes old.
    /// Indoors, or in the simulator with a fixed location, iOS may only ever send an older fix.
    private func checkLocationReceived(_ location: CLLocation, now: Date = .now) {
        guard awaitingCheckLocation else { return }
        let age = now.timeIntervalSince(location.timestamp)
        if age <= Self.maxTrackedFixAge {
            finishCheckLocation()
            record(location, source: .checkLocation)
            return
        }
        guard age <= Self.maxCheckLocationFixAge else { return }
        if let fallback = checkLocationFallback, fallback.timestamp >= location.timestamp { return }
        checkLocationFallback = location
        guard checkLocationFallbackTask == nil else { return }
        checkLocationFallbackTask = Task { [weak self, checkLocationGrace] in
            try? await Task.sleep(for: checkLocationGrace)
            guard !Task.isCancelled, let self, self.awaitingCheckLocation,
                  let fallback = self.checkLocationFallback,
                  Date.now.timeIntervalSince(fallback.timestamp) <= Self.maxCheckLocationFixAge else { return }
            self.finishCheckLocation()
            self.record(fallback, source: .checkLocation)
        }
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

    /// Saves a fix to the current journey (or with no journey); the sync engine uploads it later.
    /// Core Location can deliver the same cached fix more than once; repeats are ignored.
    private func record(_ location: CLLocation, source: Waypoint.Source) {
        if let lastRecorded, location.isSameFix(as: lastRecorded) {
            return
        }
        lastRecorded = location
        let waypoint = store.addWaypoint(location, source: source, journey: currentJourney)
        if waypoint.journey != nil {
            syncEngine?.recordSaved()
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
            checkLocationReceived(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Failed to find user's location: \(error.localizedDescription)")
    }

    /// Saves a new journey and makes it the current journey at once, online or not;
    /// the sync engine uploads it later.
    func createJourney(name: String, notes: String) {
        let journey = store.addJourney(name: name, notes: notes, syncState: .pending)
        setCurrentJourney(journey)
        syncEngine?.recordSaved()
    }

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
