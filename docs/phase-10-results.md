# Phase 10 stabilization results

This report records the completed phase 10 stabilization evidence. It intentionally excludes transcript text, meeting content, API credentials, and other sensitive values.

## Automated regression

- Current working tree after the audit fixes, transcription-language selector, and pre-inference activity batching: 133 SwiftPM tests executed, 124 passed, 9 optional hardware, credential, model, session, or fixture-dependent tests skipped, 0 failures.
- Current complete signed Xcode app/test scheme: `TEST SUCCEEDED` on macOS arm64 using an Apple Development identity. This verifies the SwiftUI application target, including the new language picker, as well as the test bundle.
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

AirPods connect/disconnect with automatic microphone recovery is accepted. The external USB-input test is recorded separately below.

## External USB microphone route change

Date: 2026-07-13

Commit: `1e99ca1`

Session: `2026-07-13T06-36-36Z_23463E`

During one active recording, the system input was changed from the built-in microphone to an external USB microphone after approximately 30 seconds and then back to the built-in microphone after another approximately 30 seconds. Speech was recorded during all three phases.

Verified result:

- system audio: 93.18 seconds, 4,659 buffers, 4,472,640 frames, readable 48 kHz stereo CAF;
- microphone: 90.10 seconds, 901 buffers, 4,324,800 frames, readable 48 kHz mono CAF;
- microphone presentation timestamps span 91.84 seconds and continue to the end of the recording;
- gaps within the microphone timeline during the two route changes total approximately 1.74 seconds;
- both 16 kHz mono working WAV files were generated and are readable;
- Large v3 Turbo automatically detected Slovak on the microphone track;
- microphone transcription contains 8 segments in the initial built-in phase, 7 in the USB phase, and 11 after returning to the built-in microphone;
- system transcription contains 4 segments, microphone transcription 26 segments, and the merged transcript 30 segments;
- finalization, transcription, deterministic merge, and Markdown export completed without warnings;
- all original and derived artifacts remained present.

Built-in microphone → USB microphone → built-in microphone recovery is accepted.

## Czech and mixed Czech/Slovak quality

Date: 2026-07-13

Model: Large v3 Turbo with automatic language detection

### Czech sample

Session: `2026-07-13T06-45-55Z_39DACD`

A controlled Czech statement containing nonconfidential names, dates, times, counts, monetary values, decisions, risks, and action items was spoken into the microphone.

Verified result:

- system audio: 105.86 seconds; microphone: 105.80 seconds;
- both CAF and both 16 kHz WAV files are readable;
- microphone transcription: 17 segments; merged transcript: 21 segments;
- finalization, transcription, merge, and Markdown export completed without warnings;
- all test names were preserved;
- dates, times, counts, prices, and the room identifier were preserved, with minor formatting differences;
- the main decisions and action items remained understandable;
- the detected language was `sk`, not Czech;
- several Czech words were converted to Slovak forms, and a few phrases were substituted or garbled, most notably the sentence about two-factor authentication;
- the content was not translated into English and no unrelated hallucinated passage appeared.

The Czech sample demonstrates usable semantic and numeric retention but fails correct automatic Czech language identification.

### Mixed Czech/Slovak sample

Session: `2026-07-13T06-50-25Z_72566B`

Six alternating Czech and Slovak blocks were spoken, producing five explicit language switches.

Verified result:

- system audio: 86.20 seconds; microphone: 86.10 seconds;
- both CAF and both 16 kHz WAV files are readable;
- microphone transcription: 16 segments; merged transcript: 19 segments;
- finalization, transcription, merge, and Markdown export completed without warnings;
- the sequence and meaning of all six source blocks remained recognizable;
- names, dates, times, counts, prices, decisions, risks, and action items were substantially preserved;
- the transcript remained Czech/Slovak and was not translated into English;
- the track-level detected language was `sk`, and every segment was labelled `sk` even during Czech blocks;
- Czech and Slovak word forms were mixed within several segments, with occasional word substitutions.

The mixed sample passes content preservation and the no-English-translation requirement, but it does not provide per-segment language-switch detection. MeetingScribe currently stores one Whisper-detected language for the complete track and propagates it to all segments.

### Explicit Czech sample

Session: `2026-07-13T07-05-29Z_41C911`

The test used Large v3 Turbo with the explicit **Čeština** selection during a real online meeting in the Microsoft Teams desktop application. It captured approximately 93 seconds of Czech meeting audio.

Verified result:

- the session manifest stored `language: cs`;
- both the system and microphone track requests used `cs`, and both track results reported `cs`;
- system audio: 92.66 seconds and 4,633 buffers; microphone: 92.50 seconds and 925 buffers;
- both CAF and both 16 kHz WAV files are readable;
- system transcription: 32 segments; microphone transcription: 4 segments; merged transcript: 36 segments;
- finalization, transcription, deterministic merge, and Markdown export completed without warnings;
- the system transcript remained predominantly intelligible Czech with consistent Czech word forms, while several proper names and short phrases were still imperfect;
- the content was not translated into another language;
- the microphone working track was very quiet (approximately -50.0 dB mean and -24.5 dB peak) and the original build repeated one unrelated phrase across four long segments. This was recorded as a low-energy-track hallucination, not as a failure of the language selector;
- after adding the segment-level activity filter, an opt-in Large v3 Turbo regression using this exact microphone WAV produced zero microphone segments and passed.

The explicit Czech selector and Czech language forwarding are accepted. Czech transcription quality is acceptable for the current prototype, with the documented limitations above.

The product decision is implemented and validated: MeetingScribe offers a persisted **Auto / Čeština / Slovenčina / English** selector and stores the selected mode in each session manifest. Explicit modes are forwarded to both transcription tracks. Automatic mode intentionally remains track-level, so a mixed meeting can still receive one dominant language label for all segments.

## Additional real capture evidence

Session `2026-07-11T19-36-46Z_0D602C` recorded 21.48 seconds of system audio, finalized it, completed Tiny transcription with five segments, and exported Markdown. The microphone was denied by macOS during this run.

## Defects found during stabilization

- Opening or refreshing the menu could scan the active recording as unfinished. Recovery scanning now excludes the active session identifier.
- Relaunching the application could reset the selected Whisper model to Large. Model selection is now persisted and restored.
- The app could be absent from the macOS Microphone privacy list because Hardened Runtime lacked `com.apple.security.device.audio-input`. The entitlement is now part of Debug and Release signing.
- `AVAudioEngine` could report that it restarted after a Bluetooth route change while producing no microphone buffers. Route recovery now requires observed buffers and recreates the engine against the current hardware when necessary.
- A nearly silent microphone track could produce repeated Whisper text instead of no segments. Transcription now checks each proposed segment against 64 ms audio-energy windows and discards segments with insufficient active audio. The original low-energy WAV is covered by an opt-in real-model regression, while synthetic tests cover silence, low-level noise, sparse noise, valid speech-like activity, and track-local time ranges. Empty microphone transcripts are preserved with a `No speech was detected in microphone audio.` warning.

The deterministic defects have automated regression coverage; hardware route recovery is additionally covered by the real AirPods run above.

## Final acceptance — 2026-07-13

Final acceptance used stably signed builds from audio-route recovery commit `cf871c9` through optimized transcription commit `0d0add2`, with Large v3 Turbo for quality and long-session validation. For every manual recording, the session ID, input/output routes, duration, `session.json`, `processing.log`, CAF/WAV metadata, Markdown path, and a concise pass/fail result were preserved without copying confidential transcript text into this report.

### Meeting applications

Run one Microsoft Teams desktop call of at least five minutes with remote speech and local microphone speech:

- [x] Microsoft Teams desktop — accepted in session `2026-07-13T07-29-43Z_3A940D`.

Slack Huddle, Google Meet in Chrome or Safari, and Zoom are explicitly outside the phase 10 acceptance scope.

Pass criteria for each row:

- system and microphone buffer counters continue increasing;
- both source CAF files are nonempty and readable;
- both 16 kHz working WAV files are produced;
- the transcript contains timestamped segments from both available tracks;
- Markdown export completes, or any provider/model failure is explicit and recoverable;
- no session artifact is silently deleted.

Verified Microsoft Teams result:

- real online meeting duration: 920.58 seconds (15 minutes 20.58 seconds);
- system audio: 46,029 buffers, 44,187,840 frames, readable 48 kHz stereo CAF;
- microphone audio: 9,204 buffers, 44,179,200 frames, readable 48 kHz mono CAF;
- both 16 kHz mono working WAV files are readable and span the complete meeting;
- Large v3 Turbo completed both tracks in Auto mode without warnings;
- system track: 264 segments, detected language `pl`; microphone track: 429 segments, detected language `sk`;
- merged transcript: 693 segments, both sources present, no negative or reversed timestamps, and final timestamp 920.538 seconds;
- session JSON, both track transcripts, merged transcript, processing log, and 44 KB Markdown output are valid and present;
- finalization, transcription, deterministic merge, and Markdown export completed normally;
- approximately 15 GB remained available when the artifacts were inspected, above the 1 GB storage threshold.

The recording was created by the already-running build from before the low-energy filter was relaunched. Its persisted microphone transcript contained one repeated phrase 187 times. The same preserved microphone WAV was therefore transcribed offline with the current filter and the local Large v3 Turbo model:

- the opt-in real-audio integration test completed successfully in 276.12 seconds;
- Auto detected `sk`;
- the filtered result contained 217 segments and 174 unique texts;
- the maximum repetition fell from 187 to 14;
- the validation did not modify the original session or its exported artifacts.

The Microsoft Teams meeting-application row is accepted. Capture, dual-track finalization, and export passed in the recorded session, while offline reprocessing confirms that the current low-energy filter materially cleans its microphone transcript. The earlier 93-second explicit-Czech Teams session remains useful language evidence but is no longer needed for the Teams duration criterion.

### External input device

- [x] During an active recording, switch from the built-in microphone to an external USB microphone after at least 30 seconds.
- [x] Confirm that microphone buffers resume and continue for at least 30 seconds.
- [x] Switch back from USB to the built-in microphone and confirm another successful recovery.
- [x] Stop normally and verify both CAF files, both WAV files, the manifest, and Markdown output.

The USB and AirPods route-change paths are accepted and do not need to be repeated unless a regression appears.

### Czech and mixed CZ/SK quality

- [x] Record approximately two minutes of Czech speech containing nonconfidential names, dates, times, numbers, monetary values, and action items.
- [x] Record a mixed Czech/Slovak exchange with at least four explicit language switches.
- [x] Document automatic-mode behavior. Timestamp order and source labels passed, but standalone Czech and all mixed segments were labelled `sk` because language detection is track-level.
- [x] Repeat the Czech sample with the explicit **Čeština** mode and confirm that the manifest and both transcription tracks use `cs`.
- [x] Compare the explicit-Czech result with the automatic sample. Czech word forms were more consistent and overall intelligibility was acceptable, with several proper-name and short-phrase errors documented above.
- [x] Confirm that the mixed recording is not translated into English.
- [x] Record only summarized word-error and hallucination patterns; do not paste transcript text into the report.

The Slovak and explicit-Czech Large v3 Turbo quality rows are accepted. Mixed Auto behavior is documented and accepted as a track-level limitation. The low-energy microphone hallucination is fixed and covered by synthetic and real-model regression tests.

### Real long recording

- [x] Record a real meeting or controlled playback for at least 60 minutes.
- [x] Note CPU and memory near the start, around 30 minutes, and near the end using Activity Monitor-equivalent `ps` RSS/CPU sampling plus `footprint` snapshots.
- [x] Confirm that memory does not grow continuously with duration and buffer counters keep increasing.
- [x] Confirm that more than 1 GB remains free and the storage guard does not trigger incorrectly.
- [x] Stop normally and verify that both CAF files are readable and processing completes or fails recoverably.
- [x] Confirm that no audio, transcript, Markdown, manifest, or log file is silently deleted.

Verified long-session result:

- date: 2026-07-13;
- session: `2026-07-13T08-07-22Z_777771`;
- real Microsoft Teams meeting with mixed Czech/Slovak speech; approximately the final six minutes were controlled online-video playback to reach the one-hour threshold;
- wall-clock recording span: 60 minutes 17 seconds;
- system audio: 180,644 buffers, 173,418,240 frames, 3,614.8 captured seconds; readable 48 kHz stereo CAF and 3,612.88-second 16 kHz mono WAV;
- microphone audio: 36,132 buffers, 173,433,600 frames, 3,614.13 captured seconds; readable 48 kHz mono CAF and 3,613.2-second 16 kHz mono WAV;
- finalization completed in approximately two seconds without warnings;
- original Large v3 Turbo transcription ran from 09:07:41Z to 09:36:05Z, or 28 minutes 24 seconds: system completed after 11 minutes 20 seconds and microphone required another 17 minutes 4 seconds;
- original system result: 986 segments, 828 unique texts, maximum identical repetition 36, detected `cs`;
- original microphone result: 389 segments, 33 unique texts, maximum identical repetition 338, detected `en`; this exposed the limitation of filtering only after full-track inference;
- Markdown export, both track transcripts, merged transcript, manifest, and processing log completed without warnings or missing artifacts;
- approximately 13 GB remained free during post-test inspection, above the 1 GB guard threshold.

The preserved microphone WAV was then processed offline without modifying the session artifacts. The final pre-inference implementation measured:

- 3,613.2 seconds of source audio;
- 792.824 seconds of active audio and 2,820.376 seconds skipped before Whisper;
- 99 activity islands compacted into three bounded inference batches with 250 ms separators;
- 816.824 seconds of actual inference input;
- 186.01 seconds wall time, compared with the original 1,024 seconds;
- 195 segments, 183 unique texts, maximum identical repetition 5, and detected language `sk`;
- all returned timestamps remained finite, nonnegative, ordered, and mapped to the original track timeline.

The highly active system track is intentionally kept as one full-track batch. Using its already measured 680-second time originally gave a projected optimized dual-track wall time of approximately 866 seconds, or 14 minutes 26 seconds, instead of 28 minutes 24 seconds.

Final resource and optimized end-to-end validation used signed build commit `0d0add2` and session `2026-07-13T12-26-50Z_D5C621`:

- controlled recording span: 62 minutes 18 seconds, with no sleep or audio-route changes;
- 58 one-minute resource samples from approximately minute 5 through minute 62;
- CPU: 2.4% near the start, 7.2% around recording minute 30, and 4.8% near the end; 4.06% average and 1.8-11.0% observed range;
- RSS: 47.9 MB near the start, 40.9 MB around minute 30, and 41.1 MB near the end; approximately 34-48 MB observed range;
- physical footprint: 39 MB near the start and 40 MB near the end, with a 43 MB process-lifetime peak;
- free disk: approximately 11.0 GiB at the first sample and 8.9 GiB near the end, always above the 1 GB guard threshold;
- `system.caf` grew from 107,024,896 to 1,421,287,936 bytes during sampling; `microphone.caf` grew from 53,456,896 to 710,922,496 bytes;
- final readable system CAF/WAV duration: 3,735.46 seconds; final readable microphone CAF/WAV duration: 3,736.9 seconds;
- finalization completed in nine seconds without warnings;
- explicit Czech Large v3 Turbo processing completed in 11 minutes 19 seconds without warnings: system 487.05 seconds, microphone 191.15 seconds;
- the system track remained one full inference batch; the microphone track used four batches, processed 975.552 seconds of input, and skipped 2,781.348 inactive seconds;
- 2,515 ordered merged segments, both track transcripts, merged JSON, Markdown, manifest, processing log, both CAF files, and both WAV files were preserved;
- performance metrics were persisted in both track transcripts, `session.json`, and `processing.log` as designed.
- the complete minute-by-minute resource series is preserved in [`evidence/phase-10-long-recording-resources-2026-07-13.csv`](evidence/phase-10-long-recording-resources-2026-07-13.csv).

The actual optimized dual-track result is approximately 60% faster than the original 28-minute-24-second run. CPU stayed low, RSS and physical footprint remained flat rather than growing with recording duration, and both track files grew continuously. Capture continuity, finalization, storage protection, resource stability, artifact preservation, and the complete real pipeline are accepted.

### Final automated release check

- [x] Run the current full Xcode app/test scheme from commit `1e99ca1` or later and record the result. The signed scheme completed with `TEST SUCCEEDED`; the current SwiftPM baseline is 133 executed, 124 passed, 9 optional tests skipped, and 0 failed.

Phase 10 is complete. Every required automated, hardware, meeting-application, recovery, audio-route, language-quality, long-recording, resource-stability, finalization, transcription, and artifact-preservation row has recorded passing evidence.
