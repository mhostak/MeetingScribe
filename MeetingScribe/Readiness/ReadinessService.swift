import AVFoundation
import CoreGraphics
import Foundation

enum ReadinessStatus: Equatable, Sendable {
    case checking
    case ready
    case needsAttention
    case unverified
    case optional
}

enum ReadinessImpact: Equatable, Sendable {
    case blocksRecording
    case blocksCaptureMode(CaptureMode)
    case limitsProcessing
    case warning
    case informational
    case none
}

enum ReadinessAction: Equatable, Sendable {
    case requestSystemAudioPermission
    case openSystemAudioSettings
    case requestMicrophonePermission
    case connectMicrophoneInput
    case freeStorageSpace
    case fixStorageAccess
    case downloadTranscriptionModel
    case importTranscriptionModel
    case repairTranscriptionModel
    case chooseOutputFolder
    case useSessionFolder
    case fixOutputFileNameTemplate
    case openAISettings
    case disableAI
    case openCalendarSettings
    case openNotificationSettings
    case none
}

/// The current configuration behind a readiness check, so a row can state what
/// is actually set instead of only whether it passed. The values stay raw and
/// unformatted; `AppLocalization.readinessDetail` turns them into user text.
enum ReadinessDetail: Equatable, Sendable {
    case systemAudio(permission: ReadinessPermissionStatus, captureMode: CaptureMode)
    case microphone(permission: ReadinessPermissionStatus)
    case storage(availableBytes: Int64, requiredBytes: Int64)
    case storageUnavailable
    case transcriptionModel(name: String, state: ReadinessModelProbeResult)
    case output(folderPath: String?, template: String)
    case outputTemplateInvalid(tokens: [String])
    case analysisDisabled
    case analysis(tool: String, model: String?, status: AnalysisToolStatus)
    case optionalFeature(isEnabled: Bool, permission: ReadinessPermissionStatus)
}

struct ReadinessCheck: Equatable, Identifiable, Sendable {
    enum ID: String, CaseIterable, Equatable, Sendable {
        case systemAudio
        case microphone
        case storage
        case transcriptionModel
        case outputDestination
        case aiAnalysis
        case calendar
        case notifications
    }

    let id: ID
    let status: ReadinessStatus
    let localizationKey: String
    let impact: ReadinessImpact
    let action: ReadinessAction
    let detail: ReadinessDetail

    init(
        id: ID,
        status: ReadinessStatus,
        localizationKey: String,
        impact: ReadinessImpact,
        action: ReadinessAction,
        detail: ReadinessDetail
    ) {
        self.id = id
        self.status = status
        self.localizationKey = localizationKey
        self.impact = impact
        self.action = action
        self.detail = detail
    }
}

enum ReadinessPermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    case restricted
    case unknown
}

enum ReadinessStorageProbeResult: Equatable, Sendable {
    case available(StorageStatus)
    case unavailable
}

enum ReadinessModelProbeResult: Equatable, Sendable {
    case ready
    case missing
    case invalid
    case unavailable
}

enum ReadinessOutputProbeResult: Equatable, Sendable {
    case writable
    case failed(reason: String)
}

struct ReadinessOptionalFeature: Equatable, Sendable {
    let isEnabled: Bool
    let authorization: ReadinessPermissionStatus

    init(isEnabled: Bool, authorization: ReadinessPermissionStatus = .unknown) {
        self.isEnabled = isEnabled
        self.authorization = authorization
    }
}

struct ReadinessConfiguration: Equatable, Sendable {
    let captureMode: CaptureMode
    let outputFolderURL: URL?
    let outputFileNameTemplate: String
    let transcriptionModelName: String
    let analysisToolName: String
    /// `nil` means the selected tool picks its own model.
    let analysisModelName: String?
    let aiAnalysis: ReadinessOptionalFeature
    let calendar: ReadinessOptionalFeature
    let notifications: ReadinessOptionalFeature

    init(
        captureMode: CaptureMode = .systemAndMicrophone,
        outputFolderURL: URL? = nil,
        outputFileNameTemplate: String = MarkdownFileNameTemplate.defaultValue,
        transcriptionModelName: String = FluidAudioModelDescriptor.parakeetV3.displayName,
        analysisToolName: String = AnalysisTool.codex.displayName,
        analysisModelName: String? = nil,
        aiAnalysis: ReadinessOptionalFeature = ReadinessOptionalFeature(isEnabled: false),
        calendar: ReadinessOptionalFeature = ReadinessOptionalFeature(isEnabled: false),
        notifications: ReadinessOptionalFeature = ReadinessOptionalFeature(isEnabled: false)
    ) {
        self.captureMode = captureMode
        self.outputFolderURL = outputFolderURL
        self.outputFileNameTemplate = outputFileNameTemplate
        self.transcriptionModelName = transcriptionModelName
        self.analysisToolName = analysisToolName
        self.analysisModelName = analysisModelName
        self.aiAnalysis = aiAnalysis
        self.calendar = calendar
        self.notifications = notifications
    }
}

struct ReadinessProbeResults: Equatable, Sendable {
    let systemAudioPermission: ReadinessPermissionStatus
    let microphonePermission: ReadinessPermissionStatus
    let storage: ReadinessStorageProbeResult
    let transcriptionModel: ReadinessModelProbeResult
    let outputDestination: ReadinessOutputProbeResult
    let analysisTool: AnalysisToolStatus
}

enum ReadinessRecordingSummary: Equatable, Sendable {
    case readyForRecordingAndTranscription
    case readyForRecordingTranscriptionNeedsAttention
    case recordingNeedsAttention
}

struct ReadinessSnapshot: Equatable, Sendable {
    let checkedAt: Date
    let configuration: ReadinessConfiguration
    let checks: [ReadinessCheck]
    let summary: ReadinessRecordingSummary

    func check(_ id: ReadinessCheck.ID) -> ReadinessCheck? {
        checks.first { $0.id == id }
    }
}

struct ReadinessEvaluator: Sendable {
    func evaluate(
        configuration: ReadinessConfiguration,
        results: ReadinessProbeResults,
        checkedAt: Date
    ) -> ReadinessSnapshot {
        var checks = [
            systemAudioCheck(configuration: configuration, status: results.systemAudioPermission),
            microphoneCheck(configuration: configuration, status: results.microphonePermission),
            storageCheck(results.storage),
            transcriptionModelCheck(
                configuration: configuration,
                result: results.transcriptionModel
            ),
            outputCheck(
                configuration: configuration,
                result: results.outputDestination
            ),
            aiCheck(configuration: configuration, analysisToolStatus: results.analysisTool),
            optionalFeatureCheck(
                id: .calendar,
                feature: configuration.calendar,
                openSettingsAction: .openCalendarSettings
            ),
            optionalFeatureCheck(
                id: .notifications,
                feature: configuration.notifications,
                openSettingsAction: .openNotificationSettings
            )
        ]
        if configuration.captureMode == .microphoneOnly {
            checks.removeFirst()
        }
        let summary = summary(for: configuration, checks: checks)
        return ReadinessSnapshot(
            checkedAt: checkedAt,
            configuration: configuration,
            checks: checks,
            summary: summary
        )
    }

    private func systemAudioCheck(
        configuration: ReadinessConfiguration,
        status: ReadinessPermissionStatus
    ) -> ReadinessCheck {
        let detail = ReadinessDetail.systemAudio(
            permission: status,
            captureMode: configuration.captureMode
        )
        switch status {
        case .granted:
            return ReadinessCheck(
                id: .systemAudio,
                status: .ready,
                localizationKey: "readiness.check.systemAudio",
                impact: .none,
                action: .none,
                detail: detail
            )
        case .denied:
            return ReadinessCheck(
                id: .systemAudio,
                status: .needsAttention,
                localizationKey: "readiness.check.systemAudio",
                impact: configuration.captureMode == .systemAndMicrophone
                    ? .blocksCaptureMode(.systemAndMicrophone)
                    : .none,
                action: .openSystemAudioSettings,
                detail: detail
            )
        case .notDetermined:
            return ReadinessCheck(
                id: .systemAudio,
                status: .unverified,
                localizationKey: "readiness.check.systemAudio",
                impact: configuration.captureMode == .systemAndMicrophone
                    ? .blocksCaptureMode(.systemAndMicrophone)
                    : .none,
                action: .requestSystemAudioPermission,
                detail: detail
            )
        case .restricted, .unknown:
            return ReadinessCheck(
                id: .systemAudio,
                status: .unverified,
                localizationKey: "readiness.check.systemAudio",
                impact: configuration.captureMode == .systemAndMicrophone
                    ? .blocksCaptureMode(.systemAndMicrophone)
                    : .none,
                action: .openSystemAudioSettings,
                detail: detail
            )
        }
    }

    private func microphoneCheck(
        configuration: ReadinessConfiguration,
        status: ReadinessPermissionStatus
    ) -> ReadinessCheck {
        let impact: ReadinessImpact
        let action: ReadinessAction
        switch configuration.captureMode {
        case .systemAndMicrophone:
            impact = .warning
            action = .requestMicrophonePermission
        case .microphoneOnly:
            impact = .blocksCaptureMode(.microphoneOnly)
            action = .connectMicrophoneInput
        }
        let detail = ReadinessDetail.microphone(permission: status)
        switch status {
        case .granted:
            return ReadinessCheck(
                id: .microphone,
                status: .ready,
                localizationKey: "readiness.check.microphone",
                impact: .none,
                action: .none,
                detail: detail
            )
        case .denied, .restricted:
            return ReadinessCheck(
                id: .microphone,
                status: .needsAttention,
                localizationKey: "readiness.check.microphone",
                impact: impact,
                action: action,
                detail: detail
            )
        case .notDetermined, .unknown:
            return ReadinessCheck(
                id: .microphone,
                status: .unverified,
                localizationKey: "readiness.check.microphone",
                impact: impact,
                action: action,
                detail: detail
            )
        }
    }

    private func storageCheck(_ result: ReadinessStorageProbeResult) -> ReadinessCheck {
        switch result {
        case let .available(status):
            let detail = ReadinessDetail.storage(
                availableBytes: status.availableBytes,
                requiredBytes: status.requiredBytes
            )
            if status.hasSufficientCapacity {
                return ReadinessCheck(
                    id: .storage,
                    status: .ready,
                    localizationKey: "readiness.check.storage",
                    impact: .none,
                    action: .none,
                    detail: detail
                )
            }
            return ReadinessCheck(
                id: .storage,
                status: .needsAttention,
                localizationKey: "readiness.check.storage",
                impact: .blocksRecording,
                action: .freeStorageSpace,
                detail: detail
            )
        case .unavailable:
            return ReadinessCheck(
                id: .storage,
                status: .unverified,
                localizationKey: "readiness.check.storage",
                impact: .blocksRecording,
                action: .fixStorageAccess,
                detail: .storageUnavailable
            )
        }
    }

    private func transcriptionModelCheck(
        configuration: ReadinessConfiguration,
        result: ReadinessModelProbeResult
    ) -> ReadinessCheck {
        let detail = ReadinessDetail.transcriptionModel(
            name: configuration.transcriptionModelName,
            state: result
        )
        switch result {
        case .ready:
            return ReadinessCheck(
                id: .transcriptionModel,
                status: .ready,
                localizationKey: "readiness.check.transcriptionModel",
                impact: .none,
                action: .none,
                detail: detail
            )
        case .missing:
            return ReadinessCheck(
                id: .transcriptionModel,
                status: .needsAttention,
                localizationKey: "readiness.check.transcriptionModel",
                impact: .limitsProcessing,
                action: .downloadTranscriptionModel,
                detail: detail
            )
        case .invalid:
            return ReadinessCheck(
                id: .transcriptionModel,
                status: .needsAttention,
                localizationKey: "readiness.check.transcriptionModel",
                impact: .limitsProcessing,
                action: .repairTranscriptionModel,
                detail: detail
            )
        case .unavailable:
            return ReadinessCheck(
                id: .transcriptionModel,
                status: .unverified,
                localizationKey: "readiness.check.transcriptionModel",
                impact: .limitsProcessing,
                action: .importTranscriptionModel,
                detail: detail
            )
        }
    }

    private func outputCheck(
        configuration: ReadinessConfiguration,
        result: ReadinessOutputProbeResult
    ) -> ReadinessCheck {
        let unsupportedTokens = MarkdownFileNameTemplate.unsupportedTokens(
            in: configuration.outputFileNameTemplate
        )
        if !unsupportedTokens.isEmpty {
            return ReadinessCheck(
                id: .outputDestination,
                status: .needsAttention,
                localizationKey: "readiness.check.outputDestination",
                impact: .limitsProcessing,
                action: .fixOutputFileNameTemplate,
                detail: .outputTemplateInvalid(tokens: unsupportedTokens)
            )
        }
        let detail = ReadinessDetail.output(
            folderPath: configuration.outputFolderURL?.path,
            template: configuration.outputFileNameTemplate
        )
        guard configuration.outputFolderURL != nil else {
            return ReadinessCheck(
                id: .outputDestination,
                status: .ready,
                localizationKey: "readiness.check.outputDestination",
                impact: .none,
                action: .useSessionFolder,
                detail: detail
            )
        }
        switch result {
        case .writable:
            return ReadinessCheck(
                id: .outputDestination,
                status: .ready,
                localizationKey: "readiness.check.outputDestination",
                impact: .none,
                action: .none,
                detail: detail
            )
        case .failed:
            return ReadinessCheck(
                id: .outputDestination,
                status: .needsAttention,
                localizationKey: "readiness.check.outputDestination",
                impact: .limitsProcessing,
                action: .chooseOutputFolder,
                detail: detail
            )
        }
    }

    private func aiCheck(
        configuration: ReadinessConfiguration,
        analysisToolStatus: AnalysisToolStatus
    ) -> ReadinessCheck {
        guard configuration.aiAnalysis.isEnabled else {
            return ReadinessCheck(
                id: .aiAnalysis,
                status: .optional,
                localizationKey: "readiness.check.aiAnalysis",
                impact: .none,
                action: .none,
                detail: .analysisDisabled
            )
        }
        let detail = ReadinessDetail.analysis(
            tool: configuration.analysisToolName,
            model: configuration.analysisModelName,
            status: analysisToolStatus
        )
        switch analysisToolStatus {
        case .available:
            return ReadinessCheck(
                id: .aiAnalysis,
                status: .ready,
                localizationKey: "readiness.check.aiAnalysis",
                impact: .none,
                action: .none,
                detail: detail
            )
        case .unknown:
            return ReadinessCheck(
                id: .aiAnalysis,
                status: .unverified,
                localizationKey: "readiness.check.aiAnalysis",
                impact: .limitsProcessing,
                action: .openAISettings,
                detail: detail
            )
        case .unavailable:
            return ReadinessCheck(
                id: .aiAnalysis,
                status: .needsAttention,
                localizationKey: "readiness.check.aiAnalysis",
                impact: .limitsProcessing,
                action: .openAISettings,
                detail: detail
            )
        case .authenticationRequired:
            return ReadinessCheck(
                id: .aiAnalysis,
                status: .needsAttention,
                localizationKey: "readiness.check.aiAnalysis",
                impact: .limitsProcessing,
                action: .openAISettings,
                detail: detail
            )
        case .failed:
            return ReadinessCheck(
                id: .aiAnalysis,
                status: .needsAttention,
                localizationKey: "readiness.check.aiAnalysis",
                impact: .limitsProcessing,
                action: .openAISettings,
                detail: detail
            )
        }
    }

    private func optionalFeatureCheck(
        id: ReadinessCheck.ID,
        feature: ReadinessOptionalFeature,
        openSettingsAction: ReadinessAction
    ) -> ReadinessCheck {
        let localizationKey = id == .calendar
            ? "readiness.check.calendar"
            : "readiness.check.notifications"
        let detail = ReadinessDetail.optionalFeature(
            isEnabled: feature.isEnabled,
            permission: feature.authorization
        )
        guard feature.isEnabled else {
            return ReadinessCheck(
                id: id,
                status: .optional,
                localizationKey: localizationKey,
                impact: .none,
                action: .none,
                detail: detail
            )
        }
        switch feature.authorization {
        case .granted:
            return ReadinessCheck(
                id: id,
                status: .ready,
                localizationKey: localizationKey,
                impact: .informational,
                action: .none,
                detail: detail
            )
        case .denied, .restricted:
            return ReadinessCheck(
                id: id,
                status: .needsAttention,
                localizationKey: localizationKey,
                impact: .informational,
                action: openSettingsAction,
                detail: detail
            )
        case .notDetermined, .unknown:
            return ReadinessCheck(
                id: id,
                status: .unverified,
                localizationKey: localizationKey,
                impact: .informational,
                action: openSettingsAction,
                detail: detail
            )
        }
    }

    private func summary(
        for configuration: ReadinessConfiguration,
        checks: [ReadinessCheck]
    ) -> ReadinessRecordingSummary {
        let blocksRecording = checks.contains { check in
            switch check.impact {
            case .blocksRecording:
                return true
            case let .blocksCaptureMode(mode):
                return mode == configuration.captureMode
            default:
                return false
            }
        }
        guard !blocksRecording else { return .recordingNeedsAttention }
        guard checks.first(where: { $0.id == .transcriptionModel })?.status == .ready else {
            return .readyForRecordingTranscriptionNeedsAttention
        }
        return .readyForRecordingAndTranscription
    }
}

struct ReadinessPermissionSnapshot: Equatable, Sendable {
    let systemAudio: ReadinessPermissionStatus
    let microphone: ReadinessPermissionStatus
}

protocol ReadinessPermissionProbing: Sendable {
    func snapshot() async -> ReadinessPermissionSnapshot
}

struct SystemAndMicrophonePermissionProbe: ReadinessPermissionProbing {
    func snapshot() async -> ReadinessPermissionSnapshot {
        ReadinessPermissionSnapshot(
            systemAudio: CGPreflightScreenCaptureAccess() ? .granted : .unknown,
            microphone: microphoneStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        )
    }

    private func microphoneStatus(_ status: AVAuthorizationStatus) -> ReadinessPermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }
}

protocol ReadinessStorageProbing: Sendable {
    func status() async -> ReadinessStorageProbeResult
}

struct SessionStorageProbe: ReadinessStorageProbing {
    private let recordingsRoot: URL
    private let storageGuard: StorageGuard

    init(recordingsRoot: URL, storageGuard: StorageGuard = StorageGuard()) {
        self.recordingsRoot = recordingsRoot
        self.storageGuard = storageGuard
    }

    func status() async -> ReadinessStorageProbeResult {
        do {
            return .available(try storageGuard.status(at: recordingsRoot))
        } catch {
            return .unavailable
        }
    }
}

protocol ReadinessModelProbing: Sendable {
    func status() async -> ReadinessModelProbeResult
}

struct FluidAudioReadinessProbe: ReadinessModelProbing {
    private let manager: any FluidAudioModelManaging
    private let descriptor: FluidAudioModelDescriptor

    init(
        manager: any FluidAudioModelManaging = FluidAudioModelManager(),
        descriptor: FluidAudioModelDescriptor = .parakeetV3
    ) {
        self.manager = manager
        self.descriptor = descriptor
    }

    func status() async -> ReadinessModelProbeResult {
        switch await manager.status(for: descriptor) {
        case .ready:
            return .ready
        case .missing:
            return .missing
        case .invalid:
            return .invalid
        }
    }
}

protocol ReadinessOutputProbing: Sendable {
    func verifyWritableDirectory(_ url: URL) async -> ReadinessOutputProbeResult
}

actor OutputFolderWriteProbe: ReadinessOutputProbing {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func verifyWritableDirectory(_ url: URL) async -> ReadinessOutputProbeResult {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let probeURL = url.appendingPathComponent(
            ".MeetingScribe-readiness-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(atPath: probeURL.path, contents: Data([0])) else {
            return .failed(reason: "The output folder is not writable.")
        }
        do {
            try fileManager.removeItem(at: probeURL)
            return .writable
        } catch {
            return .failed(reason: "The readiness probe file could not be removed.")
        }
    }
}

protocol ReadinessAnalysisStatusProviding: Sendable {
    func status() async -> AnalysisToolStatus
}

struct CachedAnalysisStatusProvider: ReadinessAnalysisStatusProviding {
    private let status: AnalysisToolStatus

    init(status: AnalysisToolStatus) {
        self.status = status
    }

    func status() async -> AnalysisToolStatus {
        status
    }
}

enum ReadinessRefreshError: Error, Equatable {
    case staleResult
}

actor ReadinessService {
    private let permissionProbe: any ReadinessPermissionProbing
    private let storageProbe: any ReadinessStorageProbing
    private let modelProbe: any ReadinessModelProbing
    private let outputProbe: any ReadinessOutputProbing
    private let analysisStatusProvider: any ReadinessAnalysisStatusProviding
    private let evaluator = ReadinessEvaluator()
    private let now: @Sendable () -> Date
    private var generation = 0
    private var latestSnapshot: ReadinessSnapshot?

    init(
        permissionProbe: any ReadinessPermissionProbing = SystemAndMicrophonePermissionProbe(),
        storageProbe: any ReadinessStorageProbing,
        modelProbe: any ReadinessModelProbing = FluidAudioReadinessProbe(),
        outputProbe: any ReadinessOutputProbing = OutputFolderWriteProbe(),
        analysisStatusProvider: any ReadinessAnalysisStatusProviding = CachedAnalysisStatusProvider(status: .unknown),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.permissionProbe = permissionProbe
        self.storageProbe = storageProbe
        self.modelProbe = modelProbe
        self.outputProbe = outputProbe
        self.analysisStatusProvider = analysisStatusProvider
        self.now = now
    }

    func currentSnapshot() -> ReadinessSnapshot? {
        latestSnapshot
    }

    func refresh(_ configuration: ReadinessConfiguration) async throws -> ReadinessSnapshot {
        generation += 1
        let targetGeneration = generation

        async let permissions = permissionProbe.snapshot()
        async let storage = storageProbe.status()
        async let model = modelProbe.status()
        async let output = outputDestinationProbeResult(for: configuration.outputFolderURL)
        async let analysisStatus = analysisStatusProvider.status()

        let permissionSnapshot = await permissions
        let storageResult = await storage
        let modelResult = await model
        let outputResult = await output
        let analysisResult = await analysisStatus
        let results = ReadinessProbeResults(
            systemAudioPermission: permissionSnapshot.systemAudio,
            microphonePermission: permissionSnapshot.microphone,
            storage: storageResult,
            transcriptionModel: modelResult,
            outputDestination: outputResult,
            analysisTool: analysisResult
        )
        let snapshot = evaluator.evaluate(
            configuration: configuration,
            results: results,
            checkedAt: now()
        )
        guard generation == targetGeneration else {
            throw ReadinessRefreshError.staleResult
        }
        latestSnapshot = snapshot
        return snapshot
    }

    private func outputDestinationProbeResult(for url: URL?) async -> ReadinessOutputProbeResult {
        guard let url else { return .writable }
        return await outputProbe.verifyWritableDirectory(url)
    }
}
