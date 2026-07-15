# Speaker recognition and management implementation plan

Status: product implementation complete on 2026-07-15; automated acceptance passes; consented labeled DER and final signed-app hardware acceptance remain release gates

This feature is the prerequisite for Phase B of [Apple Calendar and participants](apple-calendar-participants.md). It answers “which anonymous speaker was active when?” within one recording and lets the user manage session-local display names. It does not identify a real person from their voice, learn voiceprints, or automatically map Calendar attendees.

## Delivered product boundary

MeetingScribe now uses FluidAudio `0.15.5` exclusively:

- Parakeet TDT 0.6B v3 produces timestamped system and microphone transcripts;
- offline `community-1` diarizes the finalized system-audio file;
- the microphone remains an independent, stable `local-user` speaker;
- system clusters receive deterministic session-local IDs (`speaker-001`, `speaker-002`, …);
- word timestamps are resolved against diarized turns, including explicit overlap and unmatched-speech states;
- users can rename, classify, and merge speakers from the Recordings window;
- saved edits regenerate only derived speaker output and Markdown;
- raw audio, per-track transcripts, and `transcript.json` are never changed by diarization or speaker edits.

When the diarization model is missing, stale, cancelled, or fails, successful transcription and deterministic continuous-utterance output remain available. The application can resume at the diarization or resolution checkpoint without rerunning speech-to-text.

## Artifacts and compatibility

Raw compatibility boundaries remain unchanged:

- `system-transcript.json` and `microphone-transcript.json` contain normalized source ASR;
- `transcript.json` is the deterministic overlap-preserving raw merge;
- `utterance-transcript.json` is the engine-neutral readability fallback.

Speaker processing adds:

- `speaker-diarization.json`: FluidAudio provenance, source audio and transcript fingerprints, stable profiles, anonymous turns, and user edits;
- `resolved-transcript.json`: derived word-level speaker assignments used by Markdown and, when valid, optional AI analysis.

Session schema 13 adds optional diarization metadata. Older manifests and old engine provenance continue to decode without loading an obsolete model or runtime. Every derived artifact is fingerprinted; changed audio, transcript, or speaker mappings invalidate dependent output instead of silently reusing it.

## Resolution rules

`SpeakerTranscriptResolver` is deterministic and independent of FluidAudio types:

1. microphone speech always maps to `local-user`;
2. system words use the diarized speaker with the greatest time overlap;
3. effectively tied overlaps are retained as `overlappingSpeakers` rather than hidden;
4. speech without a matching turn is retained as `unmatchedSpeech` and shown as Unknown speaker;
5. word-level boundaries are used when available; a segment-level fallback is used otherwise;
6. simultaneous microphone and system speech remains overlapping output;
7. adjacent compatible words are grouped without dropping any non-empty source word;
8. every resolved item retains its source segment IDs.

The configuration is versioned as `speaker-resolution-v1` and the production diarization configuration as `community-1-offline-v1`.

## Speaker editor

Completed recordings with a valid speaker artifact expose **Edit speakers**. The editor provides:

- anonymous system clusters and the independent microphone speaker;
- turn count, total speaking duration, and short timestamped transcript examples;
- an editable display name;
- Anonymous, Named, and Unknown states;
- merge into another same-source cluster and undo before Save;
- explicit Save and Cancel actions;
- progress and non-destructive errors.

The neutral local default is “Me”. A user can rename it per session. Saving validates merge targets and rejects cycles, atomically persists the profile changes, regenerates `resolved-transcript.json`, and atomically refreshes existing Markdown without invoking ASR or diarization.

Phase B may later offer explicitly confirmed Calendar attendees as naming candidates. It must never choose a real person automatically merely because they were invited.

## Implementation slices

### S0 — continuous-utterance grouping — complete

- [x] preserve raw segments while creating stable source-local utterances;
- [x] split deterministically on source, silence, punctuation, overlap, and duration boundaries;
- [x] persist source-segment mappings in `utterance-transcript.json`;
- [x] use the artifact for Markdown with raw transcript fallback;
- [x] retain old `speaker-turns.json` as read-only compatibility data after TinyDiarize removal.

TinyDiarize was evaluated as a boundary hint but was not retained as a production speaker identity mechanism. Deterministic grouping remains the no-model fallback. Historical real-session validation preserved all 377 raw segments while producing a separate readable export.

### S1 — FluidAudio diarization spike — complete

- [x] pin FluidAudio `0.15.5` and offline `community-1`;
- [x] implement normalization, DER scoring, and opt-in real-fixture evaluation;
- [x] record model provenance, storage, wall time, and deterministic output;
- [x] complete an 83.7-minute CZ/SK offline run with 3 clusters and 633 turns in 58 seconds;
- [x] select FluidAudio for the production adapter.

The performance run had no timestamped ground truth, so it is evidence for long-input, offline, storage, speed, and determinism—not a DER claim. Details remain in [S1 FluidAudio offline diarization spike](s1-fluid-audio-diarization-spike.md).

### S2 — speaker domain and persistence — complete

- [x] add stable profile IDs, source type, mutable display state, and merge mapping;
- [x] add atomic `speaker-diarization.json` and `resolved-transcript.json` stores;
- [x] fingerprint audio, transcript, diarization, and resolution dependencies;
- [x] add optional session paths and diarization metadata with schema 13 compatibility;
- [x] reject invalid profiles, duplicate IDs, invalid targets, and merge cycles.

### S3 — production offline diarization — complete

- [x] move `community-1` behind the engine-neutral `SpeakerDiarizing` boundary;
- [x] force offline model loading from the verified installed bundle;
- [x] process the finalized WAV using FluidAudio's disk-backed API;
- [x] run only after sequential ASR so inference never competes with capture;
- [x] checkpoint completion/failure in session metadata and processing logs;
- [x] propagate cancellation, release model resources, and preserve fallback output;
- [x] recover from valid ASR/diarization artifacts without repeating earlier work.

### S4 — transcript resolution — complete

- [x] resolve word-level timestamps with deterministic overlap rules;
- [x] preserve ambiguity, unmatched speech, overlaps, text, and source mappings;
- [x] keep the microphone identity independent of all system clusters;
- [x] persist speaker-aware output without modifying raw transcript artifacts;
- [x] use valid resolved output for Markdown and optional AI analysis;
- [x] retain continuous utterances and raw merge as ordered fallbacks.

### S5 — speaker management UI — complete

- [x] add the editor to completed rows in the Recordings window and context menu;
- [x] show cluster metrics and transcript examples;
- [x] implement rename, Anonymous/Named/Unknown, merge, undo, Save, and Cancel;
- [x] support a per-session local microphone name with neutral “Me” default;
- [x] regenerate resolved JSON and Markdown without ASR or diarization;
- [x] localize user-facing editor controls in Czech and Slovak.

### S6 — acceptance and Phase B handoff

Implementation and automated acceptance:

- [x] deterministic IDs, coding, fingerprint invalidation, and merge-cycle tests;
- [x] word-level splitting, local-speaker independence, fallback, and raw preservation tests;
- [x] missing-model, inference-failure, cancellation, resource-release, and recovery behavior;
- [x] Markdown regeneration without ASR or diarization;
- [x] full SwiftPM regression suite and Xcode application compilation;
- [x] stable IDs and editor hooks needed by Calendar Phase B.

Release acceptance still requiring consented fixtures or target hardware:

- [ ] measure DER and speaker-count error on labeled Czech, Slovak, mixed-language, two-, three-, and four-speaker fixtures, including overlap, echo, music, and silence;
- [ ] capture peak resident memory on the oldest supported Apple Silicon Mac;
- [ ] complete a signed end-to-end recording and editor smoke test of at least 60 minutes.

These open items are release-quality measurements, not missing product behavior. No unlabeled meeting is used to fabricate a DER result, and repository evidence must contain aggregate metrics only.

## Acceptance thresholds

- labeled DER at or below 20% with overlap scoring rules recorded;
- detected speaker-count error at most one on the labeled fixture matrix;
- no dropped non-empty ASR words and no destructive changes to raw artifacts;
- deterministic output for the same audio, model, and configuration;
- no network request during inference or reopening an installed model;
- failed or cancelled diarization never turns a valid transcript into a failed session;
- long-session processing remains disk-backed and does not eagerly allocate the complete WAV as samples;
- Calendar Phase B can consume stable speaker IDs without changing the diarization model or persistence contract.

## Definition of done

- [x] A completed recording can produce stable anonymous system clusters fully on-device.
- [x] The microphone is an independently managed local speaker.
- [x] The user can rename, classify, merge, save, and reopen session speaker profiles.
- [x] Raw track transcripts and `transcript.json` remain byte-for-byte unchanged by speaker edits.
- [x] `resolved-transcript.json`, Markdown, and optional AI input reproducibly use valid mappings.
- [x] Missing, stale, failed, or cancelled diarization preserves the successful fallback path.
- [x] Old sessions remain readable without the removed runtime.
- [x] Stable speaker IDs and consent-first editor hooks are ready for Calendar Phase B.
- [ ] The remaining labeled quality, oldest-hardware resource, and signed-app release gates are recorded as passed.
