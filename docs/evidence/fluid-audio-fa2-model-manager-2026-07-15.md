# FluidAudio FA2 model-manager evidence — 2026-07-15

Status: archival evidence. The diarization bundle and its Settings row described below were later removed; the current app manages only the Parakeet ASR bundle.

This record covers the FA2 production model manager and Settings implementation. It intentionally contains no meeting audio, transcript text, participant names, or Calendar data.

## Pinned inputs

- FluidAudio Swift package: exact version `0.15.5` in SwiftPM and the Xcode application target.
- Parakeet ASR repository: `FluidInference/parakeet-tdt-0.6b-v3-coreml`.
- Parakeet revision: `aed02740059203c4a87495924f685de3722ae9ce`.
- Parakeet variant: `v3-int8`; 21 required files with pinned byte sizes and SHA-256 hashes.
- Speaker-diarization repository: `FluidInference/speaker-diarization-coreml`.
- Speaker-diarization revision: `1ed7a662fdc7109e36d822db793ee6eebdaf8594`.
- Diarization variant: `offline-community-1`; 21 required files with pinned byte sizes and SHA-256 hashes.

The application constructs download URLs from the immutable revision rather than a moving branch. Every promoted bundle contains `.meetingscribe-model-manifest.json` and must match the app-owned descriptor.

## Implemented behavior

- per-file download into a unique `.staging` directory with aggregate byte progress;
- cooperative cancellation and cleanup of abandoned staging directories;
- exact file-size and SHA-256 verification before installation;
- verified import of an existing directory with the same checks as a download;
- actual FluidAudio model initialization from staging before promotion;
- atomic promotion or replacement, preserving the previous installed bundle when validation fails;
- repair that reuses valid installed files and fetches only missing or invalid files;
- repeated offline validation with `ModelHub.offlineMode` enabled;
- explicit, model-scoped deletion;
- separate localized Parakeet and diarization rows in Settings with Download, Cancel, Verify and repair, Import, and Delete actions at the time of this evaluation.

The normal Settings status refresh intentionally checks the manifest and expected byte sizes so opening Settings does not repeatedly hash roughly 500 MiB. The explicit **Verify and repair** action performs the full cryptographic and FluidAudio load validation.

## Automated validation

`FluidAudioModelManagerTests` covers:

- immutable production revisions and a SHA-256 for every expected file;
- manifest writing, load validation, and promotion;
- corrupt-file detection and selective repair;
- preservation of the previous bundle after a failed replacement;
- cancellation without a promoted or staged partial bundle;
- disk-full failure without partial promotion;
- rejection of an imported bundle with a wrong hash;
- repeated offline validation without invoking the downloader;
- deletion of only the selected model;
- an opt-in real-bundle import and offline reload test.

The synthetic manager suite passed with 9 tests and 0 failures. The opt-in real-bundle test separately imported the pinned local Parakeet and speaker-diarization directories, verified all 42 files, initialized each model from staging, promoted both bundles, and initialized them again offline; 1 test passed with 0 failures.

Final validation after the implementation, project wiring, localization, and documentation changes:

- SwiftPM: 202 tests executed, 14 opt-in integration tests skipped, 0 failures;
- shared Xcode `MeetingScribe` scheme: `TEST SUCCEEDED` with FluidAudio resolved at exact version `0.15.5`;
- localization catalog: valid JSON and successfully compiled by `xcstringstool` for English, Slovak, and Czech;
- Xcode project file: valid property list;
- `git diff --check`: clean.

## Signed-build evidence

Build configuration: Debug, manual signing with the maintainer's locally configured Apple Development team and certificate.

- app: `/private/tmp/MeetingScribe-current-signed-derivedData/Build/Products/Debug/MeetingScribe.app`;
- `codesign --verify --deep --strict --verbose=4`: valid on disk and satisfies its Designated Requirement;
- authority, Team identifier, and leaf-certificate fingerprint: verified against the maintainer's then-local signing configuration; values intentionally omitted from the public record.

The build was verified but not launched because this step does not replace or exercise the user's currently installed/running application.

## Remaining FA2 acceptance

One manual pass in the signed application remains: exercise Download, Cancel, Verify and repair, Import, and Delete for both model rows while no recording is started. A complete large-model HTTP download was not claimed by the automated suite; its transport is covered with controlled download doubles, while the real bundles cover exact manifest, import, load, promotion, and offline reuse.
