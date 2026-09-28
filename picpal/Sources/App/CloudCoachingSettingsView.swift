import SwiftUI

struct CloudCoachingSettingsView: View {
    let onChange: () -> Void
    @State private var cloudEnabled = !VLMSettings.shared.isOnDeviceOnly
    @State private var endpoint = VLMSettings.shared.proxyURL.absoluteString
    @State private var status: String?
    @State private var isChecking = false

    var body: some View {
        Form {
            Section("Privacy & Cloud Coaching") {
                Toggle("Cloud composition coaching", isOn: $cloudEnabled)
                    .onChange(of: cloudEnabled) { _, enabled in
                        VLMSettings.shared.isOnDeviceOnly = !enabled
                        onChange()
                    }
                Text(VLMPrivacyDisclosure.text).font(.footnote)
            }
            Section("Coaching service") {
                TextField("Service address", text: $endpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("coachingServiceAddress")
                Button("Save and check connection") { checkConnection() }
                    .disabled(isChecking)
                if isChecking { ProgressView() }
                if let status { Text(status).font(.footnote) }
                Text("For a development server, use your Mac’s address on the same Wi-Fi network. localhost refers to this iPhone. Saving an address does not enable photo uploads.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func checkConnection() {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            status = "Enter an http or https service address without credentials or query parameters."
            return
        }
        // Changing the upload destination requires a fresh explicit global choice.
        if url != VLMSettings.shared.proxyURL {
            VLMSettings.shared.isOnDeviceOnly = true
            cloudEnabled = false
        }
        VLMSettings.shared.proxyURL = url
        onChange()
        isChecking = true
        Task { @MainActor in
            let healthURL = url.deletingLastPathComponent().appendingPathComponent("health")
            let health = await ProxyHealthClient(healthURL: healthURL).checkHealth()
            status = health.isReachable ? "Connected — reference photos still require your consent."
                : "Can't reach the service. Local framing and pose guidance remain available."
            isChecking = false
        }
    }
}

/// Resolve settings for each request so a saved endpoint takes effect immediately.
struct ConfiguredVLMClient: VLMClient {
    func analyze(_ request: VLMRequest) async throws(VLMError) -> VLMResponse {
        try await AnthropicVLMClient(proxyURL: VLMSettings.shared.proxyURL).analyze(request)
    }
}
