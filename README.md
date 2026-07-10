# MeetingScribe

Native macOS menu-bar application for recording meeting audio and producing local transcripts.

## Current scope

Phase 1 provides the application shell, validated application state transitions, and durable recording-session metadata. Audio capture and transcription are intentionally not part of this phase.

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
