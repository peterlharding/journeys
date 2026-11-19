//
//  RecordedLocation.swift
//  LocationDemo
//

import CoreLocation

/// A location fix the app has recorded, with its own identity for display in lists.
/// A fix's timestamp is not a reliable identity: the same cached fix can be delivered more than once.
struct RecordedLocation: Identifiable {
    let id = UUID()
    let location: CLLocation
}

extension CLLocation {
    /// Whether this is the same fix as `other`: same time and same position.
    func isSameFix(as other: CLLocation) -> Bool {
        timestamp == other.timestamp
            && coordinate.latitude == other.coordinate.latitude
            && coordinate.longitude == other.coordinate.longitude
    }
}
