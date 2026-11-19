//
//  JourneysApp.swift
//  Journeys
//
//  Created by Peter Harding on 14/10/2024.
//

import SwiftUI

@main
struct JourneysApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var syncEngine: SyncEngine
    @StateObject private var locationManager: LocationManager

    /// Unit tests run inside the app; the app then stays inert, so tests never upload real data.
    private static let isHostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        let network: NetworkStatusProviding = Self.isHostingUnitTests ? NoNetwork() : NetworkMonitor()
        let engine = SyncEngine(store: .shared, api: .shared, network: network)
        _syncEngine = StateObject(wrappedValue: engine)
        _locationManager = StateObject(wrappedValue: LocationManager(store: .shared, syncEngine: engine))
    }

    var body: some Scene {
        WindowGroup {
            if Self.isHostingUnitTests {
                Text("Running unit tests")
            } else {
                ContentView()
                    .environment(\.managedObjectContext, Store.shared.viewContext)
                    .environmentObject(locationManager)
                    .environmentObject(syncEngine)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !Self.isHostingUnitTests {
                syncEngine.appBecameActive()
            }
        }
    }
}

/// The network while hosting unit tests: automatic sync is never allowed.
@MainActor
private final class NoNetwork: NetworkStatusProviding {
    let allowsAutomaticSync = false
    var onChange: (() -> Void)?
}
