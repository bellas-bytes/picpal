import Foundation

// MARK: - VLMRequest

/// Immutable snapshot of one VLM analysis request.
///
/// JPEG bytes are sent to the proxy; they never reach the Anthropic API directly.
/// The `prompt` drives the aesthetic analysis on the server side.
public struct VLMRequest: Sendable {

    /// Compressed JPEG frame at the target analysis resolution.
    public let imageJPEG: Data

    /// Plain-text prompt forwarded verbatim to the model.
    public let prompt: String

    public init(imageJPEG: Data, prompt: String) {
        self.imageJPEG = imageJPEG
        self.prompt = prompt
    }
}

// MARK: - VLMResponse

/// Immutable result of a successful VLM call.
public struct VLMResponse: Sendable {

    /// Plain-text aesthetic coaching text returned by the model.
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

// MARK: - VLMError

/// Typed error domain for all VLM client failures.
public enum VLMError: Error, Sendable, Equatable {

    /// The underlying URLSession call failed (unreachable host, timeout, TLS, etc.).
    /// Stores the `localizedDescription` string so the enum stays `Equatable`.
    case networkFailure(String)

    /// The proxy returned a non-2xx, non-429 HTTP status.
    case httpError(statusCode: Int, body: String)

    /// The proxy response could not be decoded into the expected JSON shape.
    case decodingFailure(String)

    /// The proxy refused the request due to rate limiting (HTTP 429).
    case rateLimited

    /// The caller cancelled the in-flight `Task`.
    case cancelled
}

// MARK: - VLMClient

/// Vendor-agnostic interface for asynchronous VLM aesthetic analysis.
///
/// Callers use Swift structured concurrency: cancellation propagates automatically
/// when the parent `Task` is cancelled.
public protocol VLMClient: Sendable {

    /// Analyze a JPEG frame with the given prompt.
    ///
    /// - Parameter request: Image bytes and prompt text.
    /// - Returns: `VLMResponse` containing the model's plain-text reply.
    /// - Throws: `VLMError` on any failure, including cancellation.
    func analyze(_ request: VLMRequest) async throws(VLMError) -> VLMResponse
}

// MARK: - AnthropicVLMClient

/// `VLMClient` conformance that forwards requests to the local dev proxy.
///
/// The proxy (`proxy/index.js`) calls Claude Sonnet 5 on the server.
/// The Anthropic API key never reaches this binary.
///
/// Inject a custom `URLSession` (configured with `MockURLProtocol`) for unit tests.
public struct AnthropicVLMClient: VLMClient {

    // MARK: - Named constants

    /// Default proxy endpoint. Override in tests or via the initialiser.
    public static let defaultProxyURL: URL = URL(string: "http://localhost:4000/analyze")!

    /// URLSession timeout for a single proxy round-trip.
    public static let requestTimeoutSeconds: TimeInterval = 30

    /// Prefix used when generating multipart boundary strings.
    private static let boundaryPrefix: String = "PicPalBoundary"

    // MARK: - Dependencies

    private let session: URLSession
    private let proxyURL: URL

    // MARK: - Init

    /// Create a client targeting the given proxy endpoint.
    ///
    /// - Parameters:
    ///   - session: URLSession to use. Default is `.shared`.
    ///   - proxyURL: Proxy URL. Default is `http://localhost:4000/analyze`.
    public init(
        session: URLSession = .shared,
        proxyURL: URL = AnthropicVLMClient.defaultProxyURL
    ) {
        self.session = session
        self.proxyURL = proxyURL
    }

    // MARK: - VLMClient

    public func analyze(_ request: VLMRequest) async throws(VLMError) -> VLMResponse {
        let boundary = "\(Self.boundaryPrefix)\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let body = buildMultipartBody(
            imageJPEG: request.imageJPEG,
            prompt: request.prompt,
            boundary: boundary
        )

        var urlRequest = URLRequest(
            url: proxyURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeoutSeconds
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        urlRequest.httpBody = body

        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await session.data(for: urlRequest)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw VLMError.cancelled
        } catch {
            throw VLMError.networkFailure(error.localizedDescription)
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw VLMError.networkFailure("Non-HTTP response received from proxy")
        }

        let bodyString = String(data: data, encoding: .utf8) ?? ""

        if http.statusCode == 429 {
            throw VLMError.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VLMError.httpError(statusCode: http.statusCode, body: bodyString)
        }

        return try decodeSuccess(from: data)
    }

    // MARK: - Private helpers

    /// Decode a `{ "result": "..." }` proxy response.
    private func decodeSuccess(from data: Data) throws(VLMError) -> VLMResponse {
        struct ProxySuccess: Decodable { let result: String }
        do {
            let decoded = try JSONDecoder().decode(ProxySuccess.self, from: data)
            return VLMResponse(text: decoded.result)
        } catch {
            throw VLMError.decodingFailure(error.localizedDescription)
        }
    }

    /// Build a minimal `multipart/form-data` body containing the image and prompt fields.
    private func buildMultipartBody(imageJPEG: Data, prompt: String, boundary: String) -> Data {
        var body = Data()
        let crlf = "\r\n"

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        // Image part
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\(crlf)")
        append("Content-Type: image/jpeg\(crlf)\(crlf)")
        body.append(imageJPEG)
        append(crlf)

        // Prompt part
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"prompt\"\(crlf)\(crlf)")
        append(prompt)
        append(crlf)

        // End boundary
        append("--\(boundary)--\(crlf)")
        return body
    }
}
