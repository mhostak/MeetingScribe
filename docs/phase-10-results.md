# Phase 10 stabilization results

This report records completed evidence separately from the manual checks that still remain. It intentionally excludes transcript text, meeting content, API credentials, and other sensitive values.

## Automated regression

- Standard SwiftPM suite: 69 tests executed, 64 passed, 5 optional hardware or fixture-dependent tests skipped, 0 failures.
- Final full Xcode app/test scheme: 68 tests executed, 63 passed, 5 skipped, 0 failed; result `Passed` on macOS arm64.
- After adding the entitlement, the signed Xcode app build succeeded and the embedded entitlement was verified. A redundant fresh-DerivedData Xcode test rerun emitted passcode-protected-device warnings and later Xcode builds stalled in `NSFileCoordinator` while opening the File Provider-managed project directory. Building an identical source mirror under `/private/tmp` succeeded with the stable Apple Development identity and verified audio-input entitlement. The complete SwiftPM suite passed 69/64/5/0 after the recovery-offset regression was added.
- Opt-in one-hour stability test: passed with a generated 3,600-second, approximately 58 MB mono PCM stream.
- AppState integration: interrupted-session recovery creates Markdown and completes the recovery audit.
- AppState integration: failure of required system-audio capture triggers a safe automatic stop and preserves the session.
- Regression: the active recording is excluded from recovery scanning.
- Regression: the selected Whisper model persists across application launches.

## Real crash and recovery

Date: 2026-07-11

Session: `2026-07-11T19-45-10Z_769585`

Procedure and result:

1. A stably signed development build started ScreenCaptureKit system-audio recording.
2. MeetingScribe was terminated with `kill -9` during active capture.
3. The same app binary was relaunched without rebuilding.
4. The unfinished session was detected and **Recover and process** was selected.
5. Recovery completed successfully with one recorded attempt.

Verified artifacts and metadata:

- original `system.caf`: preserved, 66,320,896 bytes;
- recovered source duration: 172.7 seconds, 48 kHz, two channels;
- `system-16k.wav`: created, 172.7 seconds, 16 kHz mono PCM;
- `system-transcript.json` and `transcript.json`: created;
- Markdown export: completed;
- manifest: `status = recorded`, `recovery.status = completed`, `attemptCount = 1`;
- processing log: contains detection, recovery, finalization, transcription, export, and completion events;
- privacy check: no transcript text, bearer token, or API-key pattern was found in the technical log.

Tiny transcription completed with zero segments for the captured test audio. This is not a recovery failure: finalization, transcription execution, export, and audit all completed.

The microphone permission was unavailable in this run. Recovery therefore correctly completed from the required system-audio track and recorded a microphone warning. Stable-signing dual-track recovery is not yet accepted.

## Stable-signing dual-track capture

Date: 2026-07-12

Session: `2026-07-12T08-15-53Z_588BB0`

The signed app originally did not appear under System Settings → Privacy & Security → Microphone. The bundle had a valid usage description and requested AVFoundation access, but Hardened Runtime was enabled without the audio-input entitlement. `com.apple.security.device.audio-input` was added to the app entitlements, the bundle-specific microphone TCC decision was reset, and the same stable Apple Development identity was used for the rebuilt app.

Verified result:

- system CAF: 27.04 seconds, 1,352 buffers, 1,297,920 frames, 48 kHz stereo;
- microphone CAF: 24.70 seconds, 247 buffers, 1,185,600 frames, 48 kHz mono;
- both source CAF files are readable;
- both 16 kHz mono working WAV files were generated and are readable;
- audio finalization completed without warnings;
- system transcription: 5 segments;
- microphone transcription: 10 segments;
- merged transcript: 15 segments;
- transcription and Markdown export completed without warnings.

Stable-signing dual-track capture, finalization, transcription, merge, and export are accepted. The forced-crash scenario is recorded separately below.

## Real dual-track crash and recovery

Date: 2026-07-12

Session: `2026-07-12T08-27-01Z_E9A830`

MeetingScribe was terminated with `kill -9` while both counters and both CAF files were growing. The same signed binary was relaunched and **Recover and process** was selected.

Verified result:

- original system CAF preserved: 102.48 seconds, 48 kHz stereo, 39,352,320 audio bytes;
- original microphone CAF preserved: 102.30 seconds, 48 kHz mono, 19,641,600 audio bytes;
- both 16 kHz mono working WAV files generated and readable;
- recovery audit: `completed`, one attempt, original status `recording`;
- system transcript: 5 segments;
- microphone transcript: 5 segments;
- merged transcript: 10 segments;
- Markdown export completed;
- processing log contains the complete recovery pipeline and no transcript text, bearer token, API-key pattern, or meeting title.

The real run exposed a 0.18-second difference between track lengths while the reconstructed offsets were both zero. Recovery now infers the microphone start from each CAF file's modification time and duration, respecting the invariant that system capture starts first. A deterministic regression test verifies a delayed microphone start and the complete SwiftPM suite passes.

Dual-track forced-crash recovery is accepted.

## Additional real capture evidence

Session `2026-07-11T19-36-46Z_0D602C` recorded 21.48 seconds of system audio, finalized it, completed Tiny transcription with five segments, and exported Markdown. The microphone was denied by macOS during this run.

## Defects found during stabilization

- Opening or refreshing the menu could scan the active recording as unfinished. Recovery scanning now excludes the active session identifier.
- Relaunching the application could reset the selected Whisper model to Large. Model selection is now persisted and restored.
- The app could be absent from the macOS Microphone privacy list because Hardened Runtime lacked `com.apple.security.device.audio-input`. The entitlement is now part of Debug and Release signing.

Both defects have dedicated automated regression tests.

## Remaining manual acceptance

- Teams, Slack, Chrome/Safari Meet, Zoom, and local-video rows;
- sleep/wake behavior;
- USB/input-device changes and AirPods disconnect/reconnect;
- a real recording of at least 60 minutes with CPU, memory, and free-space observations;
- Czech and Slovak quality evaluation with the production Whisper model;
- explicit **Close without deleting files** recovery path on a real interrupted session.

Phase 10 remains in progress until the required hardware matrix in `phase-10-stabilization.md` is recorded.
