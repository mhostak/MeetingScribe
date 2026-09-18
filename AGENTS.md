# MeetingScribe project instructions

## Runnable local macOS builds

When the user asks Codex to build or run MeetingScribe locally, produce a properly signed app. An unsigned build is acceptable only for CI-style compile validation, never as the build handed to or launched for the user.

1. Build the requested commit (normally current `origin/main`) in a clean checkout or isolated worktree.
2. Before building, verify that the certificate fingerprint and Team ID configured in the unversioned `Config/Signing.local.xcconfig` are available. If the configured identity is unavailable, stop and report the blocker; do not silently use another identity. Initialize that file from `Config/Signing.local.xcconfig.example`; do not put personal signing values in a versioned file.
   Run the identity lookup, signed build, and every `codesign` trust check outside the workspace sandbox. The sandbox cannot access the login Keychain on this machine and produces the false result `CSSMERR_TP_NOT_TRUSTED` for an otherwise valid bundle. A sandboxed identity or trust failure is not evidence of a broken certificate chain; repeat the same check with escalated execution before reporting a blocker.
3. Use manual signing. `Config/Signing.xcconfig` supplies the shared settings and the local override supplies the developer-specific identity:

   ```sh
   xcodebuild \
     -project MeetingScribe.xcodeproj \
     -scheme MeetingScribe \
     -configuration Debug \
     -derivedDataPath /private/tmp/MeetingScribe-current-signed-derivedData \
     CODE_SIGNING_ALLOWED=YES \
     CODE_SIGNING_REQUIRED=YES \
     CODE_SIGN_STYLE=Manual \
     build
   ```

4. Never use `CODE_SIGNING_ALLOWED=NO` for a user-facing or locally launched build.
5. Before launching, require all of these checks to pass:
   - `codesign --verify --deep --strict --verbose=4 <MeetingScribe.app>`
   - `codesign -dv --verbose=4 <MeetingScribe.app>` reports the Authority and TeamIdentifier configured locally
   - the extracted signing certificate has the SHA-1 fingerprint configured locally
6. When replacing a running build, terminate older MeetingScribe instances first. After launch, verify that only the intended app path is running.

## After updating `main`

Whenever Codex pushes or otherwise lands a new MeetingScribe version on the Git remote's `main` branch, treat installation and launch as part of the same workflow; do not consider the update complete until all of the following steps succeed:

1. Confirm the exact commit now at `origin/main` and build that commit in a clean checkout or isolated worktree using the signing requirements above.
2. Pass every signing and certificate check above before installing the app.
3. Terminate any running MeetingScribe instance, then replace `/Applications/MeetingScribe.app` with the newly built signed bundle. The user has explicitly authorized this replacement for future `main` updates in this project.
4. Verify the installed `/Applications/MeetingScribe.app` again with the required `codesign` checks, launch that installed bundle, and confirm that it is the only MeetingScribe instance running.
5. If building, signing, installation, verification, or launch fails, report the blocker clearly and do not launch an older, unsigned, differently signed, or wrong-commit build as a fallback.

## Running the tests

This project has **two** test suites, and they do not cover the same thing:

- the Xcode scheme (`MeetingScribeTests` hosted by the app), which the assistant build daemon's
  `test` job runs, and
- the SwiftPM package (`Package.swift`), which CI runs as a separate `swift test` job.

A green daemon run therefore does not mean CI is green. The suites compile a different set of
sources — `Package.swift` excludes the SwiftUI entry point and several views — and `swift test`
runs every test in one process with a different environment, so a change can pass one and fail the
other. It has happened: a test-host guard keyed off `XCTestConfigurationFilePath` passed under
Xcode and failed under `swift test`, which sets none of those variables. Run both before pushing a
branch for review.

Running `swift test` from a checkout under `~/Documents` may fail while signing the test bundle:

```
MeetingScribeTests.xctest: resource fork, Finder information, or similar detritus not allowed
error: CodeSign ... failed with a nonzero exit code
```

Build outside the checkout instead, which avoids it reliably:

```sh
swift test --scratch-path /private/tmp/MeetingScribe-spm
```

`xattr -cr .build` sometimes clears the failure for one run, but it comes back on the next relink.
The daemon and CI both build elsewhere and are unaffected.
