//
//  BackgroundUploader.swift
//  Journeys
//
//  Automatic sync uploads go through iOS's background transfer service (docs/OFFLINE_SYNC.md, phase 4).
//

import Foundation

/// Uploads a sync batch and reports the server's answer, possibly long after the app was suspended.
/// A protocol so tests can stand in for iOS's transfer service.
@MainActor
protocol SyncUploading: AnyObject {
    /// Called on the main actor when an upload finishes, with the HTTP status and body, or the error.
    var onFinish: ((Result<(status: Int, body: Data), Error>) -> Void)? { get set }
    /// Whether an upload is queued or running, including one handed over before a relaunch.
    func hasUploadInFlight() async -> Bool
    /// Queues `body` for `POST /sync`, not before `notBefore`.
    func upload(_ body: Data, notBefore: Date?)
    /// Cancels uploads still waiting out a start delay, or aimed at another server, so a fresh one
    /// can go at once (the app was opened).
    func cancelDelayedUploads() async
    /// Cancels queued and running uploads (the server's idempotency makes resending safe).
    func cancelAll() async
}

/// Hands uploads to a background `URLSession`: iOS performs them even while the app is suspended or
/// has been terminated by the system, as soon as an allowed network appears, then relaunches the app
/// in the background to deliver the answer. The session refuses mobile data and Low Data Mode, so
/// automatic uploads happen on Wi-Fi only. A user force-quitting the app cancels them.
final class BackgroundUploader: NSObject, SyncUploading, URLSessionDataDelegate, @unchecked Sendable {
    static let sessionIdentifier = "com.performiq.Journeys.sync"

    @MainActor var onFinish: ((Result<(status: Int, body: Data), Error>) -> Void)?

    /// Set by the app delegate when iOS relaunches the app for this session's events; called once
    /// the answers are recorded, so iOS can suspend the app again. iOS may report the events finished
    /// before handing the handler over, so either order works.
    @MainActor var eventsCompletionHandler: (() -> Void)? {
        didSet {
            if eventsFinishedWithoutHandler, eventsCompletionHandler != nil {
                eventsFinishedWithoutHandler = false
                finishEvents()
            }
        }
    }
    @MainActor private var eventsFinishedWithoutHandler = false
    /// Called when iOS has delivered all of this session's pending events.
    @MainActor var onEventsFinished: ((@escaping () -> Void) -> Void)?

    private let endpoint: URL
    private let directory: URL
    /// Uploads started since launch and not yet finished. The session's own task list can lag a
    /// just-started task, so it alone would let a second trigger queue a duplicate.
    @MainActor private var startedTasks: Set<Int> = []
    /// Response bodies by task, filled on the session's delegate queue.
    private var bodies: [Int: Data] = [:]
    private let lock = NSLock()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(baseURL: URL) {
        endpoint = baseURL.appending(path: "sync")
        directory = FileManager.default.temporaryDirectory.appending(path: "SyncUploads")
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = session  // Reconnect to uploads handed over before a relaunch.
    }

    func hasUploadInFlight() async -> Bool {
        if !startedTasks.isEmpty { return true }
        // Uploads handed over before a relaunch are known only to the session.
        return await session.allTasks.contains { $0.state == .running || $0.state == .suspended }
    }

    func cancelDelayedUploads() async {
        for task in await session.allTasks {
            let delayed = (task.earliestBeginDate ?? .distantPast) > .now
            let elsewhere = task.originalRequest?.url != endpoint
            if delayed || elsewhere {
                task.cancel()
            }
        }
    }

    @MainActor
    func upload(_ body: Data, notBefore: Date?) {
        // Background sessions only upload from a file.
        let file = directory.appending(path: "\(UUID().uuidString).json")
        do {
            try body.write(to: file)
        } catch {
            onFinish?(.failure(error))
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = file.path
        task.earliestBeginDate = notBefore
        startedTasks.insert(task.taskIdentifier)
        task.resume()
    }

    func cancelAll() async {
        for task in await session.allTasks {
            task.cancel()
        }
    }

    // MARK: - URLSessionDataDelegate (on the session's delegate queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = lock.withLock { bodies.removeValue(forKey: task.taskIdentifier) } ?? Data()
        if let path = task.taskDescription {
            try? FileManager.default.removeItem(atPath: path)
        }
        let result: Result<(status: Int, body: Data), Error>
        if let error {
            result = .failure(error)
        } else if let http = task.response as? HTTPURLResponse {
            result = .success((http.statusCode, body))
        } else {
            result = .failure(APIError.notHTTP)
        }
        let identifier = task.taskIdentifier
        Task { @MainActor in
            self.startedTasks.remove(identifier)
            self.onFinish?(result)
        }
    }

    /// The API's NGINX used to redirect errors to an HTML page; refuse redirects so they show as errors.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            if self.eventsCompletionHandler == nil {
                self.eventsFinishedWithoutHandler = true
            } else {
                self.finishEvents()
            }
        }
    }

    @MainActor
    private func finishEvents() {
        guard let handler = eventsCompletionHandler else { return }
        eventsCompletionHandler = nil
        if let onEventsFinished {
            onEventsFinished(handler)
        } else {
            handler()
        }
    }
}
