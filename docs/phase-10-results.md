# Phase 10 stabilization results

This report records completed evidence separately from the manual checks that still remain. It intentionally excludes transcript text, meeting content, API credentials, and other sensitive values.

## Automated regression

- Standard SwiftPM suite: 72 tests executed, 67 passed, 5 optional hardware or fixture-dependent tests skipped, 0 failures.
- Final full Xcode app/test scheme: 68 tests executed, 63 passed, 5 skipped, 0 failed; result `Passed` on macOS arm64.
- After adding the entitlement, the signed Xcode app build succeeded and the embedded entitlement was verified. A redundant fresh-DerivedData Xcode test rerun emitted passcode-protected-device warnings and later Xcode builds stalled in `NSFileCoordinator` while opening the File Provider-managed project directory. Building an identical source mirror under `/private/tmp` succeeded with the stable Apple Development identity and verified audio-input entitlement. The complete SwiftPM suite passed 72/67/5/0 after the recovery-offset and device-route regressions were added.
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

The microphone permission was unavailable in this run. Recovery therefore correctly completed from the required system-audio track and recorded a microphone warning. Successful stable-signing dual-track recovery is recorded separately below.

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

## Explicit close without deleting artifacts

Date: 2026-07-12

Session: `2026-07-12T13-35-04Z_B386AC`

MeetingScribe was terminated with `kill -9` while both CAF tracks were growing. After relaunch, **Close without deleting files** was selected instead of processing the session.

Verified result:

- manifest status: `failed` with the explicit user-close reason;
- recovery status: `closed`, original status `recording`, attempt count 0;
- the original system CAF remained preserved at approximately 20 MB;
- the original microphone CAF remained preserved at approximately 10 MB;
- the technical log contains `recoveryDetected` and `recoveryClosed`;
- the log contains no transcript text, meeting title, bearer token, or API-key pattern;
- the closed session is no longer offered as a recovery candidate.

The explicit close-without-deletion path is accepted.

## Slovak quality and local-video runs

Date: 2026-07-12

Session: `2026-07-12T14-31-06Z_CC30CA`

A Slovak spoken-word video was played through the built-in speakers while a known Slovak test statement was spoken into the built-in microphone. Large v3 Turbo was selected with automatic language detection.

Verified result:

- system audio: 165.54 seconds, 8,277 buffers, 43 transcript segments;
- microphone: 164.20 seconds, 1,642 buffers, 44 transcript segments;
- both tracks detected `sk` automatically;
- finalization, both transcriptions, deterministic merge, and Markdown export completed without warnings;
- merged transcript: 87 segments in timestamp order with correct source labels;
- the known local statement appeared only in the microphone track;
- names, date, time, and monetary amount in the known statement were preserved;
- two clear word substitutions occurred in the known statement;
- speaker playback was strongly audible in the microphone track, producing duplicated speech in the merged transcript when built-in speakers were used without echo cancellation.

The Slovak Large v3 Turbo quality sample and the required speakers-without-headphones echo observation are accepted. The local-video matrix row remains partial because this run lasted approximately 2 minutes 46 seconds instead of the required five minutes.

A second run completed the required duration:

- session: `2026-07-12T14-40-12Z_841503`;
- duration: 312.84 seconds (5 minutes 12.84 seconds);
- system audio: 15,642 buffers, 95 Slovak transcript segments;
- microphone: 3,127 buffers, 60 Slovak transcript segments;
- all source CAF and 16 kHz WAV files are readable;
- both tracks automatically detected `sk`;
- merged transcript: 155 correctly ordered and source-labelled segments;
- finalization, transcription, merge, Markdown export, and technical-log privacy scan completed without warnings.

The five-minute local-video row is accepted.

## Sleep and wake

Date: 2026-07-12

Session: `2026-07-12T14-48-45Z_ED0DAF`

MeetingScribe was recording both tracks when the Mac was put to sleep for at least 30 seconds. ScreenCaptureKit reported that no window or display was available as sleep began. MeetingScribe followed the permitted safe-stop outcome instead of crashing.

Verified result:

- required system capture failure was reported explicitly;
- safe stop preserved an 8.56-second system CAF and an 8.50-second microphone CAF;
- both original CAF files remained readable after wake;
- the session was presented as recoverable;
- **Recover and process** completed one recovery attempt;
- both 16 kHz working WAV files were generated and readable;
- Large v3 Turbo produced 2 system segments and 1 microphone segment;
- merged transcript, Markdown export, and recovery audit completed without warnings;
- technical-log privacy scan found no transcript text, meeting title, bearer token, or API-key pattern.

The safe-stop manifest contained the original presentation timestamps. The first recovery implementation unnecessarily replaced them with filesystem-based inference, producing a 0.888-second microphone offset instead of the captured 0.077-second offset. Recovery now prefers persisted capture timestamps when available and uses CAF modification-time inference only when a hard crash left no timestamps. A deterministic regression test covers the safe-stop case, and the complete SwiftPM suite passes.

The sleep/wake row is accepted with safe stop and successful recovery.

## AirPods connect and disconnect

Date: 2026-07-12

The first route-change run, session `2026-07-12T14-57-27Z_05D39F`, preserved system audio but the microphone stopped after AirPods were connected and did not resume after returning to the built-in input. A first recovery implementation restarted `AVAudioEngine`; session `2026-07-12T15-17-07Z_44E95A` showed that the engine could report a successful start while delivering no microphone buffers. That run contained a 40-second microphone gap and recovered only after the AirPods were disconnected.

The capture service now recreates the audio engine after a configuration change, waits for real microphone buffers instead of trusting `start()`, retries a temporarily unavailable route, converts changed input formats into the original CAF format, and preserves a partial microphone track if recovery ultimately fails.

Final retest session: `2026-07-12T15-25-40Z_3F54CD`.

Verified result:

- system audio: 68.96 seconds, 3,448 buffers, 3,310,080 frames;
- microphone: 66.18 seconds of readable CAF audio, 565 buffers, 3,176,704 frames;
- microphone presentation timestamps span 68.61 seconds and continue through the end of the recording;
- gaps within the microphone timeline total approximately 2.43 seconds; including normal start/end skew, the microphone track is 2.78 seconds shorter than system audio, compared with the previous 40-second gap;
- both 16 kHz WAV files were generated and readable;
- Large v3 Turbo completed both track transcriptions and merged 25 segments;
- finalization, transcription, merge, and Markdown export completed without warnings.

AirPods connect/disconnect with automatic microphone recovery is accepted. A separate external USB-input test remains pending.

## Additional real capture evidence

Session `2026-07-11T19-36-46Z_0D602C` recorded 21.48 seconds of system audio, finalized it, completed Tiny transcription with five segments, and exported Markdown. The microphone was denied by macOS during this run.

## Defects found during stabilization

- Opening or refreshing the menu could scan the active recording as unfinished. Recovery scanning now excludes the active session identifier.
- Relaunching the application could reset the selected Whisper model to Large. Model selection is now persisted and restored.
- The app could be absent from the macOS Microphone privacy list because Hardened Runtime lacked `com.apple.security.device.audio-input`. The entitlement is now part of Debug and Release signing.
- `AVAudioEngine` could report that it restarted after a Bluetooth route change while producing no microphone buffers. Route recovery now requires observed buffers and recreates the engine against the current hardware when necessary.

The deterministic defects have automated regression coverage; hardware route recovery is additionally covered by the real AirPods run above.

## Remaining manual acceptance

- Teams, Slack, Chrome/Safari Meet, and Zoom rows;
- an external USB-input-device change;
- a real recording of at least 60 minutes with CPU, memory, and free-space observations;
- Czech and mixed CZ/SK quality evaluation with the production Whisper model.

Phase 10 remains in progress until the required hardware matrix in `phase-10-stabilization.md` is recorded.
