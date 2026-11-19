//
//  APIClientTests.swift
//  JourneysTests
//

import XCTest
@testable import Journeys

/// Answers every request with a fixed HTTP status and records the request it received.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        var headers = ["Content-Type": "application/json"]
        if Self.status == 302 { headers["Location"] = "https://example.com/error" }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    private struct Body: Encodable { let name: String }

    private var client: APIClient!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        client = APIClient(baseURL: URL(string: "https://api.test")!, configuration: configuration)
        StubURLProtocol.lastRequest = nil
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
