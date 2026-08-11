import Testing
import Foundation
@testable import PicPal

// MARK: - VLMSettingsTests

/// Unit tests for `VLMSettings`.
///
/// Tests verify:
/// 1. `isOnDeviceOnly` defaults to `false` (cloud coaching enabled).
/// 2. Setting `isOnDeviceOnly = true` persists (readable back as `true`).
/// 3. Setting `isOnDeviceOnly = false` persists (readable back as `false`).
/// 4. `VLMSettings.shared` is the same singleton instance.
///
/// Each test cleans up after itself so tests do not influence each other
/// through the shared `UserDefaults` key.
struct VLMSettingsTests {

    // MARK: - Storage key (mirrors VLMSettings internal constant)

    private static let key = "com.picpal.vlm.onDeviceOnly"

    // MARK: - Test 1: default value

    @Test("isOnDeviceOnly defaults to false when key is absent")
    func defaultsToFalse() {
        // Remove the key so UserDefaults returns the zero-value (false).
        UserDefaults.standard.removeObject(forKey: Self.key)
        #expect(VLMSettings.shared.isOnDeviceOnly == false)
    }

    // MARK: - Test 2: set true persists

    @Test("setting isOnDeviceOnly = true is readable back as true")
    func setTruePersists() {
        VLMSettings.shared.isOnDeviceOnly = true
        defer { UserDefaults.standard.removeObject(forKey: Self.key) }
        #expect(VLMSettings.shared.isOnDeviceOnly == true)
    }

    // MARK: - Test 3: set false persists

    @Test("setting isOnDeviceOnly = false is readable back as false")
    func setFalsePersists() {
        VLMSettings.shared.isOnDeviceOnly = true   // set to true first
        VLMSettings.shared.isOnDeviceOnly = false  // then explicitly false
        defer { UserDefaults.standard.removeObject(forKey: Self.key) }
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
