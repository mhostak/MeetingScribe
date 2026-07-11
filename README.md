# MeetingScribe

Native macOS menu-bar application for recording meeting audio and producing local transcripts.

## Current scope

The current implementation provides the menu-bar application shell, validated application state transitions, durable recording-session metadata, ScreenCaptureKit-based system audio capture to `system.caf`, and a separate microphone track in `microphone.caf`. After recording, both available tracks are validated and converted to 16 kHz mono PCM WAV files (`system-16k.wav` and `microphone-16k.wav`). Local transcription uses the official whisper.cpp v1.8.1 XCFramework with Metal acceleration and writes separate timestamped `system-transcript.json` and `microphone-transcript.json` files. Their normalized segments are merged deterministically into `transcript.json`; overlapping speech is preserved with its original source and speaker. The original CAF recordings are always preserved, including when the model is missing or transcription fails.

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

## Recording permissions during development

macOS binds Screen & System Audio Recording and Microphone approvals to the application's code-signing identity. Configure an Apple Development or Personal Team signing identity in Xcode for stable permissions across builds.

With an ad-hoc `Sign to Run Locally` build, each rebuild changes the app's designated code requirement. Reset the stale permission before testing the newly built binary, grant it again, and relaunch the same binary without rebuilding:

```sh
tccutil reset ScreenCapture com.martinhostak.MeetingScribe
tccutil reset Microphone com.martinhostak.MeetingScribe
```

System audio is required to start a session. Microphone capture is optional: if its permission is denied or no usable input is available, MeetingScribe keeps recording the system-audio track and records the microphone failure in the session manifest.
