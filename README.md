# MeetingScribe

Native macOS menu-bar application for recording meeting audio and producing local transcripts. The popover is focused on the recording workflow, while configuration lives in a native Settings window with General, Readiness, Transcription, AI, Output, Calendar, and Advanced sections. The interface can follow the system language or explicitly use Slovak, Czech, or English; app-owned dynamic errors and native file-picker prompts follow the same selection, while provider and operating-system diagnostic details remain verbatim for troubleshooting.

## Current scope

The current implementation provides the menu-bar application shell, validated application state transitions, durable recording-session metadata, and two recording modes. Online/hybrid mode captures ScreenCaptureKit system audio to `system-16k.wav` plus an optional independent microphone track in `microphone-16k.wav`. Offline/microphone mode does not start ScreenCaptureKit and requires a verified microphone stream. Produced tracks use 16 kHz mono PCM and are finalized without a normal post-recording conversion; legacy sessions with CAF inputs remain recoverable. Local transcription uses FluidAudio `0.15.5` with the pinned Parakeet TDT 0.6B v3 Core ML bundle and writes timestamped per-source transcripts for the tracks that exist. Their normalized segments are merged deterministically into `transcript.json`; overlapping speech is preserved with its original source. The `community-1` diarization runtime and speaker editor are permanently removed after failing real multi-speaker validation. Old diarization files are preserved as untouched session artifacts, while new recordings use deterministic source-local grouping and never claim speaker identity. A consent-first Apple Calendar integration can add a confirmed event title, attendee display names, and optional event description to one recording. MeetingScribe can optionally analyze a valid transcript through Codex CLI or Claude Code and render the returned free-form Markdown into the completed note. Interrupted and failed sessions can recover from preserved audio, ASR, and completed output checkpoints. The original files are never deleted by recovery, including when a model is missing, transcription or AI analysis fails, Markdown export fails, or the application exits unexpectedly.

## Processing notifications

Enable processing notifications in **Settings → General** to request macOS permission. Each processing attempt sends one result after the output is saved or processing fails. The notification includes the meeting title; successful results open the Markdown file, while failures open the recording overview. Notifications use the selected interface language (Slovak, Czech, or English).

Failure notifications identify the affected step: audio preparation, transcription, AI analysis, or saving/export. A failed AI analysis remains a partial result even if Markdown was exported. An intentionally disabled analysis is not an error. Notifications also cover recovery and explicit reprocessing; scans of existing recordings do not generate notifications. Denied system permission does not interrupt processing. macOS notification settings and Focus determine whether a banner is displayed.

These notifications report completed or failed attempts. They do not impose a timeout on a transcription that is still running.

## Processing queue

Stopping a recording hands it to a processing queue rather than blocking the application, so the next meeting can be recorded while the previous one is still being transcribed. The menu-bar popover and the Recordings overview list every queued, running, paused, completed and failed attempt with the stage it reached.

One heavy stage runs at a time. A resource governor holds the queue when starting another would compete with capture or with the machine: while a recording is being prepared, is running or is stopping, when capture itself is unhealthy, under memory pressure, under thermal pressure, or below the configured storage reserve. Holding is explained rather than silent — a held row states the unmet condition, and the queue resumes on its own once the condition clears. A pause that arrives while a worker is running cancels that worker, waits for it to exit and releases its model before the job is reported paused, so a paused queue is not still holding a loaded ASR model.

An attempt checkpoints each completed stage into the session manifest. A queue interrupted by quitting or by a crash resumes from those checkpoints at the next launch, and a validated `transcript.json` is reused rather than transcribed again.

## Requirements

- macOS 14 or newer
- Xcode 26 or newer

## Runtime and architecture invariants

The current application target uses Hardened Runtime but does **not** enable App Sandbox. `MeetingScribe.entitlements` contains the audio-input and Calendar personal-information entitlements, and no `com.apple.security.app-sandbox` entitlement. The Calendar entitlement is required for hardened-runtime TCC prompting; the separate full-access usage description remains in `Info.plist`. The security-scoped bookmark used for a user-selected Markdown folder is still maintained for stable folder access, but it must not be interpreted as evidence that the process is sandboxed.

FluidAudio `0.15.5` is pinned exactly in both SwiftPM and the Xcode project. Runtime model bundles are installed only on explicit request under `~/Library/Application Support/MeetingScribe/Models/FluidAudio/`, verified against pinned manifests and SHA-256 checksums, load-tested before atomic promotion, and never embedded in the app.

Capture and transcript processing preserve these invariants:

- Incoming system and microphone buffers keep their native device format at capture boundaries, then a persistent `AVAudioConverter` downsamples and mixes them into separate 16 kHz mono signed-16-bit PCM WAV files. The microphone tap uses the input node's explicit hardware format, retries once with a fresh audio engine after an unsupported-format or no-buffer startup, and does not report success until the first buffers arrive. RMS and peak levels are measured from the same converted PCM that is written to disk and drive the live recording meter in the popover. The writer checkpoints the WAV header every second; recovery repairs an interrupted header from the physical PCM payload before opening the file.
- ScreenCaptureKit presentation timestamps and valid microphone mach host-time values are the only inputs to the shared capture timeline. Invalid microphone host time stays missing; `systemUptime` and sample time are not mixed into the timeline.
- Finalization chooses the earliest plausible captured track start as the timeline origin. A microphone start more than 60 seconds from the system-audio host-time is treated as implausible and omitted from the shared timeline. A track's relative offset is `max(0, trackStart - timelineOrigin)`; the converter does not insert leading silence.
- Tracks present in the selected recording mode are transcribed sequentially. One loaded FluidAudio manager is reused between them and explicitly released after the complete session. A lightweight engine-neutral energy gate rejects completely silent or negligible tracks before inference; meaningful tracks are passed to Parakeet unchanged, preserving their original timeline.
- Merge is deterministic and loss-preserving: segments are normalized to millisecond precision and ordered by time with stable tie-breakers. Cross-track overlap is retained and labelled; acoustic echo is not deduplicated.
- Continuous utterances are a derived, fingerprinted view of that merged transcript. Current production grouping stays source-local: a block changes only when the recorded source changes, preserving overlap without inferring individual people. It never rewrites raw transcript files.

## Build and test

The commands below validate compilation and tests only. Their unsigned app bundle must not be installed or launched for normal use.

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

## First-run readiness test

The setup guide's final step can run a real 10-second capture through the normal recording, finalization, recovery, transcription, and Markdown path. The test uses a clearly named `MeetingScribe Setup Test` session, does not consume a draft meeting title or selected Calendar event, and disables AI for that session. It shows the artifact destination before it starts, a countdown and manual stop button while recording, and separate buffer/activity results for system audio and microphone.

Timeout, a second stop click, and closing the setup window all stop capture once. Processing remains visible in the normal application status and Recordings overview. A missing transcription model still produces an audio result marked `Transcription not verified`; a ready model also produces a local transcript and Markdown export. Artifacts are retained under the normal session rules and are never automatically deleted by the test.

### Signed local installation

For a runnable local build, use a clean checkout of the intended commit and the manual-signing command in [AGENTS.md](AGENTS.md). The shared [`Config/Signing.xcconfig`](Config/Signing.xcconfig) requires manual signing for both Xcode targets. Copy [`Config/Signing.local.xcconfig.example`](Config/Signing.local.xcconfig.example) to the ignored `Config/Signing.local.xcconfig` and enter a valid local Apple Development certificate fingerprint and Team ID. Verify that identity through the login Keychain before building; Codex must run signing and trust checks outside its workspace sandbox. A contributor uses their own local override without changing the shared configuration.

After a `main` update, build the exact `origin/main` commit, verify the bundle with `codesign --verify --deep --strict --verbose=4`, check its authority and Team ID, and extract its signing certificate to verify the SHA-1 fingerprint. Stop existing MeetingScribe instances, replace `/Applications/MeetingScribe.app`, repeat all signature checks on the installed bundle, and launch it. Confirm that only that installed app path is running. Stop if any check fails. The fingerprint each check compares against is the one in the ignored `Config/Signing.local.xcconfig`, so every contributor verifies against their own identity.

If Xcode reports an unaccepted license, open Xcode or run `sudo xcodebuild -license` and review and accept it before building.

Recording sessions are stored under `~/Library/Application Support/MeetingScribe/Recordings/`.

## Recovery and resilience

Microphone capture follows the macOS default **input** device. Select the microphone under **System Settings → Sound → Input**; selecting a headset for sound output alone does not select its microphone.

If microphone startup reports an unsupported format or Core Audio `kAudioHardwareNotRunningError` (`1937010544`, `'stop'`), MeetingScribe waits 0.5 seconds and retries once with a new audio engine and a fresh input format. Startup succeeds only after microphone buffers arrive. Cancellation stops the retry, and a persistent failure remains visible while system-audio recording can continue.

At startup, MeetingScribe scans recording manifests for interrupted capture, failed transcription, missing models, and incomplete Markdown export. The menu-bar UI requires each recoverable session to be either processed again or closed explicitly. Closing recovery marks the session as failed but does not delete any audio, transcript, analysis, or log file.

Recovery reuses valid `transcript.json`, `utterance-transcript.json`, and `analysis.json` checkpoints when available. Otherwise it repairs and inspects the directly captured `system-16k.wav` and resumes from the earliest missing stage without another conversion or unnecessary ASR pass. Historical `speaker-diarization.json` and `resolved-transcript.json` files are preserved but never read or regenerated. Legacy schema-7 sessions with CAF inputs remain supported and are converted through the previous working-audio path. Recovery attempts, outcomes, optional source-audio cleanup, and the optional notes artifact are recorded in the session manifest; `notes.md` is never deleted by recovery. Current session schema 16 snapshots the selected transcription language, output language, Markdown file-name template, AI tool/prompt configuration, any explicitly confirmed Calendar metadata, grouping results, and engine-neutral provenance so a recovered meeting is not changed by later preference edits.

New recordings no longer create full-quality CAF files. The persisted **Delete legacy CAF after successful export** option applies to older recoverable sessions: it is disabled by default, requires explicit confirmation, and deletes CAF inputs only after the Markdown export, every available track transcript, and every 16 kHz finalized WAV have been verified. Failed or incomplete processing always preserves source audio.

Recording requires at least 1 GB of free space. Capacity is checked before creating a session and every five seconds while recording. If available storage becomes critical, capture is stopped and finalized through the normal safe-stop pipeline.

Each session has a newline-delimited JSON `processing.log`. It contains only technical events and bounded diagnostic fields such as timestamps, models, frame counts, sample rates, durations, and error domain/code pairs. Transcript text, audio data, AI requests, free-form error messages, file paths, and credentials are not logged; token-like values are redacted. Meeting titles are redacted when they are long enough to be safely distinguished from ordinary numeric or diagnostic values; very short titles can remain in a diagnostic value to avoid corrupting unrelated data.

## Stabilization testing

Both suites are green as of 2026-09-19: 407 SwiftPM tests and 401 Xcode-scheme tests, 6 optional tests skipped in each, 0 failures. The two now run the same 37 test classes; until `ReadinessTests` was added to the Xcode target it did not, so a green scheme run was not the same evidence as a green CI run. Test counts here date quickly and are not a target to hold constant. Current coverage includes streaming conversion, checkpointed and repaired WAV headers, direct-PCM finalization, legacy CAF cleanup gates, manifest compatibility, Calendar consent and privacy boundaries, localized UI errors and Markdown, configurable file names, verified ASR model management, deterministic continuous-utterance grouping, cancellation and resource release, silent and sparse-audio gating, non-destructive FluidAudio revisions, and interrupted-recording recovery. The Xcode app and test targets use Swift 6 with complete strict-concurrency checking. GitHub Actions runs both the SwiftPM suite and the shared Xcode scheme on a pinned `macos-26` runner, so the SwiftUI application layer cannot be skipped by a core-only build. The opt-in long-session test generates one hour of 16 kHz mono Int16 output, approximately 115 MB per track; it passed on 2026-07-14. These automated results describe that source commit; release acceptance still requires the [labeled quality fixtures](docs/evidence/fluid-audio-acceptance-fixture-matrix.md) and [manual hardware protocol](docs/phase-10-stabilization.md).

AppState-level integration tests cover recovery from a preserved merged transcript and a safe automatic stop after required system-audio capture fails. These tests verify the resulting Markdown, manifest, processing log, preserved audio, and recovery status rather than only isolated model types.

### Historical hardware evidence

The following results describe earlier builds, including the removed Whisper/Large v3 Turbo pipeline and CAF capture. They are retained as historical evidence and do not establish current FluidAudio or direct-PCM hardware acceptance.

Legacy-pipeline forced-termination tests recovered both a 172.7-second system-only session and a 102-second dual-track session. The dual-track recovery preserved both original CAF files, generated both 16 kHz working WAV files, transcribed both tracks, merged 10 segments, exported Markdown, and completed the recovery audit. Recovery also infers the relative microphone start from file end times and durations because CAF does not retain presentation timestamps after a hard crash.

The alternative **Close without deleting files** path has also been validated after a real forced termination. It closes the recovery audit without processing and preserves both original CAF tracks.

The stably signed build now includes the Hardened Runtime audio-input entitlement. A real dual-track run recorded and finalized both system audio and microphone audio, created both 16 kHz working WAV files, transcribed both tracks without warnings, merged 15 segments, and exported Markdown.

A five-minute local-video run with built-in speakers also completed on Large v3 Turbo with automatic Slovak detection, readable dual-track audio, 155 ordered merged segments, and Markdown output. Speaker playback was audibly duplicated through the microphone track, documenting the expected echo behavior when headphones are not used.

During a real sleep/wake run, ScreenCaptureKit reported that no display was available as the Mac entered sleep. MeetingScribe stopped safely, preserved both CAF tracks, offered recovery after wake, and completed dual-track Large v3 Turbo processing. Recovery prefers exact persisted capture timestamps after a safe stop and falls back to CAF timestamp inference only after a hard crash.

AirPods connect/disconnect was also validated during active recording. Microphone capture automatically recreated its engine for the current route, resumed after each change, and limited gaps within the microphone timeline to approximately 2.43 seconds while system audio continued.

An external USB-input change was validated during active recording in both directions. Microphone capture resumed after switching from the built-in input to USB and back, with approximately 1.74 seconds of gaps across the microphone timeline and no finalization or transcription warnings.

Czech and mixed CZ/SK Large v3 Turbo samples were evaluated. Names, numbers, decisions, and action items were substantially preserved, and mixed content was not translated into English. Automatic mode nevertheless labelled standalone Czech and every mixed segment as Slovak and mixed Czech/Slovak word forms. MeetingScribe now offers a persisted **Auto / Čeština / Slovenčina / English** transcription-language selector. A real explicit-Czech run stored and forwarded `cs` to both tracks and produced predominantly intelligible Czech with more consistent Czech word forms. Auto remains useful for unknown or mixed meetings but reports one dominant language per track rather than per segment.

Parakeet processes the untouched finalized WAV timeline. A 64 ms RMS gate prevents model inference for completely silent or negligible tracks without compacting sparse speech or remapping timestamps. `TranscriptSanitizer` additionally rejects empty and known non-speech markers. Opt-in production fixtures cover Czech, Slovak, mixed-language, English, silence, sparse audio, and long input.

A second 62-minute legacy-pipeline signed-build run validated the optimized transcription path end to end. Transcription completed in 11 minutes 19 seconds: 8 minutes 7 seconds for the highly active system track and 3 minutes 11 seconds for the microphone track, which skipped 2,781 seconds of inactive input. Across 58 one-minute resource samples, CPU averaged 4.06%, RSS stayed between approximately 34 and 48 MB, and physical footprint changed from 39 MB to 40 MB. Both CAF files grew continuously, more than 8.8 GiB remained free, finalization and export completed without warnings, and no artifact was deleted. The complete phase 10 hardware and application matrix is accepted for that build; the direct-PCM capture path requires separate [manual hardware checks](docs/phase-10-stabilization.md). Detailed evidence is in [the phase 10 results](docs/phase-10-results.md).

## Apple Calendar metadata

**Phase A is complete.** The consent-first event and participant snapshot flow described below is implemented and validated. **Calendar Phase B is permanently retired.** The current model failed real multi-speaker speaker-count and identity-consistency validation, so attendee-to-speaker mapping must not be built on its labels. The decision is recorded in [Apple Calendar and participants](docs/apple-calendar-participants.md) and [Speaker recognition and management](docs/speaker-recognition-management-plan.md).

The Apple Calendar integration is off by default. MeetingScribe does not query EventKit at launch: the user must first enable the integration and grant macOS full Calendar access in **MeetingScribe Settings → Calendar**, then explicitly choose an event for the current meeting. The menu-bar Calendar action routes to that Settings section until access is configured; the event picker itself contains no integration or permission controls. The picker is an independent foreground window that remains open until it is confirmed or cancelled. After either action, the recording popover is shown again. The picker is available before and during recording. Choosing an event never silently replaces a manually entered meeting title, and every attendee starts unchecked so the user confirms who actually participated.

The confirmed snapshot is written to current schema-16 session metadata: event title, start and end time, confirmation time, selected attendee display names, the participant-sharing flag, and an optional event description. The picker pre-fills the description from Calendar notes and enables **Include event description** when one is available; the user can edit it or disable inclusion before confirming. Included text is saved with the recording and exported as `calendar_description` in Markdown frontmatter. It can contain any details present in the original notes or entered by the user.

MeetingScribe does not separately persist attendee email addresses, event or calendar identifiers, calendar names, locations, URLs, organizer fields, or the unconfirmed candidate list. This field restriction does not sanitize those details out of an included free-form description. Turning the integration off prevents future reads without altering saved snapshots.

Selecting attendees and confirming the picker saves their display names and enables their use in AI analysis; the current picker has no additional participant-sharing toggle. Names populate Markdown participants. When AI analysis is enabled, selected names and the included event description are passed to the chosen CLI provider along with the transcript. Older snapshots with participant sharing disabled continue to withhold those names; the description is independent of that flag. MeetingScribe does not generate diarization labels or attendee-to-speaker assignments.

## Optional AI analysis

AI analysis is opt-in and runs through a locally installed, already authenticated Codex CLI or Claude Code executable. MeetingScribe launches the selected tool directly without a shell, sends the prompt and transcript through standard input, disables unnecessary file tools, and validates a small structured transport response containing one free-form Markdown fragment. Recorded audio remains local. The transcript, meeting metadata, and confirmed participant display names may be sent to the provider used by the selected CLI tool.

When meeting notes exist, they are attached to every analysis request. The analysis keeps the structure defined by the prompt template and preserves every note in its original wording and order. Each note is expanded with facts from the transcript and cited meeting timestamps; a note without support in the transcript remains in the output and is marked as the user's own note. In practice, the provider adds a note-by-note section listing that evidence. A `[hh:mm:ss]` mark written with the timestamp button refers to the recording timeline, the same zero the transcript uses. The custom prompt can reference them with `{{user_notes}}`. Notes are sent to the provider only when AI analysis is enabled.

The analysis prompt, executable, and tool are configurable in Settings. The model menu offers provider-specific presets for Codex and Claude Code, an automatic tool default, and a custom model identifier; each tool remembers its own model choice. Tool verification checks the executable, version, and cached CLI authentication without sending meeting content or making a model request. If sign-in is missing, Settings shows a copyable login command and can open Terminal without executing a hidden shell script. The prompt may define any Markdown structure and supports `{{output_language}}`, `{{meeting_title}}`, and `{{recording_id}}`. Long transcripts are split into bounded requests with overlapping context. Oversized individual segments are split too. Requests preserve the original meeting timestamps and audio-source roles; the prompt tells the provider not to count repeated context twice. Partial Markdown analyses are consolidated with the same prompt. Each recording snapshots its analysis configuration so later preference changes cannot alter recovery output.

Each CLI request has a 600-second (10-minute) timeout; a multi-request analysis can take longer overall. Claude runs with file tools, slash commands, external MCP configuration, and settings sources disabled. If Claude reports expired or invalid authentication, the recording shows a copyable login command. Run that command in Terminal, complete sign-in, and retry AI analysis; the recording and transcript remain saved. Recording error text is selectable for troubleshooting, and raw Claude error output containing meeting content is not surfaced.

Successful output is persisted as a versioned `analysis.json` artifact and inserted only between `meetingscribe:ai-analysis:start` and `meetingscribe:ai-analysis:end` markers. The YAML frontmatter includes the analysis date, tool, and optional model. If the executable is missing, authentication fails, the command times out, or the response is invalid, transcription and the base Markdown output still complete and the failure is recorded in the session manifest.

## Markdown and Obsidian output

MeetingScribe always writes a Markdown result after successful transcription. By default it is stored in the recording's session directory. Use **Settings → Output → Choose folder…** to select an Obsidian folder or another destination. The selection is persisted as a security-scoped bookmark and can be reset to the default session folder.

The default file name follows `YYYY-MM-DD HH-mm - Meeting title.md`. Settings can customize it with `{date}`, `{time}`, `{title}`, and `{id}` tokens. Existing files are never overwritten; a numeric suffix is added on collision. When the selected folder is inside a directory containing `.obsidian`, the completed result can be opened through an `obsidian://open` URI. Finder reveal and normal file opening are also available. Markdown headings and AI analysis follow the independently selected Slovak, Czech, or English output language.

When meeting notes exist, they are exported between the reserved `meetingscribe:user-notes:start` and `meetingscribe:user-notes:end` markers, and the Markdown frontmatter records the artifact with `notes: true`.

The Obsidian action is a best-effort handoff, not a vault sync or import API. MeetingScribe locates the nearest ancestor containing `.obsidian` and builds `obsidian://open` from the vault directory name plus the note's relative path. Obsidian must already know that local vault and be registered as the URI handler. Two registered vaults with the same directory name can be ambiguous, and MeetingScribe cannot confirm which one Obsidian selects; use normal file opening or Finder reveal in that case.

## FluidAudio models

Models are not embedded in the app or committed to Git. Settings manages the pinned Parakeet TDT 0.6B v3 bundle for transcription. Download, import, verification/repair, cancellation, and deletion validate the complete manifest before the bundle becomes active.

Parakeet is the only active inference runtime. Offline `community-1` is permanently retired from new recordings and has no Settings control because it failed production speaker-quality validation. Old transcript and turn-artifact JSON remains readable and exportable without an old engine or model. The permanent diarization decision and independent ASR status are documented in [the FluidAudio-only migration plan](docs/fluid-audio-migration-plan.md).

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

Use the stable signed local-installation workflow above for recording permission tests. The exact maintainer signing requirements and verification gates are maintained in [AGENTS.md](AGENTS.md). An unsigned CI bundle or ad-hoc build is not the runnable local deliverable.

Online/hybrid mode requires system audio and treats the microphone as optional: if its permission is denied or no usable input is available, MeetingScribe keeps recording the system-audio track and records the microphone failure in the session manifest. Offline/microphone mode starts no ScreenCaptureKit capture and requires the microphone to deliver real buffers before the session can begin.
