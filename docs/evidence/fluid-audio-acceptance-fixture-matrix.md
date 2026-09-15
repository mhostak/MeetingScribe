# FluidAudio acceptance fixture matrix

Status: archival diarization-fixture contract. `community-1` was rejected after failed real multi-speaker validation on 2026-07-16, and the feature was later permanently retired.

No real recording enters this matrix without explicit consent for local evaluation. Audio and transcript ground truth remain outside Git. The repository stores only fixture IDs, non-identifying characteristics, aggregate scores, and hashes needed to reproduce a local run.

## Required fixtures

| ID | Source | Language/acoustics | Speakers | Ground truth | Purpose |
| --- | --- | --- | ---: | --- | --- |
| `FA-SYN-CS-2` | synthetic | Czech, clean, names and numbers | 2 | word text and speaker turns | basic ASR, timestamps, DER |
| `FA-SYN-SK-3` | synthetic | Slovak, clean, decisions and actions | 3 | word text and speaker turns | Slovak ASR and clustering |
| `FA-SYN-MIX-2` | synthetic | alternating Czech/Slovak | 2 | word text, language spans, speaker turns | mixed-language behavior |
| `FA-SYN-OVERLAP-4` | synthetic | Czech/Slovak with controlled overlap | 4 | overlapping speaker turns | ambiguity and maximum target count |
| `FA-REAL-HEADSET` | consented internal | headphones, ordinary meeting | 2–4 | manually labeled speaker turns plus content checklist | production-like quality |
| `FA-REAL-ECHO` | consented internal | loudspeaker echo into microphone | 2–4 | manually labeled system turns plus echo regions | cross-track duplication behavior |
| `FA-NOISE-MUSIC` | synthetic | silence, music, isolated noise | 0 | nonspeech regions | hallucination and false-speaker rejection |
| `FA-SPARSE-MIC` | synthetic or consented | less than 10% active microphone audio | 1 local | active regions and text checklist | sparse long-track cost and empty handling |
| `FA-LONG-UNLABELED` | consented internal | CZ/SK, 60–90 minutes | unknown | aggregate content checklist only | speed, RSS, offline use, determinism |
| `FA-REAL-MULTI-10` | consented internal | 102-minute Teams meeting, mixed CZ/SK | 10 actual speakers | direct participant count and identity-consistency review; no time-aligned RTTM | production speaker-count and qualitative identity gate |
| `FA-RECOVERY` | derived local copy of an approved fixture | process termination at checkpoints | inherited | inherited | cancellation and recovery |

The current `2026-07-15T11-03-35Z_086BA6` comparison may satisfy `FA-LONG-UNLABELED`; it cannot satisfy a labeled DER or speaker-count row merely because Calendar participants are present.

`FA-REAL-MULTI-10` failed the evaluated model: automatic output contained two system clusters, while 10 people actually spoke, and at least one known person was split across both clusters. Exact-count experiments did not restore trustworthy identities. Detailed aggregate evidence is in [FluidAudio diarization release validation](fluid-audio-diarization-release-validation-2026-07-16.md). The diarization fixture work is archival because the feature is permanently retired; ASR fixtures remain independently useful.

## Measurements per fixture

- source-audio SHA-256, duration, sample rate, channel count, and consent classification;
- exact app, FluidAudio, ASR model, and diarization model revisions;
- ASR word count, mean confidence, monotonic/in-range timestamps, wall time, calculated speed, and peak RSS;
- content preservation checklist for names, numbers, decisions, and action items;
- WER only where a normalized word transcript is available;
- diarization cluster count, DER, missed speech, false alarm, speaker confusion, overlap policy, wall time, calculated speed, and peak RSS;
- normalized-result hash from two warm-cache offline runs;
- artifact fingerprints and recovery outcome;
- no transcript text, participant names, audio path, or audio content in committed result files.

## Pass gates

- ASR and diarization each run at least 10x real time on the oldest supported Apple Silicon Mac;
- complete sequential post-processing stays below 20% of the recording duration;
- labeled diarization DER is at most 20% and automatic speaker-count error is at most one;
- no non-empty normalized ASR word is dropped during merge or speaker resolution;
- silence/music fixtures do not produce a material transcript or persistent speaker identity;
- the second run succeeds with network denied and produces the same normalized diarization result;
- cancellation or termination at every checkpoint leaves the source audio intact and a recoverable session;
- model footprint remains within the 600 MiB selected-variant budget;
- any material regression in names, numbers, decisions, or action items blocks default cutover even when aggregate speed passes.

## Result naming

Local detailed results use `FA-<fixture>-<machine>-<date>.json` outside Git. A sanitized aggregate may be committed under `docs/evidence/` only after review confirms that it contains no transcript text, participant names, local paths, or device identifiers.
