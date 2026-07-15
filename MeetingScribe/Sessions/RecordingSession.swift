import Foundation

struct RecordingSession: Equatable, Sendable {
    var metadata: SessionMetadata
    let directoryURL: URL

    var manifestURL: URL {
        directoryURL.appendingPathComponent("session.json", isDirectory: false)
    }

    var processingLogURL: URL {
        directoryURL.appendingPathComponent("processing.log", isDirectory: false)
    }

    var systemAudioURL: URL {
        directoryURL.appendingPathComponent(metadata.audioFiles.system, isDirectory: false)
    }

    var microphoneAudioURL: URL {
        directoryURL.appendingPathComponent(metadata.audioFiles.microphone, isDirectory: false)
    }

    var systemWorkingAudioURL: URL {
        directoryURL.appendingPathComponent(
            metadata.audioFiles.systemWorking ?? "system-16k.wav",
            isDirectory: false
        )
    }

    var microphoneWorkingAudioURL: URL {
        directoryURL.appendingPathComponent(
            metadata.audioFiles.microphoneWorking ?? "microphone-16k.wav",
            isDirectory: false
        )
    }

    var systemTrackTranscriptURL: URL {
        directoryURL.appendingPathComponent(
            metadata.transcriptFiles?.systemTrack ?? "system-transcript.json",
            isDirectory: false
        )
    }

    var microphoneTrackTranscriptURL: URL {
        directoryURL.appendingPathComponent(
            metadata.transcriptFiles?.microphoneTrack ?? "microphone-transcript.json",
            isDirectory: false
        )
    }

    var mergedTranscriptURL: URL {
        directoryURL.appendingPathComponent(
            metadata.transcriptFiles?.merged ?? "transcript.json",
            isDirectory: false
        )
    }

    var speakerTurnsURL: URL {
        directoryURL.appendingPathComponent(
            metadata.transcriptFiles?.speakerTurns ?? "speaker-turns.json",
            isDirectory: false
        )
    }

    var utteranceTranscriptURL: URL {
        directoryURL.appendingPathComponent(
            metadata.transcriptFiles?.utterances ?? "utterance-transcript.json",
            isDirectory: false
        )
    }

    var speakerDiarizationURL: URL {
        directoryURL.appendingPathComponent(
            metadata.transcriptFiles?.speakerDiarization ?? "speaker-diarization.json",
            isDirectory: false
        )
    }

    var resolvedTranscriptURL: URL {
        directoryURL.appendingPathComponent(
            metadata.transcriptFiles?.resolved ?? "resolved-transcript.json",
            isDirectory: false
        )
    }

    var analysisURL: URL {
        directoryURL.appendingPathComponent(
            metadata.transcriptFiles?.analysis ?? "analysis.json",
            isDirectory: false
        )
    }
}
