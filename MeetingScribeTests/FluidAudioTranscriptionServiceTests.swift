import AVFoundation
import Foundation
import XCTest
@testable import MeetingScribe

final class FluidAudioTranscriptionServiceTests: XCTestCase {
    func testConfigurationAndProvenanceArePinned() {
        let configuration = FluidAudioTranscriptionConfiguration.current
        let descriptor = FluidAudioModelDescriptor.parakeetV3
        let provenance = TranscriptionProvenance.fluidAudioParakeetV3()

        XCTAssertEqual(FluidAudioTranscriptionConfiguration.sdkVersion, "0.15.5")
        XCTAssertEqual(configuration.revision, "parakeet-v3-int8-longform-v1")
        XCTAssertFalse(configuration.melChunkContext)
        XCTAssertTrue(configuration.dualDecodeArbitration)
        XCTAssertEqual(configuration.parallelChunkConcurrency, 1)
        XCTAssertEqual(configuration.streamingThresholdSamples, 480_000)
        XCTAssertEqual(provenance.engine, "FluidAudio")
        XCTAssertEqual(provenance.engineVersion, "0.15.5")
        XCTAssertEqual(provenance.model, descriptor.repository)
        XCTAssertEqual(provenance.modelRevision, descriptor.revision)
        XCTAssertEqual(provenance.modelVariant, descriptor.variant)
        XCTAssertEqual(provenance.configurationRevision, configuration.revision)
    }

    func testServiceNormalizesWordsAndOwnsTimingMetrics() async throws {
        let runner = StubFluidAudioASRRunner(
            output: FluidAudioASROutput(
                text: "Toto je test. Druhá veta",
                confidence: 1.4,
                tokenTimings: [
                    token("▁Druhá", id: 4, start: 8, end: 12, confidence: 0.8),
                    token("▁Toto", id: 1, start: -1, end: 1, confidence: 0.9),
                    token("▁je", id: 2, start: 1.1, end: 2, confidence: 0.7),
                    token("▁test", id: 3, start: 2.1, end: 3, confidence: 0.6),
                    token(".", id: 5, start: 3, end: 3.1, confidence: 0.5),
                    token("▁veta", id: 6, start: 12, end: 13, confidence: 2),
                ]
            )
        )
        let clock = TestUptimeClock(values: [100, 104])
        let service = FluidAudioTranscriptionService(
            runner: runner,
            now: { Date(timeIntervalSince1970: 1_000) },
            uptime: { clock.next() },
            audioFileInfo: { _ in
                FluidAudioAudioFileInfo(
                    sampleRate: 16_000,
                    channelCount: 1,
                    frameCount: 160_000
                )
            },
            hasMeaningfulActivity: { _ in true }
        )
        let transcript = try await service.transcribe(makeRequest(offset: 5))

        XCTAssertEqual(transcript.schemaVersion, 4)
        XCTAssertEqual(transcript.detectedLanguage, "und")
        XCTAssertEqual(transcript.completedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(transcript.provenance, .fluidAudioParakeetV3())
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].text, "Toto je test.")
        XCTAssertEqual(transcript.segments[0].words?.map(\.text), ["Toto", "je", "test."])
        XCTAssertEqual(transcript.segments[0].start, 5, accuracy: 0.001)
        XCTAssertEqual(transcript.segments[1].end, 15, accuracy: 0.001)
        XCTAssertEqual(transcript.segments[1].words?.last?.confidence, 1)
        XCTAssertEqual(transcript.performance?.audioDurationSeconds, 10)
        XCTAssertEqual(transcript.performance?.wallTimeSeconds, 4)
        XCTAssertEqual(transcript.performance?.realTimeFactor, 2.5)
        XCTAssertEqual(transcript.performance?.chunkCount, 1)
        let callCount = await runner.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testFallbackTextAndForcedLanguageRemainCompatibleWithoutTokenTiming() async throws {
        let runner = StubFluidAudioASRRunner(
            output: FluidAudioASROutput(
                text: "  Ahoj světe.  ",
                confidence: 0.75,
                tokenTimings: []
            )
        )
        let service = FluidAudioTranscriptionService(
            runner: runner,
            audioFileInfo: { _ in
                FluidAudioAudioFileInfo(
                    sampleRate: 16_000,
                    channelCount: 1,
                    frameCount: 32_000
                )
            },
            hasMeaningfulActivity: { _ in true }
        )
        let transcript = try await service.transcribe(
            makeRequest(language: .czech, offset: 2)
        )

        XCTAssertEqual(transcript.detectedLanguage, "cs")
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].text, "Ahoj světe.")
        XCTAssertEqual(transcript.segments[0].start, 2)
        XCTAssertEqual(transcript.segments[0].end, 4)
        XCTAssertNil(transcript.segments[0].words)
        XCTAssertEqual(transcript.performance?.activeDurationSeconds, 2)
    }

    func testSilentActivityGateSkipsInferenceAndPreservesTrackDuration() async throws {
        let runner = StubFluidAudioASRRunner(
            output: .init(text: "unexpected", confidence: 1, tokenTimings: [])
        )
        let service = FluidAudioTranscriptionService(
            runner: runner,
            audioFileInfo: { _ in
                .init(sampleRate: 16_000, channelCount: 1, frameCount: 160_000)
            },
            hasMeaningfulActivity: { _ in false }
        )

        let transcript = try await service.transcribe(makeRequest(offset: 3))
        let callCount = await runner.callCount()

        XCTAssertTrue(transcript.segments.isEmpty)
        XCTAssertEqual(transcript.performance?.audioDurationSeconds, 10)
        XCTAssertEqual(callCount, 0)
    }

    func testEnergyDetectorRejectsSilenceButKeepsSparseMeaningfulAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingScribeActivity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let silentURL = root.appendingPathComponent("silent.wav")
        let sparseURL = root.appendingPathComponent("sparse.wav")
        try writeActivityFixture([Float](repeating: 0, count: 16_000), to: silentURL)
        var sparse = [Float](repeating: 0, count: 32_000)
        for range in [2_048..<3_072, 12_288..<13_312, 24_576..<25_600] {
            for index in range { sparse[index] = 0.02 }
        }
        try writeActivityFixture(sparse, to: sparseURL)

        let detector = AudioActivityDetector()
        XCTAssertFalse(try detector.hasMeaningfulActivity(at: silentURL))
        XCTAssertTrue(try detector.hasMeaningfulActivity(at: sparseURL))
    }

    func testServiceRejectsWrongEngineInvalidFormatAndEmptyAudioBeforeInference() async throws {
        let runner = StubFluidAudioASRRunner(output: .init(text: "", confidence: 0, tokenTimings: []))
        let wrongEngine = FluidAudioTranscriptionService(
            runner: runner,
            audioFileInfo: { _ in
                .init(sampleRate: 16_000, channelCount: 1, frameCount: 1)
            },
            hasMeaningfulActivity: { _ in true }
        )
        do {
            _ = try await wrongEngine.transcribe(
                SpeechTranscriptionRequest(
                    audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
                    model: TranscriptionModelReference(
                        location: URL(fileURLWithPath: "/tmp/model"),
                        provenance: TranscriptionProvenance(
                            engine: "Unsupported",
                            engineVersion: nil,
                            model: "legacy",
                            modelRevision: nil,
                            configurationRevision: nil
                        )
                    ),
                    options: .init(source: .system, speaker: "Other")
                )
            )
            XCTFail("Expected the engine contract to reject an unsupported engine.")
        } catch TranscriptionError.unsupportedEngine("Unsupported") {}

        let invalidFormat = FluidAudioTranscriptionService(
            runner: runner,
            audioFileInfo: { _ in
                .init(sampleRate: 48_000, channelCount: 2, frameCount: 100)
            },
            hasMeaningfulActivity: { _ in true }
        )
        do {
            _ = try await invalidFormat.transcribe(makeRequest())
            XCTFail("Expected invalid format.")
        } catch TranscriptionError.invalidAudioFormat(let sampleRate, let channelCount) {
            XCTAssertEqual(sampleRate, 48_000)
            XCTAssertEqual(channelCount, 2)
        }

        let empty = FluidAudioTranscriptionService(
            runner: runner,
            audioFileInfo: { _ in
                .init(sampleRate: 16_000, channelCount: 1, frameCount: 0)
            },
            hasMeaningfulActivity: { _ in true }
        )
        do {
            _ = try await empty.transcribe(makeRequest())
            XCTFail("Expected empty audio.")
        } catch TranscriptionError.emptyAudio {}

        let callCount = await runner.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testCancellationPropagatesAndResourcesCanBeReleased() async throws {
        let runner = SuspendingFluidAudioASRRunner()
        let service = FluidAudioTranscriptionService(
            runner: runner,
            audioFileInfo: { _ in
                .init(sampleRate: 16_000, channelCount: 1, frameCount: 16_000)
            },
            hasMeaningfulActivity: { _ in true }
        )
        let request = makeRequest()
        let task = Task { try await service.transcribe(request) }
        await runner.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {}

        await service.releaseResources()
        let releaseCount = await runner.releaseCount()
        XCTAssertEqual(releaseCount, 1)
    }

    func testIsolatedWorkerCancelsOnlyItsOwnedProcess() async throws {
        let fixture = try makeWorkerFixture(script: """
        #!/bin/sh
        exec sleep 5
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runner = FluidAudioASRWorkerProcessRunner(
            executableURL: { fixture.executable },
            terminationGracePeriod: 0.05
        )
        let task = Task {
            try await runner.transcribe(
                audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
                modelBundleURL: URL(fileURLWithPath: "/tmp/model"),
                language: .automatic,
                configuration: .current
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled worker task to fail.")
        } catch is CancellationError {}
    }

    func testLegacySegmentJSONWithoutWordsStillDecodes() throws {
        let data = Data(#"""
        {
          "id":"system-000001","source":"system","speaker":"Other",
          "start":1.0,"end":2.0,"language":"sk","text":"Ahoj","confidence":0.9
        }
        """#.utf8)

        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: data)

        XCTAssertEqual(segment.text, "Ahoj")
        XCTAssertNil(segment.words)
    }

    func testExplicitReprocessingCreatesRevisionWithoutChangingLegacyArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingScribe-FA3-revision-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyTranscriptURL = root.appendingPathComponent("transcript.json")
        let legacyMarkdownURL = root.appendingPathComponent("legacy.md")
        let manifestURL = root.appendingPathComponent("session.json")
        let legacyTranscript = Data("legacy transcript".utf8)
        let legacyMarkdown = Data("legacy markdown".utf8)
        let legacyManifest = Data("legacy manifest".utf8)
        try legacyTranscript.write(to: legacyTranscriptURL)
        try legacyMarkdown.write(to: legacyMarkdownURL)
        try legacyManifest.write(to: manifestURL)
        try Data("source audio".utf8).write(
            to: root.appendingPathComponent("system-16k.wav")
        )

        let finalization = AudioFinalizationMetadata(
            completedAt: Date(timeIntervalSince1970: 10),
            timelineOrigin: 0,
            system: FinalizedAudioTrackMetadata(
                fileName: "system-16k.wav",
                sampleRate: 16_000,
                channelCount: 1,
                totalFrames: 160_000,
                durationSeconds: 10,
                timelineOffsetSeconds: 0
            ),
            microphone: nil,
            warnings: []
        )
        let session = RecordingSession(
            metadata: SessionMetadata(
                id: "source-session",
                title: "Legacy meeting",
                status: .recorded,
                createdAt: Date(timeIntervalSince1970: 1),
                audioFinalization: finalization
            ),
            directoryURL: root
        )
        let speechService = RevisionSpeechService()
        let reprocessor = FluidAudioTranscriptionRevisionService(
            transcriber: SessionTranscriber(
                service: speechService,
                now: { Date(timeIntervalSince1970: 20) }
            ),
            processingFileService: RevisionProcessingFileService(),
            now: { Date(timeIntervalSince1970: 30) },
            makeID: { "revision-test" }
        )

        let result = try await reprocessor.reprocess(
            session: session,
            modelBundleURL: root.appendingPathComponent("model")
        )

        XCTAssertEqual(result.directoryURL, root.appendingPathComponent("revisions/revision-test"))
        XCTAssertEqual(result.manifest.status, .completed)
        XCTAssertEqual(result.manifest.sourceSessionID, "source-session")
        XCTAssertEqual(result.manifest.provenance, .fluidAudioParakeetV3())
        XCTAssertEqual(result.manifest.sourceAudioFingerprints["system"]?.count, 64)
        XCTAssertEqual(result.manifest.transcription?.status, .completed)
        XCTAssertEqual(try Data(contentsOf: legacyTranscriptURL), legacyTranscript)
        XCTAssertEqual(try Data(contentsOf: legacyMarkdownURL), legacyMarkdown)
        XCTAssertEqual(try Data(contentsOf: manifestURL), legacyManifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.directoryURL
            .appendingPathComponent("revision.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.directoryURL
            .appendingPathComponent("system-transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.directoryURL
            .appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.directoryURL
            .appendingPathComponent("comparison.md").path))
        let revisionTranscriptData = try Data(contentsOf: result.directoryURL
            .appendingPathComponent("transcript.json"))
        let revisionTranscript = try TranscriptJSONCoder.makeDecoder().decode(
            MergedTranscript.self,
            from: revisionTranscriptData
        )
        XCTAssertEqual(revisionTranscript.segments.first?.words?.first?.text, "Porovnávací prepis.")
        let calls = await speechService.callCount()
        let releases = await speechService.releaseCount()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(releases, 1)
    }

    func testExplicitReprocessingRecoversFinalizationFromPreservedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingScribe-FA3-recovered-revision-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let systemAudioURL = root.appendingPathComponent("system-16k.wav")
        try writeActivityFixture(Array(repeating: 0.2, count: 16_000), to: systemAudioURL)
        let originalManifest = Data("failed source manifest".utf8)
        let manifestURL = root.appendingPathComponent("session.json")
        try originalManifest.write(to: manifestURL)
        let session = RecordingSession(
            metadata: SessionMetadata(
                id: "failed-source-session",
                title: "Recovered meeting",
                status: .failed,
                createdAt: Date(timeIntervalSince1970: 1),
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2)
            ),
            directoryURL: root
        )
        let speechService = RevisionSpeechService()
        let reprocessor = FluidAudioTranscriptionRevisionService(
            transcriber: SessionTranscriber(
                service: speechService,
                now: { Date(timeIntervalSince1970: 20) }
            ),
            processingFileService: RevisionProcessingFileService(),
            now: { Date(timeIntervalSince1970: 30) },
            makeID: { "recovered-revision-test" }
        )

        let result = try await reprocessor.reprocess(
            session: session,
            modelBundleURL: root.appendingPathComponent("model")
        )

        XCTAssertEqual(result.manifest.status, .completed)
        XCTAssertEqual(result.manifest.transcription?.status, .completed)
        XCTAssertEqual(result.manifest.sourceAudioFingerprints["system"]?.count, 64)
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifest)
        let calls = await speechService.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testRevisionExportFailureReportsExportStepAndPreservesTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeActivityFixture(Array(repeating: 0.2, count: 16_000), to: root.appendingPathComponent("system-16k.wav"))
        let session = RecordingSession(
            metadata: SessionMetadata(
                id: "export-failure", title: "Meeting", status: .failed,
                createdAt: Date(timeIntervalSince1970: 1),
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2)
            ), directoryURL: root
        )
        let steps = RevisionStepRecorder()
        let service = FluidAudioTranscriptionRevisionService(
            transcriber: SessionTranscriber(service: RevisionSpeechService()),
            processingFileService: RevisionProcessingFileService(failExport: true),
            makeID: { "export-failure" }
        )
        do {
            _ = try await service.reprocess(
                session: session, modelBundleURL: root.appendingPathComponent("model"),
                onStep: { await steps.append($0) }
            )
            XCTFail("Expected export failure")
        } catch {
            let recordedSteps = await steps.values
            XCTAssertEqual(recordedSteps, [.preparingAudio, .transcribing, .exporting])
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("revisions/export-failure/transcript.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("revisions/export-failure/comparison.md").path))
        }
    }

    func testOptInRealModelFixtureMatrixProducesValidWordTimings() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["MEETINGSCRIBE_FA3_MODEL_BUNDLE"] else {
            throw XCTSkip(
                "Set MEETINGSCRIBE_FA3_MODEL_BUNDLE and one or more FA3 audio fixtures."
            )
        }
        let fixtureDefinitions: [(key: String, label: String, expectsSpeech: Bool)] = [
            ("MEETINGSCRIBE_FA3_AUDIO_FIXTURE", "generic", true),
            ("MEETINGSCRIBE_FA3_AUDIO_CZ", "Czech", true),
            ("MEETINGSCRIBE_FA3_AUDIO_SK", "Slovak", true),
            ("MEETINGSCRIBE_FA3_AUDIO_MIXED", "mixed Czech/Slovak", true),
            ("MEETINGSCRIBE_FA3_AUDIO_ENGLISH", "English", true),
            ("MEETINGSCRIBE_FA3_AUDIO_SILENCE", "silence", false),
            ("MEETINGSCRIBE_FA3_AUDIO_SPARSE", "sparse audio", true),
            ("MEETINGSCRIBE_FA3_AUDIO_LONG", "long input", true),
        ]
        let fixtures = fixtureDefinitions.compactMap { definition in
            environment[definition.key].map {
                (
                    url: URL(fileURLWithPath: $0),
                    label: definition.label,
                    expectsSpeech: definition.expectsSpeech
                )
            }
        }
        guard !fixtures.isEmpty else {
            throw XCTSkip("No MEETINGSCRIBE_FA3_AUDIO_* fixture path was provided.")
        }
        let modelURL = URL(fileURLWithPath: modelPath, isDirectory: true)
        let service = FluidAudioTranscriptionService()

        do {
            for fixture in fixtures {
                let transcript = try await service.transcribe(
                    SpeechTranscriptionRequest(
                        audioURL: fixture.url,
                        model: .fluidAudioParakeetV3(bundleURL: modelURL),
                        options: .init(
                            language: .automatic,
                            source: .system,
                            speaker: "Other"
                        )
                    )
                )
                XCTAssertEqual(
                    transcript.provenance,
                    .fluidAudioParakeetV3(),
                    fixture.label
                )
                if fixture.expectsSpeech {
                    XCTAssertFalse(transcript.segments.isEmpty, fixture.label)
                } else {
                    XCTAssertTrue(transcript.segments.isEmpty, fixture.label)
                }
                let words = transcript.segments.flatMap { $0.words ?? [] }
                if fixture.expectsSpeech {
                    XCTAssertFalse(words.isEmpty, fixture.label)
                }
                for (previous, current) in zip(words, words.dropFirst()) {
                    XCTAssertLessThanOrEqual(previous.start, current.start, fixture.label)
                }
                let duration = try FluidAudioAudioFileInfo
                    .forTestFixture(at: fixture.url).durationSeconds
                XCTAssertTrue(words.allSatisfy {
                    $0.start >= 0 && $0.end >= $0.start && $0.end <= duration + 0.001
                }, fixture.label)
            }
            await service.releaseResources()
        } catch {
            await service.releaseResources()
            throw error
        }
    }

    private func makeRequest(
        language: TranscriptionLanguage = .automatic,
        offset: Double = 0
    ) -> SpeechTranscriptionRequest {
        SpeechTranscriptionRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            model: .fluidAudioParakeetV3(
                bundleURL: URL(fileURLWithPath: "/tmp/parakeet-v3")
            ),
            options: .init(
                language: language,
                source: .system,
                speaker: "Other",
                timelineOffsetSeconds: offset
            )
        )
    }

    private func writeActivityFixture(_ samples: [Float], to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        try file.write(from: buffer)
    }

    private func makeWorkerFixture(
        script: String
    ) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingScribe-ASRWorkerTest-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let executable = directory.appendingPathComponent("worker")
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return (directory, executable)
    }

    private func token(
        _ text: String,
        id: Int,
        start: Double,
        end: Double,
        confidence: Double
    ) -> FluidAudioASRToken {
        FluidAudioASRToken(
            text: text,
            tokenID: id,
            startTime: start,
            endTime: end,
            confidence: confidence
        )
    }
}

private actor StubFluidAudioASRRunner: FluidAudioASRRunning {
    private let output: FluidAudioASROutput
    private var calls = 0

    init(output: FluidAudioASROutput) {
        self.output = output
    }

    func transcribe(
        audioURL: URL,
        modelBundleURL: URL,
        language: TranscriptionLanguage,
        configuration: FluidAudioTranscriptionConfiguration
    ) async throws -> FluidAudioASROutput {
        calls += 1
        return output
    }

    func releaseResources() async {}

    func callCount() -> Int { calls }
}

private actor SuspendingFluidAudioASRRunner: FluidAudioASRRunning {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var releases = 0

    func transcribe(
        audioURL: URL,
        modelBundleURL: URL,
        language: TranscriptionLanguage,
        configuration: FluidAudioTranscriptionConfiguration
    ) async throws -> FluidAudioASROutput {
        started = true
        continuation?.resume()
        continuation = nil
        try await Task.sleep(for: .seconds(60))
        return FluidAudioASROutput(text: "", confidence: 0, tokenTimings: [])
    }

    func releaseResources() async { releases += 1 }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func releaseCount() -> Int { releases }
}

private final class TestUptimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval]

    init(values: [TimeInterval]) {
        self.values = values
    }

    func next() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? 0 : values.removeFirst()
    }
}

private actor RevisionSpeechService: SpeechTranscribing {
    private var calls = 0
    private var releases = 0

    func transcribe(_ request: SpeechTranscriptionRequest) async throws -> TrackTranscript {
        calls += 1
        return TrackTranscript(
            schemaVersion: 4,
            source: request.options.source,
            model: request.model.provenance.model,
            requestedLanguage: request.options.language,
            detectedLanguage: "sk",
            completedAt: Date(timeIntervalSince1970: 20),
            segments: [
                TranscriptSegment(
                    id: "system-000000",
                    source: request.options.source,
                    speaker: request.options.speaker,
                    start: 0,
                    end: 1,
                    language: "sk",
                    text: "Porovnávací prepis.",
                    confidence: 0.9,
                    words: [
                        TranscriptWord(
                            start: 0,
                            end: 1,
                            text: "Porovnávací prepis.",
                            confidence: 0.9
                        )
                    ]
                )
            ],
            provenance: request.model.provenance
        )
    }

    func releaseResources() async { releases += 1 }
    func callCount() -> Int { calls }
    func releaseCount() -> Int { releases }
}

private actor RevisionStepRecorder {
    var values: [ProcessingStepID] = []
    func append(_ value: ProcessingStepID) { values.append(value) }
}

private actor RevisionProcessingFileService: ProcessingFileServicing {
    private let failExport: Bool
    init(failExport: Bool = false) { self.failExport = failExport }

    func loadRecoveredArtifacts(from session: RecordingSession) async -> RecoveredProcessingArtifacts? {
        nil
    }

    func loadUserNotes(from session: RecordingSession) async -> String? { nil }

    func persistAnalysis(_ analysis: AIAnalysisArtifact, to url: URL) async throws {}

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        analysis: AIAnalysisArtifact?,
        notes: String?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult {
        if failExport { throw CocoaError(.fileWriteNoPermission) }
        let url = directoryURL.appendingPathComponent("comparison.md")
        try Data("comparison".utf8).write(to: url, options: .atomic)
        return MarkdownExportResult(
            fileURL: url,
            exportedAt: Date(timeIntervalSince1970: 30)
        )
    }
}

private extension FluidAudioAudioFileInfo {
    static func forTestFixture(at url: URL) throws -> FluidAudioAudioFileInfo {
        let file = try AVAudioFile(forReading: url)
        return FluidAudioAudioFileInfo(
            sampleRate: file.processingFormat.sampleRate,
            channelCount: Int(file.processingFormat.channelCount),
            frameCount: file.length
        )
    }
}

/// The worker process controller is exercised with `/bin/sleep` so the
/// cancellation contract is verified without an ASR model or a real worker.
final class FluidAudioASRWorkerProcessControllerTests: XCTestCase {
    private static let sleepURL = URL(fileURLWithPath: "/bin/sleep")

    func testStaleCancellationDoesNotTerminateTheNextRun() async throws {
        let controller = FluidAudioASRWorkerProcessController(terminationGracePeriod: 1)

        // A cancellation that arrives while no process is attached used to latch
        // and then SIGTERM the next worker, which the queue recorded as a
        // permanent failure with "exit code 15".
        controller.cancel()

        let status = try await controller.run(
            executableURL: Self.sleepURL,
            arguments: ["0.1"]
        )
        XCTAssertEqual(status, 0)
    }

    func testCancellingTheCurrentRunReportsCancellationNotAnExitCode() async {
        let controller = FluidAudioASRWorkerProcessController(terminationGracePeriod: 1)
        let task = Self.startSleeping(controller, seconds: "30")
        try? await Task.sleep(for: .milliseconds(400))
        controller.cancel()

        do {
            let status = try await task.value
            XCTFail("Expected cancellation, got exit status \(status)")
        } catch is CancellationError {
            // The pause path depends on this: a termination we asked for must
            // not look like a worker failure.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testConsecutiveRunsSucceedAfterACancelledRun() async throws {
        let controller = FluidAudioASRWorkerProcessController(terminationGracePeriod: 1)
        let task = Self.startSleeping(controller, seconds: "30")
        try? await Task.sleep(for: .milliseconds(400))
        controller.cancel()
        _ = try? await task.value

        let status = try await controller.run(
            executableURL: Self.sleepURL,
            arguments: ["0.1"]
        )
        XCTAssertEqual(status, 0)
    }

    /// Kept off the test instance so the task closure captures only Sendable
    /// values: XCTestCase and XCTestExpectation are not Sendable.
    private static func startSleeping(
        _ controller: FluidAudioASRWorkerProcessController,
        seconds: String
    ) -> Task<Int32, Error> {
        let executableURL = sleepURL
        return Task {
            try await controller.run(
                executableURL: executableURL,
                arguments: [seconds]
            )
        }
    }
}
