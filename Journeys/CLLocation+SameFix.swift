//
//  CLLocation+SameFix.swift
//  Journeys
//

import CoreLocation

extension CLLocation {
    /// Whether this is the same fix as `other`: same time and same position.
    /// Core Location can hand the same cached fix over more than once, so a timestamp alone is not an identity.
    func isSameFix(as other: CLLocation) -> Bool {
        timestamp == other.timestamp
            && coordinate.latitude == other.coordinate.latitude
            && coordinate.longitude == other.coordinate.longitude
    }
}
