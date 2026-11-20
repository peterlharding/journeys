//
//  JourneysApp.swift
//  Journeys
//
//  Created by Peter Harding on 14/10/2024.
//

import SwiftUI

@main
struct JourneysApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            if AppDelegate.isHostingUnitTests {
                Text("Running unit tests")
            } else {
                RootView()
            }
        }
    }
}

/// The main screen with the app's services, syncing whenever the app becomes active.
private struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var syncEngine = AppServices.shared.syncEngine
    @StateObject private var auth = AppServices.shared.auth
    @StateObject private var locationManager = AppServices.shared.locationManager

    var body: some View {
        ContentView()
            .environment(\.managedObjectContext, Store.shared.viewContext)
            .environmentObject(locationManager)
            .environmentObject(syncEngine)
            .environmentObject(auth)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: syncEngine.appBecameActive()
                case .background: AppServices.shared.scheduleRefreshIfNeeded()
                default: break
                }
            }
    }
}
