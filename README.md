# MeetingScribe

Native macOS menu-bar application for recording meeting audio and producing local transcripts.

## Current scope

The current implementation provides the menu-bar application shell, validated application state transitions, durable recording-session metadata, ScreenCaptureKit-based system audio capture to `system.caf`, and a separate microphone track in `microphone.caf`. After recording, both available tracks are validated and converted to 16 kHz mono PCM WAV files (`system-16k.wav` and `microphone-16k.wav`). Local transcription uses the official whisper.cpp v1.8.1 XCFramework with Metal acceleration and writes separate timestamped `system-transcript.json` and `microphone-transcript.json` files. Their normalized segments are merged deterministically into `transcript.json`; overlapping speech is preserved with its original source and speaker. MeetingScribe can optionally analyze the transcript with OpenAI and then renders YAML-frontmatter Markdown with structured meeting notes and timestamped speakers. Interrupted and failed sessions can be recovered from preserved audio or transcript artifacts. The original files are never deleted by recovery, including when the model is missing, transcription fails, AI analysis fails, Markdown export fails, or the application exits unexpectedly.

## Requirements

- macOS 14 or newer
- Xcode 26 or newer

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

The standard SwiftPM suite contains 69 tests. Five hardware or fixture-dependent tests skip unless explicitly enabled; the remaining 64 pass without failures. The most recent completed full Xcode app/test scheme contains the preceding 68-test set and reports 63 passed, 5 skipped, and 0 failed. In addition, the opt-in long-session test has been executed successfully against a generated one-hour, approximately 58 MB PCM stream.

AppState-level integration tests cover recovery from a preserved merged transcript and a safe automatic stop after required system-audio capture fails. These tests verify the resulting Markdown, manifest, processing log, preserved audio, and recovery status rather than only isolated model types.

Real forced-termination tests recovered both a 172.7-second system-only session and a 102-second dual-track session. The dual-track recovery preserved both original CAF files, generated both 16 kHz working WAV files, transcribed both tracks, merged 10 segments, exported Markdown, and completed the recovery audit. Recovery also infers the relative microphone start from file end times and durations because CAF does not retain presentation timestamps after a hard crash.

The stably signed build now includes the Hardened Runtime audio-input entitlement. A real dual-track run recorded and finalized both system audio and microphone audio, created both 16 kHz working WAV files, transcribed both tracks without warnings, merged 15 segments, and exported Markdown.

Sleep/wake, Bluetooth/device changes, meeting-application scenarios, real 60-minute recording, and production-model CZ/SK quality acceptance still require the remaining hardware matrix in [the phase 10 stabilization protocol](docs/phase-10-stabilization.md). Detailed completed and pending evidence is recorded in [the phase 10 results](docs/phase-10-results.md). Automated results must not be treated as a substitute for that manual evidence.

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
