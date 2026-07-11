import Foundation
import XCTest
@testable import MeetingScribe

final class APIKeyStoreTests: XCTestCase {
    @MainActor
    func testAnalysisSettingsPersistOptInAndModel() throws {
        let suiteName = "MeetingScribeTests.AnalysisSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AnalysisSettingsStore(defaults: defaults)

        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.model, OpenAIAnalysisProvider.defaultModel)

        store.setEnabled(true)
        store.setModel("gpt-5.6-terra")

        XCTAssertTrue(store.isEnabled)
        XCTAssertEqual(store.model, "gpt-5.6-terra")
    }

    func testKeychainRoundTripWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["MEETINGSCRIBE_KEYCHAIN_TEST"] == "1" else {
            throw XCTSkip("Set MEETINGSCRIBE_KEYCHAIN_TEST=1 for the real Keychain test.")
        }

        let store = KeychainAPIKeyStore(
            service: "com.martinhostak.MeetingScribeTests.\(UUID().uuidString)",
            account: "test-api-key"
        )
        defer {
            Task { try? await store.delete() }
        }

        try await store.save("test-secret")
        let savedValue = try await store.load()
        XCTAssertEqual(savedValue, "test-secret")
        try await store.delete()
        let deletedValue = try await store.load()
        XCTAssertNil(deletedValue)
    }
}
