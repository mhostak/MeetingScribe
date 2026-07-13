import Foundation
import whisper

enum WhisperTranscriptSanitizer {
    private static let nonSpeechMarkers: Set<String> = [
        "[blank_audio]",
        "[silence]",
        "(silence)",
    ]

    static func meaningfulText(from rawText: String) -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard !nonSpeechMarkers.contains(text.lowercased()) else { return nil }
        return text
    }
}

private final class WhisperContextHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        whisper_free(pointer)
    }
}

final class WhisperCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

func whisperCancellationCallback(_ userData: UnsafeMutableRawPointer?) -> Bool {
    guard let userData else { return false }
    return Unmanaged<WhisperCancellationToken>
        .fromOpaque(userData)
        .takeUnretainedValue()
        .isCancelled
}

final class WhisperCppService: TranscriptionService, @unchecked Sendable {
    private let audioReader: WhisperAudioReader
    private let activityDetector: WhisperAudioActivityDetector
    private let batchPlanner: WhisperInferenceBatchPlanner
    private let now: @Sendable () -> Date
    private let inferenceQueue = DispatchQueue(
        label: "com.martinhostak.MeetingScribe.whisper-inference",
        qos: .userInitiated
    )
    private var context: WhisperContextHandle?
    private var loadedModelURL: URL?

    init(
        audioReader: WhisperAudioReader = WhisperAudioReader(),
        activityDetector: WhisperAudioActivityDetector = WhisperAudioActivityDetector(),
        batchPlanner: WhisperInferenceBatchPlanner = WhisperInferenceBatchPlanner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.audioReader = audioReader
        self.activityDetector = activityDetector
        self.batchPlanner = batchPlanner
        self.now = now
    }

    func transcribe(
        audioURL: URL,
        modelURL: URL,
        options: TranscriptionOptions
    ) async throws -> TrackTranscript {
        try Task.checkCancellation()
        let cancellationToken = WhisperCancellationToken()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                inferenceQueue.async { [self] in
                    guard !cancellationToken.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        continuation.resume(returning: try transcribeSynchronously(
                            audioURL: audioURL,
                            modelURL: modelURL,
                            options: options,
                            cancellationToken: cancellationToken
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellationToken.cancel()
        }
    }

    func releaseResources() async {
        await withCheckedContinuation { continuation in
            inferenceQueue.async { [self] in
                context = nil
                loadedModelURL = nil
                continuation.resume()
            }
        }
    }

    func hasLoadedContext() async -> Bool {
        await withCheckedContinuation { continuation in
            inferenceQueue.async { [self] in
                continuation.resume(returning: context != nil)
            }
        }
    }

    private func transcribeSynchronously(
        audioURL: URL,
        modelURL: URL,
        options: TranscriptionOptions,
        cancellationToken: WhisperCancellationToken
    ) throws -> TrackTranscript {
        let wallTimeStartedAt = ProcessInfo.processInfo.systemUptime
        guard !cancellationToken.isCancelled else { throw CancellationError() }
        let samples = try audioReader.readSamples(from: audioURL)
        guard !cancellationToken.isCancelled else { throw CancellationError() }
        let activityPlan = activityDetector.activityPlan(for: samples)
        let inferenceBatches = batchPlanner.batches(for: activityPlan.chunks)
        guard !cancellationToken.isCancelled else { throw CancellationError() }

        guard !activityPlan.chunks.isEmpty else {
            return TrackTranscript(
                source: options.source,
                model: modelURL.lastPathComponent,
                requestedLanguage: options.language,
                detectedLanguage: options.language.rawValue,
                completedAt: now(),
                segments: [],
                performance: makePerformance(
                    plan: activityPlan,
                    inferenceBatchCount: 0,
                    inferenceInputSampleCount: 0,
                    wallTimeStartedAt: wallTimeStartedAt
                )
            )
        }

        let context = try loadContext(modelURL: modelURL)
        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        parameters.translate = false
        parameters.no_context = true
        parameters.no_timestamps = false
        parameters.single_segment = false
        parameters.print_special = false
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false
        parameters.detect_language = false
        parameters.abort_callback = whisperCancellationCallback
        parameters.abort_callback_user_data = Unmanaged
            .passUnretained(cancellationToken)
            .toOpaque()

        let result: TrackTranscript
        if let initialPrompt = options.initialPrompt, !initialPrompt.isEmpty {
            result = try initialPrompt.withCString { promptPointer in
                parameters.initial_prompt = promptPointer
                return try runInference(
                    context: context.pointer,
                    parameters: parameters,
                    samples: samples,
                    options: options,
                    modelURL: modelURL,
                    activityPlan: activityPlan,
                    inferenceBatches: inferenceBatches,
                    wallTimeStartedAt: wallTimeStartedAt,
                    cancellationToken: cancellationToken
                )
            }
        } else {
            parameters.initial_prompt = nil
            result = try runInference(
                context: context.pointer,
                parameters: parameters,
                samples: samples,
                options: options,
                modelURL: modelURL,
                activityPlan: activityPlan,
                inferenceBatches: inferenceBatches,
                wallTimeStartedAt: wallTimeStartedAt,
                cancellationToken: cancellationToken
            )
        }
        return result
    }

    private func loadContext(modelURL: URL) throws -> WhisperContextHandle {
        if loadedModelURL == modelURL, let context {
            return context
        }

        context = nil

        var parameters = whisper_context_default_params()
        parameters.use_gpu = true
        parameters.flash_attn = true
        guard let newContext = whisper_init_from_file_with_params(modelURL.path, parameters) else {
            throw TranscriptionError.modelCouldNotBeLoaded(
                fileName: modelURL.lastPathComponent
            )
        }
        let handle = WhisperContextHandle(pointer: newContext)
        context = handle
        loadedModelURL = modelURL
        return handle
    }

    private func runInference(
        context: OpaquePointer,
        parameters: whisper_full_params,
        samples: [Float],
        options: TranscriptionOptions,
        modelURL: URL,
        activityPlan: WhisperAudioActivityPlan,
        inferenceBatches: [WhisperInferenceBatch],
        wallTimeStartedAt: TimeInterval,
        cancellationToken: WhisperCancellationToken
    ) throws -> TrackTranscript {
        whisper_reset_timings(context)
        var pendingSegments: [(start: Double, end: Double, language: String, text: String)] = []
        var trackLanguage = options.language == .automatic
            ? nil
            : options.language.rawValue
        let batches: [WhisperInferenceBatch]
        if options.language == .automatic,
           let languageProbe = inferenceBatches.max(by: {
               $0.inferenceSampleCount < $1.inferenceSampleCount
           }) {
            batches = [languageProbe]
                + inferenceBatches.filter { $0 != languageProbe }
        } else {
            batches = inferenceBatches
        }

        for batch in batches {
            guard !cancellationToken.isCancelled else { throw CancellationError() }
            let (batchSamples, mappings) = makeBatchInput(
                batch: batch,
                samples: samples
            )
            let inferenceLanguage = trackLanguage ?? TranscriptionLanguage.automatic.rawValue
            let code = inferenceLanguage.withCString { languagePointer in
                var chunkParameters = parameters
                chunkParameters.language = languagePointer
                return batchSamples.withUnsafeBufferPointer { pointer in
                    whisper_full(
                        context,
                        chunkParameters,
                        pointer.baseAddress,
                        Int32(pointer.count)
                    )
                }
            }
            guard !cancellationToken.isCancelled else { throw CancellationError() }
            guard code == 0 else {
                throw TranscriptionError.inferenceFailed(code: code)
            }

            let detectedLanguage = detectedLanguage(
                context: context,
                fallback: inferenceLanguage
            )
            if trackLanguage == nil {
                trackLanguage = detectedLanguage
            }

            let count = Int(whisper_full_n_segments(context))
            for index in 0..<count {
                let rawText = String(cString: whisper_full_get_segment_text(context, Int32(index)))
                guard let text = WhisperTranscriptSanitizer.meaningfulText(from: rawText) else {
                    continue
                }

                let batchStart = Double(whisper_full_get_segment_t0(context, Int32(index))) * 0.01
                let batchEnd = Double(whisper_full_get_segment_t1(context, Int32(index))) * 0.01
                let midpointSample = (batchStart + batchEnd) / 2
                    * WhisperAudioActivityDetector.sampleRate
                guard let mapping = mappings.first(where: {
                    midpointSample >= Double($0.batchRange.lowerBound)
                        && midpointSample < Double($0.batchRange.upperBound)
                }) else {
                    continue
                }
                let segmentStart = mapBatchTimeToTrack(
                    batchStart,
                    mapping: mapping
                )
                let segmentEnd = mapBatchTimeToTrack(
                    batchEnd,
                    mapping: mapping
                )
                let midpoint = (segmentStart + segmentEnd) / 2
                let ownershipStart = Double(mapping.chunk.ownershipRange.lowerBound)
                    / WhisperAudioActivityDetector.sampleRate
                let ownershipEnd = Double(mapping.chunk.ownershipRange.upperBound)
                    / WhisperAudioActivityDetector.sampleRate
                guard midpoint >= ownershipStart, midpoint < ownershipEnd else {
                    continue
                }
                guard activityDetector.hasMeaningfulActivity(
                    in: samples,
                    startTime: segmentStart,
                    endTime: segmentEnd
                ) else {
                    continue
                }
                pendingSegments.append((
                    start: segmentStart,
                    end: segmentEnd,
                    language: detectedLanguage,
                    text: text
                ))
            }
        }

        pendingSegments.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.text < $1.text
        }
        let segments = pendingSegments.enumerated().map { index, segment in
            let start = segment.start + options.timelineOffsetSeconds
            let end = segment.end + options.timelineOffsetSeconds
            return TranscriptSegment(
                id: String(format: "%@-%06d", options.source.rawValue, index),
                source: options.source,
                speaker: options.speaker,
                start: start,
                end: max(start, end),
                language: segment.language,
                text: segment.text,
                confidence: nil
            )
        }
        let detectedLanguage = trackLanguage ?? options.language.rawValue

        return TrackTranscript(
            source: options.source,
            model: modelURL.lastPathComponent,
            requestedLanguage: options.language,
            detectedLanguage: detectedLanguage,
            completedAt: now(),
            segments: segments,
            performance: makePerformance(
                plan: activityPlan,
                inferenceBatchCount: inferenceBatches.count,
                inferenceInputSampleCount: inferenceBatches.reduce(0) {
                    $0 + $1.inferenceSampleCount
                },
                wallTimeStartedAt: wallTimeStartedAt
            )
        )
    }

    private func detectedLanguage(context: OpaquePointer, fallback: String) -> String {
        let languageID = whisper_full_lang_id(context)
        if languageID >= 0, let language = whisper_lang_str(languageID) {
            return String(cString: language)
        }
        return fallback
    }

    private func makePerformance(
        plan: WhisperAudioActivityPlan,
        inferenceBatchCount: Int,
        inferenceInputSampleCount: Int,
        wallTimeStartedAt: TimeInterval
    ) -> TrackTranscriptionPerformance {
        TrackTranscriptionPerformance(
            audioDurationSeconds: plan.totalDurationSeconds,
            activeDurationSeconds: plan.activeDurationSeconds,
            skippedDurationSeconds: plan.skippedDurationSeconds,
            inferenceInputDurationSeconds: Double(inferenceInputSampleCount)
                / WhisperAudioActivityDetector.sampleRate,
            chunkCount: inferenceBatchCount,
            wallTimeSeconds: max(0, ProcessInfo.processInfo.systemUptime - wallTimeStartedAt)
        )
    }

    private struct BatchMapping {
        let chunk: WhisperAudioChunk
        let batchRange: Range<Int>
    }

    private func makeBatchInput(
        batch: WhisperInferenceBatch,
        samples: [Float]
    ) -> ([Float], [BatchMapping]) {
        if batch.chunks.count == 1,
           batch.chunks[0].sampleRange == samples.indices {
            return (samples, [BatchMapping(
                chunk: batch.chunks[0],
                batchRange: samples.indices
            )])
        }

        var batchSamples: [Float] = []
        batchSamples.reserveCapacity(batch.inferenceSampleCount)
        var mappings: [BatchMapping] = []
        for (index, chunk) in batch.chunks.enumerated() {
            if index > 0 {
                batchSamples.append(contentsOf: repeatElement(
                    0,
                    count: batch.separatorSampleCount
                ))
            }
            let batchStart = batchSamples.count
            batchSamples.append(contentsOf: samples[chunk.sampleRange])
            mappings.append(BatchMapping(
                chunk: chunk,
                batchRange: batchStart..<batchSamples.count
            ))
        }
        return (batchSamples, mappings)
    }

    private func mapBatchTimeToTrack(
        _ batchTime: Double,
        mapping: BatchMapping
    ) -> Double {
        let batchSample = batchTime * WhisperAudioActivityDetector.sampleRate
        let offset = batchSample - Double(mapping.batchRange.lowerBound)
        let sourceSample = min(
            Double(mapping.chunk.sampleRange.upperBound),
            max(
                Double(mapping.chunk.sampleRange.lowerBound),
                Double(mapping.chunk.sampleRange.lowerBound) + offset
            )
        )
        return sourceSample / WhisperAudioActivityDetector.sampleRate
    }
}
