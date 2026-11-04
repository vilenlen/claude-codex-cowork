#!/usr/bin/env -S python3 -I
"""Block until the Codex turn needs attention, then print ONE status line. Run in the background.

Usage: wait.py <pane-id> [timeout-seconds=3600]
Status: completed | aborted | needs_input | stalled | exited | timeout.
Details go to the file named by last=, never stdout: the final answer, the pending question (JSON) or the screen tail.
Signal: Codex's rollout log; the pane is only peeked at (by this script, not the caller) once the log goes quiet.
"""
import json, os, re, subprocess, sys, tempfile, time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
POLL = 3
STALL = 120  # seconds of a silent log before peeking at the screen for an unlogged prompt
# Tools through which Codex asks the user mid-turn. Blocking ones show a menu (answer.sh); async ones take a message (send.sh).
ASK_TOOLS = {"request_user_input": "blocking", "request_user_input_async": "async", "send_message_to_user_async": "message"}


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


def pane_tty(pane):
    if re.fullmatch(r"%\d+", pane):
        return run("tmux", "display", "-p", "-t", pane, "#{pane_tty}") if pane in run("tmux", "list-panes", "-a", "-F", "#{pane_id}").split() else ""
    if re.fullmatch(r"ttys\d+", pane):
        return run(os.path.join(HERE, "terminal.sh"), "tty", pane)
    return run(os.path.join(HERE, "iterm.sh"), "tty", pane)


def find_rollout(since, needle):
    """Codex opens its rollout log only while writing, so locate it by content: written after `since` and containing the prompt."""
    # ponytail: if two panes are sent an identical first line in the same second, the first match wins.
    root = os.path.join(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"), "sessions")
    needle = json.dumps(needle, ensure_ascii=False)[1:-1]
    for d, _, files in os.walk(root):
        for f in files:
            path = os.path.join(d, f)
            if f.startswith("rollout-") and f.endswith(".jsonl") and os.path.getmtime(path) >= since:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    if needle in fh.read():
                        return path


def scan(lines, sent, seen=()):
    """State of the newest turn: (status, detail), or None while it runs with nothing to report.

    A turn that ended before `sent` is stale (we are waiting for the next one); one that ends after it counts even if it
    started earlier, which is the case when a mid-turn answer was sent. Questions whose call_id is in `seen` were already
    reported and are not reported again.
    """
    turn = end = None
    asks = {}
    for line in lines:
        try:
            o = json.loads(line)
        except ValueError:
            continue  # partially written line; picked up on the next poll
        p, ts = o.get("payload") or {}, o.get("timestamp", "")
        kind = p.get("type")
        if o.get("type") == "event_msg":
            if kind == "task_started":
                turn, end, asks = p.get("turn_id"), None, {}
            elif turn and p.get("turn_id") == turn and kind == "task_complete":
                end = ("completed", p.get("last_agent_message") or "", ts)
            elif turn and p.get("turn_id") == turn and kind == "turn_aborted":
                end = ("aborted", "", ts)
        elif o.get("type") == "response_item" and turn and not end:
            if kind == "function_call" and p.get("name") in ASK_TOOLS:
                try:
                    args = json.loads(p.get("arguments") or "{}")
                except ValueError:
                    args = p.get("arguments")
                asks[p.get("call_id")] = {"kind": ASK_TOOLS[p["name"]], "call_id": p.get("call_id"), **(args if isinstance(args, dict) else {"arguments": args})}
            elif kind == "function_call_output" and asks.get(p.get("call_id"), {}).get("kind") == "blocking":
                del asks[p["call_id"]]  # answered, or rejected (e.g. unavailable in this mode)
            elif kind == "message" and p.get("role") == "user":
                asks = {k: v for k, v in asks.items() if v["kind"] == "blocking"}  # a user message answers async asks
    if end:
        return end[:2] if end[2] >= sent else None
    pending = [a for a in asks.values() if a["call_id"] not in seen]
    return ("needs_input", json.dumps(pending[-1], ensure_ascii=False)) if turn and pending else None


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    pane, timeout = sys.argv[1], int(sys.argv[2]) if len(sys.argv) == 3 else 3600
    base = os.path.join(tempfile.gettempdir(), "coworker")
    with open(os.path.join(base, pane + ".sent"), encoding="utf-8") as f:
        sent, needle = (f.read().split("\n", 1) + [""])[:2]
    since = datetime.fromisoformat(sent.replace("Z", "+00:00")).timestamp() - 1
    cache, last, seen_file = (os.path.join(base, pane + ext) for ext in (".rollout", ".last.md", ".seen"))
    rollout = open(cache).read().strip() if os.path.exists(cache) else None
    seen = set(open(seen_file).read().split()) if os.path.exists(seen_file) else set()
    t0, size, tick, quiet_since = time.time(), -1, 0, time.time()

    def done(status, msg=""):
        with open(last, "w") as f:
            f.write(msg)
        print(f"status={status} pane={pane} elapsed={int(time.time() - t0)}s chars={len(msg)} last={last}")
        sys.exit(0)

    while time.time() - t0 < timeout:
        # Size check keeps polling cheap; the liveness call is rarer because it spawns osascript/tmux.
        if tick % 3 == 0 and not pane_tty(pane):
            done("exited")
        if not rollout and needle.strip():
            rollout = find_rollout(since, needle.strip())
            if rollout:
                with open(cache, "w") as f:
                    f.write(rollout)
        if rollout and os.path.getsize(rollout) != size:
            size, quiet_since = os.path.getsize(rollout), time.time()
            with open(rollout) as f:
                state = scan(f, sent, seen)
            if state and state[0] == "needs_input":
                with open(seen_file, "a") as f:
                    f.write(json.loads(state[1])["call_id"] + "\n")
            if state:
                done(*state)
        elif time.time() - quiet_since > STALL:
            # Log silent: either a long command (screen shows "Working (") or a prompt Codex does not log.
            screen = run(os.path.join(HERE, "capture.sh"), pane, "25")
            if "Working (" not in screen:
                done("stalled", screen + "\n")
            quiet_since = time.time()
        tick += 1
        time.sleep(POLL)
    done("timeout")


if __name__ == "__main__":
    main()
