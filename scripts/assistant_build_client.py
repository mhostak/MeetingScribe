#!/usr/bin/env python3
"""Queue a build job for the host daemon and wait for its result.

Runs from the assistant's Linux sandbox as well as from the Mac itself: it only
writes a request file into the repository and polls for the matching result, so
it needs nothing but a shared filesystem and python3.

    scripts/assistant_build_client.py ping
    scripts/assistant_build_client.py test --ref codex/my-branch
    scripts/assistant_build_client.py test --only-testing MeetingScribeTests/ProcessingQueueTests
    scripts/assistant_build_client.py build-signed --ref main
    scripts/assistant_build_client.py install
    scripts/assistant_build_client.py status

Exit code is 0 only when the job succeeded.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
QUEUE = REPO / ".claude" / "build-queue"
REQUESTS = QUEUE / "requests"
RESULTS = QUEUE / "results"
LOGS = QUEUE / "logs"

JOBS = ("ping", "test", "build-signed", "codesign-verify", "install", "push-branch", "session-report", "fetch")
DEFAULT_WAIT = {"ping": 180, "test": 2400, "build-signed": 2400,
                "codesign-verify": 600, "install": 900, "push-branch": 420, "session-report": 180, "fetch": 300}


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def daemon_state() -> dict:
    try:
        return json.loads((QUEUE / "state.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def print_status() -> int:
    state = daemon_state()
    daemon = state.get("daemon") or {}
    lock = QUEUE / "daemon.lock"
    print(f"queue:           {QUEUE}")
    print(f"daemon lock:     {'present' if lock.exists() else 'absent'}"
          f"{' (pid ' + lock.read_text(encoding='utf-8').strip() + ')' if lock.exists() else ''}")
    print(f"daemon started:  {daemon.get('started_at', 'unknown')}")
    print(f"state updated:   {state.get('updated_at', 'never')}")
    signed = state.get("last_signed_build") or {}
    if signed:
        print(f"last signed:     {signed.get('commit', '')[:10]} "
              f"({signed.get('ref', '?')}) at {signed.get('built_at', '?')}")
    pending = sorted(REQUESTS.glob("*.json")) if REQUESTS.is_dir() else []
    print(f"pending:         {len(pending)}"
          + (" -> " + ", ".join(p.stem for p in pending[:5]) if pending else ""))
    recent = sorted(RESULTS.glob("*.json"), key=lambda p: p.stat().st_mtime,
                    reverse=True)[:5] if RESULTS.is_dir() else []
    for path in recent:
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        print(f"  {result.get('status', '?'):<9} {result.get('job', '?'):<15} "
              f"{result.get('finished_at', '')} {path.stem}")
    return 0


def submit(arguments: argparse.Namespace) -> int:
    REQUESTS.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    request_id = f"{stamp}-{arguments.job}"
    request = {
        "id": request_id,
        "job": arguments.job,
        "requested_at": now(),
        "requested_by": arguments.requested_by,
    }
    if arguments.ref:
        request["ref"] = arguments.ref
    if arguments.only_testing:
        request["only_testing"] = arguments.only_testing
    if arguments.target:
        request["target"] = arguments.target
    if getattr(arguments, "session", None):
        request["session"] = arguments.session
    if getattr(arguments, "limit", None):
        request["limit"] = arguments.limit
    if arguments.note:
        request["note"] = arguments.note

    path = REQUESTS / f"{request_id}.json"
    temporary = path.with_suffix(".json.part")
    temporary.write_text(json.dumps(request, indent=2) + "\n", encoding="utf-8")
    # The daemon only ever sees a complete request: it globs *.json.
    temporary.rename(path)
    print(f"queued {request_id}")

    if arguments.no_wait:
        return 0

    state = daemon_state()
    if not (QUEUE / "daemon.lock").exists() and not state.get("daemon"):
        print("warning: no daemon has ever registered in this queue. "
              "Run scripts/install-assistant-build-daemon.sh on the Mac.",
              file=sys.stderr)

    deadline = time.monotonic() + (arguments.wait or DEFAULT_WAIT[arguments.job])
    result_path = RESULTS / f"{request_id}.json"
    waited = 0.0
    while time.monotonic() < deadline:
        if result_path.is_file():
            return report(result_path, arguments)
        time.sleep(3)
        waited += 3
        if waited % 60 == 0:
            print(f"  … still waiting ({int(waited)}s)", flush=True)
    print(f"timed out after {int(waited)}s; the job may still be running. "
          f"Poll with: scripts/assistant_build_client.py await {request_id}",
          file=sys.stderr)
    return 2


def await_result(arguments: argparse.Namespace) -> int:
    result_path = RESULTS / f"{arguments.request_id}.json"
    deadline = time.monotonic() + (arguments.wait or 2400)
    while time.monotonic() < deadline:
        if result_path.is_file():
            return report(result_path, arguments)
        time.sleep(3)
    print("still no result", file=sys.stderr)
    return 2


def report(result_path: Path, arguments: argparse.Namespace) -> int:
    try:
        result = json.loads(result_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"result file is unreadable: {error}", file=sys.stderr)
        return 3

    status = result.get("status", "unknown")
    print(f"\n{status.upper()}  {result.get('job')}  "
          f"({result.get('duration_seconds', '?')}s)")
    if result.get("blocker"):
        print(f"blocker: {result['blocker']}")
    for step in result.get("steps", []):
        mark = "ok  " if step.get("ok") else "FAIL"
        print(f"  {mark} {step.get('name')}"
              + (f" — {step['detail']}" if step.get("detail") else ""))

    data = result.get("data") or {}
    for key in ("ref", "commit", "test_summary", "app_path", "team_identifier",
                "warning", "compare_url", "origin_main", "origin_main_subject"):
        if data.get(key):
            print(f"  {key}: {data[key]}")
    if data.get("failed_tests"):
        print("  failed tests:")
        for name in data["failed_tests"]:
            print(f"    {name}")
    if data.get("first_errors"):
        print("  compiler errors:")
        for line in data["first_errors"]:
            print(f"    {line}")
    for report in data.get("sessions") or []:
        print(f"\n  === {report['directory']}")
        for key in ("manifest_error",):
            if report.get(key):
                print(f"    {key}: {report[key]}")
        for key, value in (report.get("processing") or {}).items():
            print(f"    processing.{key}: {value}")
        present = [k for k, v in (report.get("artifacts") or {}).items() if v]
        print(f"    artifacts present: {', '.join(present) or 'none'}")
        print(f"    files: {', '.join(report.get('files') or [])}")
        for line in report.get("processing_log_tail") or []:
            print(f"    | {line}")
    if data.get("worktree_kept_for_inspection"):
        print(f"  worktree kept: {data['worktree_kept_for_inspection']}")

    if status != "succeeded" or arguments.show_log:
        print("\n--- log tail ---")
        print(result.get("log_tail", "(no log)"))
        local_log = LOGS / f"{result.get('id')}.log"
        if local_log.is_file():
            print(f"--- full log: {local_log} ---")
    return 0 if status == "succeeded" else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("status", help="show the queue and daemon state")

    awaiting = subparsers.add_parser("await", help="wait for an already queued request")
    awaiting.add_argument("request_id")
    awaiting.add_argument("--wait", type=int, default=None)
    awaiting.add_argument("--show-log", action="store_true")

    for job in JOBS:
        job_parser = subparsers.add_parser(job, help=f"run the {job} job")
        job_parser.add_argument("--ref", default=None,
                                help="git ref to build (default: HEAD of the repository)")
        job_parser.add_argument("--only-testing", action="append", default=None,
                                metavar="Target/Class",
                                help="restrict `test` to one target, class or method")
        job_parser.add_argument("--target", choices=("installed", "last-build"),
                                default=None, help="codesign-verify subject")
        job_parser.add_argument("--session", default=None,
                                help="session-report: one session directory name")
        job_parser.add_argument("--limit", type=int, default=None,
                                help="session-report: how many recent sessions")
        job_parser.add_argument("--note", default=None, help="free-text reminder")
        job_parser.add_argument("--wait", type=int, default=None,
                                help="seconds to wait for the result")
        job_parser.add_argument("--no-wait", action="store_true")
        job_parser.add_argument("--show-log", action="store_true")
        job_parser.add_argument("--requested-by", default="assistant")

    arguments = parser.parse_args()
    if arguments.command == "status":
        return print_status()
    if arguments.command == "await":
        return await_result(arguments)
    arguments.job = arguments.command
    return submit(arguments)


if __name__ == "__main__":
    sys.exit(main())
