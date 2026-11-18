//
//  LocationData.swift
//  LocationDemo
//
//  Created by Peter Harding on 14/10/2024.
//

import Foundation

struct LocationData: Codable {
    let latitude: Double
    let longitude: Double
    let timestamp: String
    let journeyId: String  // A GUID
}


