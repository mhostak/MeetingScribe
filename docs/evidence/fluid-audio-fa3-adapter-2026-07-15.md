# FluidAudio FA3 adapter evidence — 2026-07-15

## Scope

This evidence covers the production Parakeet v3 transcription adapter, its internal migration switch, compatibility normalization, recovery/model checkpoints, and non-destructive comparison revisions. It contains no transcript text or participant data.

## Pinned runtime

- FluidAudio SDK: `0.15.5`
- ASR model repository: `FluidInference/parakeet-tdt-0.6b-v3-coreml`
- Model revision: `aed02740059203c4a87495924f685de3722ae9ce`
- Adapter configuration: `parakeet-v3-int8-longform-v1`
- Encoder precision: int8
- Streaming threshold: 480,000 samples
- Parallel chunk concurrency: 4
- Mel chunk context: disabled
- Dual-decode arbitration: enabled

## Automated validation

- `FluidAudioTranscriptionServiceTests`: 8 deterministic tests passed; the environment-gated real-model test is skipped when fixture paths are absent.
- The tests cover runtime opt-in, pinned provenance, token-to-word normalization, timestamp ordering and clamping, punctuation segmentation, fallback text, automatic and forced language metadata, MeetingScribe-owned timing metrics, wrong-engine/format/empty-audio errors, cancellation, cleanup, legacy JSON decoding, and non-destructive revision output.
- A reprocessing test preserved byte-identical legacy `session.json`, transcript, and Markdown data while producing `revision.json`, source-audio fingerprints, complete transcription/provenance metrics, raw track output, merged transcript, utterance output, and comparison Markdown in `revisions/revision-test/`.
- Full SwiftPM regression: 211 tests executed, 15 environment-gated tests skipped, 0 failures.
- Xcode Debug application compile with signing disabled for CI validation: succeeded. This build was not launched or handed to the user.

## Production-model inference

The opt-in integration test used the installed verified Parakeet bundle and the system-audio track from session `2026-07-15T13-00-47Z_C4BB0B` in read-only mode.

- Audio duration: 1,781.14 seconds
- Test wall time including cold Core ML loading/compilation and cleanup: 41.128 seconds
- Effective end-to-end throughput: approximately 43.3x real time
- Result: non-empty transcript, non-empty word timing data, monotonic word starts, every word end at or before the audio duration, expected FluidAudio provenance
- Source audio, session manifest, existing transcript, and existing Markdown were not written by the test

## Remaining interactive gate

A properly signed app still needs one interactive migration-mode smoke run covering:

1. a new recording through FluidAudio transcription and Markdown export;
2. termination/relaunch recovery from a persisted processing checkpoint;
3. the Recordings-window reprocessing action and its Finder result;
4. byte-preservation of source audio and pre-existing legacy artifacts.
