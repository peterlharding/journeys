//
//  APIClient.swift
//  LocationDemo
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
    static let shared = APIClient()

    /// Production API; the `API_BASE_URL` environment variable overrides it (used by UI tests).
    let baseURL: URL

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Fail within 30 s rather than the default 60 s, so a stalled network reports an error promptly.
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    override init() {
        let override = ProcessInfo.processInfo.environment["API_BASE_URL"].flatMap(URL.init(string:))
        baseURL = override ?? URL(string: "https://mongo-api.performiq.com")!
        super.init()
    }

    /// POSTs `body` as JSON to `path` and throws unless the server answers with a 2xx status.
    func post<Body: Encodable>(_ path: String, body: Body) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw APIError.unexpectedStatus(http.statusCode) }
    }

    /// The API's NGINX turns errors into a 302 to an HTML error page; refuse it so the error status is seen.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
