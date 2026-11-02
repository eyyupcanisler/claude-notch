#!/usr/bin/env python3
"""End-to-end driver: runs a real `claude` in a pty with a test settings file.

Usage: drive.py <scenario> <settings.json> <workdir> <testdir>
Scenarios: allow | deny | terminal | noapp | stop | esc | no | agent | identity
  identity: like stop, then checks tty / pid / branch against the claude child and that a
            SIGKILLed session (no SessionEnd) is dropped by the liveness sweep.
Needs the ClaudeNotch app running (except `noapp`, where it must be NOT running).
Prints one JSON object with the observations.
"""
import json
import os
import pty
import re
import select
import signal
import subprocess
import sys
import time

SCENARIO, SETTINGS, WORKDIR, TESTDIR = sys.argv[1:5]
SOCK = os.path.expanduser("~/Library/Application Support/ClaudeNotch/notch.sock")
PROMPT = f"Run exactly this bash command and nothing else: mkdir -p {TESTDIR}"
if SCENARIO == "agent":
    PROMPT = ("Use the Agent tool to launch a general-purpose subagent whose only job is to run "
              f"this bash command: mkdir -p {TESTDIR}. Do nothing else yourself.")
if SCENARIO in ("stop", "identity"):
    PROMPT = "Reply with exactly the single word: pong. Do not use any tools."

ANSI = re.compile(rb"\x1b\[[0-9;?<>=]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-B]")


def curl(path, data=None):
    cmd = ["curl", "-s", "--max-time", "3", "--unix-socket", SOCK]
    if data is not None:
        cmd += ["-d", json.dumps(data)]
    cmd.append("http://localhost" + path)
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except ValueError:
        return None


def state():
    return curl("/debug/state") or {"sessions": [], "pending": []}


def bridge_procs():
    out = subprocess.run(["pgrep", "-f", "claude-notch-hook.sh permission"],
                         capture_output=True, text=True).stdout.split()
    return len(out)


BEFORE = {x["session_id"] for x in state().get("sessions", [])} if os.path.exists(SOCK) else set()

pid, fd = pty.fork()
if pid == 0:
    os.chdir(WORKDIR)
    os.environ["TERM"] = "xterm-256color"
    os.execvp("claude", ["claude", "--settings", SETTINGS, "--permission-mode", "default",
                         PROMPT])

raw = b""
log = {"scenario": SCENARIO}
t0 = time.time()


def text():
    return re.sub(r"\s+", "", ANSI.sub(b"", raw).decode("utf8", "ignore"))


def pump(sec):
    global raw
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                raw += os.read(fd, 65536)
            except OSError:
                return


def wait_for(pred, timeout, step=0.15):
    end = time.time() + timeout
    while time.time() < end:
        pump(step)
        if "Yes,Itrustthisfolder" in text() and not log.get("trusted"):
            os.write(fd, b"\x1b[B")
            pump(0.5)
            os.write(fd, b"\r")
            log["trusted"] = True
        v = pred()
        if v:
            return v
    return None


def pending_cards():
    return state().get("pending", [])


try:
    if SCENARIO in ("allow", "deny"):
        cards = wait_for(pending_cards, 60)
        log["card_seen"] = bool(cards)
        if cards:
            log["card"] = cards[0]
            log["dialog_in_terminal"] = "Doyouwanttoproceed" in text()
            decision = {"id": cards[0]["id"], "decision": SCENARIO}
            if SCENARIO == "deny":
                decision["message"] = "Denied by test harness. Do not retry."
            log["decide_response"] = curl("/debug/decide", decision)
            log["t_decide"] = round(time.time() - t0, 1)
        if SCENARIO == "deny":
            # deny any retries for a while
            end = time.time() + 25
            denies = 0
            while time.time() < end:
                pump(0.3)
                for c in pending_cards():
                    curl("/debug/decide", {"id": c["id"], "decision": "deny",
                                           "message": "Denied by test harness. Do not retry."})
                    denies += 1
            log["denies"] = denies
        else:
            pump(8)
        log["dir_exists"] = os.path.isdir(TESTDIR)
        log["screen_has_hook_error"] = "hookerror" in text().lower()
    elif SCENARIO == "agent":
        # Does a subagent's PermissionRequest carry agent_id? (one card, then deny it)
        cards = wait_for(pending_cards, 90)
        log["card_seen"] = bool(cards)
        if cards:
            log["agent_id"] = cards[0].get("agent_id")
            log["tool_name"] = cards[0].get("tool_name")
            log["decide_response"] = curl("/debug/decide", {
                "id": cards[0]["id"], "decision": "deny", "message": "Denied by test harness."})
    elif SCENARIO == "terminal":
        cards = wait_for(pending_cards, 60)
        log["card_seen"] = bool(cards)
        wait_for(lambda: "Doyouwanttoproceed" in text(), 10)
        pump(1.0)
        log["bridge_before"] = bridge_procs()
        t_enter = time.time()
        os.write(fd, b"\r")  # option 1: Yes
        gone = wait_for(lambda: not pending_cards(), 20, 0.1)
        log["card_gone_after_s"] = round(time.time() - t_enter, 2) if gone else None
        pump(1.5)
        log["bridge_after"] = bridge_procs()
        log["dir_exists"] = os.path.isdir(TESTDIR)
    elif SCENARIO in ("esc", "no"):
        # Esc / "No" at the terminal dialog: how long does the card live?
        cards = wait_for(pending_cards, 60)
        log["card_seen"] = bool(cards)
        wait_for(lambda: "Doyouwanttoproceed" in text(), 10)
        pump(1.0)
        t_esc = time.time()
        if SCENARIO == "esc":
            os.write(fd, b"\x1b")
        else:  # option 4: "No"
            for _ in range(3):
                os.write(fd, b"\x1b[B")
                pump(0.3)
            os.write(fd, b"\r")
        gone = wait_for(lambda: not pending_cards(), 150, 0.5)
        log["card_gone_after_s"] = round(time.time() - t_esc, 1) if gone else None
        log["dir_exists"] = os.path.isdir(TESTDIR)
        log["sessions"] = [s["status"] for s in state().get("sessions", [])
                           if cards and s["session_id"] == cards[0]["session_id"]]
    elif SCENARIO == "noapp":
        ok = wait_for(lambda: "Doyouwanttoproceed" in text(), 60)
        log["dialog_seen"] = bool(ok)
        pump(3)
        log["screen_has_hook_error"] = "hookerror" in text().lower() or "hookfailed" in text().lower()
        log["dir_exists_before_answer"] = os.path.isdir(TESTDIR)
        os.write(fd, b"\r")
        pump(6)
        log["dir_exists"] = os.path.isdir(TESTDIR)
    elif SCENARIO == "identity":
        def done():
            for s in state().get("sessions", []):
                if s["status"] == "done" and s["session_id"] not in BEFORE:
                    return s
            return None
        s = wait_for(done, 60)
        log["session"] = s
        tty = subprocess.run(["ps", "-o", "tty=", "-p", str(pid)], capture_output=True,
                             text=True).stdout.strip()
        branch = subprocess.run(["git", "-C", WORKDIR, "branch", "--show-current"],
                                capture_output=True, text=True).stdout.strip()
        log["expected"] = {"tty": "/dev/" + tty, "pid": pid, "branch": branch or None}
        if s:
            log["tty_ok"] = s.get("tty") == "/dev/" + tty
            log["pid_ok"] = s.get("pid") == pid
            log["branch_ok"] = s.get("branch") == (branch or None)
            log["done_unseen"] = s.get("unseen")
            os.kill(pid, signal.SIGKILL)
            try:
                os.close(fd)
            except OSError:
                pass
            os.waitpid(pid, 0)
            t_kill = time.time()
            gone = None
            while time.time() - t_kill < 30:
                ids = {x["session_id"] for x in state().get("sessions", [])}
                if s["session_id"] not in ids:
                    gone = round(time.time() - t_kill, 1)
                    break
                time.sleep(0.5)
            log["removed_after_kill_s"] = gone
    elif SCENARIO == "stop":
        def done():
            for s in state().get("sessions", []):
                if s["status"] == "done" and s["session_id"] not in BEFORE:
                    return s
            return None
        s = wait_for(done, 60)
        log["session"] = s
    log["elapsed_s"] = round(time.time() - t0, 1)
finally:
    if os.environ.get("DRIVE_DEBUG"):
        sys.stderr.write(ANSI.sub(b"", raw).decode("utf8", "ignore")[-3000:] + "\n")
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.close(fd)  # macOS: the child cannot finish exiting while the pty output is undrained
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
print(json.dumps(log, ensure_ascii=False))
