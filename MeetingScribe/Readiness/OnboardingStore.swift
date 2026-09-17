import Foundation

enum OnboardingStep: Int, CaseIterable, Codable, Hashable, Sendable {
    case welcome
    case audioPermissions
    case transcriptionAndOutput
    case review

    var id: Int { rawValue }
}

struct OnboardingState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    var step: OnboardingStep
    var isCompleted: Bool
    var isDeferred: Bool
    let hasPromptedOnLaunch: Bool
    let isExistingInstallation: Bool

    init(
        version: Int = OnboardingState.currentVersion,
        step: OnboardingStep = .welcome,
        isCompleted: Bool = false,
        isDeferred: Bool = false,
        hasPromptedOnLaunch: Bool = false,
        isExistingInstallation: Bool = false
    ) {
        self.version = version
        self.step = step
        self.isCompleted = isCompleted
        self.isDeferred = isDeferred
        self.hasPromptedOnLaunch = hasPromptedOnLaunch
        self.isExistingInstallation = isExistingInstallation
    }
}

@MainActor
final class OnboardingStore {
    private enum Key {
        static let state = "onboardingReadinessState"
    }

    private static let existingInstallationKeys = [
        "applicationLanguage",
        "meetingOutputLanguage",
        "markdownFileNameTemplate",
        "minimumRecordingStorageBytes",
        "appleCalendarIntegrationEnabled",
        "outputFolderBookmark",
        "outputFolderFallbackPath",
        "processingNotificationsEnabled",
        "selectedTranscriptionLanguage",
        "automaticallyDeleteSourceCAFAfterExport",
        "recordingAudioRetentionPolicy",
    ]

    private let defaults: UserDefaults
    private(set) var state: OnboardingState

    init(
        defaults: UserDefaults = .standard,
        existingInstallationDetector: (() -> Bool)? = nil
    ) {
        self.defaults = defaults
        let isExistingInstallation = existingInstallationDetector.map { $0() }
            ?? Self.detectsExistingInstallation(defaults: defaults)
        self.state = Self.loadState(
            defaults: defaults,
            isExistingInstallation: isExistingInstallation
        )
    }

    var shouldOpenOnLaunch: Bool {
        state.isExistingInstallation == false
            && state.hasPromptedOnLaunch == false
            && state.isDeferred == false
            && state.isCompleted == false
    }

    var shouldShowInvitation: Bool {
        state.isCompleted == false
    }

    func markPresentedOnLaunch() {
        guard !state.hasPromptedOnLaunch else { return }
        state = OnboardingState(
            version: state.version,
            step: state.step,
            isCompleted: state.isCompleted,
            isDeferred: state.isDeferred,
            hasPromptedOnLaunch: true,
            isExistingInstallation: state.isExistingInstallation
        )
        persist()
    }

    func markExistingInstallation() {
        guard !state.isExistingInstallation else { return }
        state = OnboardingState(
            version: state.version,
            step: state.step,
            isCompleted: state.isCompleted,
            isDeferred: state.isDeferred,
            hasPromptedOnLaunch: state.hasPromptedOnLaunch,
            isExistingInstallation: true
        )
        persist()
    }

    func deferOnboarding() {
        update { state in
            state.isDeferred = true
        }
    }

    func resume() {
        update { state in
            state.isDeferred = false
        }
    }

    func setStep(_ step: OnboardingStep) {
        update { state in
            state.step = step
            state.isDeferred = false
        }
    }

    func advance() {
        setStep(nextStep(after: state.step))
    }

    func complete() {
        update { state in
            state.step = .review
            state.isCompleted = true
            state.isDeferred = false
        }
    }

    private func nextStep(after step: OnboardingStep) -> OnboardingStep {
        let allSteps = OnboardingStep.allCases
        guard let index = allSteps.firstIndex(of: step), index < allSteps.count - 1 else {
            return .review
        }
        return allSteps[index + 1]
    }

    private func update(_ mutate: (inout OnboardingState) -> Void) {
        var nextState = state
        mutate(&nextState)
        state = nextState
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Key.state)
    }

    private static func loadState(
        defaults: UserDefaults,
        isExistingInstallation: Bool
    ) -> OnboardingState {
        if
            let data = defaults.data(forKey: Key.state),
            let decoded = try? JSONDecoder().decode(OnboardingState.self, from: data),
            decoded.version == OnboardingState.currentVersion,
            OnboardingStep(rawValue: decoded.step.rawValue) != nil {
            return decoded
        }

        let state = OnboardingState(isExistingInstallation: isExistingInstallation)
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Key.state)
        }
        return state
    }

    static func detectsExistingInstallation(defaults: UserDefaults) -> Bool {
        existingInstallationKeys.contains { defaults.object(forKey: $0) != nil }
    }
}
