# MeetingScribe

Native macOS menu-bar application for recording meeting audio and producing local transcripts. The popover is focused on the recording workflow, while configuration lives in a native Settings window with General, Transcription, AI, Output, Calendar, and Advanced sections. The interface can follow the system language or explicitly use Slovak, Czech, or English; app-owned dynamic errors and native file-picker prompts follow the same selection, while provider and operating-system diagnostic details remain verbatim for troubleshooting.

## Current scope

The current implementation provides the menu-bar application shell, validated application state transitions, durable recording-session metadata, and two recording modes. Online/hybrid mode captures ScreenCaptureKit system audio to `system-16k.wav` plus an optional independent microphone track in `microphone-16k.wav`. Offline/microphone mode does not start ScreenCaptureKit and requires a verified microphone stream. Produced tracks use 16 kHz mono PCM and are finalized without a normal post-recording conversion; legacy sessions with CAF inputs remain recoverable. Local transcription uses FluidAudio `0.15.5` with the pinned Parakeet TDT 0.6B v3 Core ML bundle and writes timestamped per-source transcripts for the tracks that exist. Their normalized segments are merged deterministically into `transcript.json`; overlapping speech is preserved with its original source and speaker. Offline FluidAudio `community-1` diarization and a speaker editor are implemented, but real 10-speaker validation found the generated identities unreliable; anonymous speaker labels must not be treated as trustworthy people and further speaker-recognition work is paused. The microphone remains an independent local source, and existing speaker edits regenerate only derived `resolved-transcript.json` and Markdown while raw audio and transcripts remain unchanged. A consent-first Apple Calendar integration can add a confirmed event title and attendee display names to one recording. MeetingScribe can optionally analyze a valid transcript through Codex CLI or Claude Code and render the returned free-form Markdown into the completed note. Interrupted and failed sessions can recover from preserved audio, ASR, diarization, or resolution checkpoints. The original files are never deleted by recovery, including when a model is missing, transcription or diarization fails, AI analysis fails, Markdown export fails, or the application exits unexpectedly.

## Requirements

- macOS 14 or newer
- Xcode 26 or newer

## Runtime and architecture invariants

The current application target uses Hardened Runtime but does **not** enable App Sandbox. `MeetingScribe.entitlements` contains the audio-input and Calendar personal-information entitlements, and no `com.apple.security.app-sandbox` entitlement. The Calendar entitlement is required for hardened-runtime TCC prompting; the separate full-access usage description remains in `Info.plist`. The security-scoped bookmark used for a user-selected Markdown folder is still maintained for stable folder access, but it must not be interpreted as evidence that the process is sandboxed.

FluidAudio `0.15.5` is pinned exactly in both SwiftPM and the Xcode project. Runtime model bundles are installed only on explicit request under `~/Library/Application Support/MeetingScribe/Models/FluidAudio/`, verified against pinned manifests and SHA-256 checksums, load-tested before atomic promotion, and never embedded in the app.

Capture and transcript processing preserve these invariants:

- Incoming system and microphone buffers keep their native device format at capture boundaries, then a persistent `AVAudioConverter` downsamples and mixes them into separate 16 kHz mono signed-16-bit PCM WAV files. The microphone tap uses the input node's explicit hardware format, retries once with a fresh audio engine after an unsupported-format or no-buffer startup, and does not report success until the first buffers arrive. RMS and peak levels are measured from the same converted PCM that is written to disk and drive the live recording meter in the popover. The writer checkpoints the WAV header every second; recovery repairs an interrupted header from the physical PCM payload before opening the file.
- ScreenCaptureKit presentation timestamps and valid microphone mach host-time values are the only inputs to the shared capture timeline. Invalid microphone host time stays missing; `systemUptime` and sample time are not mixed into the timeline.
- Finalization chooses the earliest plausible captured track start as the timeline origin. A track's relative offset is `max(0, trackStart - timelineOrigin)`; the converter does not insert leading silence.
- Tracks present in the selected recording mode are transcribed sequentially. One loaded FluidAudio manager is reused between them and explicitly released after the complete session. A lightweight engine-neutral energy gate rejects completely silent or negligible tracks before inference; meaningful tracks are passed to Parakeet unchanged, preserving their original timeline.
- Merge is deterministic and loss-preserving: segments are normalized to millisecond precision and ordered by time with stable tie-breakers. Cross-track overlap is retained and labelled; acoustic echo is not deduplicated.
- Continuous utterances are a derived, fingerprinted view of that merged transcript. Grouping stays source-local and splits on explicit turn markers, speaker-label changes, overlap, configured silence, sentence pauses, and maximum duration. Invalid or missing turn artifacts fall back to the deterministic rules without rewriting raw transcript files.

## Build and test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project MeetingScribe.xcodeproj \
  -scheme MeetingScribe \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The state and session core can also be tested independently of the app bundle:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
  test --scratch-path .derivedData/swiftpm
```

Recording sessions are stored under `~/Library/Application Support/MeetingScribe/Recordings/`.

## Recovery and resilience

At startup, MeetingScribe scans recording manifests for interrupted capture, failed transcription, missing models, and incomplete Markdown export. The menu-bar UI requires each recoverable session to be either processed again or closed explicitly. Closing recovery marks the session as failed but does not delete any audio, transcript, analysis, or log file.

Recovery reuses valid `transcript.json`, `utterance-transcript.json`, `speaker-diarization.json`, `resolved-transcript.json`, and `analysis.json` checkpoints when available. Otherwise it repairs and inspects the directly captured `system-16k.wav` and resumes from the earliest missing stage without another conversion or unnecessary ASR pass. Fingerprints invalidate stale grouping, diarization, and resolution artifacts independently. Legacy schema-7 sessions with CAF inputs remain supported and are converted through the previous working-audio path. Recovery attempts, outcomes, diarization state, and optional source-audio cleanup are recorded in the session manifest. Schema 14 snapshots the selected transcription language, output language, Markdown file-name template, AI tool/prompt configuration, any explicitly confirmed Calendar metadata, grouping and diarization results, and engine-neutral provenance so a recovered meeting is not changed by later preference edits.

New recordings no longer create full-quality CAF files. The persisted **Delete legacy CAF after successful export** option applies to older recoverable sessions: it is disabled by default, requires explicit confirmation, and deletes CAF inputs only after the Markdown export, every available track transcript, and every 16 kHz finalized WAV have been verified. Failed or incomplete processing always preserves source audio.

Recording requires at least 1 GB of free space. Capacity is checked before creating a session and every five seconds while recording. If available storage becomes critical, capture is stopped and finalized through the normal safe-stop pipeline.

Each session has a newline-delimited JSON `processing.log`. It contains only technical events and bounded diagnostic fields such as timestamps, models, frame counts, sample rates, durations, and error domain/code pairs. Transcript text, audio data, AI requests, free-form error messages, meeting titles, file paths, and credentials are not logged; token-like values are redacted.

## Stabilization testing

The current standard SwiftPM baseline contains 179 tests, with 7 hardware-, credential-, model-, session-, stress-, or fixture-dependent tests skipped unless explicitly enabled and 0 failures. Coverage includes streaming conversion, checkpointed and repaired WAV headers, direct-PCM finalization, legacy CAF cleanup gates, manifest compatibility, Calendar consent and privacy boundaries, localized UI errors and Markdown, configurable file names, verified FluidAudio model management, deterministic continuous-utterance grouping, production diarization persistence, word-level speaker resolution, rename/merge regeneration, cancellation and resource release, diarization result validation and DER scoring, artifact invalidation, silent and sparse-audio gating, non-destructive FluidAudio revisions, and interrupted-recording recovery. The Xcode app and test targets use Swift 6 with complete strict-concurrency checking. GitHub Actions runs both the SwiftPM suite and the shared Xcode scheme on a pinned `macos-26` runner, so the SwiftUI application layer cannot be skipped by a core-only build. The opt-in long-session test generates one hour of 16 kHz mono Int16 output, approximately 115 MB per track; it passed on 2026-07-14. These automated counts describe the current working tree; release acceptance still requires the labeled quality and manual hardware matrix below.

AppState-level integration tests cover recovery from a preserved merged transcript and a safe automatic stop after required system-audio capture fails. These tests verify the resulting Markdown, manifest, processing log, preserved audio, and recovery status rather than only isolated model types.

Legacy-pipeline forced-termination tests recovered both a 172.7-second system-only session and a 102-second dual-track session. The dual-track recovery preserved both original CAF files, generated both 16 kHz working WAV files, transcribed both tracks, merged 10 segments, exported Markdown, and completed the recovery audit. Recovery also infers the relative microphone start from file end times and durations because CAF does not retain presentation timestamps after a hard crash.

The alternative **Close without deleting files** path has also been validated after a real forced termination. It closes the recovery audit without processing and preserves both original CAF tracks.

The stably signed build now includes the Hardened Runtime audio-input entitlement. A real dual-track run recorded and finalized both system audio and microphone audio, created both 16 kHz working WAV files, transcribed both tracks without warnings, merged 15 segments, and exported Markdown.

A five-minute local-video run with built-in speakers also completed on Large v3 Turbo with automatic Slovak detection, readable dual-track audio, 155 ordered merged segments, and Markdown output. Speaker playback was audibly duplicated through the microphone track, documenting the expected echo behavior when headphones are not used.

During a real sleep/wake run, ScreenCaptureKit reported that no display was available as the Mac entered sleep. MeetingScribe stopped safely, preserved both CAF tracks, offered recovery after wake, and completed dual-track Large v3 Turbo processing. Recovery prefers exact persisted capture timestamps after a safe stop and falls back to CAF timestamp inference only after a hard crash.

AirPods connect/disconnect was also validated during active recording. Microphone capture automatically recreated its engine for the current route, resumed after each change, and limited gaps within the microphone timeline to approximately 2.43 seconds while system audio continued.

An external USB-input change was validated during active recording in both directions. Microphone capture resumed after switching from the built-in input to USB and back, with approximately 1.74 seconds of gaps across the microphone timeline and no finalization or transcription warnings.

Czech and mixed CZ/SK Large v3 Turbo samples were evaluated. Names, numbers, decisions, and action items were substantially preserved, and mixed content was not translated into English. Automatic mode nevertheless labelled standalone Czech and every mixed segment as Slovak and mixed Czech/Slovak word forms. MeetingScribe now offers a persisted **Auto / Čeština / Slovenčina / English** transcription-language selector. A real explicit-Czech run stored and forwarded `cs` to both tracks and produced predominantly intelligible Czech with more consistent Czech word forms. Auto remains useful for unknown or mixed meetings but reports one dominant language per track rather than per segment.

Parakeet processes the untouched finalized WAV timeline. A 64 ms RMS gate prevents model inference for completely silent or negligible tracks without compacting sparse speech or remapping timestamps. `TranscriptSanitizer` additionally rejects empty and known non-speech markers. Opt-in production fixtures cover Czech, Slovak, mixed-language, English, silence, sparse audio, and long input.

A second 62-minute legacy-pipeline signed-build run validated the optimized transcription path end to end. Transcription completed in 11 minutes 19 seconds: 8 minutes 7 seconds for the highly active system track and 3 minutes 11 seconds for the microphone track, which skipped 2,781 seconds of inactive input. Across 58 one-minute resource samples, CPU averaged 4.06%, RSS stayed between approximately 34 and 48 MB, and physical footprint changed from 39 MB to 40 MB. Both CAF files grew continuously, more than 8.8 GiB remained free, finalization and export completed without warnings, and no artifact was deleted. The complete phase 10 hardware and application matrix is accepted for that build; the new direct-PCM capture path still requires the manual hardware checks below. Detailed evidence is in [the phase 10 results](docs/phase-10-results.md).

## Apple Calendar metadata

**Phase A is complete.** The consent-first event and participant snapshot flow described below is implemented and validated. **Phase B remains deferred and is blocked on a more reliable diarization model.** The persistence and editor contracts exist, but the current model failed real multi-speaker speaker-count and identity-consistency validation, so attendee-to-speaker mapping must not be built on its labels. The decision is recorded in [Apple Calendar and participants](docs/apple-calendar-participants.md) and [Speaker recognition and management](docs/speaker-recognition-management-plan.md).

The Apple Calendar integration is off by default. MeetingScribe does not query EventKit at launch: the user must first enable the integration and grant macOS full Calendar access in **MeetingScribe Settings → Calendar**, then explicitly choose an event for the current meeting. The menu-bar Calendar action routes to that Settings section until access is configured; the event picker itself contains no integration or permission controls. The picker is an independent foreground window that remains open until it is confirmed or cancelled. After either action, the recording popover is shown again. The picker is available before and during recording. Choosing an event never silently replaces a manually entered meeting title, and every attendee starts unchecked so the user confirms who actually participated.

Only the confirmed snapshot is written to schema-13 session metadata: the event title, start and end time, confirmation time, confirmed attendee display names, and the per-meeting AI-sharing choice. MeetingScribe does not persist attendee email addresses, event or calendar identifiers, calendar names, locations, notes, URLs, organizer data, or the unconfirmed candidate list. Turning the integration off prevents future reads without altering snapshots already stored with recordings.

Confirmed attendee names populate Markdown participants. They remain local unless AI analysis is enabled and the user separately opts to share the selected names for that meeting. Experimental anonymous diarization remains technically available, but its labels are not reliable identities. Speaker-to-person assignment remains outside Phase A and is blocked rather than merely awaiting confirmation UI.

## Optional AI analysis

AI analysis is opt-in and runs through a locally installed, already authenticated Codex CLI or Claude Code executable. MeetingScribe launches the selected tool directly without a shell, sends the prompt and transcript through standard input, disables unnecessary file tools, and validates a small structured transport response containing one free-form Markdown fragment. Recorded audio remains local. The transcript, meeting metadata, and explicitly shared participant display names may be sent to the provider used by the selected CLI tool.

The analysis prompt, executable, and tool are configurable in Settings. The model menu offers provider-specific presets for Codex and Claude Code, an automatic tool default, and a custom model identifier; each tool remembers its own model choice. Tool verification checks the executable, version, and cached CLI authentication without sending meeting content or making a model request. If sign-in is missing, Settings shows a copyable login command and can open Terminal without executing a hidden shell script. The prompt may define any Markdown structure and supports `{{output_language}}`, `{{meeting_title}}`, and `{{recording_id}}`. Long transcripts are split at segment boundaries and partial Markdown analyses are consolidated with the same prompt. Each recording snapshots its analysis configuration so later preference changes cannot alter recovery output.

Successful output is persisted as a versioned `analysis.json` artifact and inserted only between `meetingscribe:ai-analysis:start` and `meetingscribe:ai-analysis:end` markers. The YAML frontmatter includes the analysis date, tool, and optional model. If the executable is missing, authentication fails, the command times out, or the response is invalid, transcription and the base Markdown output still complete and the failure is recorded in the session manifest.

## Markdown and Obsidian output

MeetingScribe always writes a Markdown result after successful transcription. By default it is stored in the recording's session directory. Use **Settings → Output → Choose folder…** to select an Obsidian folder or another destination. The selection is persisted as a security-scoped bookmark and can be reset to the default session folder.

The default file name follows `YYYY-MM-DD HH-mm - Meeting title.md`. Settings can customize it with `{date}`, `{time}`, `{title}`, and `{id}` tokens. Existing files are never overwritten; a numeric suffix is added on collision. When the selected folder is inside a directory containing `.obsidian`, the completed result can be opened through an `obsidian://open` URI. Finder reveal and normal file opening are also available. Markdown headings and AI analysis follow the independently selected Slovak, Czech, or English output language.

The Obsidian action is a best-effort handoff, not a vault sync or import API. MeetingScribe locates the nearest ancestor containing `.obsidian` and builds `obsidian://open` from the vault directory name plus the note's relative path. Obsidian must already know that local vault and be registered as the URI handler. Two registered vaults with the same directory name can be ambiguous, and MeetingScribe cannot confirm which one Obsidian selects; use normal file opening or Finder reveal in that case.

## FluidAudio models

Models are not embedded in the app or committed to Git. Settings manages two pinned directory bundles independently: Parakeet TDT 0.6B v3 for transcription and offline `community-1` for anonymous speaker diarization. Download, import, verification/repair, cancellation, and deletion validate the complete manifest before a bundle becomes active.

Parakeet is the only transcription runtime. Offline `community-1` remains connected to post-recording processing, but it failed production speaker-quality validation and must not be treated as reliable speaker identity. Missing or failed diarization falls back to deterministic continuous-utterance grouping. Old transcript and turn-artifact JSON remains readable and exportable without an old engine or model. The paused diarization decision and independent ASR status are documented in [the FluidAudio-only migration plan](docs/fluid-audio-migration-plan.md).

The real inference test is optional and skips when no local model or sample is supplied:

```sh
MEETINGSCRIBE_FA3_MODEL_BUNDLE=/path/to/parakeet-v3-bundle \
MEETINGSCRIBE_FA3_AUDIO_SK=/path/to/slovak-16-kHz-mono.wav \
MEETINGSCRIBE_FA3_AUDIO_SILENCE=/path/to/silence-16-kHz-mono.wav \
MEETINGSCRIBE_FA3_AUDIO_SPARSE=/path/to/sparse-16-kHz-mono.wav \
swift test --filter FluidAudioTranscriptionServiceTests/testOptInRealModelFixtureMatrixProducesValidWordTimings
```

The transcript merger can also be verified against an existing recording session without modifying it:

```sh
MEETINGSCRIBE_SESSION_PATH="$HOME/Library/Application Support/MeetingScribe/Recordings/<session-id>" \
swift test --filter TranscriptMergerTests/testMergesExistingSessionWhenPathIsProvided
```

The same environment variable enables the real-session Markdown renderer test:

```sh
MEETINGSCRIBE_SESSION_PATH="$HOME/Library/Application Support/MeetingScribe/Recordings/<session-id>" \
swift test --filter MarkdownRendererTests/testRendersExistingSessionWhenPathIsProvided
```

## Recording permissions during development

macOS binds Screen & System Audio Recording and Microphone approvals to the application's code-signing identity. Configure an Apple Development or Personal Team signing identity in Xcode for stable permissions across builds.

With an ad-hoc `Sign to Run Locally` build, each rebuild changes the app's designated code requirement. Reset the stale permission before testing the newly built binary, grant it again, and relaunch the same binary without rebuilding:

```sh
tccutil reset ScreenCapture com.martinhostak.MeetingScribe
tccutil reset Microphone com.martinhostak.MeetingScribe
```

Online/hybrid mode requires system audio and treats the microphone as optional: if its permission is denied or no usable input is available, MeetingScribe keeps recording the system-audio track and records the microphone failure in the session manifest. Offline/microphone mode starts no ScreenCaptureKit capture and requires the microphone to deliver real buffers before the session can begin.
