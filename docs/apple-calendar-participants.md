# Apple Calendar and participants

Status date: 2026-07-15

## Delivery status

| Phase | Status | Delivery boundary |
| --- | --- | --- |
| Phase A — consent-first Calendar metadata | Complete | Select one nearby event, explicitly confirm attendees, and persist a privacy-minimized snapshot for the recording. |
| Phase B — attendee-to-speaker mapping | Deferred by product decision; prerequisite complete | Map confirmed attendees to anonymous diarization clusters and regenerate speaker-resolved output without retranscribing audio. |

Phase B remains intentionally deferred. Its separate [Speaker recognition and management](speaker-recognition-management-plan.md) prerequisite is now implemented: MeetingScribe persists stable anonymous speaker IDs, resolves transcript words to those speakers, and exposes a session editor. Calendar attendees are still only candidate names and cannot identify voices by themselves, so attendee-to-speaker mapping remains an explicit future consent step rather than an automatic consequence of diarization.

## Phase A — complete

Phase A is accepted as implemented with these guarantees:

- the integration is disabled by default and EventKit is not queried at launch;
- Calendar configuration lives in the native application Settings window;
- the app requests full Calendar access through the macOS EventKit API and exposes a route to System Settings when access is denied;
- nearby events are ranked using recording or current time, overlap, distance, and all-day status;
- the event picker is an independent foreground window and remains open until the user confirms or cancels it;
- event title use is explicit and never silently replaces a manually edited recording title;
- every attendee is unselected by default and only explicitly selected display names are retained;
- the session snapshot stores the event title, interval, confirmation time, selected display names, and the per-meeting AI-sharing choice;
- email addresses, calendar and event identifiers, calendar names, location, notes, URLs, organizer data, and unconfirmed candidates are not persisted;
- a confirmed snapshot can be attached before or during recording and survives recovery through schema 10 session metadata;
- Markdown participants use confirmed names, while external AI receives them only after the separate per-meeting opt-in;
- disabling the integration stops future Calendar reads but preserves already confirmed snapshots so previous output remains reproducible.

The implementation is covered by the standard automated suite, including consent boundaries, ranking, persistence, recovery compatibility, Markdown rendering, and AI-sharing privacy. The signed application was also exercised through the native Calendar permission and picker UI.

## Phase B — deferred

Phase B will not attempt to infer a person's identity from Calendar membership. After diarization produces stable anonymous clusters such as `Speaker 1` and `Speaker 2`, the user will be able to:

1. review the anonymous speakers and representative transcript segments;
2. map an explicitly confirmed Calendar attendee to a speaker cluster;
3. leave a cluster unknown or enter a non-Calendar display name;
4. change or remove a mapping later;
5. regenerate the resolved transcript, Markdown, and optional analysis input without rerunning speech-to-text or diarization.

The mapping remains local session data. Calendar names are sent to an external AI provider only when the existing per-meeting participant-sharing consent is enabled.

## Phase B prerequisite status

The speaker prerequisite now provides every required handoff contract:

- [x] stable session-scoped speaker identifiers independent of display names;
- [x] a persisted diarization artifact tied to fingerprints of the source transcript and audio;
- [x] deterministic word-level assignment to anonymous speakers, including explicit overlapping and unmatched states;
- [x] a speaker-management UI that can rename, classify, and merge clusters;
- [x] a derived speaker-resolved transcript and Markdown that can be regenerated without changing raw track transcripts;
- [x] backward-compatible loading of sessions that contain no speaker artifacts;
- [x] missing-model, failure, cancellation, and checkpoint recovery fallbacks;
- [x] tests proving that saved speaker edits cannot silently change raw transcription data.

Phase B may therefore start when it is reprioritized; no further diarization data-model migration is required. Final labeled DER, oldest-hardware memory, and signed long-session measurements remain release-quality gates for diarization, but they do not block implementation of the explicit attendee-mapping UI and persistence contract.

## Invariants

- Calendar is a candidate metadata source, not an identity authority.
- User confirmation is required at the system permission, event, attendee, and attendee-to-speaker mapping boundaries.
- Raw audio and raw track transcripts remain unchanged by speaker naming.
- Biometric identification and cross-session voice profiles remain out of scope.
- Phase B must preserve the ability to use the application with Calendar integration disabled.
