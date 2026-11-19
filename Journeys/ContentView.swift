//
//  ContentView.swift
//  Journeys
//
//  Created by Peter Harding on 14/10/2024.
//

import SwiftUI
import CoreData
import CoreLocation

// ---------------------------------------------------------------------------

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Image(systemName: configuration.isOn ? "checkmark.square" : "square")
                .resizable()
                .frame(width: 20, height: 20)
                .onTapGesture {
                    configuration.isOn.toggle()
                }
            configuration.label
        }
    }
}

// ---------------------------------------------------------------------------

struct ContentView: View {
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var syncEngine: SyncEngine

    @State private var isModalPresented: Bool = false
    @State private var isAboutPresented = false
    @State private var isJourneysPresented = false
    @State private var showLocations: Bool = true // State variable to control showing the list

    var body: some View {
        VStack {
            HStack {
                Button {
                    isJourneysPresented = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.title2)
                }
                .accessibilityLabel("Journeys")
                Spacer()
                Button {
                    isAboutPresented = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title2)
                }
                .accessibilityLabel("About")
            }

            if locationManager.permissionDenied {
                Text("Location permission denied. Please enable it in settings.")
                    .foregroundColor(.red)
            } else {
                if let journey = locationManager.currentJourney {
                    Text("Current Journey: \(journey.name)")
                        .font(.headline)
                    if !journey.notes.isEmpty {
                        Text("Notes: \(journey.notes)")
                            .font(.subheadline)
                    }
                    Text("Id: \(journey.id)")
                        .font(.subheadline)
                } else {
                    Text("No current journey")
                }

                Button {
                    isModalPresented = true // Show modal to create a new journey
                } label: {
                    Text("New Journey")
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding()

                RecordedLocationsView(journey: locationManager.currentJourney, part: .header,
                                      showLocations: showLocations)
                    .id(locationManager.currentJourney?.objectID)

                HStack {
                    Button {
                        locationManager.requestLocation()
                    } label: {
                        Text("Check Location")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .padding()

                    Button {
                        if locationManager.isTracking {
                            locationManager.stopTracking()
                        } else {
                            locationManager.startTracking()
                        }
                    } label: {
                        Text(locationManager.isTracking ? "Stop Tracker" : "Start Tracker")
                            .padding()
                            .background(locationManager.isTracking ? Color.red : Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .padding()
                }

                SyncStatusView(syncEngine: syncEngine)

                Toggle(isOn: $showLocations) {
                    Text("Show Locations")
                }
                .toggleStyle(CheckboxToggleStyle()) // Apply checkbox style
                .padding()

                RecordedLocationsView(journey: locationManager.currentJourney, part: .list,
                                      showLocations: showLocations)
                    .id(locationManager.currentJourney?.objectID)
            }
        }
        .padding()
        .sheet(isPresented: $isModalPresented) {
            NewJourneyModal(locationManager: locationManager)
        }
        .sheet(isPresented: $isAboutPresented) {
            AboutView()
        }
        .sheet(isPresented: $isJourneysPresented) {
            JourneysView(currentJourneyID: locationManager.currentJourney?.id)
        }
    }
}

/// The recorded locations of the current journey (or, with no journey, the fixes taken without one),
/// read from the store so they survive relaunches. Split into the header above the buttons and the
/// list below them; each part has its own fetch, which Core Data keeps up to date.
struct RecordedLocationsView: View {
    enum Part { case header, list }

    let part: Part
    let showLocations: Bool
    @FetchRequest private var waypoints: FetchedResults<Waypoint>

    init(journey: Journey?, part: Part, showLocations: Bool) {
        self.part = part
        self.showLocations = showLocations
        _waypoints = FetchRequest(fetchRequest: Waypoint.fetchRequest(for: journey), animation: .default)
    }

    var body: some View {
        if showLocations {
            switch part {
            case .header: header
            case .list: list
            }
        }
    }

    private var header: some View {
        VStack {
            Text("Current Location")
                .font(.largeTitle)
            if let latest = waypoints.last {
                VStack(spacing: 4) {
                    Text("Latitude: \(latest.latitude)")
                    Text("Longitude: \(latest.longitude)")
                }
                .padding(.bottom)
            } else {
                Text("No location yet")
                    .foregroundStyle(.secondary)
                    .padding(.bottom)
            }
        }
    }

    private var list: some View {
        VStack {
            Text("^[\(waypoints.count) location](inflect: true) recorded")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recordCount")
            List(waypoints) { waypoint in
                VStack(alignment: .leading) {
                    Text("Latitude: \(waypoint.latitude)")
                    Text("Longitude: \(waypoint.longitude)")
                    Text("Timestamp: \(waypoint.recordedAt)")
                        .font(.caption)
                    HStack {
                        Text("Open in - ")
                        if let googleMapsURL = createGoogleMapsURL(latitude: waypoint.latitude,
                                                                   longitude: waypoint.longitude) {
                            Link("Google Maps", destination: googleMapsURL)
                        }
                        if let appleMapsURL = createAppleMapsURL(latitude: waypoint.latitude,
                                                                 longitude: waypoint.longitude) {
                            Link("Apple Maps", destination: appleMapsURL)
                        }
                    }
                    // Keeps each link separately tappable and tinted inside a list row.
                    .buttonStyle(.borderless)
                }
            }
            .listStyle(.plain)
        }
    }

    func createAppleMapsURL(latitude: Double, longitude: Double) -> URL? {
        let urlString = "http://maps.apple.com/?ll=\(latitude),\(longitude)"
        return URL(string: urlString)
    }

    func createGoogleMapsURL(latitude: Double, longitude: Double) -> URL? {
        let urlString = "http://maps.google.com/?q=\(latitude),\(longitude)"
        return URL(string: urlString)
    }
}

#Preview {
    let store = Store.inMemory()
    ContentView()
        .environment(\.managedObjectContext, store.viewContext)
        .environmentObject(LocationManager(store: store))
        .environmentObject(SyncEngine(store: store, api: .shared, uploader: PreviewUploader(),
                                      network: NetworkMonitor()))
}

/// Previews never hand anything to iOS's background transfer service.
@MainActor
private final class PreviewUploader: SyncUploading {
    var onFinish: ((Result<(status: Int, body: Data), Error>) -> Void)?
    func hasUploadInFlight() async -> Bool { false }
    func upload(_ body: Data, notBefore: Date?) {}
    func cancelDelayedUploads() async {}
    func cancelAll() async {}
}
