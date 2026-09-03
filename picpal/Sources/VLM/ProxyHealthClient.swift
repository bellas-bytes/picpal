import Foundation
import os.log

// MARK: - ProxyHealth

/// Immutable snapshot of the proxy's health state.
public struct ProxyHealth: Sendable {
    /// Whether the proxy responded to the health check.
    public let isReachable: Bool
    /// Total VLM calls made since the proxy last reset its counter.
    public let calls: Int
    /// Hard call ceiling configured on the proxy.
    public let ceiling: Int
    /// `true` when usage has crossed 80 % of the ceiling.
    public var isNearCeiling: Bool { calls > Int(Double(ceiling) * 0.8) }
}

// MARK: - ProxyHealthClient

/// Checks the health of the local VLM proxy via `GET /health`.
public struct ProxyHealthClient: Sendable {

    // MARK: - Named constants

    /// Default health endpoint derived from the base proxy origin.
    public static let defaultHealthURL: URL = URL(string: "http://localhost:4000/health")!

    /// Timeout for a health check round-trip.
    public static let requestTimeoutSeconds: TimeInterval = 5

    // MARK: - Dependencies

    private let session: URLSession
    private let healthURL: URL

    // MARK: - Init

    public init(
        session: URLSession = .shared,
        healthURL: URL = ProxyHealthClient.defaultHealthURL
    ) {
        self.session = session
        self.healthURL = healthURL
    }

    // MARK: - Public API

    /// Fetches proxy health. Never throws — returns `.isReachable == false` on any failure.
    public func checkHealth() async -> ProxyHealth {
        var request = URLRequest(
            url: healthURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeoutSeconds
        )
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return ProxyHealth(isReachable: false, calls: 0, ceiling: 0)
            }
            struct HealthPayload: Decodable {
                let status: String
                let calls: Int
                let ceiling: Int
            }
            let payload = try JSONDecoder().decode(HealthPayload.self, from: data)
            let health = ProxyHealth(
                isReachable: payload.status == "ok",
                calls: payload.calls,
                ceiling: payload.ceiling
            )
            if health.isNearCeiling {
                os_log(
                    "[picpal-proxy] WARNING: VLM call usage near ceiling — %d / %d calls used.",
                    log: .default,
                    type: .info,
                    health.calls,
                    health.ceiling
                )
            }
            return health
        } catch {
            return ProxyHealth(isReachable: false, calls: 0, ceiling: 0)
        }
    }
}
