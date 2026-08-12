import Foundation
import XCTest
@testable import MeetingScribe

final class AnalysisSettingsStoreTests: XCTestCase {
    @MainActor
    func testSettingsPersistToolModelPromptAndExecutable() throws {
        let suiteName = "MeetingScribeTests.AnalysisSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AnalysisSettingsStore(defaults: defaults)

        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.tool, .codex)
        XCTAssertEqual(store.model, "")
        XCTAssertEqual(store.prompt, AnalysisPrompt.defaultTemplate)

        store.setEnabled(true)
        store.setTool(.claude)
        store.setModel("sonnet")
        store.setPrompt("Custom {{meeting_title}}")
        store.setExecutablePath("/usr/local/bin/claude", for: .claude)

        XCTAssertTrue(store.isEnabled)
        XCTAssertEqual(store.tool, .claude)
        XCTAssertEqual(store.model, "sonnet")
        XCTAssertEqual(store.prompt, "Custom {{meeting_title}}")
        XCTAssertEqual(store.executablePath(for: .claude), "/usr/local/bin/claude")
    }

    @MainActor
    func testRemovedProviderPreferenceIsClearedAndAnalysisIsDisabled() throws {
        let suiteName = "MeetingScribeTests.AnalysisMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "aiAnalysisEnabled")
        defaults.set("gpt-5.6", forKey: "openAIAnalysisModel")

        let store = AnalysisSettingsStore(defaults: defaults)

        XCTAssertFalse(store.isEnabled)
        XCTAssertNil(defaults.object(forKey: "openAIAnalysisModel"))
        XCTAssertEqual(store.tool, .codex)
    }

    @MainActor
    func testFirstCLIMigrationDisablesPreviouslyEnabledAnalysisWithoutStoredModel() throws {
        let suiteName = "MeetingScribeTests.AnalysisMigrationDefault.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "aiAnalysisEnabled")

        let store = AnalysisSettingsStore(defaults: defaults)

        XCTAssertFalse(store.isEnabled)
    }

    func testPromptRenderingAndHashAreDeterministic() {
        let session = SessionMetadata(
            id: "recording-42",
            title: "Weekly sync",
            status: .recorded,
            createdAt: Date(),
            outputLanguage: .czech
        )
        let rendered = AnalysisPrompt.render(
            template: "{{meeting_title}} / {{recording_id}} / {{output_language}}",
            session: session
        )

        XCTAssertEqual(rendered, "Weekly sync / recording-42 / cs")
        XCTAssertEqual(AnalysisPrompt.hash(rendered), AnalysisPrompt.hash(rendered))
        XCTAssertNotEqual(AnalysisPrompt.hash(rendered), AnalysisPrompt.hash(rendered + "!"))
    }
}
