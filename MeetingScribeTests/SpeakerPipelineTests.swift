import Foundation
import XCTest
@testable import MeetingScribe

final class SpeakerPipelineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeSpeakerPipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testPipelinePersistsStableSpeakerArtifactAndWordResolvedTranscript() async throws {
        let fixture = try makeFixture()
        let diarizer = FixtureDiarizer(result: diarizationResult())
        let pipeline = SpeakerPipeline(diarizer: diarizer)

        let result = try await pipeline.process(
            session: fixture.session,
            transcript: fixture.transcript,
            systemAudioURL: fixture.audioURL,
            systemTimelineOffsetSeconds: 0,
            modelBundleURL: root.appendingPathComponent("speaker-diarization")
        )

        XCTAssertEqual(result.metadata.status, .completed)
        XCTAssertEqual(result.metadata.speakerCount, 2)
        XCTAssertEqual(
            result.artifact?.speakers.map(\.id),
            ["speaker-001", "speaker-002", SpeakerProfile.localID]
        )
        XCTAssertEqual(
            result.artifact?.result.segments.map(\.speakerID),
            ["speaker-001", "speaker-002"]
        )
        XCTAssertEqual(
            result.resolvedTranscript?.segments.map(\.speakerID),
            ["speaker-001", SpeakerProfile.localID, "speaker-002"]
        )
        XCTAssertEqual(
            result.resolvedTranscript?.segments.map(\.text),
            ["Hello", "Local reply", "world."]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.session.speakerDiarizationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.session.resolvedTranscriptURL.path))
    }

    func testNonzeroSystemTimelineOffsetAlignsWordsWithDiarizationTurns() async throws {
        let fixture = try makeFixture(systemTimelineOffsetSeconds: 5)
        let result = try await SpeakerPipeline(diarizer: FixtureDiarizer(
            result: diarizationResult()
        )).process(
            session: fixture.session,
            transcript: fixture.transcript,
            systemAudioURL: fixture.audioURL,
            systemTimelineOffsetSeconds: 5,
            modelBundleURL: root.appendingPathComponent("speaker-diarization")
        )

        XCTAssertEqual(result.artifact?.schemaVersion, 2)
        XCTAssertEqual(result.artifact?.sourceTimelineOffsetSeconds, 5)
        XCTAssertEqual(
            result.resolvedTranscript?.segments
                .filter { $0.source == .system }
                .map(\.speakerID),
            ["speaker-001", "speaker-002"]
        )
        XCTAssertEqual(
            result.resolvedTranscript?.segments
                .filter { $0.source == .system }
                .map(\.text),
            ["Hello", "world."]
        )
    }

    func testLegacyArtifactIsUpgradedWithSessionTimelineOffsetWithoutRediarization() async throws {
        let fixture = try makeFixture(systemTimelineOffsetSeconds: 5)
        let store = SpeakerArtifactStore()
        let artifact = try store.makeArtifact(
            sessionID: fixture.session.metadata.id,
            result: diarizationResult(),
            sourceAudioURL: fixture.audioURL,
            transcript: fixture.transcript,
            sourceTimelineOffsetSeconds: 5,
            configurationRevision: "test"
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: TranscriptJSONCoder.makeEncoder().encode(artifact)
            ) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object.removeValue(forKey: "sourceTimelineOffsetSeconds")
        try JSONSerialization.data(withJSONObject: object)
            .write(to: fixture.session.speakerDiarizationURL, options: .atomic)

        let result = try await SpeakerPipeline(diarizer: FixtureDiarizer(
            error: FixtureError.failed
        )).process(
            session: fixture.session,
            transcript: fixture.transcript,
            systemAudioURL: fixture.audioURL,
            systemTimelineOffsetSeconds: 5,
            modelBundleURL: root.appendingPathComponent("speaker-diarization")
        )

        XCTAssertEqual(result.metadata.status, .completed)
        XCTAssertEqual(result.artifact?.schemaVersion, 2)
        XCTAssertEqual(result.artifact?.sourceTimelineOffsetSeconds, 5)
        XCTAssertEqual(
            result.resolvedTranscript?.segments
                .filter { $0.source == .system }
                .map(\.speakerID),
            ["speaker-001", "speaker-002"]
        )
        let persisted = try store.load(from: fixture.session.speakerDiarizationURL)
        XCTAssertEqual(persisted.schemaVersion, 2)
        XCTAssertEqual(persisted.sourceTimelineOffsetSeconds, 5)
    }

    func testLegacyArtifactRemainsUsableWhenSchemaUpgradeCannotBePersisted() throws {
        let fixture = try makeFixture(systemTimelineOffsetSeconds: 5)
        let store = SpeakerArtifactStore()
        let artifact = try store.makeArtifact(
            sessionID: fixture.session.metadata.id,
            result: diarizationResult(),
            sourceAudioURL: fixture.audioURL,
            transcript: fixture.transcript,
            sourceTimelineOffsetSeconds: 5,
            configurationRevision: "test"
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: TranscriptJSONCoder.makeEncoder().encode(artifact)
            ) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object.removeValue(forKey: "sourceTimelineOffsetSeconds")
        try JSONSerialization.data(withJSONObject: object)
            .write(to: fixture.session.speakerDiarizationURL, options: .atomic)
        let persistedLegacy = try store.load(from: fixture.session.speakerDiarizationURL)
        let readOnlyStore = SpeakerArtifactStore(atomicWriter: { _, _ in
            throw FixtureError.failed
        })

        let loaded = try XCTUnwrap(readOnlyStore.loadValid(
            from: fixture.session.speakerDiarizationURL,
            sessionID: fixture.session.metadata.id,
            sourceAudioURL: fixture.audioURL,
            transcript: fixture.transcript,
            expectedTimelineOffsetSeconds: 5
        ))

        XCTAssertEqual(loaded.schemaVersion, 2)
        XCTAssertEqual(loaded.sourceTimelineOffsetSeconds, 5)
        XCTAssertEqual(loaded.modifiedAt, persistedLegacy.modifiedAt)
        XCTAssertEqual(try store.load(from: fixture.session.speakerDiarizationURL).schemaVersion, 1)
    }

    func testMissingModelAndDiarizationFailurePreserveFallbackPath() async throws {
        let fixture = try makeFixture()
        let missing = try await SpeakerPipeline(diarizer: FixtureDiarizer(
            result: diarizationResult()
        )).process(
            session: fixture.session,
            transcript: fixture.transcript,
            systemAudioURL: fixture.audioURL,
            systemTimelineOffsetSeconds: 0,
            modelBundleURL: nil
        )
        XCTAssertEqual(missing.metadata.status, .modelMissing)
        XCTAssertNil(missing.artifact)
        XCTAssertNil(missing.resolvedTranscript)

        let failed = try await SpeakerPipeline(diarizer: FixtureDiarizer(
            error: FixtureError.failed
        )).process(
            session: fixture.session,
            transcript: fixture.transcript,
            systemAudioURL: fixture.audioURL,
            systemTimelineOffsetSeconds: 0,
            modelBundleURL: root.appendingPathComponent("speaker-diarization")
        )
        XCTAssertEqual(failed.metadata.status, .failed)
        XCTAssertNil(failed.artifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.session.mergedTranscriptURL.path))
    }

    func testCancellationPropagatesAndReleasesDiarizerResources() async throws {
        let fixture = try makeFixture()
        let diarizer = CancellingFixtureDiarizer()
        let pipeline = SpeakerPipeline(diarizer: diarizer)

        do {
            _ = try await pipeline.process(
                session: fixture.session,
                transcript: fixture.transcript,
                systemAudioURL: fixture.audioURL,
                systemTimelineOffsetSeconds: 0,
                modelBundleURL: root.appendingPathComponent("speaker-diarization")
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must not be converted into a fallback failure.
        }

        let releaseCount = await diarizer.releaseCount
        XCTAssertEqual(releaseCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.session.speakerDiarizationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.session.resolvedTranscriptURL.path))
    }

    func testSpeakerEditsRenameMergeRegenerateMarkdownAndPreserveRawTranscript() async throws {
        let fixture = try makeFixture(includeMarkdown: true)
        let pipelineResult = try await SpeakerPipeline(diarizer: FixtureDiarizer(
            result: diarizationResult()
        )).process(
            session: fixture.session,
            transcript: fixture.transcript,
            systemAudioURL: fixture.audioURL,
            systemTimelineOffsetSeconds: 0,
            modelBundleURL: root.appendingPathComponent("speaker-diarization")
        )
        XCTAssertNotNil(pipelineResult.artifact)
        let rawBefore = try Data(contentsOf: fixture.session.mergedTranscriptURL)

        let service = SpeakerEditingService()
        let snapshot = try await service.load(session: fixture.session)
        var speakers = snapshot.speakers
        speakers[0].displayName = "Alice"
        speakers[0].state = .named
        speakers[1].mergedIntoSpeakerID = speakers[0].id
        let localIndex = try XCTUnwrap(speakers.firstIndex { $0.id == SpeakerProfile.localID })
        speakers[localIndex].displayName = "Martin"
        speakers[localIndex].state = .named

        let edited = try await service.save(session: fixture.session, speakers: speakers)

        XCTAssertEqual(
            Set(edited.resolvedTranscript.segments.filter { $0.source == .system }.map(\.speaker)),
            ["Alice"]
        )
        XCTAssertEqual(
            edited.resolvedTranscript.segments.first { $0.source == .microphone }?.speaker,
            "Martin"
        )
        XCTAssertEqual(try Data(contentsOf: fixture.session.mergedTranscriptURL), rawBefore)
        let markdown = try String(contentsOf: try XCTUnwrap(fixture.markdownURL), encoding: .utf8)
        XCTAssertFalse(markdown.contains("— Alice"))
        XCTAssertFalse(markdown.contains("— Martin"))
        XCTAssertTrue(markdown.contains("— Vzdialení účastníci"))
        XCTAssertTrue(markdown.contains("— Účastníci na mieste"))
    }

    func testArtifactFingerprintRejectsChangedTranscriptAndMergeCycles() throws {
        let fixture = try makeFixture()
        let store = SpeakerArtifactStore()
        let artifact = try store.makeArtifact(
            sessionID: fixture.session.metadata.id,
            result: diarizationResult(),
            sourceAudioURL: fixture.audioURL,
            transcript: fixture.transcript,
            sourceTimelineOffsetSeconds: 0,
            configurationRevision: "test"
        )
        try store.persist(artifact, to: fixture.session.speakerDiarizationURL)

        var changedSegments = fixture.transcript.segments
        changedSegments[0] = TranscriptSegment(
            id: changedSegments[0].id,
            source: changedSegments[0].source,
            speaker: changedSegments[0].speaker,
            start: changedSegments[0].start,
            end: changedSegments[0].end,
            language: changedSegments[0].language,
            text: "Changed",
            confidence: changedSegments[0].confidence,
            words: changedSegments[0].words
        )
        let changed = MergedTranscript(
            sessionID: fixture.transcript.sessionID,
            title: fixture.transcript.title,
            completedAt: fixture.transcript.completedAt,
            tracks: fixture.transcript.tracks,
            segments: changedSegments
        )
        XCTAssertThrowsError(try store.loadValid(
            from: fixture.session.speakerDiarizationURL,
            sessionID: fixture.session.metadata.id,
            sourceAudioURL: fixture.audioURL,
            transcript: changed
        )) { error in
            XCTAssertEqual(error as? SpeakerArtifactError, .staleTranscript)
        }

        var cyclic = artifact.speakers
        cyclic[0].mergedIntoSpeakerID = cyclic[1].id
        cyclic[1].mergedIntoSpeakerID = cyclic[0].id
        XCTAssertThrowsError(try store.validateProfiles(cyclic))
    }

    private func makeFixture(
        includeMarkdown: Bool = false,
        systemTimelineOffsetSeconds: Double = 0
    ) throws -> (session: RecordingSession, transcript: MergedTranscript, audioURL: URL, markdownURL: URL?) {
        let audioURL = root.appendingPathComponent("system-16k.wav")
        try Data("audio-fixture".utf8).write(to: audioURL)
        let markdownURL = includeMarkdown ? root.appendingPathComponent("meeting.md") : nil
        if let markdownURL { try Data("old markdown".utf8).write(to: markdownURL) }
        let finalization = AudioFinalizationMetadata(
            completedAt: Date(),
            timelineOrigin: 0,
            system: FinalizedAudioTrackMetadata(
                fileName: audioURL.lastPathComponent,
                sampleRate: 16_000,
                channelCount: 1,
                totalFrames: 32_000,
                durationSeconds: 2,
                timelineOffsetSeconds: systemTimelineOffsetSeconds
            ),
            microphone: nil,
            warnings: []
        )
        let metadata = SessionMetadata(
            id: "speaker-fixture",
            title: "Speaker fixture",
            status: .recorded,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_002),
            audioFinalization: finalization,
            output: markdownURL.map {
                SessionOutputMetadata(
                    status: .completed,
                    markdownFileName: $0.lastPathComponent,
                    markdownPath: $0.path,
                    exportedAt: Date(),
                    failureReason: nil
                )
            }
        )
        let session = RecordingSession(metadata: metadata, directoryURL: root)
        let transcript = MergedTranscript(
            sessionID: metadata.id,
            title: metadata.title,
            completedAt: Date(),
            tracks: [],
            segments: [
                TranscriptSegment(
                    id: "system-1",
                    source: .system,
                    speaker: "Other",
                    start: systemTimelineOffsetSeconds,
                    end: systemTimelineOffsetSeconds + 2,
                    language: "en",
                    text: "Hello world.",
                    confidence: 0.9,
                    words: [
                        TranscriptWord(
                            start: systemTimelineOffsetSeconds,
                            end: systemTimelineOffsetSeconds + 0.8,
                            text: "Hello",
                            confidence: 0.9
                        ),
                        TranscriptWord(
                            start: systemTimelineOffsetSeconds + 1.2,
                            end: systemTimelineOffsetSeconds + 2,
                            text: "world.",
                            confidence: 0.8
                        ),
                    ]
                ),
                TranscriptSegment(
                    id: "microphone-1",
                    source: .microphone,
                    speaker: "Me",
                    start: 0.9,
                    end: 1.1,
                    language: "en",
                    text: "Local reply",
                    confidence: 0.95
                ),
            ]
        )
        try TranscriptJSONCoder.makeEncoder().encode(transcript)
            .write(to: session.mergedTranscriptURL, options: .atomic)
        return (session, transcript, audioURL, markdownURL)
    }

    private func diarizationResult() -> SpeakerDiarizationResult {
        SpeakerDiarizationResult(
            engine: "FluidAudio",
            engineVersion: "0.15.5",
            model: "community-1",
            audioDurationSeconds: 2,
            segments: [
                SpeakerDiarizationSegment(
                    id: "turn-1",
                    speakerID: "S9",
                    start: 0,
                    end: 1,
                    confidence: 0.9
                ),
                SpeakerDiarizationSegment(
                    id: "turn-2",
                    speakerID: "S3",
                    start: 1,
                    end: 2,
                    confidence: 0.8
                ),
            ]
        )
    }
}

private enum FixtureError: Error {
    case failed
}

private actor FixtureDiarizer: SpeakerDiarizing {
    private let result: SpeakerDiarizationResult?
    private let error: Error?

    init(result: SpeakerDiarizationResult) {
        self.result = result
        self.error = nil
    }

    init(error: Error) {
        self.result = nil
        self.error = error
    }

    func diarize(_ request: SpeakerDiarizationRequest) async throws -> SpeakerDiarizationResult {
        if let error { throw error }
        return result!
    }
}

private actor CancellingFixtureDiarizer: SpeakerDiarizing {
    private(set) var releaseCount = 0

    func diarize(_ request: SpeakerDiarizationRequest) async throws -> SpeakerDiarizationResult {
        throw CancellationError()
    }

    func releaseResources() async {
        releaseCount += 1
    }
}
