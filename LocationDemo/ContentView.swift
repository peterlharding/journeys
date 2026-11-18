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
                
                Button(action: {
                    isModalPresented = true // Show modal to create a new journey
                }) {
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
                    Text("Latitude: \(locationManager.userLatitude)")
                    Text("Longitude: \(locationManager.userLongitude)")
                        .padding()
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
                    Button(action: {
                        locationManager.requestLocation() // Call the update method on the LocationManager
                    }) {
                        Text("Check Location")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .padding()
                    
                    Button(action: {
                        if locationManager.isTracking {
                            locationManager.stopTracking()
                        } else {
                            locationManager.startTracking()
                        }
                    }) {
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
//                    Map(coordinateRegion: $locationManager.currentLocation.coordinateRegion) { MapPin(coordinate: $locationManager.currentLocation.coordinate) }
                    Text("\(locationManager.locations.count) locations recorded")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recordCount")
                    // Displaying the list of all recorded locations
                    List(locationManager.locations, id: \.timestamp) { location in
                        VStack(alignment: .leading) {
                            Text("Latitude: \(location.coordinate.latitude)")
                            Text("Longitude: \(location.coordinate.longitude)")
                            Text("Timestamp: \(location.timestamp)")
                                .font(.caption)
                            HStack {
                                Text("Open in - ")
                                if let googleMapsURL = createGoogleMapsURL(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude) {
                                    Link("Google Maps", destination: googleMapsURL)
                                }
                                if let appleMapsURL = createAppleMapsURL(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude) {
                                    Link("Apple Maps", destination: appleMapsURL)
                                }
                            }

                        }
                    }
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
