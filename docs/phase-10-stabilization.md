# Phase 10 stabilization protocol

This checklist separates automated evidence from tests that require real macOS hardware, permissions, or a live meeting application. Do not mark a manual scenario as passed without preserving the session ID and the requested evidence.

## Automated baseline

Run before and after every manual test round:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path .derivedData/swiftpm

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project MeetingScribe.xcodeproj \
  -scheme MeetingScribe \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData/xcode-phase10 \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Run the opt-in one-hour incremental audio writer test once per release candidate:

```sh
MEETINGSCRIBE_STRESS_TEST=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path .derivedData/swiftpm \
  --filter LongSessionStabilityTests
```

Pass criteria:

- no test failures or Swift concurrency warnings;
- Xcode reports `TEST SUCCEEDED`;
- the stress test creates a readable 3,600-second CAF and removes its temporary fixture;
- `plutil -lint MeetingScribe.xcodeproj/project.pbxproj` and `git diff --check` succeed.

## Evidence to preserve for every manual session

- application commit and build path;
- session ID and meeting application;
- audio input/output device names;
- start/end timestamps and test duration;
- `session.json`, `processing.log`, CAF/WAV sizes and Markdown path;
- pass/fail result with a concise failure description;
- Activity Monitor CPU and memory observations for tests longer than 30 minutes.

Never paste transcript text or API keys into the test report.

## Meeting application matrix

Repeat a five-minute call with remote speech and local microphone speech for each row.

| Scenario | Output route | Input route | Required evidence |
| --- | --- | --- | --- |
| Microsoft Teams desktop | built-in or headphones | built-in microphone | both CAF tracks nonempty, timestamped Markdown |
| Slack Huddle | built-in or headphones | built-in microphone | both CAF tracks nonempty, timestamped Markdown |
| Google Meet in Chrome | built-in or headphones | built-in microphone | both CAF tracks nonempty, timestamped Markdown |
| Google Meet in Safari | built-in or headphones | built-in microphone | both CAF tracks nonempty, timestamped Markdown |
| Zoom desktop | built-in or headphones | built-in microphone | both CAF tracks nonempty, timestamped Markdown |
| Local video playback | built-in speakers | built-in microphone | system track nonempty, echo noted if present |

For at least one row, repeat with an external USB microphone. For at least one row, use speakers without headphones and record whether duplicated/echoed speech appears.

## CZ/SK quality matrix

Use `large-v3-turbo`, not `tiny`.

1. Record a two-minute Slovak sample containing names, dates, numbers, and action items.
2. Record a two-minute Czech sample with the same structure.
3. Record a mixed CZ/SK exchange with at least four language switches.
4. Confirm detected languages, timestamp order, speaker/source labels, and that the mixed sample is not translated to English.
5. Record obvious word error patterns and hallucinations without copying confidential meeting text.

## Sleep and wake

1. Start recording and confirm both tracks receive buffers.
2. Put the Mac to sleep for at least 30 seconds using the Apple menu.
3. Wake and unlock it, wait 15 seconds, then stop recording.
4. Confirm the app either resumes capture or reports the required system-track failure and performs a safe stop.
5. Confirm all files written before sleep remain present and the session is recoverable after relaunch if processing was interrupted.

## Audio-device changes

Run each change after at least 30 seconds of active recording:

- built-in microphone → USB microphone;
- USB microphone → built-in microphone;
- connect AirPods;
- disconnect AirPods;
- switch the system output between speakers and headphones.

Expected result: system audio remains the required track. Microphone interruption may produce a warning but must not discard system audio or crash the app. If system capture fails, MeetingScribe must stop safely and preserve the session.

## Real crash and recovery

Use a development build with stable signing permissions.

1. Start recording and wait until both buffer counters are nonzero.
2. Note the session ID from the recording folder.
3. Terminate only the MeetingScribe process with `kill -9 <pid>` while capture is active.
4. Relaunch the same app binary without rebuilding it.
5. Confirm the menu shows **Unfinished recording found** and blocks a new recording.
6. Choose **Recover and process**.
7. Confirm the original CAF files still exist, recovery attempt count is incremented, Markdown is produced, and `processing.log` contains recovery events without transcript text.
8. Repeat once and choose **Close without deleting files**; confirm the files remain and the prompt does not return.

## Long recording

Record a real meeting or controlled audio playback for at least 60 minutes.

Pass criteria:

- buffer counters continue increasing;
- memory does not grow continuously with recording duration;
- free-space protection does not trigger when more than 1 GB remains;
- both CAF files are readable after stop;
- processing completes or reports a recoverable model/provider failure;
- no audio, transcript, or log file is silently deleted.

## Release decision

Phase 10 is fully accepted only after every required matrix row has a recorded result. Automated tests establish code-level readiness; they do not substitute for ScreenCaptureKit, sleep/wake, Bluetooth, and meeting-application validation on real hardware.
