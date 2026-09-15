# Speaker recognition and management — archival record

Status: permanently retired on 2026-09-15. This is historical implementation and validation evidence, not a description of a shipped feature.

## Product decision

A signed 102.04-minute Microsoft Teams meeting with mixed Czech/Slovak speech and 10 actual speakers rejected the FluidAudio `community-1` candidate for production speaker recognition:

- automatic diarization returned only two system-speaker clusters;
- direct review found one real person split between both clusters;
- forcing nine or ten clusters did not establish consistent identities;
- the constrained variants disagreed on 270.545 seconds of their shared speech timeline after optimal anonymous-label alignment.

The speaker-count and identity-consistency gates therefore failed. The project permanently removed the diarization runtime, its model-management controls, speaker-resolution code, speaker editor, and Calendar attendee-to-speaker mapping. Parakeet ASR remains accepted independently.

## Current behavior and compatibility

New recordings contain timestamped ASR transcripts, the deterministic overlap-preserving `transcript.json`, and source-local `utterance-transcript.json` grouping. The grouping preserves system and microphone source boundaries without inferring an individual speaker identity.

Historical `speaker-diarization.json`, `resolved-transcript.json`, and `speaker-turns.json` files are retained untouched within existing sessions. They are not read for output, regenerated during recovery, or exposed in the UI. Old session manifests continue to decode without loading an obsolete model or runtime.

Calendar attendee names are user-confirmed meeting metadata only. MeetingScribe does not associate them with audio or transcript speakers.

## Historical evidence

The former implementation used offline `community-1` diarization after sequential ASR, stored anonymous session-local clusters, resolved timestamped transcript words against those turns, and offered a session-local editor. It never claimed biometric identification or cross-session voice recognition. This work was removed because the validation above showed that its anonymous labels did not consistently represent people.

The historical spike, data contracts, and acceptance criteria are retained only to document the evaluation and rejection:

- [FluidAudio diarization spike](s1-fluid-audio-diarization-spike.md)
- [FluidAudio diarization release validation](evidence/fluid-audio-diarization-release-validation-2026-07-16.md)
- [FluidAudio migration record](fluid-audio-migration-plan.md)

No diarization or speaker-management release gate is active.
