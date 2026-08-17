import SwiftUI

// MARK: - ReferenceConsentAlert

/// View modifier that presents a one-per-session consent alert before sending
/// reference photos to the cloud VLM service.
///
/// ## Trigger conditions (all must be true)
/// - The user has selected a reference photo.
/// - Global cloud VLM is enabled (`!VLMSettings.shared.isOnDeviceOnly`).
/// - `referenceCloudConsentGiven` is `false` in the caller.
///
/// ## Session scope
/// `referenceCloudConsentGiven` is `@State` in the owning view — it resets to
/// `false` on every cold launch and is NOT written to `UserDefaults`.
/// This modifier never mutates `VLMSettings.shared.isOnDeviceOnly`.
///
/// ## Buttons
/// - **"Enable for this session"**: sets `referenceModeConsented = true` on the
///   orchestrator so reference-image cloud calls proceed.
/// - **"On-device only"**: prevents the alert from re-appearing this session but
///   does NOT set `referenceModeConsented`; reference mode runs landmarks-only.
struct ReferenceConsentAlert: ViewModifier {

    // MARK: - Dependencies

    @Binding var isPresented: Bool

    /// Called when the user taps "Enable for this session".
    let onEnableForSession: () -> Void

    /// Called when the user taps "On-device only".
    let onOnDeviceOnly: () -> Void

    // MARK: - Body

    func body(content: Content) -> some View {
        content
            .alert("Send reference to cloud?", isPresented: $isPresented) {
                Button("Enable for this session", action: onEnableForSession)
                Button("On-device only", action: onOnDeviceOnly)
            } message: {
                Text(
                    "To help match your shot, the reference photo will be sent to " +
                    "the coaching service along with your live camera frames."
                )
            }
    }
}

// MARK: - View extension

extension View {

    /// Attaches the reference-photo cloud consent alert.
    ///
    /// - Parameters:
    ///   - isPresented: Binding that controls alert visibility. Set to `true` to show.
    ///   - onEnableForSession: Closure executed when the user consents to cloud calls.
    ///   - onOnDeviceOnly: Closure executed when the user declines cloud calls for
    ///     this session (prevents re-prompt without enabling cloud).
    func referenceConsentAlert(
        isPresented: Binding<Bool>,
        onEnableForSession: @escaping () -> Void,
        onOnDeviceOnly: @escaping () -> Void
    ) -> some View {
        modifier(ReferenceConsentAlert(
            isPresented: isPresented,
            onEnableForSession: onEnableForSession,
            onOnDeviceOnly: onOnDeviceOnly
        ))
    }
}
