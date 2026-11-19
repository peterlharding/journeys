//
//  SyncEngine.swift
//  Journeys
//
//  Uploads pending journeys and waypoints to POST /sync (docs/OFFLINE_SYNC.md, phase 3).
//

import CoreData
import Foundation

/// Uploads what the phone has recorded, oldest first, in batches of up to 500 of each kind.
///
/// A record becomes synced only from the server's answer for it, so a lost reply just means the
/// batch is sent again and the server answers "duplicate". Automatic syncs run only when
/// `NetworkStatusProviding` allows (Wi-Fi); Sync now may use any network.
/// Reading and writing records happens on a background context; the published status is for the UI.
@MainActor
final class SyncEngine: ObservableObject {
    enum Status: Equatable {
        /// Nothing being sent, nothing waiting on the network.
        case idle
        case syncing
        /// Records are waiting and automatic sync is not allowed on this network.
        case waitingForWiFi
        /// The last attempt failed; it is retried automatically after a delay.
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var pendingJourneys = 0
    @Published private(set) var pendingWaypoints = 0
    @Published private(set) var rejected = 0
    @Published private(set) var lastSyncedAt: Date?

    var pendingCount: Int { pendingJourneys + pendingWaypoints }

    /// Delay before retrying after `failures` failed attempts in a row: 30 s, doubling, at most 30 minutes.
    nonisolated static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(failures, 1) - 1)), 30 * 60)
    }

    static let lastSyncedAtKey = "lastSyncedAt"

    private let store: Store
    private let api: APIClient
    private let network: NetworkStatusProviding
    private let defaults: UserDefaults
    private let debounce: Duration

    private var isSyncing = false
    private var consecutiveFailures = 0
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    init(store: Store, api: APIClient, network: NetworkStatusProviding, defaults: UserDefaults = .standard,
         debounce: Duration = .seconds(5)) {
        self.store = store
        self.api = api
        self.network = network
        self.defaults = defaults
        self.debounce = debounce
        lastSyncedAt = defaults.object(forKey: Self.lastSyncedAtKey) as? Date
        network.onChange = { [weak self] in self?.networkChanged() }
        refreshCounts()
    }

    // MARK: - Triggers

    /// A journey or waypoint was saved: sync shortly, so a burst of records goes in one batch.
    func recordSaved() {
        refreshCounts()
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.syncAutomatically()
        }
    }

    /// The app came to the foreground.
    func appBecameActive() {
        Task { await syncAutomatically() }
    }

    /// Sync now: any network, straight away, regardless of earlier failures.
    func syncNow() async {
        await sync(network: .any)
    }

    /// Syncs if the network allows automatic sync; otherwise waits for it.
    func syncAutomatically() async {
        guard network.allowsAutomaticSync else {
            refreshCounts()
            if pendingCount > 0 { status = .waitingForWiFi }
            return
        }
        await sync(network: .unmeteredOnly)
    }

    private func networkChanged() {
        // A new network deserves a fresh attempt rather than the rest of an old backoff.
        consecutiveFailures = 0
        retryTask?.cancel()
        Task { await syncAutomatically() }
    }

    // MARK: - Syncing

    private func sync(network use: APIClient.NetworkUse) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        retryTask?.cancel()
        status = .syncing

        do {
            var uploaded = false
            while true {
                let batch = await makeBatch()
                if batch.isEmpty { break }
                let data = try await api.post("sync", body: batch, encoder: .sync, network: use)
                let response = try JSONDecoder().decode(SyncResponse.self, from: data)
                let progressed = await apply(response, to: batch)
                uploaded = uploaded || progressed
                // A server that answers none of the records would otherwise be asked forever.
                if !progressed { break }
            }
            consecutiveFailures = 0
            // "Last synced" means the server confirmed records, not that there was nothing to send.
            if uploaded {
                lastSyncedAt = .now
                defaults.set(lastSyncedAt, forKey: Self.lastSyncedAtKey)
            }
            refreshCounts()
            status = .idle
        } catch let error as URLError where error.networkUnavailableReason != nil {
            // Only mobile data or Low Data Mode is available for an automatic sync: wait for Wi-Fi.
            refreshCounts()
            status = .waitingForWiFi
        } catch {
            consecutiveFailures += 1
            refreshCounts()
            status = .failed(error.localizedDescription)
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        let delay = Self.retryDelay(afterFailures: consecutiveFailures)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.syncAutomatically()
        }
    }

    /// The oldest pending records: journeys first, then waypoints whose journey the server has or
    /// is about to receive in this batch, so none is rejected just for arriving before its journey.
    private func makeBatch() async -> SyncBatch {
        let context = store.container.newBackgroundContext()
        return await context.perform {
            let pending = NSPredicate(format: "syncStateValue == %d", SyncState.pending.rawValue)

            let journeyRequest = Journey.fetchRequest(matching: pending)
            journeyRequest.fetchLimit = SyncBatch.maxRecords
            let journeys = (try? context.fetch(journeyRequest)) ?? []

            let waypointRequest = NSFetchRequest<Waypoint>(entityName: "Waypoint")
            waypointRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                pending,
                NSPredicate(format: "journey.syncStateValue == %d OR journey IN %@",
                            SyncState.synced.rawValue, journeys)
            ])
            waypointRequest.sortDescriptors = [NSSortDescriptor(key: "recordedAt", ascending: true)]
            waypointRequest.fetchLimit = SyncBatch.maxRecords
            let waypoints = (try? context.fetch(waypointRequest)) ?? []

            return SyncBatch(
                journeys: journeys.map {
                    SyncBatch.Journey(id: $0.id, name: $0.name, notes: $0.notes, createdAt: $0.createdAt)
                },
                waypoints: waypoints.compactMap { waypoint in
                    guard let journey = waypoint.journey else { return nil }
                    return SyncBatch.Waypoint(id: waypoint.id, journeyId: journey.id,
                                              recordedAt: waypoint.recordedAt, latitude: waypoint.latitude,
                                              longitude: waypoint.longitude,
                                              horizontalAccuracy: waypoint.horizontalAccuracy,
                                              speed: waypoint.speed, course: waypoint.course,
                                              source: waypoint.sourceValue)
                }
            )
        }
    }

    /// Records the server's answers. Returns whether any record got an answer.
    private func apply(_ response: SyncResponse, to batch: SyncBatch) async -> Bool {
        let journeyOutcomes = SyncResponse.byID(response.journeys)
        let waypointOutcomes = SyncResponse.byID(response.waypoints)
        let context = store.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        return await context.perform {
            let now = Date.now
            // Journeys first: a rejected journey marks its waypoints with its own reason.
            let answered = Self.applyJourneys(journeyOutcomes, ids: batch.journeys.map(\.id), in: context, at: now)
                + Self.applyWaypoints(waypointOutcomes, ids: batch.waypoints.map(\.id), in: context, at: now)
            do {
                try context.save()
            } catch {
                print("Could not save sync results: \(error)")
                return false
            }
            return answered > 0
        }
    }

    /// Returns how many journeys got an answer.
    private nonisolated static func applyJourneys(_ outcomes: [UUID: SyncResponse.Outcome], ids: [UUID],
                                                  in context: NSManagedObjectContext, at now: Date) -> Int {
        let request = Journey.fetchRequest(matching: NSPredicate(format: "id IN %@", ids))
        var answered = 0
        for journey in (try? context.fetch(request)) ?? [] {
            guard let outcome = outcomes[journey.id] else { continue }
            answered += 1
            switch outcome {
            case .accepted:
                journey.syncState = .synced
                journey.syncedAt = now
                journey.syncError = nil
            case .rejected(let reason):
                journey.syncState = .rejected
                journey.syncError = reason
                // Its waypoints can never be accepted without it.
                for waypoint in journey.waypoints where waypoint.syncState == .pending {
                    waypoint.syncState = .rejected
                    waypoint.syncError = "Its journey was rejected: \(reason)"
                }
            }
        }
        return answered
    }

    /// Returns how many waypoints got an answer.
    private nonisolated static func applyWaypoints(_ outcomes: [UUID: SyncResponse.Outcome], ids: [UUID],
                                                   in context: NSManagedObjectContext, at now: Date) -> Int {
        let request = NSFetchRequest<Waypoint>(entityName: "Waypoint")
        request.predicate = NSPredicate(format: "id IN %@", ids)
        var answered = 0
        for waypoint in (try? context.fetch(request)) ?? [] {
            guard let outcome = outcomes[waypoint.id] else { continue }
            answered += 1
            // Already marked with its journey's reason, which says more than the server's
            // "no journey with id" for a waypoint whose journey it refused.
            if waypoint.journey?.syncState == .rejected { continue }
            switch outcome {
            case .accepted:
                waypoint.syncState = .synced
                waypoint.syncedAt = now
                waypoint.syncError = nil
            case .rejected(let reason):
                waypoint.syncState = .rejected
                waypoint.syncError = reason
            }
        }
        return answered
    }

    /// Recounts pending and rejected records for the status line.
    func refreshCounts() {
        let context = store.viewContext
        func count(_ entity: String, _ format: String, _ arguments: [Any]) -> Int {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
            request.predicate = NSPredicate(format: format, argumentArray: arguments)
            return (try? context.count(for: request)) ?? 0
        }
        let pending = SyncState.pending.rawValue
        let rejectedState = SyncState.rejected.rawValue
        pendingJourneys = count("Journey", "syncStateValue == %d", [pending])
        // Fixes taken with no journey are never uploaded, so they are not waiting for anything.
        pendingWaypoints = count("Waypoint", "syncStateValue == %d AND journey != nil", [pending])
        rejected = count("Journey", "syncStateValue == %d", [rejectedState])
            + count("Waypoint", "syncStateValue == %d", [rejectedState])
    }
}
