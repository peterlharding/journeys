//
//  ContentView.swift
//  LocationDemo
//
//  Created by Peter Harding on 14/10/2024.
//

import SwiftUI
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
    @StateObject private var locationManager = LocationManager()

    @State private var isModalPresented: Bool = false
    @State private var showLocations: Bool = true // State variable to control showing the list

    var body: some View {
        VStack {
            if locationManager.permissionDenied {
                Text("Location permission denied. Please enable it in settings.")
                    .foregroundColor(.red)
            } else {
                if let journey = locationManager.currentJourney {
                    Text("Current Journey: \(journey.name)")
                        .font(.headline)
                    Text("Notes: \(journey.notes)")
                        .font(.subheadline)
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

                if showLocations {
                    Text("Current Location")
                        .font(.largeTitle)
                    if locationManager.locations.isEmpty {
                        Text("No location yet")
                            .foregroundStyle(.secondary)
                            .padding(.bottom)
                    } else {
                        VStack(spacing: 4) {
                            Text("Latitude: \(locationManager.userLatitude)")
                            Text("Longitude: \(locationManager.userLongitude)")
                        }
                        .padding(.bottom)
                    }
                }

//                Button(action: {
//                    locationManager.startNewJourney() // Generate a new GUID for the journey
//                }) {
//                    Text("New Journey")
//                        .padding()
//                        .background(Color.orange)
//                        .foregroundColor(.white)
//                        .cornerRadius(8)
//                }
//                .padding()
//                Text(locationManager.journeyGUID)

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

                Toggle(isOn: $showLocations) {
                    Text("Show Locations")
                }
                .toggleStyle(CheckboxToggleStyle()) // Apply checkbox style
                .padding()

                if showLocations {
                    Text("^[\(locationManager.locations.count) location](inflect: true) recorded")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recordCount")
                    // Displaying the list of all recorded locations
                    List(locationManager.locations) { recorded in
                        let location = recorded.location
                        VStack(alignment: .leading) {
                            Text("Latitude: \(location.coordinate.latitude)")
                            Text("Longitude: \(location.coordinate.longitude)")
                            Text("Timestamp: \(location.timestamp)")
                                .font(.caption)
                            HStack {
                                Text("Open in - ")
                                let coordinate = location.coordinate
                                if let googleMapsURL = createGoogleMapsURL(latitude: coordinate.latitude,
                                                                           longitude: coordinate.longitude) {
                                    Link("Google Maps", destination: googleMapsURL)
                                }
                                if let appleMapsURL = createAppleMapsURL(latitude: coordinate.latitude,
                                                                         longitude: coordinate.longitude) {
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
        }
        .padding()
        .sheet(isPresented: $isModalPresented) {
            NewJourneyModal(isPresented: $isModalPresented,
                            currentJourney: $locationManager.currentJourney,
                            locationManager: locationManager)
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
    ContentView()
}
