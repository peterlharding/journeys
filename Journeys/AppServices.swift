//
//  AppServices.swift
//  Journeys
//
//  The app's long-lived objects, created once at launch, including background launches.
//

import BackgroundTasks
import UIKit

/// Created at launch, before any window: iOS can launch the app in the background to deliver
/// background upload answers or run the refresh task, and those need the store and sync engine
/// without a screen.
@MainActor
final class AppServices {
    static let shared = AppServices()

    /// Wakes the app now and then to queue any records left waiting (a backstop for the background uploads).
    static let refreshTaskIdentifier = "com.performiq.Journeys.refresh"

    let uploader: BackgroundUploader
    let syncEngine: SyncEngine
    let locationManager: LocationManager

    private init() {
        uploader = BackgroundUploader(baseURL: APIClient.shared.baseURL)
        syncEngine = SyncEngine(store: .shared, api: .shared, uploader: uploader, network: NetworkMonitor())
        locationManager = LocationManager(store: .shared, syncEngine: syncEngine)
        uploader.onEventsFinished = { [syncEngine] completion in
            syncEngine.backgroundEventsFinished(completion)
        }
    }

    /// Must be called before launch finishes.
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in AppServices.shared.handleRefresh(task) }
        }
    }

    /// Asks iOS for a refresh in 15 minutes or later, if anything is waiting to upload.
    func scheduleRefreshIfNeeded() {
        syncEngine.refreshCounts()
        guard syncEngine.pendingCount > 0 else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule the refresh task: \(error)")
        }
    }

    private func handleRefresh(_ task: BGAppRefreshTask) {
        let work = Task { await syncEngine.syncAutomatically() }
        task.expirationHandler = { work.cancel() }
        Task {
            await work.value
            scheduleRefreshIfNeeded()
            task.setTaskCompleted(success: true)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Unit tests run inside the app; it then stays inert, so tests never upload real data.
    static let isHostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard !Self.isHostingUnitTests else { return true }
        MainActor.assumeIsolated {
            // Creating the services reconnects to uploads handed to iOS before the app was suspended.
            AppServices.shared.registerBackgroundTasks()
        }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploader.sessionIdentifier else { return completionHandler() }
        MainActor.assumeIsolated {
            AppServices.shared.uploader.eventsCompletionHandler = completionHandler
        }
    }
}
