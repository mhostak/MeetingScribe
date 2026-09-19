import Foundation
import XCTest
@testable import MeetingScribe

final class ReadinessTests: XCTestCase {
    func testSystemAudioPermissionBlocksOnlySystemCaptureMode() {
        let evaluator = ReadinessEvaluator()

        let systemSnapshot = evaluator.evaluate(
            configuration: ReadinessConfiguration(captureMode: .systemAndMicrophone),
            results: readyResults(systemAudioPermission: .denied),
            checkedAt: Date()
        )
        XCTAssertEqual(
            systemSnapshot.check(.systemAudio)?.impact,
            .blocksCaptureMode(.systemAndMicrophone)
        )
        XCTAssertEqual(systemSnapshot.summary, .recordingNeedsAttention)

        let microphoneOnlySnapshot = evaluator.evaluate(
            configuration: ReadinessConfiguration(captureMode: .microphoneOnly),
            results: readyResults(systemAudioPermission: .denied),
            checkedAt: Date()
        )
        XCTAssertNil(microphoneOnlySnapshot.check(.systemAudio))
        XCTAssertEqual(microphoneOnlySnapshot.summary, .readyForRecordingAndTranscription)
    }

    func testMicrophoneIsWarningForHybridAndBlockingForMicrophoneOnly() {
        let evaluator = ReadinessEvaluator()

        let hybrid = evaluator.evaluate(
            configuration: ReadinessConfiguration(captureMode: .systemAndMicrophone),
            results: readyResults(microphonePermission: .denied),
            checkedAt: Date()
        )
        XCTAssertEqual(hybrid.check(.microphone)?.status, .needsAttention)
        XCTAssertEqual(hybrid.check(.microphone)?.impact, .warning)
        XCTAssertEqual(hybrid.summary, .readyForRecordingAndTranscription)

        let microphoneOnly = evaluator.evaluate(
            configuration: ReadinessConfiguration(captureMode: .microphoneOnly),
            results: readyResults(microphonePermission: .denied),
            checkedAt: Date()
        )
        XCTAssertEqual(
            microphoneOnly.check(.microphone)?.impact,
            .blocksCaptureMode(.microphoneOnly)
        )
        XCTAssertEqual(microphoneOnly.summary, .recordingNeedsAttention)
    }

    func testMissingModelAndDisabledAIDoNotBlockRecording() {
        let evaluator = ReadinessEvaluator()
        let snapshot = evaluator.evaluate(
            configuration: ReadinessConfiguration(),
            results: readyResults(model: .missing),
            checkedAt: Date()
        )

        XCTAssertEqual(snapshot.check(.transcriptionModel)?.status, .needsAttention)
        XCTAssertEqual(snapshot.check(.transcriptionModel)?.impact, .limitsProcessing)
        XCTAssertEqual(snapshot.check(.transcriptionModel)?.action, .downloadTranscriptionModel)
        guard let aiAnalysisCheck = snapshot.check(.aiAnalysis) else {
            return XCTFail("Expected the AI analysis readiness check.")
        }
        XCTAssertEqual(aiAnalysisCheck.status, .optional)
        XCTAssertEqual(aiAnalysisCheck.impact, .none)
        XCTAssertEqual(snapshot.summary, .readyForRecordingTranscriptionNeedsAttention)
    }

    func testInsufficientStorageBlocksRecording() {
        let evaluator = ReadinessEvaluator()
        let snapshot = evaluator.evaluate(
            configuration: ReadinessConfiguration(),
            results: readyResults(
                storage: .available(
                    StorageStatus(
                        availableBytes: StorageGuard.defaultMinimumBytes - 1,
                        requiredBytes: StorageGuard.defaultMinimumBytes
                    )
                )
            ),
            checkedAt: Date()
        )

        XCTAssertEqual(snapshot.check(.storage)?.status, .needsAttention)
        XCTAssertEqual(snapshot.check(.storage)?.impact, .blocksRecording)
        XCTAssertEqual(snapshot.check(.storage)?.action, .freeStorageSpace)
        XCTAssertEqual(snapshot.summary, .recordingNeedsAttention)
    }

    func testUnavailableStorageIsUnverifiedRatherThanDenied() {
        let evaluator = ReadinessEvaluator()
        let snapshot = evaluator.evaluate(
            configuration: ReadinessConfiguration(),
            results: readyResults(storage: .unavailable),
            checkedAt: Date()
        )

        XCTAssertEqual(snapshot.check(.storage)?.status, .unverified)
        XCTAssertEqual(snapshot.check(.storage)?.impact, .blocksRecording)
        XCTAssertEqual(snapshot.check(.storage)?.action, .fixStorageAccess)
    }

    func testInvalidOutputFolderLimitsProcessingWithoutBlockingRecording() {
        let folderURL = URL(fileURLWithPath: "/tmp/MeetingScribe-unavailable-output")
        let evaluator = ReadinessEvaluator()
        let snapshot = evaluator.evaluate(
            configuration: ReadinessConfiguration(outputFolderURL: folderURL),
            results: readyResults(
                output: .failed(reason: "The output folder is not writable.")
            ),
            checkedAt: Date()
        )

        XCTAssertEqual(snapshot.check(.outputDestination)?.status, .needsAttention)
        XCTAssertEqual(snapshot.check(.outputDestination)?.impact, .limitsProcessing)
        XCTAssertEqual(snapshot.check(.outputDestination)?.action, .chooseOutputFolder)
        XCTAssertEqual(snapshot.summary, .readyForRecordingAndTranscription)
    }

    func testUnsupportedFileNameTemplateIsReportedSeparatelyFromRecording() {
        let evaluator = ReadinessEvaluator()
        let snapshot = evaluator.evaluate(
            configuration: ReadinessConfiguration(outputFileNameTemplate: "{bad} {title}"),
            results: readyResults(),
            checkedAt: Date()
        )

        XCTAssertEqual(snapshot.check(.outputDestination)?.status, .needsAttention)
        XCTAssertEqual(snapshot.check(.outputDestination)?.impact, .limitsProcessing)
        XCTAssertEqual(snapshot.check(.outputDestination)?.action, .fixOutputFileNameTemplate)
        XCTAssertEqual(snapshot.summary, .readyForRecordingAndTranscription)
    }

    func testEnabledBrokenAILimitsProcessingButDoesNotBlockRecording() {
        let evaluator = ReadinessEvaluator()
        let snapshot = evaluator.evaluate(
            configuration: ReadinessConfiguration(
                aiAnalysis: ReadinessOptionalFeature(isEnabled: true)
            ),
            results: readyResults(analysisToolStatus: .authenticationRequired(
                path: "/usr/local/bin/codex",
                version: nil,
                loginCommand: "codex login"
            )),
            checkedAt: Date()
        )

        XCTAssertEqual(snapshot.check(.aiAnalysis)?.status, .needsAttention)
        XCTAssertEqual(snapshot.check(.aiAnalysis)?.impact, .limitsProcessing)
        XCTAssertEqual(snapshot.check(.aiAnalysis)?.action, .openAISettings)
        XCTAssertEqual(snapshot.summary, .readyForRecordingAndTranscription)
    }

    func testCalendarAndNotificationsRemainOptional() {
        let evaluator = ReadinessEvaluator()
        let snapshot = evaluator.evaluate(
            configuration: ReadinessConfiguration(
                calendar: ReadinessOptionalFeature(isEnabled: true, authorization: .denied),
                notifications: ReadinessOptionalFeature(isEnabled: true, authorization: .denied)
            ),
            results: readyResults(),
            checkedAt: Date()
        )

        XCTAssertEqual(snapshot.check(.calendar)?.status, .needsAttention)
        XCTAssertEqual(snapshot.check(.calendar)?.impact, .informational)
        XCTAssertEqual(snapshot.check(.calendar)?.action, .openCalendarSettings)
        XCTAssertEqual(snapshot.check(.notifications)?.status, .needsAttention)
        XCTAssertEqual(snapshot.check(.notifications)?.impact, .informational)
        XCTAssertEqual(snapshot.check(.notifications)?.action, .openNotificationSettings)
        XCTAssertEqual(snapshot.summary, .readyForRecordingAndTranscription)
    }

    func testGrantedNotificationAuthorizationIsReadyRatherThanUnverified() {
        let evaluator = ReadinessEvaluator()
        let snapshot = evaluator.evaluate(
            configuration: ReadinessConfiguration(
                notifications: ReadinessOptionalFeature(isEnabled: true, authorization: .granted)
            ),
            results: readyResults(),
            checkedAt: Date()
        )

        XCTAssertEqual(snapshot.check(.notifications)?.status, .ready)
        XCTAssertEqual(snapshot.check(.notifications)?.action, ReadinessAction.none)
        XCTAssertEqual(
            snapshot.check(.notifications)?.detail,
            .optionalFeature(isEnabled: true, permission: .granted)
        )
    }

    func testChecksCarryTheConfigurationBehindThem() {
        let folderURL = URL(fileURLWithPath: "/tmp/MeetingScribe-readiness-detail")
        let evaluator = ReadinessEvaluator()
        let snapshot = evaluator.evaluate(
            configuration: ReadinessConfiguration(
                outputFolderURL: folderURL,
                outputFileNameTemplate: "{date} - {title}",
                transcriptionModelName: "Parakeet TDT 0.6B v3 (int8)",
                analysisToolName: "Codex",
                analysisModelName: "gpt-5.6-terra",
                aiAnalysis: ReadinessOptionalFeature(isEnabled: true)
            ),
            results: readyResults(),
            checkedAt: Date()
        )

        XCTAssertEqual(
            snapshot.check(.transcriptionModel)?.detail,
            .transcriptionModel(name: "Parakeet TDT 0.6B v3 (int8)", state: .ready)
        )
        XCTAssertEqual(
            snapshot.check(.outputDestination)?.detail,
            .output(folderPath: folderURL.path, template: "{date} - {title}")
        )
        XCTAssertEqual(
            snapshot.check(.aiAnalysis)?.detail,
            .analysis(
                tool: "Codex",
                model: "gpt-5.6-terra",
                status: .available(path: "codex", version: nil)
            )
        )
        XCTAssertEqual(
            snapshot.check(.systemAudio)?.detail,
            .systemAudio(permission: .granted, captureMode: .systemAndMicrophone)
        )
        XCTAssertEqual(
            snapshot.check(.storage)?.detail,
            .storage(
                availableBytes: StorageGuard.defaultMinimumBytes,
                requiredBytes: StorageGuard.defaultMinimumBytes
            )
        )
    }

    func testUnsupportedTemplateDetailNamesTheOffendingTokens() {
        let evaluator = ReadinessEvaluator()
        let snapshot = evaluator.evaluate(
            configuration: ReadinessConfiguration(outputFileNameTemplate: "{bad} {title}"),
            results: readyResults(),
            checkedAt: Date()
        )

        XCTAssertEqual(
            snapshot.check(.outputDestination)?.detail,
            .outputTemplateInvalid(tokens: ["{bad}"])
        )
    }

    func testReadinessDetailIsLocalizedForEachSupportedLanguage() {
        let detail = ReadinessDetail.transcriptionModel(name: "Parakeet", state: .missing)

        XCTAssertEqual(
            AppLocalization.readinessDetail(detail, language: .slovak),
            "Model: Parakeet · nie je nainštalovaný"
        )
        XCTAssertEqual(
            AppLocalization.readinessDetail(detail, language: .czech),
            "Model: Parakeet · není nainstalovaný"
        )
        XCTAssertEqual(
            AppLocalization.readinessDetail(detail, language: .english),
            "Model: Parakeet · not installed"
        )
    }

    func testOutputProbeCreatesAndRemovesOnlyItsOwnFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeReadinessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = OutputFolderWriteProbe()

        let result = await probe.verifyWritableDirectory(root)

        XCTAssertEqual(result, .writable)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testPassiveRefreshUsesAdaptersWithoutRequestsDownloadsOrAICommands() async throws {
        let modelProbe = RecordingModelProbe(status: .missing)
        let analysisStatusProvider = CachedAnalysisStatusProvider(status: .unknown)
        let service = ReadinessService(
            permissionProbe: RecordingPermissionProbe(),
            storageProbe: RecordingStorageProbe(.available(Self.sufficientStorage())),
            modelProbe: modelProbe,
            outputProbe: RecordingOutputProbe(),
            analysisStatusProvider: analysisStatusProvider
        )

        let snapshot = try await service.refresh(ReadinessConfiguration())

        guard let transcriptionModelCheck = snapshot.check(.transcriptionModel) else {
            return XCTFail("Expected the transcription model readiness check.")
        }
        XCTAssertEqual(transcriptionModelCheck.status, .needsAttention)
        let modelCalls = await modelProbe.callCount
        XCTAssertEqual(modelCalls, 1)
    }

    func testDelayedRefreshResultDoesNotReplaceNewerSnapshot() async throws {
        let firstConfiguration = ReadinessConfiguration(
            outputFileNameTemplate: "{date} {time} - {title}"
        )
        let secondConfiguration = ReadinessConfiguration(
            outputFileNameTemplate: "{date} {time} - {title} - {id}"
        )
        let modelProbe = RaceModelProbe()
        let service = ReadinessService(
            permissionProbe: RecordingPermissionProbe(),
            storageProbe: RecordingStorageProbe(.available(Self.sufficientStorage())),
            modelProbe: modelProbe,
            outputProbe: RecordingOutputProbe(),
            analysisStatusProvider: CachedAnalysisStatusProvider(status: .unknown)
        )

        let first = Task { try await service.refresh(firstConfiguration) }
        await modelProbe.waitUntilFirstCallStarted()
        let second = try await service.refresh(secondConfiguration)
        await modelProbe.releaseFirstCall()

        do {
            _ = try await first.value
            XCTFail("Expected the older refresh to be rejected.")
        } catch {
            XCTAssertEqual(error as? ReadinessRefreshError, .staleResult)
        }
        XCTAssertEqual(second.configuration, secondConfiguration)
        let latest = await service.currentSnapshot()
        XCTAssertEqual(latest?.configuration, secondConfiguration)
    }

    private func readyResults(
        systemAudioPermission: ReadinessPermissionStatus = .granted,
        microphonePermission: ReadinessPermissionStatus = .granted,
        storage: ReadinessStorageProbeResult = .available(sufficientStorage()),
        model: ReadinessModelProbeResult = .ready,
        output: ReadinessOutputProbeResult = .writable,
        analysisToolStatus: AnalysisToolStatus = .available(path: "codex", version: nil)
    ) -> ReadinessProbeResults {
        ReadinessProbeResults(
            systemAudioPermission: systemAudioPermission,
            microphonePermission: microphonePermission,
            storage: storage,
            transcriptionModel: model,
            outputDestination: output,
            analysisTool: analysisToolStatus
        )
    }

    private static func sufficientStorage() -> StorageStatus {
        StorageStatus(
            availableBytes: StorageGuard.defaultMinimumBytes,
            requiredBytes: StorageGuard.defaultMinimumBytes
        )
    }
}

private actor RecordingPermissionProbe: ReadinessPermissionProbing {
    func snapshot() async -> ReadinessPermissionSnapshot {
        ReadinessPermissionSnapshot(systemAudio: .granted, microphone: .granted)
    }
}

private actor RecordingStorageProbe: ReadinessStorageProbing {
    private let result: ReadinessStorageProbeResult

    init(_ result: ReadinessStorageProbeResult) {
        self.result = result
    }

    func status() async -> ReadinessStorageProbeResult {
        result
    }
}

private actor RecordingModelProbe: ReadinessModelProbing {
    private let result: ReadinessModelProbeResult
    private(set) var callCount = 0

    init(status: ReadinessModelProbeResult) {
        self.result = status
    }

    func status() async -> ReadinessModelProbeResult {
        callCount += 1
        return result
    }
}

/// Pins the interleaving the stale-result test is about: the first refresh has
/// to be inside its model probe when the second one starts. Sleeping only made
/// that likely, and on a loaded machine the second refresh could take the first
/// probe call instead, inverting the race the test means to assert.
private actor RaceModelProbe: ReadinessModelProbing {
    private var callCount = 0
    private var hasStartedFirstCall = false
    private var isFirstCallReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilFirstCallStarted() async {
        guard !hasStartedFirstCall else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstCall() {
        isFirstCallReleased = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }

    func status() async -> ReadinessModelProbeResult {
        callCount += 1
        guard callCount == 1 else { return .ready }
        hasStartedFirstCall = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        if !isFirstCallReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return .ready
    }
}

private actor RecordingOutputProbe: ReadinessOutputProbing {
    func verifyWritableDirectory(_ url: URL) async -> ReadinessOutputProbeResult {
        .writable
    }
}
