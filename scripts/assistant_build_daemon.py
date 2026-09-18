#!/usr/bin/env python3
"""Host-side runner for MeetingScribe build requests.

The coding assistant works in an isolated Linux sandbox that has no Xcode, no
`codesign` and no access to the login Keychain. This daemon runs in the user's
own GUI session and executes a FIXED SET OF NAMED JOBS on its behalf. It never
evaluates a shell string coming from a request file: every argument is either a
constant or a value validated against a strict pattern.

Protocol: see docs/assistant-build-daemon.md
"""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
QUEUE = REPO / ".claude" / "build-queue"
REQUESTS = QUEUE / "requests"
RESULTS = QUEUE / "results"
LOGS = QUEUE / "logs"
ARCHIVE = QUEUE / "archive"
STATE_PATH = QUEUE / "state.json"
DAEMON_LOG = QUEUE / "daemon.log"
LOCK_PATH = QUEUE / "daemon.lock"
ALLOW_NONMAIN_INSTALL = QUEUE / "ALLOW_NONMAIN_INSTALL"

DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
PROJECT = "MeetingScribe.xcodeproj"
SCHEME = "MeetingScribe"
INSTALLED_APP = Path("/Applications/MeetingScribe.app")
WORKTREE_ROOT = Path("/private/tmp/MeetingScribe-assistant")

POLL_SECONDS = 2.0
JOB_TIMEOUT_SECONDS = 2700
MAX_LOG_BYTES = 40 * 1024 * 1024

# A git ref, a test identifier and a request id are the only free-form values a
# request may carry, and each one has to match its pattern exactly.
REF_PATTERN = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
TEST_ID_PATTERN = re.compile(r"^[A-Za-z0-9_]+(/[A-Za-z0-9_]+){0,2}$")
REQUEST_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,120}$")
SHA1_PATTERN = re.compile(r"\b[0-9A-Fa-f]{40}\b")

JOBS = ("test", "build-signed", "codesign-verify", "install", "push-branch",
        "fetch", "session-report", "ping")

RECORDINGS_ROOT = (
    Path.home() / "Library" / "Application Support" / "MeetingScribe" / "Recordings"
)

# Diagnostics report processing state only. Transcript, markdown and audio
# content stay out: the failure is described by the job fields and the event
# log, and meeting content is none of this pipeline's business.
REPORTED_METADATA_KEYS = (
    "id", "title", "createdAt", "startedAt", "endedAt", "status",
    "resolvedCaptureMode", "language",
)
REPORTED_JOB_KEYS = (
    "schemaVersion", "jobID", "attemptID", "kind", "state", "stage",
    "checkpoint", "enqueuedAt", "startedAt", "updatedAt", "completedAt",
    "failureDescription",
)

# Only topic branches may be pushed, and only to origin. `main` is excluded by
# name so no request can advance it: AGENTS.md ties a main update to the whole
# signed install workflow, which is the user's decision, not a job's.
PUSHABLE_BRANCH_PATTERN = re.compile(r"^codex/[A-Za-z0-9][A-Za-z0-9._/-]{0,120}$")
PROTECTED_BRANCHES = {"main", "master", "HEAD"}


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(message: str) -> None:
    line = f"{now()} {message}"
    print(line, flush=True)
    try:
        with DAEMON_LOG.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except OSError:
        pass


class JobError(Exception):
    """A blocker that belongs in the result, not a daemon crash."""


@dataclass
class Step:
    name: str
    ok: bool
    detail: str = ""


@dataclass
class JobContext:
    request: dict
    request_id: str
    log_path: Path
    steps: list[Step] = field(default_factory=list)
    data: dict = field(default_factory=dict)

    def record(self, name: str, ok: bool, detail: str = "") -> Step:
        step = Step(name=name, ok=ok, detail=detail)
        self.steps.append(step)
        log(f"[{self.request_id}] {'ok ' if ok else 'FAIL'} {name} {detail}".rstrip())
        return step

    def append_log(self, text: str) -> None:
        with self.log_path.open("a", encoding="utf-8", errors="replace") as handle:
            handle.write(text)


# ---------------------------------------------------------------------------
# process helpers
# ---------------------------------------------------------------------------


def run(
    argv: list[str],
    ctx: JobContext | None = None,
    cwd: Path | None = None,
    timeout: int = 600,
    env_extra: dict[str, str] | None = None,
) -> subprocess.CompletedProcess:
    """Run argv with no shell. Output is streamed into the job log."""
    env = dict(os.environ)
    env.setdefault("DEVELOPER_DIR", DEVELOPER_DIR)
    if env_extra:
        env.update(env_extra)

    if ctx is not None:
        ctx.append_log(f"\n$ {' '.join(argv)}\n")

    try:
        completed = subprocess.run(
            argv,
            cwd=str(cwd) if cwd else None,
            env=env,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        if ctx is not None:
            ctx.append_log(f"\n[timeout after {timeout}s]\n")
        raise JobError(f"`{argv[0]}` exceeded {timeout}s") from error
    except FileNotFoundError as error:
        raise JobError(f"`{argv[0]}` was not found on this machine") from error

    if ctx is not None:
        ctx.append_log(completed.stdout or "")
        if completed.stderr:
            ctx.append_log("\n[stderr]\n" + completed.stderr)
        if ctx.log_path.stat().st_size > MAX_LOG_BYTES:
            raise JobError("job log exceeded the size limit")
    return completed


def git(argv: list[str], ctx: JobContext | None = None, cwd: Path | None = None,
        timeout: int = 180) -> subprocess.CompletedProcess:
    return run(["git", "-C", str(cwd or REPO), *argv], ctx=ctx, timeout=timeout)


def tail(path: Path, lines: int = 40) -> str:
    try:
        content = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(content[-lines:])


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------


def validated_ref(request: dict) -> str:
    ref = request.get("ref") or "HEAD"
    if not isinstance(ref, str) or not REF_PATTERN.match(ref):
        raise JobError(f"ref {ref!r} is not an acceptable git ref")
    if ".." in ref:
        raise JobError("ref must not contain '..'")
    return ref


def validated_only_testing(request: dict) -> list[str]:
    raw = request.get("only_testing") or []
    if not isinstance(raw, list):
        raise JobError("only_testing must be a list")
    if len(raw) > 20:
        raise JobError("only_testing accepts at most 20 identifiers")
    identifiers = []
    for item in raw:
        if not isinstance(item, str) or not TEST_ID_PATTERN.match(item):
            raise JobError(f"only_testing entry {item!r} is not a valid test identifier")
        identifiers.append(item)
    return identifiers


def resolve_commit(ref: str, ctx: JobContext) -> str:
    completed = git(["rev-parse", "--verify", f"{ref}^{{commit}}"], ctx=ctx)
    if completed.returncode != 0:
        raise JobError(f"ref {ref!r} does not resolve to a commit in this repository")
    return completed.stdout.strip()


# ---------------------------------------------------------------------------
# worktrees
# ---------------------------------------------------------------------------


def prepare_worktree(commit: str, purpose: str, ctx: JobContext) -> Path:
    """A detached worktree at `commit`, so the user's checkout is never touched."""
    WORKTREE_ROOT.parent.mkdir(parents=True, exist_ok=True)
    path = WORKTREE_ROOT.with_name(f"{WORKTREE_ROOT.name}-{purpose}-{commit[:10]}")
    if path.exists():
        release_worktree(path, ctx)
    completed = git(["worktree", "add", "--detach", str(path), commit], ctx=ctx)
    if completed.returncode != 0:
        raise JobError(f"could not create a worktree at {path}")
    ctx.record("worktree", True, str(path))
    return path


def release_worktree(path: Path, ctx: JobContext | None) -> None:
    git(["worktree", "remove", "--force", str(path)], ctx=ctx)
    if path.exists():
        shutil.rmtree(path, ignore_errors=True)
    git(["worktree", "prune"], ctx=ctx)


def copy_local_signing(worktree: Path, ctx: JobContext) -> None:
    """Signing.local.xcconfig is untracked, so a fresh worktree lacks it."""
    source = REPO / "Config" / "Signing.local.xcconfig"
    if not source.is_file():
        raise JobError(
            "Config/Signing.local.xcconfig is missing; initialize it from "
            "Config/Signing.local.xcconfig.example before requesting a signed build"
        )
    shutil.copy2(source, worktree / "Config" / "Signing.local.xcconfig")
    ctx.record("signing config", True, "copied into the worktree")


def configured_fingerprint() -> str:
    """The SHA-1 from the unversioned local config. Never logged."""
    text = (REPO / "Config" / "Signing.local.xcconfig").read_text(encoding="utf-8")
    for line in text.splitlines():
        if line.strip().startswith("//"):
            continue
        match = SHA1_PATTERN.search(line)
        if match:
            return match.group(0).upper()
    raise JobError(
        "no 40-character certificate SHA-1 found in Config/Signing.local.xcconfig"
    )


# ---------------------------------------------------------------------------
# jobs
# ---------------------------------------------------------------------------


def job_ping(ctx: JobContext) -> None:
    """Reports whether this machine can actually build and sign, before I rely on it."""
    xcode = run(["xcodebuild", "-version"], ctx=ctx, timeout=120)
    if xcode.returncode != 0:
        raise JobError("xcodebuild is not usable; check the Xcode installation")
    version_lines = xcode.stdout.strip().splitlines()[:2]
    ctx.data["xcodebuild"] = version_lines
    ctx.record("xcode", True, version_lines[0] if version_lines else "")

    identities = run(["security", "find-identity", "-v", "-p", "codesigning"], timeout=60)
    match = re.search(r"(\d+) valid identities found", identities.stdout)
    count = int(match.group(1)) if match else 0
    ctx.data["codesigning_identities"] = count
    ctx.record("codesigning identities", count > 0, f"{count} available")

    # Which MeetingScribe is actually running is the first thing I need when a
    # manual test result does not match the code that was just built.
    instances = running_instances(ctx)
    ctx.data["running_meetingscribe"] = instances
    ctx.record("running MeetingScribe", True, describe_instances(instances))

    has_local_config = (REPO / "Config" / "Signing.local.xcconfig").is_file()
    ctx.data["signing_local_xcconfig"] = has_local_config
    ctx.record("Config/Signing.local.xcconfig", has_local_config,
               "present" if has_local_config else "missing")

    if has_local_config and count > 0:
        fingerprint = configured_fingerprint()
        available = fingerprint in identities.stdout.upper()
        ctx.data["configured_identity_available"] = available
        ctx.record("configured identity", available,
                   "available for codesigning" if available
                   else "configured certificate is not in the login Keychain")


def job_test(ctx: JobContext) -> None:
    """Unsigned compile + test. Never installed or launched, per AGENTS.md."""
    ref = validated_ref(ctx.request)
    only_testing = validated_only_testing(ctx.request)
    commit = resolve_commit(ref, ctx)
    ctx.data["ref"] = ref
    ctx.data["commit"] = commit

    worktree = prepare_worktree(commit, "test", ctx)
    try:
        derived = worktree / ".derivedData"
        argv = [
            "xcodebuild",
            "-project", PROJECT,
            "-scheme", SCHEME,
            "-destination", "platform=macOS",
            "-derivedDataPath", str(derived),
            "CODE_SIGNING_ALLOWED=NO",
        ]
        for identifier in only_testing:
            argv.append(f"-only-testing:{identifier}")
        argv.append("test")

        completed = run(argv, ctx=ctx, cwd=worktree, timeout=JOB_TIMEOUT_SECONDS)
        summary = summarize_xcodebuild(ctx.log_path)
        ctx.data.update(summary)
        ctx.record(
            "xcodebuild test",
            completed.returncode == 0,
            f"exit {completed.returncode}; {summary.get('test_summary', 'no summary line')}",
        )
        if completed.returncode != 0:
            raise JobError("compilation or tests failed; see the log")
    finally:
        if all(step.ok for step in ctx.steps):
            release_worktree(worktree, ctx)
        else:
            ctx.data["worktree_kept_for_inspection"] = str(worktree)


def summarize_xcodebuild(log_path: Path) -> dict:
    """Separate 'compiled' from 'tests passed' rather than conflating them.

    Two result formats are counted: the `Test Case '-[Suite test]' failed`
    output of older xcodebuild versions and the `Test case 'Suite.test()' failed
    on 'My Mac …'` output that Xcode 26/27 emits. Reading only the old one made
    a full, green run look like it had no tests at all.
    """
    text = log_path.read_text(encoding="utf-8", errors="replace")
    summary: dict = {}

    errors = re.findall(r"^(.*?): error: (.*)$", text, re.MULTILINE)
    summary["error_count"] = len(errors)
    summary["first_errors"] = [f"{where}: {what}" for where, what in errors[:10]]

    def names(outcome: str) -> list[str]:
        modern = re.findall(rf"Test case '([^']+)' {outcome}\b", text)
        legacy = re.findall(rf"Test Case '-\[(\S+ \S+)\]' {outcome}\b", text)
        return sorted(set(modern) | set(legacy))

    passed = names("passed")
    failed = names("failed")
    skipped = names("skipped")
    summary["tests_passed"] = len(passed)
    summary["tests_failed"] = len(failed)
    summary["tests_skipped"] = len(skipped)
    summary["failed_tests"] = failed[:40]
    summary["skipped_tests"] = skipped[:40]

    legacy_total = re.search(
        r"Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)", text
    )
    if legacy_total:
        summary["test_summary"] = legacy_total.group(0)
        summary["tests_passed"] = int(legacy_total.group(1)) - int(legacy_total.group(2))
        summary["tests_failed"] = int(legacy_total.group(2))
    elif passed or failed or skipped:
        summary["test_summary"] = (
            f"{len(passed)} passed, {len(failed)} failed, {len(skipped)} skipped"
        )

    summary["test_succeeded"] = "** TEST SUCCEEDED **" in text
    summary["build_succeeded"] = (
        "** BUILD SUCCEEDED **" in text or summary["test_succeeded"]
    )
    # A test action that reports success without running anything is not proof.
    if summary["test_succeeded"] and not (passed or failed or legacy_total):
        summary["warning"] = "the test action succeeded but no test results were parsed"
    return summary


def job_build_signed(ctx: JobContext) -> None:
    """Manually signed build with every check AGENTS.md requires before launch."""
    ref = validated_ref(ctx.request)
    commit = resolve_commit(ref, ctx)
    ctx.data["ref"] = ref
    ctx.data["commit"] = commit

    fingerprint = configured_fingerprint()
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"], timeout=60)
    if fingerprint not in identities.stdout.upper():
        raise JobError(
            "the certificate configured in Config/Signing.local.xcconfig is not "
            "available to codesigning in this login session; unlock the login "
            "Keychain or install the identity, then retry"
        )
    ctx.record("configured identity", True, "available in the login Keychain")

    worktree = prepare_worktree(commit, "signed", ctx)
    keep = False
    try:
        copy_local_signing(worktree, ctx)
        derived = Path(f"/private/tmp/MeetingScribe-assistant-signed-dd-{commit[:10]}")
        shutil.rmtree(derived, ignore_errors=True)
        completed = run(
            [
                "xcodebuild",
                "-project", PROJECT,
                "-scheme", SCHEME,
                "-configuration", "Debug",
                "-derivedDataPath", str(derived),
                "CODE_SIGNING_ALLOWED=YES",
                "CODE_SIGNING_REQUIRED=YES",
                "CODE_SIGN_STYLE=Manual",
                "build",
            ],
            ctx=ctx,
            cwd=worktree,
            timeout=JOB_TIMEOUT_SECONDS,
        )
        ctx.record("xcodebuild build", completed.returncode == 0, f"exit {completed.returncode}")
        if completed.returncode != 0:
            keep = True
            raise JobError("the signed build failed; see the log")

        app = derived / "Build" / "Products" / "Debug" / "MeetingScribe.app"
        if not app.is_dir():
            keep = True
            raise JobError(f"no app bundle at {app}")
        ctx.data["app_path"] = str(app)

        verify_signature(app, fingerprint, ctx)
        ctx.data["verified"] = True
        save_state({"last_signed_build": {
            "app_path": str(app),
            "commit": commit,
            "ref": ref,
            "request_id": ctx.request_id,
            "built_at": now(),
        }})
    finally:
        if keep:
            ctx.data["worktree_kept_for_inspection"] = str(worktree)
        else:
            release_worktree(worktree, ctx)


def verify_signature(app: Path, fingerprint: str, ctx: JobContext) -> None:
    """The three checks AGENTS.md requires: deep verify, authority, fingerprint."""
    deep = run(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=4", str(app)],
        ctx=ctx, timeout=600,
    )
    deep_output = ((deep.stderr or "") + (deep.stdout or "")).strip().splitlines()
    ctx.record("codesign --verify --deep --strict", deep.returncode == 0,
               deep_output[-1] if deep_output else f"exit {deep.returncode}")
    if deep.returncode != 0:
        raise JobError("codesign deep verification failed")

    display = run(["codesign", "-dv", "--verbose=4", str(app)], ctx=ctx, timeout=300)
    text = (display.stderr or "") + (display.stdout or "")
    authority = [line.strip() for line in text.splitlines() if line.startswith("Authority=")]
    team = [line.strip() for line in text.splitlines() if line.startswith("TeamIdentifier=")]
    ctx.data["authority"] = authority
    ctx.data["team_identifier"] = team[0] if team else None
    ctx.record("authority and TeamIdentifier", bool(authority and team),
               "; ".join(authority[:1] + team[:1]))
    if not (authority and team):
        raise JobError("codesign did not report an Authority and a TeamIdentifier")

    extracted = Path(f"/private/tmp/MeetingScribe-assistant-cert-{uuid.uuid4().hex[:8]}")
    extracted.mkdir(parents=True, exist_ok=True)
    try:
        run(["codesign", "-d", f"--extract-certificates={extracted}/cert",
             str(app)], ctx=ctx, timeout=300)
        leaf = extracted / "cert0"
        if not leaf.is_file():
            raise JobError("no signing certificate could be extracted from the bundle")
        openssl = run(
            ["openssl", "x509", "-inform", "DER", "-in", str(leaf),
             "-noout", "-fingerprint", "-sha1"],
            timeout=60,
        )
        found = SHA1_PATTERN.search(openssl.stdout.replace(":", ""))
        matches = bool(found) and found.group(0).upper() == fingerprint
        # The fingerprint itself is a local personal value and stays out of logs.
        ctx.record("certificate SHA-1", matches,
                   "matches the configured identity" if matches
                   else "does NOT match the configured identity")
        if not matches:
            raise JobError("the bundle was signed with a different certificate")
    finally:
        shutil.rmtree(extracted, ignore_errors=True)


def job_codesign_verify(ctx: JobContext) -> None:
    target = ctx.request.get("target", "installed")
    if target == "installed":
        app = INSTALLED_APP
    elif target == "last-build":
        app_path = ((load_state().get("last_signed_build") or {}).get("app_path") or "").strip()
        if not app_path:
            raise JobError("no signed build has been produced yet; run build-signed first")
        app = Path(app_path)
    else:
        raise JobError("target must be 'installed' or 'last-build'")
    if not app.is_dir():
        raise JobError(f"no app bundle at {app}")
    ctx.data["app_path"] = str(app)
    verify_signature(app, configured_fingerprint(), ctx)


def job_install(ctx: JobContext) -> None:
    """Replace the installed app. AGENTS.md authorizes this for main updates."""
    state = load_state().get("last_signed_build") or {}
    # An empty path would become Path("."), which is a directory, so the
    # emptiness has to be rejected before the filesystem is consulted.
    app_path = (state.get("app_path") or "").strip()
    if not app_path or not Path(app_path).is_dir():
        raise JobError("no verified signed build is available; run build-signed first")
    app = Path(app_path)

    commit = state.get("commit", "")
    main_commits = set()
    for ref in ("refs/heads/main", "refs/remotes/origin/main"):
        completed = git(["rev-parse", "--verify", f"{ref}^{{commit}}"])
        if completed.returncode == 0:
            main_commits.add(completed.stdout.strip())
    is_main = commit in main_commits
    if not is_main and not ALLOW_NONMAIN_INSTALL.exists():
        raise JobError(
            "the last signed build is not main/origin/main. AGENTS.md authorizes "
            "automatic installation for main updates only. To allow this one, "
            f"create {ALLOW_NONMAIN_INSTALL} and retry."
        )
    ctx.record("install source", True,
               f"{commit[:10]} ({'main' if is_main else 'non-main, explicitly allowed'})")

    # Re-verify before touching /Applications, not only after building.
    verify_signature(app, configured_fingerprint(), ctx)

    ctx.data["running_before"] = running_instance_paths(ctx)
    run(["/usr/bin/pkill", "-x", "MeetingScribe"], ctx=ctx, timeout=60)
    time.sleep(3)
    still_running = running_instance_paths(ctx)
    if still_running:
        raise JobError(
            "a MeetingScribe instance is still running "
            f"({', '.join(still_running)}); stop it and retry"
        )
    ctx.record("previous instances", True,
               "terminated: " + (", ".join(ctx.data["running_before"]) or "none were running"))

    staged = INSTALLED_APP.with_name(f"MeetingScribe.app.replacing-{uuid.uuid4().hex[:8]}")
    try:
        run(["/usr/bin/ditto", str(app), str(staged)], ctx=ctx, timeout=600)
        if INSTALLED_APP.exists():
            backup = INSTALLED_APP.with_name(
                f"MeetingScribe.app.previous-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
            )
            INSTALLED_APP.rename(backup)
            ctx.data["previous_bundle"] = str(backup)
        staged.rename(INSTALLED_APP)
    except OSError as error:
        shutil.rmtree(staged, ignore_errors=True)
        raise JobError(f"could not replace {INSTALLED_APP}: {error}") from error
    ctx.record("installed", True, str(INSTALLED_APP))

    verify_signature(INSTALLED_APP, configured_fingerprint(), ctx)

    prune_previous_bundles(ctx)

    run(["/usr/bin/open", str(INSTALLED_APP)], ctx=ctx, timeout=120)

    # A launch briefly races with whatever launchd is doing with the replaced
    # bundle, so a single sample can catch a duplicate that exits on its own.
    # What matters is the settled state.
    instances: list[dict] = []
    for attempt in range(10):
        time.sleep(3)
        instances = running_instances(ctx)
        foreign = [i for i in instances if not i["path"].startswith(str(INSTALLED_APP))]
        if len(instances) == 1 and not foreign:
            break
        if attempt == 0:
            ctx.append_log(
                f"\n[settling] {describe_instances(instances)}\n"
            )

    ctx.data["running"] = instances
    foreign = [i for i in instances if not i["path"].startswith(str(INSTALLED_APP))]
    detail = describe_instances(instances)
    ctx.record("single intended instance", len(instances) == 1 and not foreign, detail)
    # A stale bundle running and the intended bundle running twice are different
    # problems, so they must not share one message.
    if foreign:
        raise JobError(f"a MeetingScribe outside {INSTALLED_APP} is running: {detail}")
    if len(instances) > 1:
        raise JobError(
            f"the installed bundle is still running {len(instances)} times after "
            f"30s: {detail}"
        )
    if not instances:
        raise JobError("the installed bundle did not start")


def prune_previous_bundles(ctx: JobContext) -> None:
    """Keep one rollback copy. Every install otherwise leaves a full app behind."""
    backups = sorted(
        INSTALLED_APP.parent.glob("MeetingScribe.app.previous-*"),
        key=lambda path: path.name,
    )
    removed = []
    for stale in backups[:-1]:
        shutil.rmtree(stale, ignore_errors=True)
        if not stale.exists():
            removed.append(stale.name)
    if removed:
        ctx.data["pruned_backups"] = removed
    if backups:
        ctx.record("rollback copy", True, f"kept {backups[-1].name}")


def running_instances(ctx: JobContext | None = None) -> list[dict]:
    """Every running MeetingScribe with its pid, parent and executable path.

    `pgrep -a` is a GNU option that BSD pgrep silently ignores, so it returned
    bare pids and the path check could never match. The pids are resolved with
    `ps -o comm=` instead, which prints the executable path on macOS. The parent
    is included because it says who started a duplicate instance.
    """
    listed = run(["/usr/bin/pgrep", "-x", "MeetingScribe"], ctx=ctx, timeout=30)
    instances: list[dict] = []
    for token in listed.stdout.split():
        if not token.isdigit():
            continue
        described = run(
            ["/bin/ps", "-p", token, "-o", "ppid=,etime=,comm="], timeout=30
        )
        fields = described.stdout.strip().split(None, 2)
        if len(fields) != 3:
            continue
        parent, elapsed, path = fields
        parent_name = run(["/bin/ps", "-p", parent, "-o", "comm="], timeout=30)
        instances.append({
            "pid": int(token),
            "ppid": int(parent),
            "parent": parent_name.stdout.strip() or "unknown",
            "elapsed": elapsed,
            "path": path,
        })
    return instances


def describe_instances(instances: list[dict]) -> str:
    return "; ".join(
        f"pid {i['pid']} (parent {i['parent']}, up {i['elapsed']}) {i['path']}"
        for i in instances
    ) or "none"


def running_instance_paths(ctx: JobContext | None = None) -> list[str]:
    return [instance["path"] for instance in running_instances(ctx)]


def job_push_branch(ctx: JobContext) -> None:
    """Push one topic branch to origin. Never main, never forced."""
    branch = ctx.request.get("ref") or ""
    if not isinstance(branch, str) or not PUSHABLE_BRANCH_PATTERN.match(branch):
        raise JobError(
            f"{branch!r} is not pushable; this job only pushes codex/* branches"
        )
    if branch in PROTECTED_BRANCHES or Path(branch).name in PROTECTED_BRANCHES:
        raise JobError(f"{branch} is protected and cannot be pushed by a job")
    if ".." in branch:
        raise JobError("branch must not contain '..'")

    resolved = git(["rev-parse", "--verify", f"refs/heads/{branch}"], ctx=ctx)
    if resolved.returncode != 0:
        raise JobError(f"there is no local branch {branch}")
    commit = resolved.stdout.strip()
    ctx.data["ref"] = branch
    ctx.data["commit"] = commit

    # Refuse to publish a commit that has no green test run on record. Nothing
    # else in this pipeline enforces "do not claim it works if you did not
    # verify it", so the gate lives here.
    tested = tested_commits()
    if commit not in tested:
        raise JobError(
            f"no succeeded test job on record for {commit[:10]}; "
            f"run `test --ref {branch}` first"
        )
    ctx.record("verified by test job", True, tested[commit])

    ahead = git(["rev-list", "--count", f"origin/main..{branch}"], ctx=ctx)
    behind = git(["rev-list", "--count", f"{branch}..origin/main"], ctx=ctx)
    ctx.data["commits_ahead_of_origin_main"] = ahead.stdout.strip()
    ctx.data["commits_behind_origin_main"] = behind.stdout.strip()
    ctx.record("relation to origin/main", True,
               f"{ahead.stdout.strip()} ahead, {behind.stdout.strip()} behind")

    pushed = git(
        ["push", "origin", f"refs/heads/{branch}:refs/heads/{branch}"],
        ctx=ctx, timeout=300,
    )
    if pushed.returncode != 0:
        raise JobError(
            "git push failed; a non-fast-forward is rejected on purpose, this "
            "job never forces. See the log."
        )
    ctx.record("pushed", True, f"origin/{branch}")

    remote = git(["remote", "get-url", "origin"], ctx=ctx)
    slug = re.sub(r"^.*github\.com[:/]|\.git$", "", remote.stdout.strip())
    if slug and "/" in slug:
        ctx.data["compare_url"] = (
            f"https://github.com/{slug}/compare/main...{branch}?expand=1"
        )


def job_fetch(ctx: JobContext) -> None:
    """Update remote-tracking refs. Never touches a local branch.

    `install` may only install `main`/`origin/main`, so a stale `origin/main`
    would make that guard compare against the wrong commit.
    """
    before = git(["rev-parse", "--verify", "refs/remotes/origin/main"], ctx=ctx)
    fetched = git(["fetch", "--prune", "origin"], ctx=ctx, timeout=300)
    if fetched.returncode != 0:
        raise JobError("git fetch failed; see the log")
    after = git(["rev-parse", "--verify", "refs/remotes/origin/main"], ctx=ctx)

    previous = before.stdout.strip()
    current = after.stdout.strip()
    ctx.data["origin_main_before"] = previous
    ctx.data["origin_main"] = current
    ctx.record("origin/main", True,
               current[:10] + (" (unchanged)" if current == previous
                               else f", was {previous[:10]}"))

    subject = git(["log", "-1", "--format=%s", current], ctx=ctx)
    ctx.data["origin_main_subject"] = subject.stdout.strip()
    local = git(["rev-parse", "--verify", "refs/heads/main"], ctx=ctx)
    if local.returncode == 0:
        behind = git(["rev-list", "--count", f"{local.stdout.strip()}..{current}"], ctx=ctx)
        ctx.record("local main", True,
                   f"{behind.stdout.strip()} commits behind origin/main "
                   "(this job never moves it)")


def job_session_report(ctx: JobContext) -> None:
    """Read-only processing diagnostics for recent recording sessions.

    The recordings live under ~/Library/Application Support, which the sandbox
    cannot reach, so without this a processing failure can only be guessed at.
    It reports job state and the event log, never meeting content.
    """
    if not RECORDINGS_ROOT.is_dir():
        raise JobError(f"no recordings directory at {RECORDINGS_ROOT}")

    wanted = ctx.request.get("session")
    if wanted is not None and (
        not isinstance(wanted, str) or not REQUEST_ID_PATTERN.match(wanted)
    ):
        raise JobError("session must be a plain session directory name")

    limit = ctx.request.get("limit", 3)
    if not isinstance(limit, int) or not 1 <= limit <= 20:
        raise JobError("limit must be an integer between 1 and 20")

    directories = sorted(
        (path for path in RECORDINGS_ROOT.iterdir() if path.is_dir()),
        key=lambda path: path.name,
        reverse=True,
    )
    if wanted:
        directories = [path for path in directories if path.name == wanted]
        if not directories:
            raise JobError(f"no session directory named {wanted}")
    directories = directories[:limit]

    reports = []
    for directory in directories:
        report: dict = {"directory": directory.name}
        manifest = directory / "session.json"
        if manifest.is_file():
            try:
                document = json.loads(manifest.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                report["manifest_error"] = str(error)
                document = {}
            report["session"] = {
                key: document.get(key) for key in REPORTED_METADATA_KEYS
                if document.get(key) is not None
            }
            job = document.get("processing") or {}
            report["processing"] = {
                key: job.get(key) for key in REPORTED_JOB_KEYS
                if job.get(key) is not None
            }
            # Presence only, so a missing artifact is visible without reading it.
            report["artifacts"] = {
                name: bool(document.get(name))
                for name in ("systemAudio", "microphoneAudio", "audioFinalization",
                             "transcription", "analysis", "output",
                             "audioSourceCleanup", "recovery")
            }
        else:
            report["manifest_error"] = "session.json is missing"

        report["files"] = sorted(
            f"{path.name} ({path.stat().st_size} B)"
            for path in directory.iterdir() if path.is_file()
        )
        log_path = directory / "processing.log"
        if log_path.is_file():
            lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
            report["processing_log_tail"] = lines[-25:]
        reports.append(report)

    ctx.data["recordings_root"] = str(RECORDINGS_ROOT)
    ctx.data["sessions"] = reports
    for report in reports:
        state = (report.get("processing") or {}).get("state", "no job")
        failure = (report.get("processing") or {}).get("failureDescription", "")
        ctx.record(report["directory"], True,
                   f"{state}{' — ' + failure if failure else ''}")


def tested_commits() -> dict[str, str]:
    """Commits with a succeeded `test` result, mapped to a short description."""
    verified: dict[str, str] = {}
    for path in sorted(RESULTS.glob("*.json")):
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if result.get("job") != "test" or result.get("status") != "succeeded":
            continue
        data = result.get("data") or {}
        commit = data.get("commit")
        if not commit:
            continue
        summary = data.get("test_summary") or "no summary"
        verified[commit] = f"{path.stem}: {summary}"
    return verified


JOB_HANDLERS = {
    "ping": job_ping,
    "push-branch": job_push_branch,
    "session-report": job_session_report,
    "fetch": job_fetch,
    "test": job_test,
    "build-signed": job_build_signed,
    "codesign-verify": job_codesign_verify,
    "install": job_install,
}


# ---------------------------------------------------------------------------
# state and queue
# ---------------------------------------------------------------------------


def load_state() -> dict:
    try:
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(update: dict) -> None:
    state = load_state()
    state.update(update)
    state["updated_at"] = now()
    temporary = STATE_PATH.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    temporary.replace(STATE_PATH)


def write_result(request_id: str, payload: dict) -> None:
    RESULTS.mkdir(parents=True, exist_ok=True)
    path = RESULTS / f"{request_id}.json"
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)  # atomic, so a poller never reads half a result


def archive_request(path: Path) -> None:
    target_dir = ARCHIVE / datetime.now().strftime("%Y-%m")
    target_dir.mkdir(parents=True, exist_ok=True)
    try:
        path.rename(target_dir / path.name)
    except OSError:
        path.unlink(missing_ok=True)


def handle(path: Path) -> None:
    started = time.monotonic()
    started_at = now()
    request_id = path.stem
    try:
        request = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(request, dict):
            raise ValueError("request must be a JSON object")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        write_result(request_id, {
            "id": request_id, "status": "rejected", "finished_at": now(),
            "blocker": f"unreadable request: {error}",
        })
        archive_request(path)
        return

    if not REQUEST_ID_PATTERN.match(request_id):
        write_result(request_id, {
            "id": request_id, "status": "rejected", "finished_at": now(),
            "blocker": "request id contains unacceptable characters",
        })
        archive_request(path)
        return

    job = request.get("job")
    LOGS.mkdir(parents=True, exist_ok=True)
    log_path = LOGS / f"{request_id}.log"
    log_path.write_text(
        f"# {request_id}\n# job: {job}\n# started: {now()}\n", encoding="utf-8"
    )
    ctx = JobContext(request=request, request_id=request_id, log_path=log_path)

    if job not in JOB_HANDLERS:
        write_result(request_id, {
            "id": request_id, "job": job, "status": "rejected",
            "finished_at": now(),
            "blocker": f"unknown job; this daemon runs only {', '.join(JOBS)}",
        })
        archive_request(path)
        return

    log(f"[{request_id}] starting {job}")
    status = "succeeded"
    blocker = None
    try:
        JOB_HANDLERS[job](ctx)
    except JobError as error:
        status = "failed"
        blocker = str(error)
    except Exception as error:  # noqa: BLE001 - a crash must still produce a result
        status = "error"
        blocker = f"{type(error).__name__}: {error}"
        ctx.append_log(f"\n[daemon exception] {blocker}\n")

    if status == "succeeded" and any(not step.ok for step in ctx.steps):
        status = "failed"
        blocker = blocker or "one or more checks did not pass"

    write_result(request_id, {
        "id": request_id,
        "job": job,
        "status": status,
        "blocker": blocker,
        "requested_at": request.get("requested_at"),
        "started_at": started_at,
        "finished_at": now(),
        "duration_seconds": round(time.monotonic() - started, 1),
        "steps": [{"name": s.name, "ok": s.ok, "detail": s.detail} for s in ctx.steps],
        "data": ctx.data,
        "log": str(log_path),
        "log_tail": tail(log_path, 60),
    })
    archive_request(path)
    log(f"[{request_id}] {status}" + (f": {blocker}" if blocker else ""))


def script_signature() -> tuple[int, int]:
    stat = Path(__file__).stat()
    return (stat.st_mtime_ns, stat.st_size)


def reexec_if_updated(signature: tuple[int, int]) -> None:
    """Pick up edits to this file without a manual restart.

    The assistant can change this script but cannot run `launchctl`, so a stale
    process would keep serving the old logic indefinitely. Only ever called
    between jobs, and only the python image is replaced: the granted launcher
    bundle stays the parent, so the TCC identity is unaffected.
    """
    try:
        current = script_signature()
    except OSError:
        return
    if current == signature:
        return
    log("this script changed on disk; restarting to pick it up")
    LOCK_PATH.unlink(missing_ok=True)
    try:
        os.execv(sys.executable, [sys.executable, str(Path(__file__).resolve())])
    except OSError as error:
        log(f"re-exec failed ({error}); continuing with the loaded version")
        acquire_lock()


def acquire_lock() -> None:
    """One daemon at a time; a stale lock from a crash is reclaimed."""
    try:
        descriptor = os.open(str(LOCK_PATH), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        try:
            existing = int(LOCK_PATH.read_text(encoding="utf-8").strip() or 0)
        except (OSError, ValueError):
            existing = 0
        if existing and existing != os.getpid():
            try:
                os.kill(existing, 0)
            except OSError:
                log(f"reclaiming stale lock from pid {existing}")
                LOCK_PATH.unlink(missing_ok=True)
                return acquire_lock()
            raise SystemExit(f"another daemon is already running as pid {existing}")
        LOCK_PATH.unlink(missing_ok=True)
        return acquire_lock()
    with os.fdopen(descriptor, "w") as handle:
        handle.write(str(os.getpid()))


def main() -> int:
    for directory in (REQUESTS, RESULTS, LOGS, ARCHIVE):
        directory.mkdir(parents=True, exist_ok=True)
    gitignore = QUEUE / ".gitignore"
    if not gitignore.exists():
        gitignore.write_text("*\n!.gitignore\n", encoding="utf-8")

    if "--once" in sys.argv:
        pending = sorted(REQUESTS.glob("*.json"))
        for path in pending:
            handle(path)
        return 0

    acquire_lock()
    stopping = {"value": False}

    def stop(signum, _frame):
        stopping["value"] = True
        log(f"received signal {signum}; finishing the current job then exiting")

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    signature = script_signature()
    log(f"daemon started as pid {os.getpid()}; repo {REPO}")
    save_state({"daemon": {"pid": os.getpid(), "started_at": now(), "repo": str(REPO)}})
    try:
        while not stopping["value"]:
            pending = sorted(REQUESTS.glob("*.json"))
            if not pending:
                reexec_if_updated(signature)
                time.sleep(POLL_SECONDS)
                continue
            for path in pending:
                if stopping["value"]:
                    break
                handle(path)
    finally:
        LOCK_PATH.unlink(missing_ok=True)
        log("daemon stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
