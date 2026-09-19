# Assistant build daemon

The coding assistant works in an isolated Linux sandbox. It has no Xcode, no
`codesign`, no access to the login Keychain and none to `/Applications`. It
therefore cannot claim that the code compiles or that the tests pass.

This daemon closes that gap. It runs in the logged-in GUI session as a
LaunchAgent, reads requests from a file queue inside the repository and executes
a **fixed set of named jobs**. The assistant writes a request, the daemon runs
it, the assistant reads the result.

## Installation

```sh
scripts/install-assistant-build-daemon.sh
```

The installer either ends with `daemon is running (pid …)` or sends you to grant
Full Disk Access — see below. Then:

```sh
python3 scripts/assistant_build_client.py ping
```

`ping` confirms that the daemon is alive, that `xcodebuild` works, which
MeetingScribe binary is currently running, and that the certificate configured
in `Config/Signing.local.xcconfig` is available for codesigning.

### Why an app bundle and Full Disk Access

A LaunchAgent has its own TCC identity. When the repository lived under a
TCC-protected directory such as `~/Documents`, that identity could not even open
the script:

```
python3: can't open file '.../assistant_build_daemon.py': [Errno 1] Operation not permitted
```

Since the move to `~/Dev/projects/MeetingScribe` that particular reason no
longer applies: the new location is not TCC-protected. The bundle stays because
the daemon also replaces `/Applications/MeetingScribe.app` and reads the login
Keychain, and because a named bundle keeps the grant attached to this daemon
rather than to every python process. If you move the repository again, re-run
the installer from the new location — the grant follows the bundle, not the
repository.

It worked from Terminal because Terminal has access to Documents. Granting Full
Disk Access to `/usr/bin/python3` directly would hand that access to every
python process on the machine, so the installer builds a dedicated bundle
instead:

```
~/Applications/MeetingScribeBuildDaemon.app
```

Its main executable is about 60 lines of C (`scripts/assistant_build_launcher.c`).
It deliberately does **not** `exec` python: it stays alive as the parent so the
python child inherits its TCC responsibility. That is the same mechanism which
gives everything started from Terminal Terminal's own access. Replacing the
process image would hand the identity back to python3 and the grant would not
apply.

Grant it once:

1. System Settings → Privacy & Security → Full Disk Access
2. `+`, then Cmd+Shift+G and paste `~/Applications/MeetingScribeBuildDaemon.app`
3. Turn the switch on
4. `launchctl kickstart -k gui/$(id -u)/com.meetingscribe.assistant-build`

The binary is signed with the identity from `Config/Signing.local.xcconfig` when
one is available, which keeps the grant valid across rebuilds. Without it the
signature is ad-hoc and the installer says so: every rebuild changes the cdhash
and the grant has to be set again. The installer therefore only recompiles the
binary when its inputs actually changed.

The grant also covers everything the daemon spawns — `git`, `xcodebuild`,
`codesign`. That is intended; without it the build could not read the
repository.

Status and shutdown:

```sh
scripts/install-assistant-build-daemon.sh --status
scripts/install-assistant-build-daemon.sh --uninstall   # agent and bundle
launchctl bootout gui/$(id -u)/com.meetingscribe.assistant-build   # stop only
```

After `--uninstall`, remove the orphaned Full Disk Access entry as well.

## Security model

This extends the sandbox boundary, so the boundary has to stay narrow and
explicit.

- **No shell.** The daemon never evaluates a command line from a request. Every
  argument is either a constant or a value validated against a strict pattern.
- **A fixed set of jobs.** `ping`, `test`, `build-signed`, `codesign-verify`,
  `install`, `push-branch`. An unknown job is rejected.
- **Three free-form values.** A git ref (`[A-Za-z0-9._/-]`, no `..`), a test
  identifier (`Target/Class/method`) and a request id. Nothing else in a request
  influences the command that runs.
- **Isolated worktrees.** Every job creates a detached worktree under
  `/private/tmp`. Your checkout and your uncommitted work are never touched. A
  successful job removes its worktree; a job that fails to build, to produce a
  bundle, or to pass a signing check keeps it for inspection.
- **`push-branch` never pushes main.** It accepts only a branch matching
  `^codex/[A-Za-z0-9][A-Za-z0-9._/-]*$` and rejects `main`, `master` and `HEAD`
  by name. It never uses `--force`, so the server rejects a non-fast-forward. It
  also refuses to push a commit that has no succeeded `test` result on record —
  the one place in this pipeline that enforces "do not publish what you have not
  verified". Merging into main stays with pull requests, and with you.
- **`install` only from `origin/main`.** It refuses a bundle whose commit is not
  the one currently at `refs/remotes/origin/main`, exactly as `AGENTS.md`
  authorizes. The local `refs/heads/main` deliberately does not count: it lives
  in a repository the requester can write, so accepting it would let a branch
  move stand in for review. A one-off
  exception is yours to grant by creating
  `.claude/build-queue/ALLOW_NONMAIN_INSTALL`. The assistant cannot create that
  file without asking you.
- **The signature is verified twice.** Before replacing `/Applications` and
  after, always with all three checks from `AGENTS.md`:
  `codesign --verify --deep --strict`, Authority/TeamIdentifier, and the SHA-1 of
  the extracted certificate against the locally configured value.
- **The fingerprint is never logged.** It is read from the unversioned
  `Config/Signing.local.xcconfig` and reaches neither the log nor the result —
  the result only says "matches" or "does NOT match".
- **The previous bundle is kept.** `install` renames the old
  `/Applications/MeetingScribe.app` to `MeetingScribe.app.previous-<stamp>`
  rather than deleting it, and keeps exactly one such rollback copy. The path is
  in the result.
- **Full Disk Access is scoped to one bundle.** The grant belongs to
  `~/Applications/MeetingScribeBuildDaemon.app`, not to an interpreter. It can be
  revoked as a single entry, independently of the rest of the system.
- **No Keychain password in a file.** A LaunchAgent runs in your session, so the
  login Keychain is unlocked. If it is locked, `build-signed` ends with a clear
  blocker instead of a background UI prompt.

What the daemon does **not** do: it never merges, never pushes `main`, never
deletes branches, never changes system settings, and never runs anything that is
not in the job list.

## Jobs

| Job | What it does | Side effects |
|---|---|---|
| `ping` | `xcodebuild -version`, codesigning identity availability, which MeetingScribe is running | none |
| `test` | `CODE_SIGNING_ALLOWED=NO … test` in a detached worktree | none; the bundle is never installed or launched |
| `build-signed` | Manually signed Debug build plus all three `codesign` checks | produces a bundle under `/private/tmp`, records it in `state.json` |
| `codesign-verify` | The three checks against `installed` or `last-build` | none |
| `install` | Terminates running instances, replaces `/Applications/MeetingScribe.app`, re-verifies, launches, confirms a single settled instance | replaces the installed application |
| `push-branch` | Pushes one `codex/*` branch to origin | publishes commits to GitHub |

`test` and `build-signed` time out after 45 minutes.

## Jobs added after the first version

| Job | What it does | Side effects |
|---|---|---|
| `fetch` | `git fetch --prune origin` | updates remote-tracking refs only, never a local branch |
| `session-report` | Processing state and the event log of recent recording sessions | none; read-only |

`session-report` exists because the recordings live outside the repository, in a
location the sandbox cannot reach, so a processing failure could otherwise only
be guessed at. It reports the job fields (state, stage, failure description) and
the event log, plus which artifacts exist. Transcript, markdown and audio
content stay out: meeting content is none of this pipeline's business.

`fetch` exists because `install` may only install the commit at `origin/main`,
so a stale remote-tracking ref would make that guard compare against the wrong
commit.

## Usage

```sh
python3 scripts/assistant_build_client.py test --ref codex/my-branch
python3 scripts/assistant_build_client.py test --only-testing MeetingScribeTests/ProcessingQueueTests
python3 scripts/assistant_build_client.py build-signed --ref main
python3 scripts/assistant_build_client.py install
python3 scripts/assistant_build_client.py push-branch --ref codex/my-branch
python3 scripts/assistant_build_client.py status
python3 scripts/assistant_build_client.py await 20260917-143000-test
```

The client prints the status, the individual steps, the failed tests or compiler
errors, and the tail of the log. The exit code is 0 only for `succeeded`.

## Protocol

The queue is `.claude/build-queue/` and is fully gitignored (`*` in its own
`.gitignore`).

```
requests/<id>.json      request, written by the client
results/<id>.json       result, written atomically by the daemon
logs/<id>.log           full xcodebuild output
archive/<YYYY-MM>/      processed requests
state.json              daemon run, last signed build
daemon.log              daemon log
daemon.lock             pid; prevents two daemons
ALLOW_NONMAIN_INSTALL   created only by the user, allows one non-main install
```

A request:

```json
{
  "id": "20260917-143000-test",
  "job": "test",
  "ref": "codex/concurrent-queue-pause-visibility",
  "only_testing": ["MeetingScribeTests/ProcessingQueueTests"],
  "requested_at": "2026-09-17T14:30:00+00:00",
  "requested_by": "assistant",
  "note": "verify the queue pause fix"
}
```

A result carries `status` (`succeeded` / `failed` / `error` / `rejected`),
`blocker`, the list of steps with their `ok` flag, `data` (commit, test summary,
failed tests, compiler errors, bundle path) and `log_tail`.

Writes are atomic: the client writes `*.json.part` and renames, the daemon
writes `*.json.tmp` and renames. Neither side ever reads a half-written file.

The daemon re-executes itself when this script changes on disk, so an edit takes
effect without a manual restart. The launcher bundle stays the parent, so the
TCC identity is unaffected. The check runs only when the queue is empty, not
after every job, so a continuously busy daemon keeps serving the loaded version
until it next goes idle.

This is also the widest part of the trust boundary, and it is worth stating
plainly: whoever can write `scripts/assistant_build_daemon.py` decides what this
daemon does on the next idle tick. The same is true of the built commit — `test`
and `build-signed` run `xcodebuild`, which executes that commit's build phases
and test code on the host. The isolated worktree protects your working copy, not
your account. Treat the job list as a convenience and an audit trail, not as a
sandbox around an untrusted requester.

## Limitations worth knowing

- The mount through which the assistant sees the repository **blocks file
  deletion**. The assistant cannot clean up even its own requests, so archiving
  is the daemon's job. There is no log rotation: `logs/` and `archive/` grow
  without bound and are yours to prune occasionally.
- A successful `test` means "it compiled and the tests passed". It is not proof
  of application behaviour. `AGENTS.md` requires that distinction and the daemon
  preserves it: `data.build_succeeded` and `data.test_succeeded` are separate
  fields, and a test action that reports success without a single parsed result
  adds a `warning`.
- The daemon runs jobs sequentially, one at a time.
- `python3` is the system `/usr/bin/python3` from the Xcode Command Line Tools.
  There are no external dependencies.
- If the daemon stops reporting after a macOS or Xcode update, look at
  `.claude/build-queue/launchd.err.log` first. `Operation not permitted` means
  the Full Disk Access grant was lost.
