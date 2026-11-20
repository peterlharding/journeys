//
//  SyncEngine.swift
//  Journeys
//
//  Uploads pending journeys and waypoints to the API's sync endpoint (docs/OFFLINE_SYNC.md, phases 3
//  and 4), as the signed-in user.
//

import CoreData
import Foundation

/// Uploads what the phone has recorded, oldest first, in batches of up to 500 of each kind.
///
/// A record becomes synced only from the server's answer for it, so a lost reply just means the
/// batch is sent again and the server answers "duplicate". Automatic syncs are handed to a
/// `SyncUploading` (iOS's background transfer service), which uploads on Wi-Fi only, even while the
/// app is suspended; Sync now uploads in the foreground on any network.
/// Uploads need a sign-in: each carries an access token from `AccessTokenProviding`, and a 401 (the
/// token expired while the upload waited for Wi-Fi) gets a fresh token and the batch is sent again.
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
        /// Records are waiting and nobody is signed in, or the server ended the sign-in.
        case signedOut
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
    private let auth: AccessTokenProviding
    private let defaults: UserDefaults
    private let debounce: Duration

    /// A Sync now is running in the foreground.
    private var isSyncingNow = false
    /// An automatic sync is deciding whether to hand over a batch. Set before the first suspension,
    /// so triggers that arrive together (at launch: becoming active, the network's first report)
    /// hand over one batch, not one each.
    private var isQueueing = false
    private var consecutiveFailures = 0
    /// Uploads refused with 401 since the last success; a second in a row is a real failure, not
    /// just a token that expired while waiting.
    private var unauthorizedInARow = 0
    private var debounceTask: Task<Void, Never>?
    /// Recording an upload's answer and queueing the next batch; awaited before iOS suspends the app.
    private var currentWork: Task<Void, Never>?

    init(store: Store, api: APIClient, uploader: SyncUploading, network: NetworkStatusProviding,
         auth: AccessTokenProviding, defaults: UserDefaults = .standard, debounce: Duration = .seconds(5)) {
        self.store = store
        self.api = api
        self.uploader = uploader
        self.network = network
        self.auth = auth
        self.defaults = defaults
        self.debounce = debounce
        lastSyncedAt = defaults.object(forKey: Self.lastSyncedAtKey) as? Date
        network.onChange = { [weak self] in self?.networkChanged() }
        uploader.onFinish = { [weak self] result in self?.uploadFinished(result) }
        auth.onChange = { [weak self] in self?.authChanged() }
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
        guard auth.isSignedIn else {
            status = .signedOut
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
        guard auth.isSignedIn else {
            refreshCounts()
            status = .signedOut
            return
        }
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
                let data = try await post(batch)
                let progressed = await apply(try JSONDecoder().decode(SyncResponse.self, from: data))
                uploaded = uploaded || progressed
                // A server that answers none of the records would otherwise be asked forever.
                if !progressed { break }
            }
            succeeded(uploaded: uploaded)
        } catch AuthError.signedOut {
            showSignedOut()
        } catch {
            await failed(error)
        }
    }

    /// Posts a batch in the foreground; after a 401, once more with a fresh token.
    private func post(_ batch: SyncBatch) async throws -> Data {
        let token = try await auth.accessToken()
        do {
            return try await api.post(APIClient.Path.sync, body: batch, encoder: .sync, bearer: token, network: .any)
        } catch APIError.unexpectedStatus(APIError.unauthorized) {
            auth.tokenRejected(token)
            return try await api.post(APIClient.Path.sync, body: batch, encoder: .sync,
                                      bearer: try await auth.accessToken(), network: .any)
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

    /// Signed in: upload what is waiting. Signed out: stop, keeping the records for the next sign-in.
    private func authChanged() {
        Task {
            if auth.isSignedIn {
                consecutiveFailures = 0
                unauthorizedInARow = 0
                status = .idle
                await syncAutomatically()
            } else {
                await uploader.cancelAll()
                showSignedOut()
            }
        }
    }

    private func showSignedOut() {
        refreshCounts()
        status = pendingCount > 0 ? .signedOut : .idle
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

    /// Queues the oldest pending records with the background uploader. Returns false if there were
    /// none, or nobody is signed in.
    @discardableResult
    private func queueNextBatch(notBefore: Date?) async -> Bool {
        let token: String?
        do {
            token = try await auth.accessToken()
        } catch AuthError.signedOut {
            showSignedOut()
            return false
        } catch {
            // No network for the refresh: queue with the old token, and the 401 brings us back here.
            token = auth.cachedAccessToken
        }
        let batch = await makeBatch()
        guard !batch.isEmpty, let body = try? JSONEncoder.sync.encode(batch) else { return false }
        uploader.upload(body, token: token, notBefore: notBefore)
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
            case .success((APIError.unauthorized, _)):
                await unauthorized()
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

    /// The upload's token was refused, most likely because it expired while the upload waited for
    /// Wi-Fi: send the batch again at once with a fresh one. Refused twice in a row, back off.
    private func unauthorized() async {
        unauthorizedInARow += 1
        if let token = auth.cachedAccessToken {
            auth.tokenRejected(token)
        }
        guard unauthorizedInARow == 1 else {
            await failed(APIError.unexpectedStatus(APIError.unauthorized))
            return
        }
        if await queueNextBatch(notBefore: nil) {
            showUploadQueued()
        }
    }

    private func succeeded(uploaded: Bool) {
        consecutiveFailures = 0
        unauthorizedInARow = 0
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
