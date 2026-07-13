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

Run one Microsoft Teams desktop call of at least five minutes with remote speech and local microphone speech. Other meeting applications are outside the phase 10 acceptance scope.

| Scenario | Output route | Input route | Required evidence |
| --- | --- | --- | --- |
| Microsoft Teams desktop | built-in or headphones | built-in microphone | both CAF tracks nonempty, timestamped Markdown |
| Local video playback | built-in speakers | built-in microphone | system track nonempty, echo noted if present |

Slack Huddle, Google Meet in Chrome or Safari, and Zoom may be tested later but are not required to complete phase 10.

The external USB microphone and speakers-without-headphones variants have already been validated separately.

Microsoft Teams is accepted in `phase-10-results.md`: session `2026-07-13T07-29-43Z_3A940D` successfully captured and processed both tracks for 15 minutes 20.58 seconds. The earlier 93-second Czech Teams session remains additional language evidence.

## CZ/SK quality matrix

Use `large-v3-turbo`, not `tiny`.

1. Record a two-minute Slovak sample containing names, dates, numbers, and action items using either Auto or explicit Slovenčina.
2. Record a two-minute Czech sample with the same structure in Auto mode.
3. Repeat a Czech sample with explicit Čeština and confirm `cs` is stored and forwarded to both tracks.
4. Record a mixed CZ/SK exchange with at least four language switches in Auto mode.
5. Confirm track languages, timestamp order, speaker/source labels, and that the mixed sample is not translated to English. Auto language detection is track-level, not per segment.
6. Record obvious word error patterns, low-energy-track hallucinations, and other anomalies without copying confidential meeting text.

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

Session `2026-07-13T08-07-22Z_777771` completed the 60-minute Microsoft Teams capture, dual-track finalization, transcription, and export requirements. Both source and working audio files remained readable, more than 1 GB remained free, and all artifacts were preserved.

Final resource validation used signed build commit `0d0add2` and session `2026-07-13T12-26-50Z_D5C621`. The controlled recording ran for 62 minutes 18 seconds. Across 58 one-minute samples, CPU averaged 4.06%, RSS stayed between approximately 34 and 48 MB, and physical footprint changed from 39 MB near the start to 40 MB near the end. Both CAF files grew continuously and approximately 8.9 GiB remained free. Finalization completed without warnings, all artifacts remained readable, and optimized Large v3 Turbo transcription completed in 11 minutes 19 seconds. This satisfies the remaining long-recording resource-stability evidence.

Pass criteria:

- buffer counters continue increasing;
- memory does not grow continuously with recording duration;
- free-space protection does not trigger when more than 1 GB remains;
- both CAF files are readable after stop;
- processing completes or reports a recoverable model/provider failure;
- no audio, transcript, or log file is silently deleted.

## Release decision

Phase 10 is fully accepted. Every required matrix row has a recorded passing result, including ScreenCaptureKit capture, Microsoft Teams, sleep/wake, Bluetooth and USB route changes, crash recovery, CZ/SK transcription, a recording longer than one hour, resource stability, and complete artifact preservation on real hardware.
