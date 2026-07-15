# Speaker recognition and management implementation plan

Status: ready for implementation planning and spike

This feature is the prerequisite for Phase B of [Apple Calendar and participants](apple-calendar-participants.md). Its purpose is to answer “which anonymous speaker was active when?” within one recording, then let the user manage display names. It does not identify a real person from their voice.

## Current baseline

MeetingScribe records two independent 16 kHz mono tracks. The local microphone transcript is currently labeled `Martin`, while every segment from system audio is labeled `Other`. `TranscriptSegment.speaker` is only a display string; there is no stable speaker identifier, diarization artifact, assignment confidence, or UI for correcting speaker attribution.

The existing raw artifacts are valuable compatibility boundaries:

- `system-transcript.json` and `microphone-transcript.json` contain source-level speech-to-text output;
- `transcript.json` deterministically merges both tracks and preserves overlaps;
- session metadata, analysis, and Markdown currently consume that merged transcript.

The implementation must add speaker attribution as a derived layer rather than destructively rewriting those raw artifacts.

## Product scope

The first usable version will:

- diarize only the system-audio track into anonymous session-scoped clusters;
- represent the local microphone as one separately managed local speaker;
- preserve timing and overlap information;
- assign each transcript segment to a stable speaker ID or mark it ambiguous;
- let the user rename anonymous speakers and merge duplicate clusters;
- persist edits with the recording;
- regenerate a resolved transcript and Markdown without rerunning Whisper;
- keep all diarization inference on the Mac.

The first version will not perform biometric voice identification, learn voiceprints across recordings, automatically assign Calendar names, or claim that an anonymous cluster belongs to a real person. Per-segment split/reassignment is a follow-up unless the engine and available timestamps make the edit lossless.

## Engine decision and technical spike

Introduce a project-owned `SpeakerDiarizing` protocol before adopting a concrete engine. The leading native candidate is FluidAudio because it exposes local Swift/Core ML diarization, supports complete-file processing, accepts 16 kHz audio, and has disk-backed input paths suitable for long meetings. The integration must pin a reviewed release and model set only after a spike verifies package size, model licensing, offline behavior, Apple Silicon performance, memory use, and Czech/Slovak meeting quality.

The spike compares at least:

1. FluidAudio offline diarization on representative MeetingScribe system tracks;
2. FluidAudio Sortformer where the four-speaker ceiling is acceptable;
3. a Python/pyannote reference run used only as an evaluation oracle, not as a shipped runtime dependency.

The current whisper.cpp stereo diarization and TinyDiarize switches are not the product solution: MeetingScribe's system track is mono, and speaker-turn detection alone does not provide persistent multi-speaker clusters and management.

Decision output:

- selected engine, model, exact dependency revision, and model license;
- supported maximum or variable speaker count;
- diarization error and manual-correction observations on a small consented fixture set;
- processing time, peak resident memory, and model storage on the oldest supported Apple Silicon Mac;
- model download, cache, deletion, and offline-start behavior;
- documented fallback when no diarization model is installed.

Useful primary references:

- [FluidAudio project and license](https://github.com/FluidInference/FluidAudio)
- [FluidAudio diarization API](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md)
- [FluidAudio model inventory](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md)
- [pyannote.audio reference toolkit](https://github.com/pyannote/pyannote-audio)
- [whisper.cpp diarization options](https://github.com/ggml-org/whisper.cpp/blob/master/examples/server/server.cpp)

## Data model

Keep identity separate from a mutable display name.

```swift
struct SessionSpeaker: Codable, Equatable, Identifiable, Sendable {
    let id: String                 // stable within the session
    let origin: SpeakerOrigin      // localMicrophone, diarizedSystem, unknown
    var displayName: String        // user-editable
    var isUserConfirmed: Bool
}

struct DiarizedTurn: Codable, Equatable, Sendable {
    let speakerID: String
    let start: Double
    let end: Double
    let confidence: Double?
}

struct SpeakerSegmentAssignment: Codable, Equatable, Sendable {
    let transcriptSegmentID: String
    let speakerID: String?
    let confidence: Double?
    let state: AssignmentState     // assigned, ambiguous, unknown
}

struct SpeakerResolutionArtifact: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: String
    let sourceFingerprint: String
    let engine: String
    let model: String
    let completedAt: Date
    var speakers: [SessionSpeaker]
    let turns: [DiarizedTurn]
    var assignments: [SpeakerSegmentAssignment]
}
```

Persist new optional paths in `SessionTranscriptFiles`:

- `speaker-diarization.json` for engine output, stable clusters, and user edits;
- `resolved-transcript.json` for the derived transcript consumed by Markdown and optional analysis.

Add optional speaker-processing metadata to the session manifest and increment the current schema. New fields must decode as absent so schema 1–10 recordings continue to load. `sourceFingerprint` must cover the relevant system transcript and finalized audio metadata; changing or replacing either invalidates the derived artifact instead of silently reusing stale assignments.

## Reconciliation rules

The diarizer produces timed turns, while Whisper currently produces timed text segments. Reconciliation must be deterministic and independently testable:

1. intersect each system transcript segment with diarized turns;
2. assign the speaker with the greatest overlap only when coverage and dominance thresholds are met;
3. preserve `ambiguous` when competing speakers overlap or evidence is weak;
4. keep microphone segments assigned to the local speaker independently of system clusters;
5. retain simultaneous system and microphone speech as overlapping segments;
6. never invent text boundaries that cannot be supported by word-level timestamps;
7. regenerate `resolved-transcript.json` from raw merged transcript plus the speaker artifact after every rename or merge.

Thresholds belong in a versioned reconciliation configuration stored in the artifact. They must not be scattered through UI code.

## Application architecture

Add these boundaries:

- `SpeakerDiarizing`: engine-neutral async diarization interface;
- `SpeakerModelManager`: explicit model download, verification, cache state, and deletion;
- `SpeakerTranscriptResolver`: pure reconciliation and resolved-transcript generation;
- `SpeakerArtifactStore`: atomic persistence, fingerprint validation, and backward-compatible loading;
- `SpeakerManagementModel`: session editor state and commands;
- `SpeakerOutputRegenerator`: rerenders Markdown and invalidates or reruns AI analysis only after explicit user action.

Diarization runs after finalization and may run before or after Whisper, but resolution waits until both the system transcript and diarization artifact are available. A diarization failure must not fail recording, transcription, or ordinary Markdown export; it records a warning and falls back to the existing source labels.

Recovery must treat each completed artifact as a checkpoint. Relaunching the app can reuse a valid diarization artifact and regenerate a missing resolved transcript without loading the model again.

## User experience

Add a **Manage speakers…** action to each completed recording with a transcript. The editor should show:

- anonymous speakers with duration and segment count;
- short timestamped transcript examples for each cluster;
- editable display names;
- a clear unconfirmed/confirmed state;
- merge action for duplicate clusters, with undo before saving;
- an explicit unknown speaker option;
- save and cancel actions;
- regeneration progress and a non-destructive error state.

Replace the hard-coded local microphone name with a setting or per-session display name. Use a neutral localized default such as “Me” until the user confirms another name.

Phase B later extends this editor with confirmed Calendar attendees as naming candidates. It must not auto-select a person merely because they were invited.

## Implementation slices

### S0 — engine spike

- build a command-line or test-only adapter against consented fixture audio;
- record quality, performance, storage, and licensing results;
- choose and pin the engine/model or stop with documented rejection criteria.

### S1 — domain and persistence

- add speaker IDs, artifacts, optional manifest fields, fingerprinting, and coders;
- add schema migration and compatibility fixtures;
- implement atomic artifact storage and invalidation.

### S2 — offline diarization pipeline

- implement the selected `SpeakerDiarizing` adapter and model manager;
- run on finalized system audio without blocking capture;
- checkpoint success/failure in the session manifest and processing log;
- support recovery and cancellation.

### S3 — transcript resolution

- implement overlap-based reconciliation and ambiguity handling;
- generate `resolved-transcript.json` without modifying raw transcripts;
- switch Markdown and optional AI input to resolved output when valid;
- preserve current output as fallback.

### S4 — speaker management UI

- add the session speaker editor from the recordings window;
- implement rename, merge, confirm, cancel, and unknown states;
- regenerate derived output without Whisper or diarization reruns;
- localize user-facing controls and failures.

### S5 — acceptance and Phase B handoff

- validate two-, three-, and four-speaker recordings, overlap, silence, music, echo, and one-hour input;
- verify bounded memory and repeatable recovery on supported Macs;
- confirm old sessions render unchanged;
- document known diarization limitations;
- expose stable speaker IDs and editor hooks required by Calendar Phase B.

## Test plan

Automated coverage must include:

- artifact coding, legacy session decoding, and source-fingerprint invalidation;
- deterministic speaker IDs and reconciliation at exact timing boundaries;
- ambiguous overlaps, gaps, empty audio, one speaker, and more speakers than the selected engine supports;
- local microphone identity remaining independent of system clusters;
- rename and merge operations preserving raw transcripts;
- resolved transcript and Markdown regeneration without invoking transcription;
- AI participant data remaining opt-in;
- recovery from model absence, cancellation, corrupt artifacts, and interrupted atomic writes;
- model cache verification and deletion;
- long-session streaming or disk-backed processing without eager full-file sample allocation.

Manual acceptance uses consented synthetic or internal fixtures and records only aggregate quality observations, never meeting transcript content in repository evidence.

## Definition of done

- A completed recording can produce stable anonymous system-speaker clusters fully on-device.
- The user can rename and merge clusters and reopen the recording with those edits intact.
- Raw track transcripts and `transcript.json` remain byte-for-byte unchanged by speaker edits.
- `resolved-transcript.json` and Markdown reproducibly reflect the saved mapping.
- Missing models or diarization failures preserve the current successful transcription/export path.
- Schema 1–10 recordings remain readable.
- Resource and quality gates selected by S0 pass on the minimum supported hardware.
- Calendar Phase B can consume stable speaker IDs without changing the diarization model or persistence contract.
