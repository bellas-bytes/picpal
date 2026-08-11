import Testing
import Foundation
@testable import PicPal

// MARK: - MockURLProtocol

/// URLProtocol subclass that intercepts all URLSession requests and dispatches them
/// to a per-test handler without touching the network.
///
/// Usage:
///   1. Configure a URLSession with `protocolClasses = [MockURLProtocol.self]`.
///   2. Set `MockURLProtocol.handler` before each test.
///   3. Tear it down by setting `handler = nil` after the test (or use a fresh session).
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    /// Synchronous handler called on the URLSession's internal queue.
    /// Return `(response, data)` to simulate success; throw to simulate a network error.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Test helpers

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeClient(session: URLSession) -> AnthropicVLMClient {
    AnthropicVLMClient(
        session: session,
        proxyURL: URL(string: "http://localhost:4000/analyze")!
    )
}

private func makeClient() -> AnthropicVLMClient {
    makeClient(session: makeMockSession())
}

private func sampleRequest() -> VLMRequest {
    // Minimal valid JPEG SOI marker — sufficient for routing tests.
    VLMRequest(imageJPEG: Data([0xFF, 0xD8, 0xFF]), prompt: "Describe the framing.")
}

private func proxyResponse(status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://localhost:4000/analyze")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
}

private func jsonData(_ dict: [String: String]) -> Data {
    (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
}

// MARK: - VLMClientTests

@Suite("VLMClient")
struct VLMClientTests {

    // MARK: - Successful response

    @Test("Successful 200 response returns VLMResponse with model text")
    func successReturnsModelText() async throws {
        let session = makeMockSession()
        MockURLProtocol.handler = { _ in
            (proxyResponse(status: 200), jsonData(["result": "Rule of thirds looks good."]))
        }
        let response = try await makeClient(session: session).analyze(sampleRequest())
        #expect(response.text == "Rule of thirds looks good.")
    }

    // MARK: - Rate limit

    @Test("HTTP 429 maps to VLMError.rateLimited")
    func http429MapsToRateLimited() async {
        let session = makeMockSession()
        MockURLProtocol.handler = { _ in
            (proxyResponse(status: 429), jsonData(["error": "Rate limit exceeded."]))
        }
        await #expect(throws: VLMError.rateLimited) {
            try await makeClient(session: session).analyze(sampleRequest())
        }
    }

    // MARK: - HTTP error

    @Test("HTTP 502 maps to VLMError.httpError with correct status code")
    func http502MapsToHttpError() async {
        let session = makeMockSession()
        MockURLProtocol.handler = { _ in
            (proxyResponse(status: 502), Data("{\"error\":\"VLM call failed\"}".utf8))
        }
        let thrownError = await #expect(throws: VLMError.self) {
            try await makeClient(session: session).analyze(sampleRequest())
        }
        guard case .httpError(let statusCode, _) = thrownError else {
            Issue.record("Expected VLMError.httpError but got \(String(describing: thrownError))")
            return
        }
        #expect(statusCode == 502)
    }

    // MARK: - Decoding failure

    @Test("Non-JSON body on 200 maps to VLMError.decodingFailure")
    func nonJSONBodyMapsToDecodingFailure() async {
        let session = makeMockSession()
        MockURLProtocol.handler = { _ in
            (proxyResponse(status: 200), Data("not-json-at-all".utf8))
        }
        let thrownError = await #expect(throws: VLMError.self) {
            try await makeClient(session: session).analyze(sampleRequest())
        }
        guard case .decodingFailure = thrownError else {
            Issue.record("Expected VLMError.decodingFailure but got \(String(describing: thrownError))")
            return
        }
    }

    @Test("200 body with missing 'result' field maps to VLMError.decodingFailure")
    func missingResultFieldMapsToDecodingFailure() async {
        let session = makeMockSession()
        MockURLProtocol.handler = { _ in
            (proxyResponse(status: 200), jsonData(["error": "something went wrong"]))
        }
        let thrownError = await #expect(throws: VLMError.self) {
            try await makeClient(session: session).analyze(sampleRequest())
        }
        guard case .decodingFailure = thrownError else {
            Issue.record("Expected VLMError.decodingFailure but got \(String(describing: thrownError))")
            return
        }
    }

    // MARK: - Network failure

    @Test("Network failure maps to VLMError.networkFailure")
    func networkFailureMapsToNetworkFailure() async {
        let session = makeMockSession()
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let thrownError = await #expect(throws: VLMError.self) {
            try await makeClient(session: session).analyze(sampleRequest())
        }
        guard case .networkFailure = thrownError else {
            Issue.record("Expected VLMError.networkFailure but got \(String(describing: thrownError))")
            return
        }
    }

    // MARK: - Cancellation

    @Test("URLError.cancelled from session maps to VLMError.cancelled")
    func urlErrorCancelledMapsToVLMErrorCancelled() async {
        let session = makeMockSession()
        MockURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }
        await #expect(throws: VLMError.cancelled) {
            try await makeClient(session: session).analyze(sampleRequest())
        }
    }

    // MARK: - Request shape

    @Test("Analyze uses POST HTTP method")
    func analyzeUsesPostMethod() async throws {
        let session = makeMockSession()
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            return (proxyResponse(status: 200), jsonData(["result": "ok"]))
        }
        _ = try await makeClient(session: session).analyze(sampleRequest())
        #expect(capturedRequest?.httpMethod == "POST")
    }

    @Test("Analyze sets multipart/form-data Content-Type header")
    func analyzeSetsmultipartContentType() async throws {
        let session = makeMockSession()
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            return (proxyResponse(status: 200), jsonData(["result": "ok"]))
        }
        _ = try await makeClient(session: session).analyze(sampleRequest())
        let contentType = capturedRequest?.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(contentType.hasPrefix("multipart/form-data; boundary=PicPalBoundary"))
    }

    @Test("Multipart body builder encodes prompt and image correctly")
    func multipartBodyBuilderEncodesFields() {
        // Test buildMultipartBody directly — URLSession strips httpBody from the
        // URLRequest seen by URLProtocol, so body-content assertions must bypass URLSession.
        // Search raw bytes: JPEG magic bytes (0xFF 0xD8 0xFF) are invalid UTF-8,
        // so we use Data.range(of:) instead of String comparison.
        let client = makeClient()
        let imageData = Data([0xFF, 0xD8, 0xFF])
        let boundary = "TestBoundary"
        let prompt = "Check headroom."
        let body = client.buildMultipartBody(imageJPEG: imageData, prompt: prompt, boundary: boundary)
        #expect(!body.isEmpty)
        #expect(body.range(of: Data(prompt.utf8)) != nil)
        #expect(body.range(of: Data("--\(boundary)--".utf8)) != nil)
        #expect(body.range(of: Data("name=\"image\"".utf8)) != nil)
        #expect(body.range(of: Data("name=\"prompt\"".utf8)) != nil)
        #expect(body.range(of: imageData) != nil)
    }
}
