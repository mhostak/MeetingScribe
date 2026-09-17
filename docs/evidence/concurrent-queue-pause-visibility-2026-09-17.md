# The processing queue stayed paused indefinitely

Base: `codex/concurrent-integration` @ `715caf0`. Fix branch:
`codex/concurrent-queue-pause-visibility`.

## Reproduction

The session "Test session - souběžná transkriopce a nahrávání" (17 Sep 2026,
13:15) stayed at `audio ✅ / transcript ⊖ / markdown ⊖` with a "Queued" badge.
The popover reported "Processing queue 1" and a header of "Ready". The recording
before it had ended in the safe stop that follows a system-audio capture
failure.

## Cause

1. On `captureIsHealthy == false`, `AppState.updateResourcePolicy()` calls
   `processingQueue.pause(reason:)`.
2. `ProcessingQueue.pause` only patches the **running** job to `pauseRequested`.
   A queued job stays `queued`, so neither the manifest nor the UI carried any
   trace of the pause, and `pauseReason` lived only in memory.
3. Resuming depended on `canResume`, which returned `.hold([])` — an empty
   reason list. When a condition stayed unmet the queue simply stood still with
   nothing to show for it.
4. The conditions that could stay unmet indefinitely: `resourceMemoryPressure`
   was only updated inside the `DispatchSourceMemoryPressure` handler, so a
   missed transition back to `.normal` left it on `.warning` forever, and
   `resumeAboveStorageBytes` was hardcoded to 3 GiB with no relation to the
   configured `minimumStorageBytes`.
5. `resourcePauseActive` in `AppState` mirrored the queue's own state. When
   `resume()` threw, the flag was already `false` and the resume was never
   retried.
6. `shutdown()` set `shuttingDown = true` permanently, so a cancelled
   application termination left the scheduler dead for the rest of the process.

No control anywhere in the UI could start a queued job. "Retry transcription"
hit the `canEnqueueProcessing` guard and returned silently.

## The policy that actually triggered it

`warning` memory pressure and a `serious` thermal state are the ordinary steady
state of a passively cooled Mac, not an exception. On the affected machine:

```
$ for i in 1 2 3 4 5; do sysctl -n kern.memorystatus_vm_pressure_level; sleep 2; done
2
2
2
2
2
$ sysctl -n kern.memorystatus_level
37
```

Pressure level 2 with 37% of memory free, held steady. Withholding background
work at that level meant the queue essentially never ran, and the missed return
to `normal` in point 4 above made it permanent.

Both levels now withhold work only while a capture is in flight, which is what
the invariant protects. The critical levels, where the system is about to
intervene itself, still stop work unconditionally.

## Changes

| File | Change |
|---|---|
| `Processing/ProcessingQueue.swift` | `ProcessingPauseKind`, `ProcessingQueuePause`, `ProcessingQueueStatus`; the pause is published through `ChangeHandler`; `status()`; a failed `resume()` keeps the pause in place and retryable; `cancelShutdown()`; a resource pause cannot overwrite a shutdown pause |
| `Processing/ProcessingResourceGovernor.swift` | `warning` memory and `serious` thermal withhold work only during capture; critical levels always do; `hold` carries the unmet resume conditions instead of `[]`; `ProcessingResourceLimits.backgroundReserve(captureMinimumBytes:)` |
| `Processing/ProcessingPresentation.swift` | `statusLabel(queueStatus:)` and `statusDetail(queueStatus:)`, so a queued job on a paused scheduler no longer reports "Queued" |
| `App/AppState.swift` | `processingQueueStatus` is the single source of truth (`resourcePauseActive` removed); localized pause reasons; `resumeProcessing()`; `abortTermination()`; memory pressure is polled via `kern.memorystatus_vm_pressure_level`; `memoryPressureSource` is assigned before `resume()`; the background reserve is derived from `minimumStorageBytes` |
| `App/MenuBarView.swift` | A banner with the pause reason and a "Resume processing" button |
| `App/RecordingsWindow.swift` | Per-row status and reason from the queue status, plus "Resume processing" for a held job |
| `App/MeetingScribeApp.swift` | A cancelled termination calls `abortTermination()` |
| `Resources/Localizable.xcstrings` | `Processing paused`, `Resume processing` (cs, sk) |

Deliberately unchanged: `ProcessingResourceLimits` remains a background-work
reserve distinct from the capture reserve, and `minimumStorageBytes` only raises
it to that floor. The thermal, memory and capture-health thresholds were already
complementary; only their reportability changed.

## Tests

Added or amended:

- `ProcessingQueueTests.testPauseIsPublishedWhileQueuedJobStaysQueued`
- `ProcessingQueueTests.testFailedResumeKeepsPauseVisibleAndRetryable`
  (fault injection by moving `session.json` aside)
- `ProcessingQueueTests.testCancelledShutdownRestartsTheScheduler`
- `ProcessingQueueTests.testResourcePauseDoesNotOverwriteShutdownPause`
- `ProcessingResourceGovernorTests.testBackgroundReserveRespectsCaptureMinimumAndKeepsHysteresis`
- `ProcessingResourceGovernorTests.testHoldInsideResumeBandStillReportsTheBlockingReason`
- `ProcessingResourceGovernorTests.testOrdinaryPressureDoesNotWithholdWorkWhileCaptureIsIdle`
- `ProcessingResourceGovernorTests.testCriticalLevelsWithholdWorkEvenWithoutCapture`
- `ProcessingResourceGovernorTests.testStoragePauseUsesHysteresisBeforeResuming` —
  the `.hold([])` expectation became `.hold([.storageReserve])`

## Verification status

`xcodebuild … CODE_SIGNING_ALLOWED=NO test` on macOS with Xcode 27.0:
**285 passed, 0 failed, 6 skipped**. The six skipped are the opt-in tests that
need real ASR model bundles or an hour of capture.

A manually signed build passed every check `AGENTS.md` requires before launch:
`codesign --verify --deep --strict`, the expected Authority and TeamIdentifier,
and the SHA-1 of the extracted certificate against the locally configured
identity. The paused-queue UI was confirmed on that build: the reason and the
resume control appear where the old build showed a silent "Queued".

Still open:

- The manual stress verification from chapter 9 of
  `docs/concurrent-recording-processing-plan.md` (60+ minutes of capture, a large
  backlog, induced memory pressure, an audio device change) has not been run.
- Nothing prevents two MeetingScribe instances from writing to the same
  `Recordings` directory, although the invariants assume a single owner. This
  surfaced while verifying the fix and belongs in a separate task: a lock on the
  recordings root at startup.
- `restore()` does not distinguish a manually paused job from a resource pause
  after a restart, which chapter 6 of the plan requires.
