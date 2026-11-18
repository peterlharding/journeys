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
    @Published var locations: [CLLocation] = [] // Array to store all locations
    @Published var journeyGUID: String = "" // Store the current journey GUID
    @Published var currentJourney: JourneyData? // Store the current journey
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

    // Method to start a new journey by generating a new GUID
    func startNewJourney() {
        journeyGUID = UUID().uuidString
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

    private func record(_ location: CLLocation) {
        userLatitude = location.coordinate.latitude
        userLongitude = location.coordinate.longitude
        locations.append(location)
        if let journey = currentJourney {
            postLocationData(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, timestamp: location.timestamp, journeyId: journey.id)
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


    func postLocationData(latitude: Double, longitude: Double, timestamp: Date, journeyId: UUID) {

        let locationData = LocationData(
                                latitude: latitude,
                                longitude: longitude,
                                timestamp: formatDateToISO8601(date: timestamp),
                                journeyId: "\(journeyId)"
                            )
        
        guard let url = URL(string: "https://mongo-api.performiq.com/waypoints") else {
            print("Invalid URL")
            return
        }
        
        // Create the URLRequest
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            // Convert location data to JSON
            let jsonData = try JSONEncoder().encode(locationData)
            request.httpBody = jsonData
            
            // Perform the network request
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    print("Error posting location data: \(error)")
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    print("Location data successfully posted")
                } else {
                    print("Failed to post location data, response: \(String(describing: response))")
                }
            }.resume()
            
        } catch {
            print("Failed to encode location data: \(error)")
        }
    }
    
    func formatDateToISO8601(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] // Ensures full ISO 8601 with milliseconds
        return formatter.string(from: date)
    }
    
    func saveJourneyToUserDefaults(journey: JourneyData) {
        let encoder = JSONEncoder()
        if let encodedJourney = try? encoder.encode(journey) {
            UserDefaults.standard.set(encodedJourney, forKey: "currentJourney")
        }
    }
    
    func loadLastJourney() {
        if let savedJourneyData = UserDefaults.standard.data(forKey: "currentJourney") {
            let decoder = JSONDecoder()
            if let loadedJourney = try? decoder.decode(JourneyData.self, from: savedJourneyData) {
                self.currentJourney = loadedJourney
            }
        }
    }
    
    // Clear the current journey from UserDefaults
    func clearJourneyFromUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "currentJourney")
    }
    
}
