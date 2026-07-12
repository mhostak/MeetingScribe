# MeetingScribe

Native macOS menu-bar application for recording meeting audio and producing local transcripts.

## Current scope

The current implementation provides the menu-bar application shell, validated application state transitions, durable recording-session metadata, ScreenCaptureKit-based system audio capture to `system.caf`, and a separate microphone track in `microphone.caf`. After recording, both available tracks are validated and converted to 16 kHz mono PCM WAV files (`system-16k.wav` and `microphone-16k.wav`). Local transcription uses the official whisper.cpp v1.8.1 XCFramework with Metal acceleration and writes separate timestamped `system-transcript.json` and `microphone-transcript.json` files. Their normalized segments are merged deterministically into `transcript.json`; overlapping speech is preserved with its original source and speaker. MeetingScribe can optionally analyze the transcript with OpenAI and then renders YAML-frontmatter Markdown with structured meeting notes and timestamped speakers. Interrupted and failed sessions can be recovered from preserved audio or transcript artifacts. The original files are never deleted by recovery, including when the model is missing, transcription fails, AI analysis fails, Markdown export fails, or the application exits unexpectedly.

## Requirements

- macOS 14 or newer
- Xcode 26 or newer

## Runtime and architecture invariants

The current application target uses Hardened Runtime but does **not** enable App Sandbox. `MeetingScribe.entitlements` contains the audio-input entitlement and no `com.apple.security.app-sandbox` entitlement. The security-scoped bookmark used for a user-selected Markdown folder is still maintained for stable folder access, but it must not be interpreted as evidence that the process is sandboxed.

`Packages/WhisperBinary` is a local SwiftPM wrapper referenced by both `Package.swift` and the Xcode project. Its manifest pins the official whisper.cpp v1.8.1 XCFramework release URL and checksum; the binary is resolved by SwiftPM and is not committed to this repository. This is separate from runtime Whisper model files, which the application downloads and verifies under Application Support.

Capture and transcript processing preserve these invariants:

- ScreenCaptureKit presentation timestamps and valid microphone mach host-time values are the only inputs to the shared capture timeline. Invalid microphone host time stays missing; `systemUptime` and sample time are not mixed into the timeline.
- Finalization chooses the earliest plausible captured track start as the timeline origin. A track's relative offset is `max(0, trackStart - timelineOrigin)`; the converter does not insert leading silence.
- System and microphone tracks are transcribed sequentially. One loaded Whisper context is reused between them and explicitly released after the complete session, while each track's audio samples are released before the next track is read.
- Merge is deterministic and loss-preserving: segments are normalized to millisecond precision and ordered by time with stable tie-breakers. Cross-track overlap is retained and labelled; acoustic echo is not deduplicated.

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

Recovery reuses a valid `transcript.json` and `analysis.json` when available. Otherwise it reconstructs technical metadata from a readable `system.caf`, regenerates the 16 kHz working audio, and resumes the normal transcription and export pipeline. Recovery attempts and outcomes are recorded in session manifest schema 7.

Recording requires at least 1 GB of free space. Capacity is checked before creating a session and every five seconds while recording. If available storage becomes critical, capture is stopped and finalized through the normal safe-stop pipeline.

Each session has a newline-delimited JSON `processing.log`. It contains only technical events and bounded diagnostic fields such as timestamps, models, frame counts, sample rates, durations, and sanitized error messages. Transcript text, audio data, API requests, meeting titles, and API keys are not logged; token-like values are redacted.

## Stabilization testing

The current standard SwiftPM baseline contains 117 tests: 111 pass and 6 hardware-, credential-, or fixture-dependent tests skip unless explicitly enabled. The Xcode app and test targets use Swift 6 with complete strict-concurrency checking. GitHub Actions runs both the SwiftPM suite and the shared Xcode scheme on a pinned `macos-26` runner, so the SwiftUI application layer cannot be skipped by a core-only build. In addition, the opt-in long-session test has been executed successfully against a generated one-hour, approximately 58 MB PCM stream. These automated counts describe the current working tree; release acceptance still requires the manual hardware matrix below.

AppState-level integration tests cover recovery from a preserved merged transcript and a safe automatic stop after required system-audio capture fails. These tests verify the resulting Markdown, manifest, processing log, preserved audio, and recovery status rather than only isolated model types.

Real forced-termination tests recovered both a 172.7-second system-only session and a 102-second dual-track session. The dual-track recovery preserved both original CAF files, generated both 16 kHz working WAV files, transcribed both tracks, merged 10 segments, exported Markdown, and completed the recovery audit. Recovery also infers the relative microphone start from file end times and durations because CAF does not retain presentation timestamps after a hard crash.

The alternative **Close without deleting files** path has also been validated after a real forced termination. It closes the recovery audit without processing and preserves both original CAF tracks.

The stably signed build now includes the Hardened Runtime audio-input entitlement. A real dual-track run recorded and finalized both system audio and microphone audio, created both 16 kHz working WAV files, transcribed both tracks without warnings, merged 15 segments, and exported Markdown.

A five-minute local-video run with built-in speakers also completed on Large v3 Turbo with automatic Slovak detection, readable dual-track audio, 155 ordered merged segments, and Markdown output. Speaker playback was audibly duplicated through the microphone track, documenting the expected echo behavior when headphones are not used.

During a real sleep/wake run, ScreenCaptureKit reported that no display was available as the Mac entered sleep. MeetingScribe stopped safely, preserved both CAF tracks, offered recovery after wake, and completed dual-track Large v3 Turbo processing. Recovery prefers exact persisted capture timestamps after a safe stop and falls back to CAF timestamp inference only after a hard crash.

AirPods connect/disconnect was also validated during active recording. Microphone capture automatically recreated its engine for the current route, resumed after each change, and limited gaps within the microphone timeline to approximately 2.43 seconds while system audio continued.

An external USB-input change, meeting-application scenarios, real 60-minute recording, and production-model Czech and mixed CZ/SK quality acceptance still require the remaining hardware matrix in [the phase 10 stabilization protocol](docs/phase-10-stabilization.md). Detailed completed and pending evidence is recorded in [the phase 10 results](docs/phase-10-results.md). Automated results must not be treated as a substitute for that manual evidence.

## Optional AI analysis

AI analysis is opt-in and uses the OpenAI Responses API with strict structured output. Only the meeting title, recording identifier, preferred output language, and transcript text are sent; recorded audio remains local. Requests explicitly disable server-side response storage with `store: false`.

The OpenAI API key is stored in the macOS Keychain and is never written to the session manifest or UserDefaults. The default model is `gpt-5.6-luna`; `gpt-5.6-terra` and `gpt-5.6` can be selected in the menu-bar UI. Long transcripts are split at segment boundaries and the partial analyses are consolidated in a final structured request.

Successful output is persisted as `analysis.json` and fills the Markdown summary, decisions, action items, open questions, risks/blockers, and next-meeting topics. If no API key is configured or an analysis request fails, transcription and the base Markdown output still complete and the failure is recorded in the session manifest.

The real Keychain round-trip test is opt-in:

```sh
MEETINGSCRIBE_KEYCHAIN_TEST=1 swift test --filter APIKeyStoreTests
```

## Markdown and Obsidian output

MeetingScribe always writes a Markdown result after successful transcription. By default it is stored in the recording's session directory. Use **Choose folder…** in the menu-bar UI to select an Obsidian folder or another destination. The selection is persisted as a security-scoped bookmark and can be reset to the default session folder.

The file name follows `YYYY-MM-DD HH-mm - Meeting title.md`. Existing files are never overwritten; a numeric suffix is added on collision. When the selected folder is inside a directory containing `.obsidian`, the completed result can be opened through an `obsidian://open` URI. Finder reveal and normal file opening are also available.

The Obsidian action is a best-effort handoff, not a vault sync or import API. MeetingScribe locates the nearest ancestor containing `.obsidian` and builds `obsidian://open` from the vault directory name plus the note's relative path. Obsidian must already know that local vault and be registered as the URI handler. Two registered vaults with the same directory name can be ambiguous, and MeetingScribe cannot confirm which one Obsidian selects; use normal file opening or Finder reveal in that case.

## Whisper models

Models are not embedded in the app or committed to Git. MeetingScribe stores checksum-validated models under `~/Library/Application Support/MeetingScribe/Models/`. The menu-bar UI supports the multilingual `large-v3-turbo`, quantized `large-v3-turbo-q5_0`, `medium`, and a small `tiny` prototype model. The production default is `large-v3-turbo`.

The real inference test is optional and skips when no local model or sample is supplied:

```sh
MEETINGSCRIBE_WHISPER_MODEL=/path/to/ggml-model.bin \
MEETINGSCRIBE_WHISPER_AUDIO=/path/to/16-kHz-mono.wav \
MEETINGSCRIBE_WHISPER_LANGUAGE=sk \
swift test --filter WhisperCppIntegrationTests
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

System audio is required to start a session. Microphone capture is optional: if its permission is denied or no usable input is available, MeetingScribe keeps recording the system-audio track and records the microphone failure in the session manifest.
