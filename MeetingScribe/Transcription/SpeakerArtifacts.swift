import CryptoKit
import Foundation

enum SpeakerProfileSource: String, Codable, Sendable {
    case system
    case microphone
}

enum SpeakerProfileState: String, Codable, CaseIterable, Sendable {
    case anonymous
    case named
    case unknown
}

struct SpeakerProfile: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let source: SpeakerProfileSource
    let sourceClusterID: String?
    var displayName: String
    var state: SpeakerProfileState
    var mergedIntoSpeakerID: String?

    static let localID = "local-user"
}

struct SpeakerDiarizationArtifact: Codable, Equatable, Sendable {
    var schemaVersion: Int
    let sessionID: String
    let createdAt: Date
    var modifiedAt: Date
    let sourceAudioFingerprint: String
    let sourceTranscriptFingerprint: String
    var sourceTimelineOffsetSeconds: Double?
    let configurationRevision: String
    let result: SpeakerDiarizationResult
    var speakers: [SpeakerProfile]

    var effectiveTimelineOffsetSeconds: Double {
        sourceTimelineOffsetSeconds ?? 0
    }
}

enum ResolvedSpeakerAmbiguity: String, Codable, Sendable {
    case none
    case overlappingSpeakers
    case unmatchedSpeech
}

struct ResolvedTranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let source: TranscriptSource
    let speakerID: String
    let speaker: String
    let start: Double
    let end: Double
    let language: String
    let text: String
    let confidence: Double?
    let sourceSegmentIDs: [String]
    let ambiguity: ResolvedSpeakerAmbiguity
}

struct ResolvedTranscript: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: String
    let createdAt: Date
    let sourceTranscriptFingerprint: String
    let diarizationFingerprint: String
    let segments: [ResolvedTranscriptSegment]

    func asMergedTranscript(basedOn transcript: MergedTranscript) -> MergedTranscript {
        MergedTranscript(
            schemaVersion: transcript.schemaVersion,
            sessionID: transcript.sessionID,
            title: transcript.title,
            completedAt: transcript.completedAt,
            tracks: transcript.tracks,
            segments: segments.map { segment in
                TranscriptSegment(
                    id: segment.id,
                    source: segment.source,
                    speaker: segment.speaker,
                    start: segment.start,
                    end: segment.end,
                    language: segment.language,
                    text: segment.text,
                    confidence: segment.confidence
                )
            }
        )
    }
}

enum SpeakerArtifactError: Error, Equatable, LocalizedError {
    case wrongSession
    case staleAudio
    case staleTranscript
    case invalidTimelineOffset
    case invalidSpeaker(String)
    case invalidMerge(String)

    var errorDescription: String? {
        switch self {
        case .wrongSession:
            return "The speaker artifact belongs to another recording."
        case .staleAudio:
            return "The speaker artifact no longer matches the source audio."
        case .staleTranscript:
            return "The speaker artifact no longer matches the source transcript."
        case .invalidTimelineOffset:
            return "The speaker artifact contains an invalid source timeline offset."
        case let .invalidSpeaker(id):
            return "The speaker profile \(id) is invalid."
        case let .invalidMerge(id):
            return "The merge target for speaker \(id) is invalid."
        }
    }
}

struct SpeakerArtifactStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let atomicWriter: @Sendable (Data, URL) throws -> Void

    init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        atomicWriter: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.fileManager = fileManager
        self.now = now
        self.atomicWriter = atomicWriter
    }

    func makeArtifact(
        sessionID: String,
        result: SpeakerDiarizationResult,
        sourceAudioURL: URL,
        transcript: MergedTranscript,
        sourceTimelineOffsetSeconds: Double,
        configurationRevision: String,
        sourceAudioFingerprint: String? = nil,
        sourceTranscriptFingerprint: String? = nil
    ) throws -> SpeakerDiarizationArtifact {
        try validateTimelineOffset(sourceTimelineOffsetSeconds)
        let orderedClusterIDs = result.segments.reduce(into: [String]()) { ids, segment in
            if !ids.contains(segment.speakerID) { ids.append(segment.speakerID) }
        }
        let stableIDs = Dictionary(uniqueKeysWithValues: orderedClusterIDs.enumerated().map {
            ($0.element, String(format: "speaker-%03d", $0.offset + 1))
        })
        let stableSegments = result.segments.map { segment in
            SpeakerDiarizationSegment(
                id: segment.id,
                speakerID: stableIDs[segment.speakerID] ?? segment.speakerID,
                start: segment.start,
                end: segment.end,
                confidence: segment.confidence
            )
        }
        let stableResult = SpeakerDiarizationResult(
            engine: result.engine,
            engineVersion: result.engineVersion,
            model: result.model,
            audioDurationSeconds: result.audioDurationSeconds,
            segments: stableSegments
        )
        var profiles = orderedClusterIDs.enumerated().map { index, clusterID in
            SpeakerProfile(
                id: stableIDs[clusterID] ?? clusterID,
                source: .system,
                sourceClusterID: clusterID,
                displayName: "Speaker \(index + 1)",
                state: .anonymous,
                mergedIntoSpeakerID: nil
            )
        }
        profiles.append(SpeakerProfile(
            id: SpeakerProfile.localID,
            source: .microphone,
            sourceClusterID: nil,
            displayName: "Me",
            state: .anonymous,
            mergedIntoSpeakerID: nil
        ))
        let timestamp = now()
        return SpeakerDiarizationArtifact(
            schemaVersion: 2,
            sessionID: sessionID,
            createdAt: timestamp,
            modifiedAt: timestamp,
            sourceAudioFingerprint: try sourceAudioFingerprint ?? fingerprint(fileAt: sourceAudioURL),
            sourceTranscriptFingerprint: try sourceTranscriptFingerprint ?? fingerprint(transcript: transcript),
            sourceTimelineOffsetSeconds: sourceTimelineOffsetSeconds,
            configurationRevision: configurationRevision,
            result: stableResult,
            speakers: profiles
        )
    }

    func persist(_ artifact: SpeakerDiarizationArtifact, to url: URL) throws {
        try validateTimelineOffset(artifact.effectiveTimelineOffsetSeconds)
        try validateProfiles(artifact.speakers)
        let data = try TranscriptJSONCoder.makeEncoder().encode(artifact)
        try atomicWriter(data, url)
    }

    func load(from url: URL) throws -> SpeakerDiarizationArtifact {
        let data = try Data(contentsOf: url)
        let artifact = try TranscriptJSONCoder.makeDecoder().decode(
            SpeakerDiarizationArtifact.self,
            from: data
        )
        try validateTimelineOffset(artifact.effectiveTimelineOffsetSeconds)
        try validateProfiles(artifact.speakers)
        return artifact
    }

    func loadValid(
        from url: URL,
        sessionID: String,
        sourceAudioURL: URL,
        transcript: MergedTranscript,
        expectedTimelineOffsetSeconds: Double? = nil,
        sourceAudioFingerprint: String? = nil,
        sourceTranscriptFingerprint: String? = nil
    ) throws -> SpeakerDiarizationArtifact? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        var artifact = try load(from: url)
        guard artifact.sessionID == sessionID else { throw SpeakerArtifactError.wrongSession }
        let audioFingerprint = try sourceAudioFingerprint ?? fingerprint(fileAt: sourceAudioURL)
        guard artifact.sourceAudioFingerprint == audioFingerprint else {
            throw SpeakerArtifactError.staleAudio
        }
        let transcriptFingerprint = try sourceTranscriptFingerprint ?? fingerprint(transcript: transcript)
        guard artifact.sourceTranscriptFingerprint == transcriptFingerprint else {
            throw SpeakerArtifactError.staleTranscript
        }
        if let expectedTimelineOffsetSeconds {
            try validateTimelineOffset(expectedTimelineOffsetSeconds)
            if artifact.schemaVersion < 2
                || artifact.sourceTimelineOffsetSeconds != expectedTimelineOffsetSeconds {
                artifact.schemaVersion = 2
                artifact.sourceTimelineOffsetSeconds = expectedTimelineOffsetSeconds
                let originalModifiedAt = artifact.modifiedAt
                artifact.modifiedAt = now()
                do {
                    try persist(artifact, to: url)
                } catch {
                    // Validation should not make a readable legacy artifact unusable
                    // only because its opportunistic schema upgrade cannot be saved.
                    artifact.modifiedAt = originalModifiedAt
                }
            }
        }
        return artifact
    }

    func fingerprint(transcript: MergedTranscript) throws -> String {
        digest(try TranscriptJSONCoder.makeEncoder().encode(transcript))
    }

    func fingerprint(artifact: SpeakerDiarizationArtifact) throws -> String {
        digest(try TranscriptJSONCoder.makeEncoder().encode(artifact))
    }

    func fingerprint(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func effectiveProfile(
        for id: String,
        in artifact: SpeakerDiarizationArtifact
    ) -> SpeakerProfile? {
        let profiles = Dictionary(uniqueKeysWithValues: artifact.speakers.map { ($0.id, $0) })
        var currentID = id
        var visited = Set<String>()
        while visited.insert(currentID).inserted,
              let profile = profiles[currentID] {
            guard let target = profile.mergedIntoSpeakerID else { return profile }
            currentID = target
        }
        return nil
    }

    func effectiveProfiles(in artifact: SpeakerDiarizationArtifact) -> [String: SpeakerProfile] {
        Dictionary(uniqueKeysWithValues: artifact.speakers.compactMap { profile in
            effectiveProfile(for: profile.id, in: artifact).map { (profile.id, $0) }
        })
    }

    func validateProfiles(_ profiles: [SpeakerProfile]) throws {
        let ids = Set(profiles.map(\.id))
        guard ids.count == profiles.count else {
            throw SpeakerArtifactError.invalidSpeaker("duplicate")
        }
        for profile in profiles {
            let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !profile.id.isEmpty, !name.isEmpty else {
                throw SpeakerArtifactError.invalidSpeaker(profile.id)
            }
            guard let target = profile.mergedIntoSpeakerID else { continue }
            guard target != profile.id, ids.contains(target) else {
                throw SpeakerArtifactError.invalidMerge(profile.id)
            }
            var visited: Set<String> = [profile.id]
            var next: String? = target
            while let current = next {
                guard visited.insert(current).inserted else {
                    throw SpeakerArtifactError.invalidMerge(profile.id)
                }
                next = profiles.first(where: { $0.id == current })?.mergedIntoSpeakerID
            }
        }
    }

    private func validateTimelineOffset(_ value: Double) throws {
        guard value.isFinite, value >= 0 else {
            throw SpeakerArtifactError.invalidTimelineOffset
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ResolvedTranscriptStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let artifactStore: SpeakerArtifactStore

    init(
        fileManager: FileManager = .default,
        artifactStore: SpeakerArtifactStore = SpeakerArtifactStore()
    ) {
        self.fileManager = fileManager
        self.artifactStore = artifactStore
    }

    func persist(_ transcript: ResolvedTranscript, to url: URL) throws {
        let data = try TranscriptJSONCoder.makeEncoder().encode(transcript)
        try data.write(to: url, options: .atomic)
    }

    func loadValid(
        from url: URL,
        transcript: MergedTranscript,
        artifact: SpeakerDiarizationArtifact,
        transcriptFingerprint: String? = nil,
        artifactFingerprint: String? = nil
    ) throws -> ResolvedTranscript? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let resolved = try TranscriptJSONCoder.makeDecoder().decode(
            ResolvedTranscript.self,
            from: data
        )
        let resolvedTranscriptFingerprint = try transcriptFingerprint
            ?? artifactStore.fingerprint(transcript: transcript)
        let resolvedArtifactFingerprint = try artifactFingerprint
            ?? artifactStore.fingerprint(artifact: artifact)
        guard resolved.sessionID == transcript.sessionID,
              resolved.sourceTranscriptFingerprint == resolvedTranscriptFingerprint,
              resolved.diarizationFingerprint == resolvedArtifactFingerprint else {
            return nil
        }
        return resolved
    }
}
