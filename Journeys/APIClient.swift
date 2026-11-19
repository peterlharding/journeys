//
//  APIClient.swift
//  Journeys
//
//  Sends JSON to the PerformIQ Mongo API.
//

import Foundation

enum APIError: LocalizedError {
    case unexpectedStatus(Int)
    case notHTTP

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "The server rejected the request (HTTP \(status))."
        case .notHTTP:
            return "The server sent an unexpected response."
        }
    }
}

final class APIClient: NSObject, URLSessionTaskDelegate {
    /// Which networks a request may use.
    enum NetworkUse {
        /// Wi-Fi or wired only: iOS itself refuses mobile data, a personal hotspot and Low Data Mode.
        case unmeteredOnly
        /// Any network, including mobile data (Sync now).
        case any
    }

    /// Production API; the `API_BASE_URL` environment variable overrides it (used by UI tests).
    static let shared = APIClient(
        baseURL: ProcessInfo.processInfo.environment["API_BASE_URL"].flatMap(URL.init(string:))
            ?? URL(string: "https://mongo-api.performiq.com")!
    )

    let baseURL: URL
    private let configuration: URLSessionConfiguration

    private lazy var anyNetworkSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

    private lazy var unmeteredSession: URLSession = {
        // swiftlint:disable:next force_cast
        let unmetered = configuration.copy() as! URLSessionConfiguration
        unmetered.allowsExpensiveNetworkAccess = false
        unmetered.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: unmetered, delegate: self, delegateQueue: nil)
    }()

    /// `configuration` is for tests, which stub the network with their own `URLProtocol`.
    init(baseURL: URL, configuration: URLSessionConfiguration = .default) {
        self.baseURL = baseURL
        // Fail within 30 s rather than the default 60 s, so a stalled network reports an error promptly.
        configuration.timeoutIntervalForRequest = 30
        self.configuration = configuration
        super.init()
    }

    /// POSTs `body` as JSON to `path` and returns the response body.
    /// Throws unless the server answers with a 2xx status.
    @discardableResult
    func post<Body: Encodable>(_ path: String, body: Body, encoder: JSONEncoder = JSONEncoder(),
                               network: NetworkUse = .any) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let session = network == .any ? anyNetworkSession : unmeteredSession
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw APIError.unexpectedStatus(http.statusCode) }
        return data
    }

    /// The API's NGINX used to turn errors into a 302 to an HTML error page; refuse redirects so a
    /// misconfigured proxy shows up as an error status instead of a page that looks like success.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
