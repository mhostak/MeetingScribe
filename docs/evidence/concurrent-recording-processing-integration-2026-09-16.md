# Concurrent recording and completed-session processing — integration evidence

Integration branch: `codex/concurrent-integration`, based on `origin/main`
`7109bd92132ed0d917fdaed48fb75b6133e4cba4`.

## Automated checks

- `swift test --scratch-path /private/tmp/MeetingScribe-concurrent-swiftpm`:
  283 tests, 6 skipped, 0 failures. This includes the barrier-based A/B/C
  capture/processing tests, one-worker FIFO, pause/restart, recovery, output
  collision and checkpoint tests. Log:
  `/private/tmp/MeetingScribe-concurrent-tests-final.log`.
- `xcodebuild ... CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES
  CODE_SIGN_STYLE=Manual build-for-testing`: succeeded. Log:
  `/private/tmp/MeetingScribe-concurrent-build-for-testing.log`.
- `xcodebuild ... test-without-building` on the signed bundle:
  283 tests, 6 skipped, 0 failures. Log:
  `/private/tmp/MeetingScribe-concurrent-xcode-tests-fixed.log`.
- The built app passed `codesign --verify --deep --strict --verbose=4`.
  `codesign -dv --verbose=4` reported the Team ID and Apple Development
  authority configured in the unversioned `Config/Signing.local.xcconfig`, and
  the extracted leaf certificate's SHA-1 fingerprint matched it. The values
  themselves are local signing metadata and stay out of this repository.
- `git diff --check`, project plist lint, and localization JSON parsing passed.

An earlier custom `async @MainActor` executable entry point caused Xcode-hosted
asynchronous tests to stop progressing. Changing it to a synchronous app entry
point and dispatching only worker mode into a detached task resolved the hang.
The full signed scheme then completed successfully.

## Unmeasured release criteria

No live signed-app A/B/C capture session or 60-minute stress run was performed.
Capture continuity, stop-to-next-start latency, worker cancellation latency,
peak RSS, CPU/GPU/disk use, audio-device changes, memory pressure, and disk-full
behavior therefore have no hardware measurements. The deterministic tests
prove state ownership and ordering; they do not prove real audio continuity.
Keep the feature's release gate open until the manual measurements in
`docs/concurrent-recording-processing-plan.md` are resolved.
