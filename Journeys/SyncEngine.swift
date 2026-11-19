//
//  SyncEngine.swift
//  Journeys
//
//  Uploads pending journeys and waypoints to POST /sync (docs/OFFLINE_SYNC.md, phases 3 and 4).
//

import CoreData
import Foundation

/// Uploads what the phone has recorded, oldest first, in batches of up to 500 of each kind.
///
/// A record becomes synced only from the server's answer for it, so a lost reply just means the
/// batch is sent again and the server answers "duplicate". Automatic syncs are handed to a
/// `SyncUploading` (iOS's background transfer service), which uploads on Wi-Fi only, even while the
/// app is suspended; Sync now uploads in the foreground on any network.
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

    let store: Store
    private let api: APIClient
    private let uploader: SyncUploading
    private let network: NetworkStatusProviding
    private let defaults: UserDefaults
    private let debounce: Duration

    /// A Sync now is running in the foreground.
    private var isSyncingNow = false
    /// An automatic sync is deciding whether to hand over a batch. Set before the first suspension,
    /// so triggers that arrive together (at launch: becoming active, the network's first report)
    /// hand over one batch, not one each.
    private var isQueueing = false
    private var consecutiveFailures = 0
    private var debounceTask: Task<Void, Never>?
    /// Recording an upload's answer and queueing the next batch; awaited before iOS suspends the app.
    private var currentWork: Task<Void, Never>?

    init(store: Store, api: APIClient, uploader: SyncUploading, network: NetworkStatusProviding,
         defaults: UserDefaults = .standard, debounce: Duration = .seconds(5)) {
        self.store = store
        self.api = api
        self.uploader = uploader
        self.network = network
        self.defaults = defaults
        self.debounce = debounce
        lastSyncedAt = defaults.object(forKey: Self.lastSyncedAtKey) as? Date
        network.onChange = { [weak self] in self?.networkChanged() }
        uploader.onFinish = { [weak self] result in self?.uploadFinished(result) }
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

    /// The app came to the foreground: try at once, rather than waiting out a queued retry's delay.
    func appBecameActive() {
        Task {
            await uploader.cancelDelayedUploads()
            await syncAutomatically()
        }
    }

    /// Hands the next batch to the background uploader, unless one is already with it.
    /// iOS uploads it on Wi-Fi, even if the app is suspended by then.
    func syncAutomatically() async {
        refreshCounts()
        guard !isSyncingNow, !isQueueing else { return }
        isQueueing = true
        defer { isQueueing = false }
        guard pendingCount > 0 else {
            if case .failed = status {} else { status = .idle }
            return
        }
        if await uploader.hasUploadInFlight() {
            if case .failed = status {} else { showUploadQueued() }
            return
        }
        if await queueNextBatch(notBefore: nil) {
            showUploadQueued()
        }
    }

    /// Sync now: straight away in the foreground, on any network, regardless of earlier failures.
    func syncNow() async {
        guard !isSyncingNow else { return }
        isSyncingNow = true
        defer { isSyncingNow = false }
        // Anything queued for later would only be answered "duplicate"; this upload replaces it.
        await uploader.cancelAll()
        status = .syncing

        do {
            var uploaded = false
            while true {
                let batch = await makeBatch()
                if batch.isEmpty { break }
                let data = try await api.post("sync", body: batch, encoder: .sync, network: .any)
                let progressed = await apply(try JSONDecoder().decode(SyncResponse.self, from: data))
                uploaded = uploaded || progressed
                // A server that answers none of the records would otherwise be asked forever.
                if !progressed { break }
            }
            succeeded(uploaded: uploaded)
        } catch {
            await failed(error)
        }
    }

    /// iOS relaunched the app to deliver background upload answers: `completion` lets it suspend the
    /// app again, once the answers are recorded and the next batch is queued.
    func backgroundEventsFinished(_ completion: @escaping () -> Void) {
        let work = currentWork
        Task {
            await work?.value
            completion()
        }
    }

    private func networkChanged() {
        guard network.allowsAutomaticSync else {
            if pendingCount > 0, case .syncing = status { status = .waitingForWiFi }
            return
        }
        Task {
            // A new network deserves a fresh attempt rather than the rest of an old backoff.
            if consecutiveFailures > 0 {
                consecutiveFailures = 0
                await uploader.cancelAll()
            }
            await syncAutomatically()
        }
    }

    // MARK: - Syncing

    private func showUploadQueued() {
        status = network.allowsAutomaticSync ? .syncing : .waitingForWiFi
    }

    /// Queues the oldest pending records with the background uploader. Returns false if there were none.
    @discardableResult
    private func queueNextBatch(notBefore: Date?) async -> Bool {
        let batch = await makeBatch()
        guard !batch.isEmpty, let body = try? JSONEncoder.sync.encode(batch) else { return false }
        uploader.upload(body, notBefore: notBefore)
        return true
    }

    private func uploadFinished(_ result: Result<(status: Int, body: Data), Error>) {
        let previous = currentWork
        currentWork = Task {
            await previous?.value
            switch result {
            case .success(let (code, body)) where (200..<300).contains(code):
                do {
                    let progressed = await apply(try JSONDecoder().decode(SyncResponse.self, from: body))
                    succeeded(uploaded: progressed)
                    if progressed, pendingCount > 0, await queueNextBatch(notBefore: nil) {
                        showUploadQueued()
                    }
                } catch {
                    await failed(error)
                }
            case .success(let (code, _)):
                await failed(APIError.unexpectedStatus(code))
            case .failure(let error as URLError) where error.code == .cancelled:
                // Cancelled by Sync now or a network change, which upload the records themselves.
                refreshCounts()
            case .failure(let error):
                await failed(error)
            }
        }
    }

    private func succeeded(uploaded: Bool) {
        consecutiveFailures = 0
        // "Last synced" means the server confirmed records, not that there was nothing to send.
        if uploaded {
            lastSyncedAt = .now
            defaults.set(lastSyncedAt, forKey: Self.lastSyncedAtKey)
        }
        refreshCounts()
        status = .idle
    }

    /// Shows the failure and queues a retry with the background uploader, which waits out the delay
    /// itself, so the retry happens even if the app is suspended by then.
    private func failed(_ error: Error) async {
        consecutiveFailures += 1
        refreshCounts()
        status = .failed(error.localizedDescription)
        let delay = Self.retryDelay(afterFailures: consecutiveFailures)
        await queueNextBatch(notBefore: .now.addingTimeInterval(delay))
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
