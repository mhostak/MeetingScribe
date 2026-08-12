import Foundation
import XCTest
@testable import MeetingScribe

final class AnalysisSettingsStoreTests: XCTestCase {
    @MainActor
    func testSettingsPersistProviderSpecificModelsPromptAndExecutable() throws {
        let suiteName = "MeetingScribeTests.AnalysisSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AnalysisSettingsStore(defaults: defaults)

        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.tool, .codex)
        XCTAssertEqual(store.modelSelection(for: .codex), .automatic)
        XCTAssertEqual(store.modelSelection(for: .claude), .automatic)
        XCTAssertNil(store.resolvedModel(for: .codex))
        XCTAssertEqual(store.prompt, AnalysisPrompt.defaultTemplate)

        store.setEnabled(true)
        store.setTool(.claude)
        store.setModelSelection(.codexTerra, for: .codex)
        store.setModelSelection(.custom, for: .claude)
        store.setCustomModel("claude-sonnet-4-6", for: .claude)
        store.setPrompt("Custom {{meeting_title}}")
        store.setExecutablePath("/usr/local/bin/claude", for: .claude)

        XCTAssertTrue(store.isEnabled)
        XCTAssertEqual(store.tool, .claude)
        XCTAssertEqual(store.modelSelection(for: .codex), .codexTerra)
        XCTAssertEqual(store.resolvedModel(for: .codex), "gpt-5.6-terra")
        XCTAssertEqual(store.modelSelection(for: .claude), .custom)
        XCTAssertEqual(store.customModel(for: .claude), "claude-sonnet-4-6")
        XCTAssertEqual(store.resolvedModel(for: .claude), "claude-sonnet-4-6")
        XCTAssertEqual(store.prompt, "Custom {{meeting_title}}")
        XCTAssertEqual(store.executablePath(for: .claude), "/usr/local/bin/claude")
    }

    @MainActor
    func testLegacyGlobalModelMigratesToSelectedToolPreset() throws {
        let suiteName = "MeetingScribeTests.AnalysisModelPresetMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "aiAnalysisCLIMigrationCompleted")
        defaults.set(AnalysisTool.claude.rawValue, forKey: "aiAnalysisTool")
        defaults.set("sonnet", forKey: "aiAnalysisModel")

        let store = AnalysisSettingsStore(defaults: defaults)

        XCTAssertEqual(store.modelSelection(for: .claude), .claudeSonnet)
        XCTAssertEqual(store.resolvedModel(for: .claude), "sonnet")
        XCTAssertEqual(store.modelSelection(for: .codex), .automatic)
        XCTAssertNil(defaults.object(forKey: "aiAnalysisModel"))
    }

    @MainActor
    func testUnknownLegacyGlobalModelMigratesWithoutChangingIdentifier() throws {
        let suiteName = "MeetingScribeTests.AnalysisCustomModelMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "aiAnalysisCLIMigrationCompleted")
        defaults.set(AnalysisTool.codex.rawValue, forKey: "aiAnalysisTool")
        defaults.set("  future-codex-model  ", forKey: "aiAnalysisModel")

        let store = AnalysisSettingsStore(defaults: defaults)

        XCTAssertEqual(store.modelSelection(for: .codex), .custom)
        XCTAssertEqual(store.customModel(for: .codex), "future-codex-model")
        XCTAssertEqual(store.resolvedModel(for: .codex), "future-codex-model")
        XCTAssertEqual(store.modelSelection(for: .claude), .automatic)
    }

    @MainActor
    func testInvalidModelSelectionForToolFallsBackToAutomatic() throws {
        let suiteName = "MeetingScribeTests.AnalysisInvalidModel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AnalysisSettingsStore(defaults: defaults)

        store.setModelSelection(.claudeOpus, for: .codex)

        XCTAssertEqual(store.modelSelection(for: .codex), .automatic)
        XCTAssertNil(store.resolvedModel(for: .codex))
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

        XCTAssertEqual(
            rendered,
            "Weekly sync / recording-42 / Czech (čeština, ISO 639-1: cs)"
        )
        XCTAssertEqual(AnalysisPrompt.hash(rendered), AnalysisPrompt.hash(rendered))
        XCTAssertNotEqual(AnalysisPrompt.hash(rendered), AnalysisPrompt.hash(rendered + "!"))
    }

    func testEveryOutputLanguageHasAnExplicitAnalysisDescription() {
        XCTAssertEqual(
            OutputLanguage.slovak.analysisLanguageDescription,
            "Slovak (slovenčina, ISO 639-1: sk)"
        )
        XCTAssertEqual(
            OutputLanguage.czech.analysisLanguageDescription,
            "Czech (čeština, ISO 639-1: cs)"
        )
        XCTAssertEqual(
            OutputLanguage.english.analysisLanguageDescription,
            "English (ISO 639-1: en)"
        )
    }
}
