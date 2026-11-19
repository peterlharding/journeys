//
//  LocationManager.swift
//  LocationDemo
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

    @Published var userLatitude: Double = 0.0
    @Published var userLongitude: Double = 0.0
    @Published var permissionDenied: Bool = false
    @Published private(set) var locations: [RecordedLocation] = []
    /// The journey new fixes are posted to; persisted in `UserDefaults` so it survives relaunches.
    @Published private(set) var currentJourney: JourneyData?
    @Published private(set) var isTracking: Bool = false

    private var trackingTask: Task<Void, Never>?
    /// Keeps the app running in the background while tracking (shows the location indicator).
    private var backgroundSession: CLBackgroundActivitySession?
    private var lastTrackedAt: Date?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()

        loadLastJourney()  // Load the last journey from UserDefaults when the app starts
    }

    /// Records the current location once, whether or not tracking is running.
    func requestLocation() {
        locationManager.requestLocation()
    }

    /// Starts recording the location while the device is moving, including in the background.
    func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        lastTrackedAt = nil
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
        if let lastTrackedAt,
           location.timestamp.timeIntervalSince(lastTrackedAt) < Self.trackingRecordInterval {
            return
        }
        lastTrackedAt = location.timestamp
        record(location)
    }

    /// Records a fix and posts it to the current journey.
    /// Core Location can deliver the same cached fix more than once; repeats are ignored.
    private func record(_ location: CLLocation) {
        if let last = locations.last?.location, location.isSameFix(as: last) {
            return
        }
        userLatitude = location.coordinate.latitude
        userLongitude = location.coordinate.longitude
        locations.append(RecordedLocation(location: location))
        if let journey = currentJourney {
            postLocationData(latitude: location.coordinate.latitude,
                             longitude: location.coordinate.longitude,
                             timestamp: location.timestamp,
                             journeyId: journey.id)
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
            record(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Failed to find user's location: \(error.localizedDescription)")
    }

    /// Stores a new journey via the API, then makes it the current journey.
    /// Throws, leaving the current journey unchanged, if the API does not accept it.
    func createJourney(name: String, notes: String) async throws {
        let journey = JourneyData(id: UUID(), name: name, notes: notes)
        try await APIClient.shared.post("journeys", body: journey)
        currentJourney = journey
        saveJourneyToUserDefaults(journey: journey)
    }

    private func postLocationData(latitude: Double, longitude: Double, timestamp: Date, journeyId: UUID) {
        let locationData = LocationData(
            latitude: latitude,
            longitude: longitude,
            timestamp: Self.timestampFormatter.string(from: timestamp),
            journeyId: journeyId.uuidString
        )
        Task {
            do {
                try await APIClient.shared.post("waypoints", body: locationData)
            } catch {
                print("Failed to post location data: \(error.localizedDescription)")
            }
        }
    }

    /// ISO 8601 with fractional seconds, as the API expects.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Journey persistence

    private static let currentJourneyKey = "currentJourney"

    private func saveJourneyToUserDefaults(journey: JourneyData) {
        if let encoded = try? JSONEncoder().encode(journey) {
            UserDefaults.standard.set(encoded, forKey: Self.currentJourneyKey)
        }
    }

    private func loadLastJourney() {
        guard let data = UserDefaults.standard.data(forKey: Self.currentJourneyKey) else { return }
        currentJourney = try? JSONDecoder().decode(JourneyData.self, from: data)
    }
}
