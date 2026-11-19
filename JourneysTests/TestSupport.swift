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

/// A location manager on an empty in-memory store, a stubbed API and its own defaults.
@MainActor
func makeManager(store: Store? = nil, defaults: UserDefaults? = nil) -> LocationManager {
    LocationManager(store: store ?? .inMemory(), api: makeStubAPI(), defaults: defaults ?? makeTestDefaults())
}

/// Waits, without blocking the main actor, until `condition` holds or a second has passed.
@MainActor
func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<100 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), "Timed out waiting", file: file, line: line)
}
