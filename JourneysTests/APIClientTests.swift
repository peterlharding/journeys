//
//  APIClientTests.swift
//  JourneysTests
//

import XCTest
@testable import Journeys

/// Answers requests without a network: with `status` and an empty JSON object, or with whatever
/// `responder` returns. Records every request and its body.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?
    /// Each request's URL and body, in order.
    nonisolated(unsafe) static var requests: [(url: URL, body: Data)] = []
    /// Returns the status and body for a request body; `nil` answers with `status` and `{}`.
    /// Throwing fails the request as if the network were down.
    nonisolated(unsafe) static var responder: ((Data) throws -> (Int, Data))?

    static func reset() {
        status = 200
        lastRequest = nil
        requests = []
        responder = nil
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        Self.requests.append((request.url!, body))

        var status = Self.status
        var data = Data("{}".utf8)
        if let responder = Self.responder {
            do {
                (status, data) = try responder(body)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }
        var headers = ["Content-Type": "application/json"]
        if status == 302 { headers["Location"] = "https://example.com/error" }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class APIClientTests: XCTestCase {
    private struct Body: Encodable { let name: String }

    private var client: APIClient!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        client = APIClient(baseURL: URL(string: "https://api.test")!, configuration: configuration)
        StubURLProtocol.reset()
    }

    private func post(withStatus status: Int) async throws {
        StubURLProtocol.status = status
        try await client.post("journeys", body: Body(name: "Trip"))
    }

    func testAnyTwoHundredStatusIsSuccess() async throws {
        for status in [200, 201, 204] {
            try await post(withStatus: status)
        }
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/journeys")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testErrorAndRedirectStatusesThrow() async {
        for status in [302, 404, 422, 500] {
            do {
                try await post(withStatus: status)
                XCTFail("HTTP \(status) should throw")
            } catch APIError.unexpectedStatus(let received) {
                XCTAssertEqual(received, status)
            } catch {
                XCTFail("HTTP \(status) threw \(error)")
            }
        }
    }
}
