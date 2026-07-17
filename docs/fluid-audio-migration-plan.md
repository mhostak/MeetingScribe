# FluidAudio-only transcription and diarization migration plan

Status: FluidAudio ASR migration and legacy-engine removal complete; `community-1` diarization failed production acceptance on 2026-07-16 and further speaker-recognition work is paused

This phase replaced the complete whisper.cpp transcription stack, optional TinyDiarize turn detection, and the separate Silero VAD model with FluidAudio. Parakeet TDT 0.6B v3 is the accepted local speech-to-text runtime. The offline `community-1` pipeline is implemented for anonymous diarization but is not production-accepted after failing a real multi-speaker validation.

The end state is deliberately not a permanent multi-engine product. A temporary internal rollback switch is allowed while the migration is being validated, but Settings will not ask the user to choose between Whisper and FluidAudio. After the acceptance gates pass, Whisper is removed from the application target and FluidAudio becomes the only transcription and diarization runtime.

The implemented diarization boundary and persistence remain described in [Speaker recognition and management](speaker-recognition-management-plan.md), but they are not a completed product prerequisite for attendee mapping. The current model does not identify real people reliably and must not be used to map Calendar attendees to clusters.

## Decision basis

FluidAudio `0.15.5` is the reviewed baseline for the migration. The app will initially pin that exact version rather than follow a floating package range.

The completed 83.7-minute CZ/SK session `2026-07-15T11-03-35Z_086BA6` was processed without Whisper or its transcript:

| Operation | Result | Wall time | Speed |
| --- | ---: | ---: | ---: |
| Parakeet v3 system transcription | 7,264 words, 93.4% mean confidence | 138.9 s | 36.2x real time |
| Parakeet v3 microphone transcription | 279 words, 88.5% mean confidence | 131.7 s | 38.1x real time |
| `community-1` system diarization | 3 anonymous clusters, 633 turns | 58.0 s | 86.7x real time |
| Resolved conversational output | 550 utterances | — | — |

The ASR run used the long-input configuration equivalent to `--no-mel-context --dual-decode-arbitration` with no forced language hint. The resulting separate Markdown was reviewed as usable. The experiment proves long-input execution, offline reuse, deterministic diarization output on the tested machine, and a practical storage footprint of approximately 469 MiB for Parakeet plus 21.8 MiB for the compiled diarization cache.

It does not yet prove general transcription accuracy or diarization error rate. There is no timestamped speaker ground truth for that meeting, and the wider Czech, Slovak, mixed-language, overlap, echo, music, sparse-microphone, and older-hardware matrix remains a production gate.

## Fixed product decisions

- ASR: FluidAudio Parakeet TDT 0.6B v3 Core ML, using the reviewed int8-compatible model bundle.
- Diarization: FluidAudio offline `community-1` is implemented on the system track, but its production use and further feature development are paused after failed quality validation.
- Local microphone: represented as the local user independently of system-audio clusters.
- Processing: starts only after recording finalization; inference must never compete with active capture.
- Resource policy: system ASR, microphone ASR, and diarization run sequentially so only one heavyweight engine workload is active at a time.
- Language policy: Auto remains the default for mixed CZ/SK meetings. Existing Czech, Slovak, and English preferences remain stored while their exact FluidAudio mapping is validated.
- Privacy: finalized audio and inference remain local. Network access is used only for an explicit model download.
- Failure policy: a missing or failed ASR model leaves the session recoverable. Failed diarization does not discard a successful transcript and falls back to source-local deterministic grouping.
- Cutover policy: no automatic fallback from FluidAudio ASR to Whisper in the final product.
- Compatibility policy: opening an old recording never requires Whisper to be installed.

## Target processing pipeline

```text
finalized system-16k.wav ─┐
                          ├─ FluidAudio ASR, sequential ─ track transcripts ─ raw merge
finalized microphone-16k.wav ┘                                      │
                                                                   │
system-16k.wav ─ FluidAudio diarization ─ anonymous timed turns ───┤
                                                                   ▼
                                                 speaker resolution and grouping
                                                                   │
                                                                   ▼
                                                    Markdown and optional AI input
```

`SessionTranscriber` remains the workflow coordinator, but it will no longer accept a single arbitrary model file URL. Model preparation belongs to a FluidAudio-specific model repository, and project-owned adapters convert FluidAudio results into MeetingScribe domain models. FluidAudio types must not leak into session persistence, Markdown rendering, recovery, or speaker-management code.

The production boundaries are:

- `SpeechTranscribing`: engine-neutral request and result interface;
- `FluidAudioTranscriptionService`: Parakeet initialization, sequential track inference, timestamp normalization, and cleanup;
- `FluidAudioDiarizationService`: adapter from the existing `SpeakerDiarizing` contract to `community-1`;
- `FluidAudioModelManager`: ASR and diarization bundle discovery, verified installation, progress, repair, deletion, and offline loading;
- `SpeakerTranscriptResolver`: deterministic assignment of ASR words or segments to diarized turns;
- `TranscriptSanitizer`: engine-neutral text validation replacing Whisper-named helpers;
- `SessionTranscriber`: checkpointed orchestration, warnings, recovery metadata, and artifact persistence.

The first production adapter will transcribe the untouched finalized WAV timeline. It will not reuse Whisper's Silero/energy-compacted inference input unless a fixture proves that FluidAudio needs it. This avoids unnecessary timestamp remapping and preserves the successful long-input behavior already observed. The app still measures source activity for diagnostics and empty-track handling.

## Artifact and schema compatibility

The existing artifact names remain stable so downstream output and recovery do not need an engine-specific branch:

- `system-transcript.json` and `microphone-transcript.json` remain normalized track transcripts;
- `transcript.json` remains the deterministic, overlap-preserving raw merge;
- `utterance-transcript.json` remains a derived readable grouping;
- `speaker-diarization.json` stores FluidAudio model provenance, anonymous turns, configuration, source fingerprint, and later user edits;
- `resolved-transcript.json` stores the derived speaker-aware transcript used by Markdown and optional analysis when valid;
- `speaker-turns.json` remains readable for old TinyDiarize sessions but is not written by the FluidAudio-only pipeline.

The next session schema adds optional, engine-neutral provenance rather than overloading the current `model` string:

- transcription engine, SDK version, model repository/revision, model variant, and configuration revision;
- diarization engine, model repository/revision, threshold/configuration revision, and performance;
- app-owned source duration, inference duration, wall time, and calculated real-time factor;
- fingerprints for every derived dependency and an explicit processing revision.

Track transcript decoding must remain backward compatible. New provenance fields decode as absent for existing schema 1–11 sessions, and old Whisper-generated JSON remains renderable and re-exportable without loading any inference engine. The app must calculate its own duration and real-time-factor metrics; the migration must not trust the currently incorrect zero `durationSeconds` and `rtfx` values emitted by the upstream CLI JSON path.

Reprocessing an old meeting with FluidAudio is always explicit and non-destructive. It creates a new processing revision with separate derived artifacts and export output; it never silently overwrites the original Whisper transcript or Markdown. Promotion of a new revision to the preferred view is a separate user action.

## Model installation and Settings

FluidAudio models are multi-file bundles, not interchangeable Whisper `.bin` files. The application therefore needs an atomic directory-based installer:

1. download into a staging directory with visible byte progress and cancellation;
2. verify an app-owned manifest containing repository, pinned revision, expected files, byte sizes, and cryptographic hashes;
3. load the model once as an installation check;
4. atomically promote the verified directory under `Application Support/MeetingScribe/Models/FluidAudio/`;
5. support an offline second load, repair, and explicit deletion.

Settings → Transcription becomes a FluidAudio model-status view:

- one Parakeet transcription model row;
- one speaker-diarization model row;
- Download/Repair, Import where bundle verification can be guaranteed, and Delete actions;
- combined storage estimate and per-model progress;
- license and attribution links;
- no Whisper model picker and no TinyDiarize toggle after final cutover.

Existing Whisper and TinyDiarize files are never deleted automatically. After FluidAudio cutover, Settings offers a separately confirmed **Remove unused legacy models** cleanup action and reports how much storage it will recover. Old preference keys may be ignored after one compatibility release, but they remain harmless if a user later installs an older app build.

## Licensing and attribution

The FluidAudio SDK is Apache 2.0. The Hugging Face metadata and the parent models identify the selected Parakeet and diarization model families as CC BY 4.0. Before release, MeetingScribe must include:

- SDK copyright and Apache 2.0 notice;
- model names, authors/origins, exact repositories and revisions, and CC BY 4.0 attribution;
- a user-visible attribution entry in Settings/About and the repository's third-party notices;
- the same provenance in the app-owned model manifest and session metadata.

License text and model-card metadata must be captured at the pinned revisions. A conflicting or later-updated model card does not silently change the terms attached to an already reviewed release.

Primary references:

- [FluidAudio project, API, and Apache 2.0 license](https://github.com/FluidInference/FluidAudio)
- [Parakeet TDT 0.6B v3 Core ML model](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
- [NVIDIA Parakeet TDT 0.6B v3 model and supported languages](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [FluidAudio speaker diarization Core ML model](https://huggingface.co/FluidInference/speaker-diarization-coreml)

## Implementation slices

### FA0 — contract and evidence lock

- [x] record the exact dependency and model direction;
- [x] preserve the pure-FluidAudio real-session comparison as baseline evidence;
- [x] archive sanitized machine details, exact repository revisions, cache/report fingerprints, and aggregate ASR evidence without committing transcript text;
- [ ] capture peak resident memory in a repeatable production-adapter run;
- [x] define the consented fixture list and expected acceptance measurements;
- [x] add third-party notice entries for the reviewed SDK and model revisions.

The current evidence record is [FluidAudio FA0 reproducibility baseline](evidence/fluid-audio-fa0-baseline-2026-07-15.md), and the remaining inputs are specified in the [FluidAudio acceptance fixture matrix](evidence/fluid-audio-acceptance-fixture-matrix.md). Peak RSS was not captured by the original comparison and remains deliberately open rather than inferred after the fact.

Exit gate: the migration can be reproduced from pinned inputs and all redistributed components have a recorded license decision.

### FA1 — engine-neutral core

- [x] replace model-URL-based transcription calls with an engine-neutral request;
- [x] add explicit engine/model provenance while preserving legacy decoding;
- [x] rename Whisper-specific sanitizer, error, settings, and coordinator concepts where they cross domain boundaries;
- [x] keep current Whisper behavior behind the new interface so this slice is behavior-neutral;
- [x] add schema 1–11 compatibility fixtures and coding tests before changing the engine.

Implemented on 2026-07-15. The shared SwiftPM and Xcode test suites pass through the new contract. Transcript text, timestamps, merge ordering, and Markdown rendering retain their existing semantics; new sessions additionally record optional engine-neutral provenance and use session schema 12. Schema 1–11 sessions continue to decode without provenance.

Exit gate: the current suite passes with no transcript-semantic changes, and engine-neutral orchestration contracts no longer expose whisper.cpp. The temporary legacy adapter selection remains isolated at the composition root until the FluidAudio cutover.

### FA2 — production model manager and Settings

- [x] link the exactly pinned FluidAudio package to both SwiftPM core validation and the Xcode application target;
- [x] implement verified directory manifests, staging, byte progress, cancellation, repair, deletion, and offline load;
- [x] replace the visible Whisper/TinyDiarize controls with the two FluidAudio model states while preserving legacy files for the later cutover cleanup;
- [x] add localized missing, invalid, download, import, cleanup, and license/attribution messages;
- [x] test interrupted download, corrupt/missing files, replacement, disk-full behavior, offline reload, verified import, and explicit cleanup;
- [x] import both real pinned model bundles, load them from staging, promote them, and load them again with the model hub in offline mode;
- [x] produce and verify a Debug app signed by the required Apple Development identity;
- [ ] complete one interactive signed-app smoke test covering Download, Cancel, Verify and repair, Import, and Delete for both rows without beginning a recording.

Implemented on 2026-07-15. The manager owns exact file manifests for Parakeet and speaker diarization, downloads from immutable repository revisions, hashes all files before promotion, validates an actual FluidAudio load, and atomically replaces only a verified bundle. Settings exposes separate state and actions for both bundles. Fast status refresh checks the pinned manifest and file sizes; **Verify and repair** performs full SHA-256 verification and the offline FluidAudio load check. Automated and real-bundle evidence is recorded in [FluidAudio FA2 model-manager evidence](evidence/fluid-audio-fa2-model-manager-2026-07-15.md).

Exit gate: a signed app can install, verify, load offline, repair, and delete both model bundles without beginning a recording. The implementation and signed build are complete; the gate remains open only for the explicit interactive smoke test above.

### FA3 — Parakeet production adapter

- [x] implement `FluidAudioTranscriptionService` for system and microphone tracks;
- [x] pin the successful long-input and dual-decode settings in a versioned adapter configuration;
- [x] normalize word/segment timestamps, confidence, detected language, punctuation, and empty speech into existing track artifacts;
- [x] calculate performance metrics in MeetingScribe rather than copying the upstream CLI duration/RTF fields;
- [x] support cancellation, resource cleanup, sequential reuse, recovery, and a missing-model checkpoint;
- [x] add synthetic contract tests plus an opt-in production-model test harness for the consented CZ, SK, mixed CZ/SK, English, silence, sparse-audio, and long-input fixture matrix;
- [x] add explicit non-destructive FluidAudio reprocessing that writes a new revision manifest, transcripts, utterances, and Markdown without changing the source session.

The adapter was initially protected by an internal migration flag so the same finalized audio could be compared without overwriting either result. That flag was removed during the final cutover.

Implemented on 2026-07-15. Normal recording and recovery use the verified Parakeet bundle and preserve engine/model/configuration provenance. Explicit reprocessing is always available in Recordings and writes under `revisions/<revision-id>/`. Synthetic tests cover normalization, fallback text, forced/automatic language handling, app-owned metrics, invalid inputs, cancellation, resource cleanup, legacy decoding, silent and sparse-audio gating, and non-destructive revision output. The production adapter also passed on a 1,781.14-second existing recording with monotonic in-range word timestamps. Detailed evidence is in [FluidAudio FA3 adapter evidence](evidence/fluid-audio-fa3-adapter-2026-07-15.md).

Exit gate: implementation, Xcode compilation, full regression tests, real-model inference, and automated non-destructive reprocessing pass. The gate remains open for one signed-app interactive run covering a new recording, interrupted recovery, Markdown export, and the migration-only reprocessing button while confirming that legacy artifacts and raw audio remain unchanged.

### FA4 — FluidAudio diarization and speaker-aware output

- [x] move the proven `SpeakerDiarizing` adapter into the application target;
- [x] diarize finalized system audio and persist `speaker-diarization.json` atomically;
- [x] reconcile word timestamps with diarized turns, preserving ambiguity and overlap;
- [x] assign microphone speech to the local user independently;
- [x] derive resolved output, Markdown, and optional AI input without modifying raw track transcripts or `transcript.json`;
- [x] fall back to deterministic source grouping when diarization is missing, stale, cancelled, or fails;
- [x] recover from each completed ASR, diarization, resolution, and output checkpoint;
- [x] expose stable profiles, rename/classify/merge editing, and deterministic output regeneration.

Implemented on 2026-07-15. The app loads `community-1` strictly offline from the verified installed bundle, processes the finalized system WAV through FluidAudio's disk-backed path, canonicalizes engine labels to stable session IDs, and persists source fingerprints plus configuration provenance. Word-level resolution retains overlap and unmatched ambiguity, while the microphone remains the independent `local-user`. The Recordings window exposes a speaker editor with per-cluster metrics, transcript examples, rename/state/merge controls, and atomic Markdown regeneration. Session schema 13 records optional diarization status, and recovery resumes from valid ASR or diarization checkpoints.

Exit gate: **failed on 2026-07-16.** A signed 102.04-minute mixed Czech/Slovak Teams meeting with 10 actual speakers produced only two system clusters, and direct review found one person split across both. Exact 9- and 10-cluster experiments did not establish consistent identities. The technical implementation remains, but FA4 is not production-accepted.

### FA5 — default cutover

- [x] make FluidAudio the production default for new recordings and recovery that requires transcription;
- [x] remove the user-visible legacy model selection and turn-detection option;
- [x] remove the temporary internal rollback switch after the comparison cycle;
- [ ] validate model onboarding, signed permissions, recording-to-export flow, cancellation, relaunch, and old-session browsing in the final signed build;
- [x] document support diagnostics without transcript text or participant data.

Code cutover completed on 2026-07-15. The composition root now constructs `SessionTranscriber` with `FluidAudioTranscriptionService` unconditionally; no environment variable or build-time switch can select the removed engine.

Exit gate: the FluidAudio path passes the complete automated and manual matrix and no normal user workflow calls Whisper.

### FA6 — remove Whisper, TinyDiarize, and Silero

- [x] remove the legacy binary package dependency and Xcode references;
- [x] delete the old transcription, model, settings, turn-detection, VAD, test, and localization code;
- [x] remove the temporary rollback switch and the FluidAudio spike executable after its useful tests moved into production targets;
- [x] retain legacy transcript/turn-artifact decoders and add separately confirmed non-destructive legacy model cleanup;
- [x] verify the final Xcode-built app contains no removed binary, model URL, control, or unused package product.

Source removal completed on 2026-07-15. Old transcript provenance and `speaker-turns.json` remain plain Codable compatibility data; opening or exporting them does not load an inference engine. Settings reports recoverable legacy-model storage and removes only the known obsolete model files after a separate destructive confirmation. An unsigned CI-style Xcode build passed and its application bundle contained no removed binary, model URL, control, or package product; signed interactive acceptance remains tracked in FA5 and FA7.

Exit gate: FluidAudio is the only shipped speech and diarization engine, while old sessions still open and export correctly.

### FA7 — acceptance and handoff

- [ ] complete the labeled quality/resource matrix below on the oldest supported Apple Silicon machine and a current reference machine; paused for diarization until a new model is selected;
- [x] run a signed release-candidate meeting of at least 60 minutes end to end; capture, ASR, integrity, and export passed, while diarization failed the quality gate;
- [x] compare production-like meetings against preserved legacy outputs without overwriting either result;
- [x] update README, recovery documentation, support instructions, model attribution, and test baselines;
- [x] complete the speaker persistence, resolution, and management UI contracts originally planned for Calendar Phase B;
- [x] keep attendee-to-speaker mapping deferred and now blocked on a future diarization model passing quality acceptance.

### 2026-07-16 release-validation verdict

The real validation candidate lasted 6,122.54 seconds and contained mixed Czech/Slovak speech from 10 actual speakers. Capture completed without warnings, both WAV tracks were valid, Parakeet produced 815 system and 158 microphone segments, and export completed with all 973 raw source segment IDs preserved. ASR plus diarization used 8.02% of the recording duration on the M2 reference machine.

Diarization itself failed:

- automatic `community-1` output contained 936 turns but only two system-speaker clusters;
- at least one known person appeared in both clusters;
- an exact 9-cluster run produced 920 segments in 87.41 seconds;
- an exact 10-cluster run produced 926 segments in 110.56 seconds;
- after optimal anonymous-label alignment, the constrained variants disagreed on 270.545 seconds of their shared speech timeline;
- the unmatched tenth cluster was assembled mainly from two different 9-cluster identities, so forcing the expected count did not prove identity consistency.

The absence of time-aligned ground truth prevents a legitimate DER score, but it does not prevent rejection: the speaker-count miss and directly observed identity split independently fail the release gates. FluidAudio ASR acceptance is retained. Diarization, speaker naming, and Calendar attendee mapping are paused until a different model passes the same validation. See [sanitized release evidence](evidence/fluid-audio-diarization-release-validation-2026-07-16.md).

## Acceptance matrix

Automated coverage must include:

- exact schema 1–11 session decoding and current-schema round trips;
- monotonic, in-range word and segment timestamps on both tracks;
- deterministic raw merge, overlap preservation, and no dropped non-empty ASR words during speaker resolution;
- diarization normalization, anonymous-label permutation, overlap, ambiguity, and stale fingerprint handling;
- cancellation during model download, model initialization, ASR, diarization, resolution, and export;
- process termination after every persisted checkpoint followed by successful recovery;
- corrupt, partial, missing, and offline model states;
- old TinyDiarize artifacts remaining readable but never treated as speaker identity;
- explicit FluidAudio reprocessing creating a new revision without changing the original artifacts.

Manual acceptance uses consented fixtures and records aggregate metrics only:

| Area | Required fixtures or threshold |
| --- | --- |
| Language | Czech, Slovak, mixed CZ/SK, English, names, numbers, and domain terms |
| Acoustics | two to four speakers, overlap, echo, headphones, music, silence, and sparse microphone |
| Duration | short sample, 60–90-minute meeting, and interrupted/recovered meeting |
| ASR speed | at least 10x real time per track on the oldest supported Apple Silicon Mac |
| Diarization speed | at least 10x real time on the system track |
| Combined processing | no more than 20% of recorded duration on the oldest supported Mac |
| Model storage | verified installed ASR plus diarization footprint no more than 600 MiB for the selected variants |
| Offline behavior | second launch and complete processing succeed with network denied |
| Determinism | repeated warm-cache diarization produces the same normalized result |
| Quality | no material regression in decisions, names, numbers, and action items versus the preserved comparison; labeled diarization target DER at or below 20% and speaker-count error at most one |
| Memory | measured peak RSS is documented and does not cause capture or UI instability; workloads remain sequential |

The earlier 83.7-minute experiment remains valid speed, storage, offline, and deterministic-execution evidence. It is not speaker-quality evidence. The later 102.04-minute real meeting explicitly failed speaker count and identity consistency, so the current model is rejected without waiting for the remaining matrix rows.

## Definition of done

- Every new recording is transcribed by FluidAudio Parakeet v3; no user workflow invokes Whisper.
- [Paused] Reliable system-audio speaker clusters require a future model; `community-1` did not pass production quality acceptance. Deterministic continuous-utterance grouping remains the safe non-identity fallback.
- Whisper, TinyDiarize, Silero, their models, settings, package products, and runtime code are absent from the shipped app.
- Existing Whisper session artifacts remain readable, renderable, and exportable without the old model or engine.
- Reprocessing never overwrites an earlier transcript or Markdown output.
- Model installation, offline use, cancellation, deletion, recovery, attribution, and storage reporting work in the signed application.
- Czech, Slovak, mixed-language, long-session, resource, and recovery gates are recorded independently from the failed speaker-quality gate.
- Speaker-management and Calendar Phase B remain blocked until diarization artifacts are demonstrated to represent consistent people.
