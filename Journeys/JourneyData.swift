//
//  Journey.swift
//  Journeys
//
//  Created by Peter Harding on 14/10/2024.
//

import Foundation

struct JourneyData: Identifiable, Codable {
    let id: UUID
    var name: String
    var notes: String
}
