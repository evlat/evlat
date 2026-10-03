#!/usr/bin/env python3
"""Fills the demo Evlat (scripts/demo.sh) with every kind of row.

Local sessions in each phase (session records + hooks), a Codex session,
sessions on three remote machines through their tunnels' listeners, Docker
sandboxes on the sandbox listener, outside jobs on /signal and the usage
windows. Names and paths are made up, except the first session's folder: it is
this repository, so its card shows a real branch. With --held an approval and
a question are held on /approval, so their cards draw their buttons.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--dir", required=True)
parser.add_argument("--repo", required=True)
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--sandbox-port", type=int, required=True)
parser.add_argument("--held", action="store_true")
args = parser.parse_args()

D = args.dir
PORT = args.port
pids = [int(x) for x in open(os.path.join(D, "agents.pid")).read().split()]
now_ms = int(time.time() * 1000)
now_s = int(time.time())


def post(port, path, body, headers=None):
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", **(headers or {})})
    try:
        return urllib.request.urlopen(request, timeout=3).read().decode()
    except Exception as error:  # a demo goes on without the one row
        return f"ERR {error}"


def hook(port, source, pid, body, headers=None):
    extra = dict(headers or {})
    if pid:
        extra["X-Evlat-Pid"] = str(pid)
    return post(port, f"/hook/{source}", body, extra)


def started_ms(pid):
    """The process's own start, which a record's `startedAt` must match."""
    out = subprocess.check_output(["ps", "-o", "lstart=", "-p", str(pid)]).decode().strip()
    return int(time.mktime(time.strptime(out, "%a %b %d %H:%M:%S %Y")) * 1000)


# Local Claude Code sessions: a record each (name, pid), then their hooks.
LOCAL = [
    ("11111111-1111-4111-8111-111111111111", args.repo,
     "Refactor the sandbox watcher's reconnect logic and its settings copy", "busy"),
    ("22222222-2222-4222-8222-222222222222", "/Users/demo/Projects/web/landing",
     "Rebuild docs pages after the release", "busy"),
    ("33333333-3333-4333-8333-333333333333",
     "/Users/demo/Projects/very-long-folder-name-for-a-monorepo/packages/backend-service-with-long-name",
     "Migrate payments service to the new billing API", "idle"),
    ("44444444-4444-4444-8444-444444444444", "/Users/demo/Projects/tools/notes", "Short", "idle"),
    None,  # the Codex session's process: no record
    ("66666666-6666-4666-8666-666666666666", "/Users/demo/Projects/terminal",
     "Terminal: GPU glyph atlas eviction under memory pressure", "busy"),
]
for index, entry in enumerate(LOCAL):
    if not entry:
        continue
    sid, cwd, name, status = entry
    record = {"pid": pids[index], "sessionId": sid, "cwd": cwd, "name": name,
              "startedAt": started_ms(pids[index]), "status": status,
              "statusUpdatedAt": now_ms, "updatedAt": now_ms}
    with open(os.path.join(D, "sessions", f"{pids[index]}.json"), "w") as f:
        json.dump(record, f)
time.sleep(2.5)  # the records are read every 1.5 s


def event(index, name, **fields):
    sid, cwd = LOCAL[index][0], LOCAL[index][1]
    return hook(PORT, "claude", pids[index], {"hook_event_name": name, "session_id": sid, "cwd": cwd, **fields})


BASH = ('swift test --parallel --filter EvlatAppTests.SandboxWatcherTests 2>&1 | '
        'tee /tmp/evlat-sandbox-watcher-test-output-with-a-long-name.log | grep -E "error|failed"')
QUESTION = {"questions": [{
    "question": "Which eviction policy should the glyph atlas use when the GPU reports memory pressure?",
    "header": "Policy", "multiSelect": False,
    "options": [
        {"label": "LRU", "description": "Evict the glyphs used least recently; simple and predictable."},
        {"label": "Clock", "description": "Second-chance sweep; cheaper bookkeeping per frame."},
        {"label": "Size-aware", "description": "Evict the largest glyphs first to free the most memory."},
    ]}]}

event(0, "SessionStart", source="startup")
event(0, "UserPromptSubmit")
event(0, "PermissionRequest", tool_name="Bash", tool_input={"command": BASH})
event(1, "UserPromptSubmit")
event(1, "PreToolUse", tool_name="Edit",
      tool_input={"file_path": "/Users/demo/Projects/web/landing/docs-src/pages/remote-servers-and-docker-sandboxes.md"})
hook(PORT, "claude", pids[1], {"hook_event_name": "PreToolUse", "session_id": LOCAL[1][0], "cwd": LOCAL[1][1],
                               "agent_id": "sub-1", "tool_name": "Grep", "tool_input": {"pattern": "TabLink.known"}})
event(2, "UserPromptSubmit")
event(2, "Stop", last_assistant_message=(
    "I migrated the payments service to the new billing API. All 214 tests pass, but two integration "
    "tests against the staging gateway are skipped because the sandbox credentials expired; renew them "
    "under **Billing / Staging** and run `make integration` again before merging."))
event(3, "UserPromptSubmit")
event(3, "StopFailure", error="rate_limit")
event(5, "UserPromptSubmit")
event(5, "PreToolUse", tool_name="AskUserQuestion", tool_input=QUESTION)
event(5, "Notification", notification_type="elicitation_dialog", message="Claude needs your input")

# A Codex session.
codex = {"session_id": "019a0000-5555-7555-8555-555555555555", "cwd": "/Users/demo/Projects/terminal-app"}
hook(PORT, "codex", pids[4], {"hook_event_name": "UserPromptSubmit", **codex})
hook(PORT, "codex", pids[4], {"hook_event_name": "PreToolUse", "tool_name": "Bash",
                              "tool_input": {"command": "cargo build --release --target aarch64-apple-darwin"}, **codex})

# Remote machines, each on its own listener, as their tunnels would bring them.
log = open(os.path.join(D, "evlat.log")).read()
machines = {m.group(1): int(m.group(2))
            for m in re.finditer(r"machine (\S+) listening on 127\.0\.0\.1:(\d+)", log)}
by_host = {host.split(".")[0] if not host[0].isdigit() else host: port for host, port in machines.items()}
REMOTE = [
    ("10.0.4.21", "claude", 4242, "aaaaaaaa-0000-4000-8000-000000000001", "/home/dev/src/server-agent",
     [("UserPromptSubmit", {}), ("PreToolUse", {"tool_name": "Bash", "tool_input": {
         "command": "docker compose -f deploy/compose.production.yml up -d --build api worker"}})]),
    ("192.168.1.217", "claude", 5151, "aaaaaaaa-0000-4000-8000-000000000002",
     "/home/ubuntu/projects/ml-training-pipeline-with-a-very-long-name",
     [("UserPromptSubmit", {}), ("PermissionRequest", {"tool_name": "Bash", "tool_input": {
         "command": "sudo systemctl restart nvidia-persistenced"}})]),
    ("gpu-01", "claude", 6161, "aaaaaaaa-0000-4000-8000-000000000003", "/srv/deploy/infra",
     [("UserPromptSubmit", {}), ("PermissionRequest", {"tool_name": "Bash", "tool_input": {
         "command": "terraform apply -auto-approve"}})]),
    ("10.0.4.21", "codex", 4343, "019a0000-aaaa-7000-8000-000000000004", "/home/dev/src/ops",
     [("UserPromptSubmit", {})]),
]
for host, source, pid, sid, cwd, events in REMOTE:
    port = by_host.get(host)
    if not port:
        continue
    for name, fields in events:
        hook(port, source, pid, {"hook_event_name": name, "session_id": sid, "cwd": cwd, **fields})
for port in by_host.values():
    post(port, "/usage/claude", {"rate_limits": {
        "five_hour": {"used_percentage": 55, "resets_at": now_s + 7200},
        "seven_day": {"used_percentage": 91, "resets_at": now_s + 86400}}})

# Docker sandboxes: named, with a long name, and unnamed (drawn as "sbx").
SANDBOXES = [
    ("bbbbbbbb-0000-4000-8000-000000000001", "claude-payments", "PreToolUse",
     {"tool_name": "Read", "tool_input": {"file_path": "/home/agent/workspace/Sources/Payments/BillingClient.swift"}}),
    ("bbbbbbbb-0000-4000-8000-000000000002", "my-very-long-sandbox-name-for-the-payments-service", "Stop",
     {"last_assistant_message": "Done — the sandbox build is green."}),
    ("bbbbbbbb-0000-4000-8000-000000000003", None, "PermissionRequest",
     {"tool_name": "WebFetch", "tool_input": {"url": "https://api.github.com/repos/evlat/evlat/releases/latest"}}),
]
for sid, name, last, fields in SANDBOXES:
    headers = {"X-Evlat-Sandbox": name} if name else {}
    body = {"session_id": sid, "cwd": "/home/agent/workspace"}
    hook(args.sandbox_port, "claude", None, {"hook_event_name": "SessionStart", "source": "startup", **body}, headers)
    hook(args.sandbox_port, "claude", None, {"hook_event_name": "UserPromptSubmit", **body}, headers)
    hook(args.sandbox_port, "claude", None, {"hook_event_name": last, **body, **fields}, headers)

# Usage: Claude's status line, Antigravity's, and a Codex rollout read from disk.
post(PORT, "/usage/claude", {"rate_limits": {
    "five_hour": {"used_percentage": 87, "resets_at": now_s + 5400},
    "seven_day": {"used_percentage": 63, "resets_at": now_s + 3 * 86400}}})


def iso(seconds):
    return dt.datetime.fromtimestamp(now_s + seconds, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


post(PORT, "/usage/antigravity", {"quota": {
    "gemini-5h": {"remaining_fraction": 0.35, "reset_time": iso(7200)},
    "gemini-weekly": {"remaining_fraction": 0.8, "reset_time": iso(5 * 86400)}}})
today = dt.date.today()
rollouts = os.path.join(D, "home", ".codex", "sessions", f"{today:%Y}", f"{today:%m}", f"{today:%d}")
os.makedirs(rollouts, exist_ok=True)
with open(os.path.join(rollouts, "rollout-demo.jsonl"), "w") as f:
    f.write(json.dumps({"timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                        "payload": {"rate_limits": {
                            "primary": {"used_percent": 72.0, "window_minutes": 300, "resets_at": now_s + 3 * 3600},
                            "secondary": {"used_percent": 41.0, "window_minutes": 10080,
                                          "resets_at": now_s + 4 * 86400}}}}) + "\n")

# Outside jobs, with the key the demo's Evlat wrote.
key = open(os.path.join(D, "home", "Library", "Application Support", "Evlat", f"signal-{PORT}.token")).read().strip()
JOBS = [
    {"id": "render", "ttl": 3600, "phase": "working", "progress": 0.42, "sender": "ffmpeg",
     "label": "Render final cut of the product launch video (4K, HDR)",
     "detail": "Encoding segment 17 of 40 — about 12 minutes left"},
    {"id": "deploy", "ttl": 3600, "phase": "waiting", "sender": "gh",
     "label": "Deploy the landing page to production", "detail": "Waiting for approval in the GitHub environment"},
    {"id": "backup", "ttl": 3600, "phase": "done", "sender": "restic",
     "label": "Nightly backup", "detail": "312 GB copied in 41 min"},
    {"id": "ci", "ttl": 3600, "phase": "failed", "sender": "watch", "label": "CI · main · make all",
     "detail": "EvlatAppTests.SandboxWatcherTests.testReconnectAfterDaemonRestart failed"},
]
for job in JOBS:
    post(PORT, "/signal", job, {"X-Evlat-Key": key})

# Held requests: the connection stays open until the card's answer, so their
# curls run on past this script; their pids go where `stop` finds them.
if args.held:
    held = [
        {"hook_event_name": "PermissionRequest", "session_id": LOCAL[0][0], "cwd": LOCAL[0][1],
         "tool_name": "Bash", "tool_input": {"command": BASH, "description": "Run the sandbox watcher tests"}},
        {"hook_event_name": "PermissionRequest", "session_id": LOCAL[5][0], "cwd": LOCAL[5][1],
         "tool_name": "AskUserQuestion", "tool_input": QUESTION},
    ]
    with open(os.path.join(D, "held.pid"), "w") as pidfile:
        for body in held:
            process = subprocess.Popen(
                ["curl", "-s", "-m", "3600", "-X", "POST", f"http://127.0.0.1:{PORT}/approval",
                 "-H", "Content-Type: application/json", "-d", json.dumps(body)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True)
            pidfile.write(f"{process.pid}\n")
