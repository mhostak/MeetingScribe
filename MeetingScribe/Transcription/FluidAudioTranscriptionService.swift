import AVFoundation
import FluidAudio
import Foundation

struct FluidAudioTranscriptionConfiguration: Equatable, Sendable {
    static let sdkVersion = "0.15.5"
    static let current = FluidAudioTranscriptionConfiguration(
        revision: "parakeet-v3-int8-longform-v1",
        melChunkContext: false,
        dualDecodeArbitration: true,
        parallelChunkConcurrency: 4,
        streamingThresholdSamples: 480_000,
        maximumSegmentDurationSeconds: 25,
        sentenceGapSeconds: 1.5
    )

    let revision: String
    let melChunkContext: Bool
    let dualDecodeArbitration: Bool
    let parallelChunkConcurrency: Int
    let streamingThresholdSamples: Int
    let maximumSegmentDurationSeconds: Double
    let sentenceGapSeconds: Double
}

struct FluidAudioASRToken: Equatable, Sendable {
    let text: String
    let tokenID: Int
    let startTime: Double
    let endTime: Double
    let confidence: Double
}

struct FluidAudioASROutput: Equatable, Sendable {
    let text: String
    let confidence: Double
    let tokenTimings: [FluidAudioASRToken]
}

protocol FluidAudioASRRunning: Sendable {
    func transcribe(
        audioURL: URL,
        modelBundleURL: URL,
        language: TranscriptionLanguage,
        configuration: FluidAudioTranscriptionConfiguration
    ) async throws -> FluidAudioASROutput

    func releaseResources() async
}

actor ProductionFluidAudioASRRunner: FluidAudioASRRunning {
    private var manager: AsrManager?
    private var loadedModelBundleURL: URL?

    func transcribe(
        audioURL: URL,
        modelBundleURL: URL,
        language: TranscriptionLanguage,
        configuration: FluidAudioTranscriptionConfiguration
    ) async throws -> FluidAudioASROutput {
        try Task.checkCancellation()
        let manager = try await preparedManager(
            modelBundleURL: modelBundleURL,
            configuration: configuration
        )
        var decoderState = TdtDecoderState.make(
            decoderLayers: await manager.decoderLayerCount
        )
        let result: ASRResult
        do {
            result = try await manager.transcribe(
                audioURL,
                decoderState: &decoderState,
                language: fluidAudioLanguage(for: language)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.engineInferenceFailed(
                engine: "FluidAudio",
                detail: error.localizedDescription
            )
        }
        try Task.checkCancellation()
        return FluidAudioASROutput(
            text: result.text,
            confidence: Double(result.confidence),
            tokenTimings: (result.tokenTimings ?? []).map {
                FluidAudioASRToken(
                    text: $0.token,
                    tokenID: $0.tokenId,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    confidence: Double($0.confidence)
                )
            }
        )
    }

    func releaseResources() async {
        if let manager {
            await manager.cleanup()
        }
        manager = nil
        loadedModelBundleURL = nil
    }

    private func preparedManager(
        modelBundleURL: URL,
        configuration: FluidAudioTranscriptionConfiguration
    ) async throws -> AsrManager {
        let standardizedURL = modelBundleURL.standardizedFileURL
        if let manager, loadedModelBundleURL == standardizedURL {
            return manager
        }

        await releaseResources()
        ModelHub.offlineMode = true
        let models: AsrModels
        do {
            models = try await AsrModels.load(
                from: standardizedURL,
                version: .v3,
                encoderPrecision: .int8
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.modelBundleCouldNotBeLoaded(
                name: standardizedURL.lastPathComponent
            )
        }
        try Task.checkCancellation()
        let tdtConfig = TdtConfig(blankId: AsrModelVersion.v3.blankId)
        let asrConfiguration = ASRConfig(
            tdtConfig: tdtConfig,
            encoderHiddenSize: AsrModelVersion.v3.encoderHiddenSize,
            parallelChunkConcurrency: configuration.parallelChunkConcurrency,
            streamingEnabled: true,
            streamingThreshold: configuration.streamingThresholdSamples,
            melChunkContext: configuration.melChunkContext,
            dualDecodeArbitration: configuration.dualDecodeArbitration
        )
        let manager = AsrManager(config: asrConfiguration, models: models)
        self.manager = manager
        loadedModelBundleURL = standardizedURL
        return manager
    }

    private func fluidAudioLanguage(
        for language: TranscriptionLanguage
    ) -> Language? {
        switch language {
        case .automatic: return nil
        case .czech: return .czech
        case .slovak: return .slovak
        case .english: return .english
        }
    }
}

struct FluidAudioAudioFileInfo: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int64

    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }
}

actor FluidAudioTranscriptionService: SpeechTranscribing {
    private let runner: any FluidAudioASRRunning
    private let configuration: FluidAudioTranscriptionConfiguration
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private let audioFileInfo: @Sendable (URL) throws -> FluidAudioAudioFileInfo
    private let hasMeaningfulActivity: @Sendable (URL) throws -> Bool

    init(
        runner: any FluidAudioASRRunning = ProductionFluidAudioASRRunner(),
        configuration: FluidAudioTranscriptionConfiguration = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        audioFileInfo: @escaping @Sendable (URL) throws -> FluidAudioAudioFileInfo = {
            let file = try AVAudioFile(forReading: $0)
            return FluidAudioAudioFileInfo(
                sampleRate: file.processingFormat.sampleRate,
                channelCount: Int(file.processingFormat.channelCount),
                frameCount: file.length
            )
        },
        hasMeaningfulActivity: @escaping @Sendable (URL) throws -> Bool = {
            try AudioActivityDetector().hasMeaningfulActivity(at: $0)
        }
    ) {
        self.runner = runner
        self.configuration = configuration
        self.now = now
        self.uptime = uptime
        self.audioFileInfo = audioFileInfo
        self.hasMeaningfulActivity = hasMeaningfulActivity
    }

    func transcribe(_ request: SpeechTranscriptionRequest) async throws -> TrackTranscript {
        guard request.model.provenance.engine == "FluidAudio" else {
            throw TranscriptionError.unsupportedEngine(request.model.provenance.engine)
        }
        try Task.checkCancellation()
        let info = try audioFileInfo(request.audioURL)
        guard info.frameCount > 0 else { throw TranscriptionError.emptyAudio }
        guard abs(info.sampleRate - 16_000) < 0.5, info.channelCount == 1 else {
            throw TranscriptionError.invalidAudioFormat(
                sampleRate: info.sampleRate,
                channelCount: info.channelCount
            )
        }

        let startedAt = uptime()
        guard try hasMeaningfulActivity(request.audioURL) else {
            let wallTime = max(0, uptime() - startedAt)
            return FluidAudioTranscriptNormalizer(configuration: configuration).normalize(
                output: FluidAudioASROutput(text: "", confidence: 1, tokenTimings: []),
                request: request,
                audioDurationSeconds: info.durationSeconds,
                wallTimeSeconds: wallTime,
                completedAt: now()
            )
        }
        let output = try await runner.transcribe(
            audioURL: request.audioURL,
            modelBundleURL: request.model.location,
            language: request.options.language,
            configuration: configuration
        )
        try Task.checkCancellation()
        let wallTime = max(0, uptime() - startedAt)
        return FluidAudioTranscriptNormalizer(configuration: configuration).normalize(
            output: output,
            request: request,
            audioDurationSeconds: info.durationSeconds,
            wallTimeSeconds: wallTime,
            completedAt: now()
        )
    }

    func releaseResources() async {
        await runner.releaseResources()
    }
}

struct FluidAudioTranscriptNormalizer: Sendable {
    let configuration: FluidAudioTranscriptionConfiguration

    func normalize(
        output: FluidAudioASROutput,
        request: SpeechTranscriptionRequest,
        audioDurationSeconds: Double,
        wallTimeSeconds: Double,
        completedAt: Date
    ) -> TrackTranscript {
        let duration = max(0, audioDurationSeconds.isFinite ? audioDurationSeconds : 0)
        let words = normalizedWords(
            from: output.tokenTimings,
            duration: duration,
            timelineOffset: request.options.timelineOffsetSeconds
        )
        let detectedLanguage = request.options.language == .automatic
            ? "und"
            : request.options.language.rawValue
        let segments = makeSegments(
            words: words,
            fallbackText: output.text,
            fallbackConfidence: normalizedConfidence(output.confidence),
            request: request,
            detectedLanguage: detectedLanguage,
            duration: duration
        )
        let activeDuration = words.isEmpty
            ? (segments.isEmpty ? 0 : duration)
            : activeDurationSeconds(
                words: words,
                timelineOffset: request.options.timelineOffsetSeconds
            )
        let chunkCount = duration > 0
            ? max(1, Int(ceil(duration / 15)))
            : 0
        return TrackTranscript(
            schemaVersion: 4,
            source: request.options.source,
            model: request.model.provenance.model,
            requestedLanguage: request.options.language,
            detectedLanguage: detectedLanguage,
            completedAt: completedAt,
            segments: segments,
            performance: TrackTranscriptionPerformance(
                audioDurationSeconds: duration,
                activeDurationSeconds: activeDuration,
                skippedDurationSeconds: max(0, duration - activeDuration),
                inferenceInputDurationSeconds: duration,
                chunkCount: chunkCount,
                wallTimeSeconds: max(0, wallTimeSeconds)
            ),
            provenance: request.model.provenance
        )
    }

    private func normalizedWords(
        from tokens: [FluidAudioASRToken],
        duration: Double,
        timelineOffset: Double
    ) -> [TranscriptWord] {
        let validTokens = tokens.filter {
            $0.startTime.isFinite && $0.endTime.isFinite
                && !$0.text.isEmpty
                && $0.text != "<blank>"
                && $0.text != "<pad>"
        }.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.endTime != $1.endTime { return $0.endTime < $1.endTime }
            return $0.tokenID < $1.tokenID
        }

        var result: [TranscriptWord] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        var confidences: [Double] = []

        func finishWord() {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let meaningful = TranscriptSanitizer.meaningfulText(from: normalized) else {
                text = ""
                confidences.removeAll(keepingCapacity: true)
                return
            }
            let clampedStart = min(duration, max(0, start)) + timelineOffset
            let clampedEnd = min(duration, max(max(0, start), end)) + timelineOffset
            let confidence = confidences.isEmpty
                ? nil
                : confidences.reduce(0, +) / Double(confidences.count)
            result.append(TranscriptWord(
                start: clampedStart,
                end: max(clampedStart, clampedEnd),
                text: meaningful,
                confidence: confidence
            ))
            text = ""
            confidences.removeAll(keepingCapacity: true)
        }

        for token in validTokens {
            let startsWord = token.text.hasPrefix("▁")
                || token.text.first?.isWhitespace == true
                || text.isEmpty
            let piece = token.text
                .replacingOccurrences(of: "▁", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if startsWord, !text.isEmpty {
                finishWord()
            }
            if text.isEmpty {
                start = token.startTime
            }
            text += piece
            end = token.endTime
            if let confidence = normalizedConfidence(token.confidence) {
                confidences.append(confidence)
            }
        }
        if !text.isEmpty {
            finishWord()
        }
        return result
    }

    private func makeSegments(
        words: [TranscriptWord],
        fallbackText: String,
        fallbackConfidence: Double?,
        request: SpeechTranscriptionRequest,
        detectedLanguage: String,
        duration: Double
    ) -> [TranscriptSegment] {
        guard !words.isEmpty else {
            guard let text = TranscriptSanitizer.meaningfulText(from: fallbackText) else {
                return []
            }
            let start = request.options.timelineOffsetSeconds
            return [TranscriptSegment(
                id: "\(request.options.source.rawValue)-000000",
                source: request.options.source,
                speaker: request.options.speaker,
                start: start,
                end: start + duration,
                language: detectedLanguage,
                text: text,
                confidence: fallbackConfidence
            )]
        }

        var groups: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []
        for word in words {
            if let first = current.first, let previous = current.last,
               word.start - previous.end > configuration.sentenceGapSeconds
                || word.end - first.start > configuration.maximumSegmentDurationSeconds {
                groups.append(current)
                current = []
            }
            current.append(word)
            if word.text.last.map({ ".!?".contains($0) }) == true,
               current.count >= 3 {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }

        return groups.enumerated().compactMap { index, group in
            guard let first = group.first, let last = group.last else { return nil }
            let text = group.map(\.text).joined(separator: " ")
            guard let meaningful = TranscriptSanitizer.meaningfulText(from: text) else {
                return nil
            }
            let confidences = group.compactMap(\.confidence)
            return TranscriptSegment(
                id: String(format: "%@-%06d", request.options.source.rawValue, index),
                source: request.options.source,
                speaker: request.options.speaker,
                start: first.start,
                end: max(first.start, last.end),
                language: detectedLanguage,
                text: meaningful,
                confidence: confidences.isEmpty
                    ? fallbackConfidence
                    : confidences.reduce(0, +) / Double(confidences.count),
                words: group
            )
        }
    }

    private func activeDurationSeconds(
        words: [TranscriptWord],
        timelineOffset: Double
    ) -> Double {
        let intervals = words.map {
            (start: $0.start - timelineOffset, end: $0.end - timelineOffset)
        }.sorted { $0.start < $1.start }
        guard var current = intervals.first else { return 0 }
        var total = 0.0
        for interval in intervals.dropFirst() {
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)
            } else {
                total += max(0, current.end - current.start)
                current = interval
            }
        }
        total += max(0, current.end - current.start)
        return total
    }

    private func normalizedConfidence(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}
