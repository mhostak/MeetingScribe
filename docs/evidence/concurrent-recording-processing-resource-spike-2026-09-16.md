# Concurrent recording and processing resource spike — 2026-09-16

## Scope

This is the T1/T6 implementation record for commit based on
`7109bd92132ed0d917fdaed48fb75b6133e4cba4`. It records source inspection and
deterministic tests only. It does not claim a signed, real-audio concurrency
measurement or a capture reliability result.

## FluidAudio 0.15.5 audit

The resolved package is FluidAudio `0.15.5` (`19600a485baa4998812e4654b70d2bab8f2c9949`) in:

`/private/tmp/MeetingScribe-current-signed-derivedData/SourcePackages/checkouts/FluidAudio`.

`ASRConfig.parallelChunkConcurrency` is immutable after `AsrManager` creation.
The long-form `ChunkProcessor` uses it to bound cloned stateless chunk workers;
one is the lowest supported value. The application profile is therefore set to
one before any capture begins, and the manager cache key includes the complete
configuration as well as the model URL.

The SDK has cooperative checks before/after many pipeline steps and decoder
loops. Its Core ML `compatPrediction` calls are awaited but expose no public
pause, cancellation token, or bounded interruption. An in-process task
cancellation can consequently wait for an active prediction and is not a
capture-protection guarantee.

## Implemented boundary

`ProductionFluidAudioASRRunner` now starts the application executable with
`--meetingscribe-fluid-audio-worker`. The worker owns the `AsrManager`, receives
only an atomic JSON request containing audio/model paths and fixed ASR config,
and atomically writes a whole-track result. On cancellation the supervisor
sends `terminate` to that exact `Process`; after a two-second grace interval it
sends `SIGKILL` only while the same owned `Process` is still running. The
processing queue must await task termination before it calls a job paused and
releases its worker slot. This makes the checkpoint a complete track, not a
partially persisted ASR chunk.

`ProcessingResourceGovernor` is pure and injectable. Healthy capture is
allowed to coexist with the single ASR worker. Memory pressure, serious/critical
thermal state, insufficient background disk reserve, or unhealthy active
capture produces `cancelRunning`; an idle queue receives `hold`. Disk resume
uses a larger threshold to avoid oscillation. The production observer and queue
must map platform diagnostics into `ProcessingResourceSnapshot` and perform the
cancel/await/release sequence; the policy itself does not pretend to throttle
CPU, GPU, or I/O.

## Automated evidence

`ProcessingResourceGovernorTests` covers healthy concurrent capture, pressure
cancellation, capture-health cancellation, and storage hysteresis.
`FluidAudioTranscriptionServiceTests.testIsolatedWorkerCancelsOnlyItsOwnedProcess`
starts a controlled worker fixture and cancels it; no user recording, model, or
AI analysis is started.

## Open release gates

The following must be measured in a signed application before concurrent
processing is enabled for users: capture baseline versus ASR during capture,
stop/handoff latency, worker cancellation latency, peak RSS, CPU/GPU/disk use,
capture frame continuity, memory pressure, thermal state, storage exhaustion,
and resume transcript integrity. The two-second hard-kill grace is a safety
bound, not an accepted performance target. The runtime dispatcher must invoke
`FluidAudioASRWorker.runIfRequested()` before SwiftUI constructs `AppState`.
