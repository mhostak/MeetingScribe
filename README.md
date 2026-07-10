# MeetingScribe

Native macOS menu-bar application for recording meeting audio and producing local transcripts.

## Current scope

The current implementation provides the menu-bar application shell, validated application state transitions, durable recording-session metadata, ScreenCaptureKit-based system audio capture to `system.caf`, and a separate microphone track in `microphone.caf`. Transcription is not implemented yet.

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

## Recording permissions during development

macOS binds Screen & System Audio Recording and Microphone approvals to the application's code-signing identity. Configure an Apple Development or Personal Team signing identity in Xcode for stable permissions across builds.

With an ad-hoc `Sign to Run Locally` build, each rebuild changes the app's designated code requirement. Reset the stale permission before testing the newly built binary, grant it again, and relaunch the same binary without rebuilding:

```sh
tccutil reset ScreenCapture com.martinhostak.MeetingScribe
tccutil reset Microphone com.martinhostak.MeetingScribe
```

System audio is required to start a session. Microphone capture is optional: if its permission is denied or no usable input is available, MeetingScribe keeps recording the system-audio track and records the microphone failure in the session manifest.
