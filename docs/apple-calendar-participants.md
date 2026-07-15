# Apple Calendar and participants

Status date: 2026-07-15

## Delivery status

| Phase | Status | Delivery boundary |
| --- | --- | --- |
| Phase A — consent-first Calendar metadata | Complete | Select one nearby event, explicitly confirm attendees, and persist a privacy-minimized snapshot for the recording. |
| Phase B — attendee-to-speaker mapping | Deferred | Map confirmed attendees to anonymous diarization clusters and regenerate speaker-resolved output without retranscribing audio. |

Phase B is intentionally deferred. It depends on the separate [Speaker recognition and management implementation plan](speaker-recognition-management-plan.md), because Calendar attendees are only candidate names and cannot identify voices by themselves.

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

## Resume criteria for Phase B

Phase B can start only when the speaker prerequisite provides all of the following:

- stable session-scoped speaker identifiers independent of display names;
- a persisted diarization artifact tied to a fingerprint of the source transcript/audio;
- deterministic assignment of transcript segments to anonymous speakers, including an explicit ambiguous or unknown state;
- a speaker-management UI that can rename and merge clusters;
- a derived speaker-resolved transcript that can be regenerated without changing raw track transcripts;
- backward-compatible loading of sessions that contain no speaker artifacts;
- tests proving that rename and mapping operations cannot silently change raw transcription data.

## Invariants

- Calendar is a candidate metadata source, not an identity authority.
- User confirmation is required at the system permission, event, attendee, and attendee-to-speaker mapping boundaries.
- Raw audio and raw track transcripts remain unchanged by speaker naming.
- Biometric identification and cross-session voice profiles remain out of scope.
- Phase B must preserve the ability to use the application with Calendar integration disabled.
