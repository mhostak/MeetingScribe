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

actor WhisperCppService: TranscriptionService {
    private let audioReader: WhisperAudioReader
    private let now: @Sendable () -> Date
    private var context: WhisperContextHandle?
    private var loadedModelURL: URL?

    init(
        audioReader: WhisperAudioReader = WhisperAudioReader(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.audioReader = audioReader
        self.now = now
    }

    func transcribe(
        audioURL: URL,
        modelURL: URL,
        options: TranscriptionOptions
    ) async throws -> TrackTranscript {
        let samples = try audioReader.readSamples(from: audioURL)
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

        let result = try options.language.rawValue.withCString { languagePointer in
            parameters.language = languagePointer
            if let initialPrompt = options.initialPrompt, !initialPrompt.isEmpty {
                return try initialPrompt.withCString { promptPointer in
                    parameters.initial_prompt = promptPointer
                    return try runInference(
                        context: context.pointer,
                        parameters: parameters,
                        samples: samples,
                        options: options,
                        modelURL: modelURL
                    )
                }
            }
            parameters.initial_prompt = nil
            return try runInference(
                context: context.pointer,
                parameters: parameters,
                samples: samples,
                options: options,
                modelURL: modelURL
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
        modelURL: URL
    ) throws -> TrackTranscript {
        whisper_reset_timings(context)
        let code = samples.withUnsafeBufferPointer { pointer in
            whisper_full(context, parameters, pointer.baseAddress, Int32(pointer.count))
        }
        guard code == 0 else {
            throw TranscriptionError.inferenceFailed(code: code)
        }

        let detectedLanguage: String
        let languageID = whisper_full_lang_id(context)
        if languageID >= 0, let language = whisper_lang_str(languageID) {
            detectedLanguage = String(cString: language)
        } else {
            detectedLanguage = options.language.rawValue
        }

        let count = Int(whisper_full_n_segments(context))
        let segments = (0..<count).compactMap { index -> TranscriptSegment? in
            let rawText = String(cString: whisper_full_get_segment_text(context, Int32(index)))
            guard let text = WhisperTranscriptSanitizer.meaningfulText(from: rawText) else {
                return nil
            }

            let start = Double(whisper_full_get_segment_t0(context, Int32(index))) * 0.01
                + options.timelineOffsetSeconds
            let end = Double(whisper_full_get_segment_t1(context, Int32(index))) * 0.01
                + options.timelineOffsetSeconds
            return TranscriptSegment(
                id: String(format: "%@-%06d", options.source.rawValue, index),
                source: options.source,
                speaker: options.speaker,
                start: start,
                end: max(start, end),
                language: detectedLanguage,
                text: text,
                confidence: nil
            )
        }

        return TrackTranscript(
            source: options.source,
            model: modelURL.lastPathComponent,
            requestedLanguage: options.language,
            detectedLanguage: detectedLanguage,
            completedAt: now(),
            segments: segments
        )
    }
}
