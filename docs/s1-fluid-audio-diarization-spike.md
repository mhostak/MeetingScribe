# S1 FluidAudio offline diarization spike

Status: adapter and long-session offline run complete; labeled CZ/SK quality matrix pending

Date: 2026-07-15

## Decision under evaluation

The leading S1 candidate is the offline `community-1` pipeline in [FluidAudio v0.15.5](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.5), pinned exactly in `Package.swift` for the spike executable. It matches MeetingScribe's macOS 14 minimum, accepts file-backed audio, processes 16 kHz mono input, returns anonymous speaker clusters with timestamps, and can operate fully offline after the model is installed.

**Decision update (2026-07-15):** the completed long-session diarization run and pure Parakeet v3 comparison are sufficient to approve FluidAudio as the migration direction. Production default cutover remains conditional on the consented labeled fixture gate below. S1 introduces no speaker names, voiceprints, Calendar matching, or cross-meeting identity. The full staged change is documented in [the FluidAudio-only migration plan](fluid-audio-migration-plan.md).

## Isolation and privacy

`MeetingScribeDiarizationSpike` is a SwiftPM-only executable. The Xcode application target does not link FluidAudio and the normal recording/transcription path does not invoke it.

Network model access is disabled by default through `ModelHub.offlineMode`. A first model download requires the explicit `--allow-model-download` flag. The JSON report stores only the source file name and SHA-256 fingerprint, not its full path or audio content. The supplied fixture must be synthetic or explicitly consented.

## Version, model, storage, and licensing

- SDK: FluidAudio `0.15.5`, release commit `19600a485baa4998812e4654b70d2bab8f2c9949`.
- SDK license: Apache-2.0.
- Model: `FluidInference/speaker-diarization-coreml`, based on pyannote `community-1` with WeSpeaker embeddings and offline VBx clustering.
- Model license: CC-BY-4.0; production distribution must preserve the required attribution.
- Published model repository size: approximately 129 MB. The spike records the real compiled cache size after every run.
- Default clustering threshold for MeetingScribe evaluation: `0.7`, because FluidAudio's current AMI-SDM results document materially better speaker counts at `0.7` than the `community-1` preset `0.6`.

The SDK and model details come from the [FluidAudio diarization API](https://github.com/FluidInference/FluidAudio/blob/v0.15.5/Documentation/API.md), [FluidAudio benchmark documentation](https://github.com/FluidInference/FluidAudio/blob/v0.15.5/Documentation/Benchmarks.md), and the [Core ML model card](https://huggingface.co/FluidInference/speaker-diarization-coreml).

## Implemented spike contract

The project-owned `SpeakerDiarizing` boundary accepts an audio URL plus optional speaker-count constraints. Engine output is normalized into deterministic segment IDs after validating finite timestamps, audio bounds, non-empty anonymous speaker IDs, and confidence range.

The spike report records:

- engine, exact version, model, and licenses;
- source SHA-256 and audio duration;
- threshold and optional speaker-count constraints;
- anonymous segments and unique speaker count;
- wall-clock time, real-time factor, compiled model-cache bytes, and FluidAudio stage timings;
- optional DER components against a consented JSON reference.

The built-in evaluator uses 10 ms frames, a 250 ms reference collar, ignored overlapping reference speech, and an optimal one-to-one mapping between anonymous hypothesis and reference speaker labels. It separately reports missed speech, false alarm, speaker confusion, and total diarization error rate.

## Running the spike

The first explicit model installation and run:

```sh
swift run -c release MeetingScribeDiarizationSpike \
  --audio /path/to/consented-16k-mono.wav \
  --output /path/to/fluid-audio-report.json \
  --model-cache /path/to/isolated-model-cache \
  --threshold 0.7 \
  --allow-model-download
```

Subsequent offline verification omits `--allow-model-download`. Add `--reference reference.json` for measured DER or `--exact-speakers N` only when the fixture's ground truth explicitly includes that constraint.

Reference JSON shape:

```json
{
  "segments": [
    { "speakerID": "speaker-a", "start": 0.0, "end": 4.2 },
    { "speakerID": "speaker-b", "start": 4.3, "end": 7.8 }
  ]
}
```

The environment-gated integration test never downloads a model unless `MEETINGSCRIBE_DIARIZATION_ALLOW_MODEL_DOWNLOAD=1` is also set.

## Acceptance gate

Evaluate consented Czech, Slovak, and mixed-language fixtures covering two, three, and four speakers, short turns, long monologues, silence, overlap, echo, and background music. At least one fixture must be 30 minutes or longer.

Proceed to the S3 production adapter only when all of these hold on the minimum supported Apple Silicon Mac:

- median DER is at most 20% with the documented scorer;
- no ordinary clean two- or three-speaker fixture exceeds 30% DER;
- automatic speaker count is exact on at least 80% of fixtures and never exceeds the reference by more than one;
- warm-cache processing is at least 10× real time;
- compiled model cache remains at most 200 MB;
- a second run succeeds with network access disabled and produces deterministic normalized JSON;
- CC-BY-4.0 attribution and model removal requirements are acceptable for distribution.

Reject or re-spike the candidate if any gate fails. A rejection does not affect S0 grouping or existing transcription/export.

## Current evidence

- The engine-neutral contract, normalizer, scorer, CLI, offline network gate, report schema, and opt-in integration test compile against FluidAudio `v0.15.5`.
- Five deterministic unit tests cover normalization, invalid engine output, anonymous-label permutation, missed speech, and overlap handling.
- Upstream FluidAudio reports an average 10.62% DER and 12/16 exact speaker counts on its AMI-SDM test split at threshold `0.7`; this is third-party benchmark evidence, not MeetingScribe acceptance evidence.
- Real inference was deferred until recording and transcription had finished. No source recording, transcript, or exported note was modified by the spike.

### Real-session run: `2026-07-15T11-03-35Z_086BA6`

The completed 83.7-minute session was evaluated at threshold `0.7` on both finalized 16 kHz mono tracks. Reports were written under ignored `.derivedData/s1-acceptance/`; they contain timestamps and anonymous cluster IDs, but no transcript text or participant names.

| Track | Automatic clusters | Segments | Speech | Wall time | Speed | Cache |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| System | 3 | 633 | 2,933.43 s | 57.97 s | 86.66x real time | 21,776,918 B |
| Microphone | 2 | 20 | 106.26 s | 28.94 s | 173.60x real time | 21,776,918 B |

The first installation-enabled system run and a later same-environment offline run produced exactly equal normalized segment arrays: 633 segments, three anonymous clusters, and result SHA-256 `e4c48d5358de7c6b0f3d3b702833cdf1876d3cd6db4a825525e1b295a67f3fd0`. This passes the long-input, warm-cache speed, cache-size, offline-load, and deterministic-output gates for this machine and recording.

An intentionally sandboxed diagnostic run could not create Apple's private Core ML execution cache and emitted E5RT/IOSurface errors; its slower, different clustering is excluded from algorithm acceptance. The spike now reports progress at approximately one-percent intervals and correctly measures a model cache located below a hidden parent directory.

The session has six consented Calendar participant display names stored locally, but that is neither a count of people who spoke nor timestamped ground truth. The system's three clusters and the microphone's small second cluster therefore cannot be scored as correct or incorrect from metadata alone. DER, speaker-count accuracy, overlap, echo, music, and the full Czech/Slovak fixture-matrix gates remain open. They are production cutover gates for the selected migration direction rather than evidence that attendee names can already be assigned to clusters.
