//
//  SyncPayload.swift
//  Journeys
//
//  The JSON exchanged with POST /sync (mongo-api doc/SYNC.md).
//

import Foundation

struct SyncBatch: Encodable, Sendable {
    struct Journey: Encodable, Sendable {
        let id: UUID
        let name: String
        let notes: String
        let createdAt: Date
    }

    struct Waypoint: Encodable, Sendable {
        let id: UUID
        let journeyId: UUID
        let recordedAt: Date
        let latitude: Double
        let longitude: Double
        let horizontalAccuracy: Double
        let speed: Double
        let course: Double
        let source: String
    }

    /// The server takes at most this many of each per request.
    static let maxRecords = 500

    var journeys: [Journey] = []
    var waypoints: [Waypoint] = []

    var isEmpty: Bool { journeys.isEmpty && waypoints.isEmpty }
}

/// The server's answer for each record: "stored", "duplicate" or "rejected: <reason>".
struct SyncResponse: Decodable, Sendable {
    let journeys: [String: String]
    let waypoints: [String: String]

    enum Outcome: Equatable {
        /// Stored now or by an earlier upload: the server has it.
        case accepted
        case rejected(reason: String)
    }

    static func outcome(_ answer: String) -> Outcome {
        if answer == "stored" || answer == "duplicate" { return .accepted }
        let prefix = "rejected: "
        return .rejected(reason: answer.hasPrefix(prefix) ? String(answer.dropFirst(prefix.count)) : answer)
    }

    /// The answers keyed by id; ids the server spelled differently from the phone still match.
    static func byID(_ answers: [String: String]) -> [UUID: Outcome] {
        Dictionary(answers.compactMap { key, answer in UUID(uuidString: key).map { ($0, outcome(answer)) } },
                   uniquingKeysWith: { first, _ in first })
    }
}

extension JSONEncoder {
    /// Dates as ISO 8601 with fractional seconds, as the API expects.
    static let sync: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }()
}
