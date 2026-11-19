//
//  TestSupport.swift
//  JourneysTests
//

import CoreLocation
import XCTest
@testable import Journeys

func makeFix(latitude: Double = -33.8688, longitude: Double = 151.2093, at time: Date) -> CLLocation {
    CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
               altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: time)
}

/// A client whose requests are answered by `StubURLProtocol`, never the network.
func makeStubAPI() -> APIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return APIClient(baseURL: URL(string: "https://api.test")!, configuration: configuration)
}

/// Defaults of their own, so tests never see or change the app's.
func makeTestDefaults() -> UserDefaults {
    let name = "JourneysTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// A location manager on an empty in-memory store, with its own defaults.
@MainActor
func makeManager(store: Store? = nil, syncEngine: SyncEngine? = nil, defaults: UserDefaults? = nil) -> LocationManager {
    LocationManager(store: store ?? .inMemory(), syncEngine: syncEngine, defaults: defaults ?? makeTestDefaults())
}

/// A network the test switches between Wi-Fi (automatic sync allowed) and mobile data.
@MainActor
final class FakeNetwork: NetworkStatusProviding {
    var allowsAutomaticSync: Bool {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    init(wifi: Bool) {
        allowsAutomaticSync = wifi
    }
}

/// Waits, without blocking the main actor, until `condition` holds or two seconds have passed.
@MainActor
func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), "Timed out waiting", file: file, line: line)
}

/// Stands in for iOS's background transfer service: holds queued uploads until the test delivers
/// them (as iOS would once Wi-Fi is available), answering with `respond`.
@MainActor
final class FakeUploader: SyncUploading {
    struct Upload {
        let body: Data
        let notBefore: Date?
    }

    var onFinish: ((Result<(status: Int, body: Data), Error>) -> Void)?
    /// Answers an upload body; throwing fails the upload as if the network were down.
    var respond: (Data) throws -> (Int, Data) = { _ in (200, Data(#"{"journeys": {}, "waypoints": {}}"#.utf8)) }

    private(set) var queued: [Upload] = []
    private(set) var cancelCount = 0

    /// Suspends, as asking the real session does, so racing callers interleave as they would on a phone.
    func hasUploadInFlight() async -> Bool {
        await Task.yield()
        return !queued.isEmpty
    }

    func upload(_ body: Data, notBefore: Date?) {
        queued.append(Upload(body: body, notBefore: notBefore))
    }

    func cancelDelayedUploads() async {
        let delayed = queued.filter { ($0.notBefore ?? .distantPast) > .now }
        queued.removeAll { ($0.notBefore ?? .distantPast) > .now }
        for _ in delayed {
            onFinish?(.failure(URLError(.cancelled)))
        }
    }

    func cancelAll() async {
        cancelCount += 1
        let cancelled = queued
        queued = []
        for _ in cancelled {
            onFinish?(.failure(URLError(.cancelled)))
        }
    }

    /// Performs the oldest queued upload and reports the answer, as iOS would.
    func deliverNext() {
        guard !queued.isEmpty else { return }
        let upload = queued.removeFirst()
        do {
            let (status, body) = try respond(upload.body)
            onFinish?(.success((status, body)))
        } catch {
            onFinish?(.failure(error))
        }
    }
}

/// A stand-in for POST /sync with the real server's rules (mongo-api doc/SYNC.md): records are
/// stored once by id, a waypoint needs its journey, and a journey named "Reject me" is refused.
final class FakeSyncServer {
    private(set) var journeys: [String: [String: Any]] = [:]
    private(set) var waypoints: [String: [String: Any]] = [:]
    /// Each request's body, decoded.
    private(set) var batches: [[String: Any]] = []
    /// When set, the next request is processed but its reply is lost.
    var loseNextReply = false

    func respond(to body: Data) throws -> (Int, Data) {
        let batch = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        batches.append(batch)
        var journeyAnswers: [String: String] = [:]
        var waypointAnswers: [String: String] = [:]
        for journey in batch["journeys"] as? [[String: Any]] ?? [] {
            let id = (journey["id"] as? String ?? "").uppercased()
            if journey["name"] as? String == "Reject me" {
                journeyAnswers[id] = "rejected: name not allowed"
            } else {
                journeyAnswers[id] = journeys[id] == nil ? "stored" : "duplicate"
                journeys[id] = journeys[id] ?? journey
            }
        }
        for waypoint in batch["waypoints"] as? [[String: Any]] ?? [] {
            let id = (waypoint["id"] as? String ?? "").uppercased()
            let journeyID = (waypoint["journeyId"] as? String ?? "").uppercased()
            if waypoints[id] != nil {
                waypointAnswers[id] = "duplicate"
            } else if journeys[journeyID] == nil {
                waypointAnswers[id] = "rejected: no journey with id \(journeyID)"
            } else {
                waypoints[id] = waypoint
                waypointAnswers[id] = "stored"
            }
        }
        if loseNextReply {
            loseNextReply = false
            throw URLError(.networkConnectionLost)
        }
        let reply = try JSONSerialization.data(withJSONObject: ["journeys": journeyAnswers,
                                                                "waypoints": waypointAnswers])
        return (200, reply)
    }
}
