# Apple Calendar and participants

Status date: 2026-09-15

## Delivery status

| Phase | Status | Delivery boundary |
| --- | --- | --- |
| Phase A — consent-first Calendar metadata | Complete | Select one nearby event, explicitly confirm attendees, and persist a privacy-minimized snapshot for the recording. |
| Phase B — attendee-to-speaker mapping | Permanently retired | The diarization runtime and speaker-management UI were removed after the model failed real multi-speaker validation. |

Phase B is permanently retired. The former FluidAudio `community-1` model did not produce trustworthy speaker clusters in a 10-speaker real meeting, so its runtime, data-processing path, and editor were removed. Calendar attendees remain user-confirmed metadata only; MeetingScribe does not map them to voices.

## Phase A — complete

Phase A is accepted as implemented with these guarantees:

- the integration is disabled by default and EventKit is not queried at launch;
- Calendar configuration lives in the native application Settings window;
- the app requests full Calendar access through the macOS EventKit API and exposes a route to System Settings when access is denied;
- nearby events are ranked using recording or current time, overlap, distance, and all-day status;
- the event picker is an independent foreground window and remains open until the user confirms or cancels it;
- event title use is explicit and never silently replaces a manually edited recording title;
- every attendee is unselected by default and only explicitly selected display names are retained;
- the session snapshot stores the event title, interval, confirmation time, selected display names, participant-sharing flag, and optional edited event description;
- attendee email addresses, calendar and event identifiers, calendar names, location, URLs, organizer fields, and unconfirmed candidates are not separately persisted; an included free-form description may contain these details;
- a confirmed snapshot can be attached before or during recording and survives recovery through current schema 16 session metadata;
- Markdown participants use confirmed names; selecting attendees and confirming the current picker also enables their use when AI analysis runs, without a second sharing toggle;
- disabling the integration stops future Calendar reads but preserves already confirmed snapshots so previous output remains reproducible.

### Description and AI-sharing behavior

The picker loads Calendar notes into an editable description and initially enables **Include event description** when the event has one. The user can edit, omit, or add a description before confirming. Included text is persisted and exported in the Markdown `calendar_description` frontmatter field. It is also included in AI requests when analysis is enabled, independently of the participant-sharing flag. Audio remains local, but the selected CLI can send this text and the transcript to its provider.

Current confirmation sets participant sharing to true when any attendees are selected. Older snapshots with that flag false still withhold participant names from AI. Turning off Calendar integration does not remove previously confirmed metadata or change the saved analysis inputs.

The implementation is covered by the standard automated suite, including consent boundaries, ranking, persistence, recovery compatibility, Markdown rendering, and AI-sharing privacy. The signed application was also exercised through the native Calendar permission and picker UI.

## Phase B — retired

MeetingScribe will not infer a person's identity from Calendar membership or map attendees to voices. Historical `speaker-diarization.json` and `resolved-transcript.json` files are retained as untouched session artifacts for compatibility, but they are not read, regenerated, or exposed in the UI. Calendar names are sent to an external AI provider only when the saved participant-sharing flag is enabled; current attendee confirmation enables that flag for selected names.

## Invariants

- Calendar is a candidate metadata source, not an identity authority.
- User confirmation is required at the system permission, event, and attendee boundaries.
- Raw audio and raw track transcripts remain unchanged by Calendar metadata.
- Biometric identification and cross-session voice profiles remain out of scope.
- Phase B must preserve the ability to use the application with Calendar integration disabled.
