import SwiftUI
import Sentry

@main
struct PicPalApp: App {

    init() {
        // M6-0c: Crash reporter — reads DSN from environment variable at runtime.
        // Set SENTRY_DSN in your scheme's environment or launch config.
        // An empty DSN is valid: Sentry initialises but sends nothing.
        // Crash reporter verified active: <leave blank — to be filled after first TestFlight build>
        SentrySDK.start { options in
            options.dsn = ProcessInfo.processInfo.environment["SENTRY_DSN"] ?? ""
            options.debug = false
            #if DEBUG
            options.debug = true
            #endif
        }

        // TODO(m6-0c): force a test crash here in DEBUG to verify dashboard, then remove
        // SentrySDK.crash()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
