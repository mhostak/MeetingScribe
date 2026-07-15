# FluidAudio FA0 reproducibility baseline

Date: 2026-07-15

This record contains aggregate, non-transcript evidence for the approved FluidAudio migration direction. It deliberately excludes transcript text, participant names, complete local paths, audio, and device identifiers.

## Reviewed dependencies

| Component | Version or revision | License decision |
| --- | --- | --- |
| FluidAudio SDK | `0.15.5`, Git commit `19600a485baa4998812e4654b70d2bab8f2c9949` | Apache 2.0 |
| Parakeet TDT 0.6B v3 Core ML | `FluidInference/parakeet-tdt-0.6b-v3-coreml`, repository revision `aed02740059203c4a87495924f685de3722ae9ce` | CC BY 4.0 attribution, following repository metadata and the NVIDIA parent model |
| Offline speaker diarization | `FluidInference/speaker-diarization-coreml`, repository revision `1ed7a662fdc7109e36d822db793ee6eebdaf8594` | CC BY 4.0 attribution, following repository metadata and the pyannote parent model |

The model revisions above were returned by the official Hugging Face repository API when FA0 was recorded. FA2 must request these revisions explicitly and must not treat a moving `main` branch as equivalent to this review.

## Test environment

- MacBook Air with Apple M2, 8 CPU cores, and 16 GB memory;
- macOS 26.5.2, build `25F84`;
- completed recording `2026-07-15T11-03-35Z_086BA6`, duration approximately 83.7 minutes;
- system and microphone audio finalized as independent 16 kHz mono WAV tracks;
- FluidAudio batch ASR used Parakeet v3 with no mel context, dual-decode arbitration, and no forced language hint;
- offline diarization used `community-1`, exclusive segments, and clustering threshold `0.7`.

The original run did not capture peak resident memory. Peak RSS is therefore not accepted by this record and remains a mandatory FA3/FA7 measurement.

## Aggregate results

| Operation | Aggregate result | Wall time | Calculated speed |
| --- | ---: | ---: | ---: |
| System ASR | 7,264 words, mean confidence `0.93405676` | `138.86118400096893` s | 36.2x real time |
| Microphone ASR | 279 words, mean confidence `0.8848032` | `131.74655306339264` s | 38.1x real time |
| System diarization | 633 segments, 3 anonymous clusters | `57.973122000694275` s | `86.65532968777906`x real time |

The upstream ASR JSON reported `durationSeconds = 0` and `rtfx = 0` for both tracks. The speeds above were calculated independently from finalized audio duration and wall time. Production code must continue to own those calculations.

## Evidence fingerprints

The source reports remain ignored under `.derivedData` because the ASR reports contain transcript text. These fingerprints allow a local operator to verify that the same evidence is being inspected without committing it:

| Local evidence | SHA-256 |
| --- | --- |
| system Parakeet v3 JSON report | `72ca03573a237075f080119904203760b240d53259a91f7853a445e292ec244e` |
| microphone Parakeet v3 JSON report | `3a87fcbcafeaac5205840f223b6233831812739693178c5239d95a76629a97ff` |
| final offline system-diarization JSON report | `dd4adde913ec0464ece495273337eae25fe09816192a1813e3a0109c6c57c95b` |
| finalized system WAV recorded by the diarization report | `70d3fe9cdb1bcd3d1b3ac8277ab719ac49e15b1604fa47b5bce8457db782683b` |

Installed-cache snapshots at the time of this record:

| Cache | Files | Allocated size | Aggregate tree digest |
| --- | ---: | ---: | --- |
| Parakeet v3 compiled bundle | 23 | 471,980 KiB | `b6a44d3e978b4ddd45a22cfdd9683e7adac46edd46f89e9abb878ee694e6fb06` |
| Diarization compiled bundle | 23 | 21,316 KiB | `e900c440f860742773a122567d2c7455a0b978db5761a2d3ce9474302b19f079` |

Each aggregate tree digest is the SHA-256 of the sorted per-file SHA-256 listing. Compiled Core ML cache output may vary with the operating system; FA2 verification must use pinned source-manifest hashes rather than treating these compiled-cache digests as portable download checksums.

## Remaining acceptance evidence

- peak RSS for ASR and diarization;
- oldest-supported Apple Silicon measurements;
- labeled Czech/Slovak DER and speaker-count fixtures;
- overlap, echo, music, sparse microphone, silence, and recovery cases;
- signed-application model installation, offline reload, repair, and deletion.
