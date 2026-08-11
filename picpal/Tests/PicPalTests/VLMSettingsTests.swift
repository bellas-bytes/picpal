import Testing
import Foundation
@testable import PicPal

// MARK: - VLMSettingsTests

/// Unit tests for `VLMSettings`.
///
/// Tests verify:
/// 1. `isOnDeviceOnly` defaults to `true` (on-device only, cloud disabled until consent).
/// 2. Setting `isOnDeviceOnly = true` persists (readable back as `true`).
/// 3. Setting `isOnDeviceOnly = false` persists (readable back as `false`).
/// 4. `VLMSettings.shared` is the same singleton instance.
///
/// Each test cleans up after itself so tests do not influence each other
/// through the shared `UserDefaults` key.
@Suite(.serialized)
struct VLMSettingsTests {

    // MARK: - Test 1: default value

    @Test("isOnDeviceOnly defaults to true when key is absent")
    func isOnDeviceOnly_defaultsToTrue_whenKeyAbsent() {
        // Remove the key so the guard path triggers, returning the safe default.
        UserDefaults.standard.removeObject(forKey: VLMSettings.onDeviceOnlyKey)
        #expect(VLMSettings.shared.isOnDeviceOnly == true)
    }

    // MARK: - Test 2: set true persists

    @Test("setting isOnDeviceOnly = true is readable back as true")
    func setTruePersists() {
        VLMSettings.shared.isOnDeviceOnly = true
        defer { UserDefaults.standard.removeObject(forKey: VLMSettings.onDeviceOnlyKey) }
        #expect(VLMSettings.shared.isOnDeviceOnly == true)
    }

    // MARK: - Test 3: set false persists

    @Test("setting isOnDeviceOnly = false is readable back as false")
    func setFalsePersists() {
        VLMSettings.shared.isOnDeviceOnly = true   // set to true first
        VLMSettings.shared.isOnDeviceOnly = false  // then explicitly false
        defer { UserDefaults.standard.removeObject(forKey: VLMSettings.onDeviceOnlyKey) }
        #expect(VLMSettings.shared.isOnDeviceOnly == false)
    }

    // MARK: - Test 4: singleton identity

    @Test("VLMSettings.shared is the same instance across references")
    func singletonIdentity() {
        let a = VLMSettings.shared
        let b = VLMSettings.shared
        #expect(a === b)
    }
}
