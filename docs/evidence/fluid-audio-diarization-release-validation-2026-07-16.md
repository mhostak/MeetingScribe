# FluidAudio diarization release validation — 2026-07-16

Status: failed; current `community-1` diarization rejected for production speaker identity and further implementation paused

This evidence contains aggregate measurements only. It includes no transcript text, participant names, email addresses, meeting title, Calendar identifiers, local audio paths, or audio content. Detailed source material remains local and was evaluated with participant consent.

## Candidate

- Signed MeetingScribe build from source revision `9ce12400bed621127bb61ff3b7ba0820a9475e45`.
- FluidAudio SDK `0.15.5`.
- Pinned offline speaker-diarization model revision `1ed7a662fdc7109e36d822db793ee6eebdaf8594`.
- Microsoft Teams, mixed Czech/Slovak.
- 10 actual speakers reported by a meeting participant.
- Recording duration 6,122.54 seconds (102.04 minutes).
- Reference machine: Apple M2 MacBook Air with 16 GB RAM; not the oldest supported Apple Silicon target.

## Capture and transcription controls

- System and microphone WAV tracks finalized without capture warnings.
- System ASR: 815 segments, 185.33 seconds wall time, 33.04x real time.
- Microphone ASR: 158 segments, 121.27 seconds wall time, 50.49x real time.
- Raw merge: 973 non-empty segments.
- Resolved output preserved all 973 raw source segment IDs with no missing, extra, reversed, or out-of-range source timings.
- Export completed and the JSON artifact set passed structural validation.
- Combined system ASR, microphone ASR, and diarization wall time was 8.02% of recorded duration.

These controls support the FluidAudio ASR, capture, artifact-integrity, and export paths. They do not compensate for failed speaker identity.

## Automatic diarization failure

- Automatic output: 936 turns and two anonymous system-speaker clusters.
- Actual meeting: 10 people spoke.
- Direct participant review found that speech from at least one real person was split between both generated clusters.
- Speaker-count gate: failed by a wide margin, whether or not the count includes the separately captured local microphone speaker.
- Identity-consistency gate: failed.
- DER: deliberately unreported because no time-aligned reference annotation exists.

The count miss and direct identity split are sufficient to reject the model configuration without inventing a DER score.

## Non-destructive exact-count experiments

Both experiments used the same audio, SDK, pinned model, and production defaults. Only the exact system-speaker constraint changed. Outputs were stored outside the recording and did not overwrite its audio or transcript artifacts.

| Exact clusters | Segments | Assigned speech | Inference wall time | Maximum RSS | Peak footprint |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 9 | 920 | 2,964.08 s | 87.41 s | 805,912,576 B | 889,537,904 B |
| 10 | 926 | 2,970.31 s | 110.56 s | 702,971,904 B | 885,523,752 B |

Both runs began from the same 2,773 valid embeddings. The unconstrained warm start contained 57 mostly tiny clusters before FluidAudio re-clustered all embeddings into the requested number of centroids.

After optimal one-to-one anonymous-label alignment:

- shared speech timeline: 2,929.445 seconds;
- agreement: 2,658.900 seconds (90.76%);
- different cluster assignment: 270.545 seconds (9.24%);
- the unmatched tenth cluster contained 91.123 seconds;
- of that cluster's 88.661 seconds overlapping the 9-cluster variant, 54.81% came from one prior identity and 44.25% from another.

Forcing the expected count prevents the two-cluster under-count but does not establish consistent people. The extra cluster was not a clean extraction of one previously merged identity, and the partition changed globally.

## Product decision

- FluidAudio Parakeet ASR remains the only accepted transcription runtime.
- `community-1` diarization is not accepted as reliable speaker identity.
- Anonymous labels such as `Speaker 1` and `Speaker 2` must not be described as trustworthy people.
- Further recognition, naming, and attendee-to-speaker mapping implementation is paused for the current model.
- Existing schemas, derived artifacts, editor code, recovery, and backward compatibility remain preserved; their existence is not a quality claim.
- Work may resume only when a future model passes speaker-count, identity-consistency, labeled DER, privacy, and resource gates on the acceptance matrix.
