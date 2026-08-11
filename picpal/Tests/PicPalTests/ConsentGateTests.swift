import Testing
import Foundation
@testable import PicPal

// MARK: - ConsentGateTests

/// Unit tests for `ConsentGate`.
///
/// Each test calls `resetConsent()` at the top to ensure a clean slate,
/// making every test idempotent regardless of execution order.
///
/// Tests that mutate `VLMSettings.shared.isOnDeviceOnly` restore the
/// default (`false`) afterwards to avoid bleeding state between tests.
struct ConsentGateTests {

    // MARK: - Helpers

    /// Removes the stored consent version so `ConsentGate` sees a fresh install.
    private func resetConsent() {
        UserDefaults.standard.removeObject(forKey: "com.picpal.consent.version")
    }

    /// Restores `VLMSettings` to its neutral default so subsequent tests start clean.
    private func resetVLMSettings() {
        VLMSettings.shared.isOnDeviceOnly = false
        UserDefaults.standard.removeObject(forKey: VLMSettings.onDeviceOnlyKey)
    }

    // MARK: - Test 1: absent key → false

    @Test("isConsentGiven returns false when no consent key is stored")
    func isConsentGiven_falseWhenAbsent() {
        resetConsent()
        #expect(ConsentGate.isConsentGiven() == false)
    }

    // MARK: - Test 2: cloud consent → true

    @Test("isConsentGiven returns true after recordConsent(cloudEnabled: true)")
    func isConsentGiven_trueAfterRecordingCloud() {
        resetConsent()
        defer { resetConsent(); resetVLMSettings() }
        ConsentGate.recordConsent(cloudEnabled: true)
        #expect(ConsentGate.isConsentGiven() == true)
    }

    // MARK: - Test 3: on-device consent → true

    @Test("isConsentGiven returns true after recordConsent(cloudEnabled: false)")
    func isConsentGiven_trueAfterRecordingOnDevice() {
        resetConsent()
        defer { resetConsent(); resetVLMSettings() }
        ConsentGate.recordConsent(cloudEnabled: false)
        #expect(ConsentGate.isConsentGiven() == true)
    }

    // MARK: - Test 4: cloud enabled → isOnDeviceOnly false

    @Test("recordConsent(cloudEnabled: true) sets VLMSettings.isOnDeviceOnly to false")
    func recordConsent_cloudEnabled_setsOnDeviceOnlyFalse() {
        resetConsent()
        defer { resetConsent(); resetVLMSettings() }
        ConsentGate.recordConsent(cloudEnabled: true)
        #expect(VLMSettings.shared.isOnDeviceOnly == false)
    }

    // MARK: - Test 5: on-device only → isOnDeviceOnly true

    @Test("recordConsent(cloudEnabled: false) sets VLMSettings.isOnDeviceOnly to true")
    func recordConsent_onDeviceOnly_setsOnDeviceOnlyTrue() {
        resetConsent()
        defer { resetConsent(); resetVLMSettings() }
        ConsentGate.recordConsent(cloudEnabled: false)
        #expect(VLMSettings.shared.isOnDeviceOnly == true)
    }

    // MARK: - Test 6: version constant

    @Test("currentConsentVersion is 1")
    func currentConsentVersion_isOne() {
        #expect(ConsentGate.currentConsentVersion == 1)
    }
}
