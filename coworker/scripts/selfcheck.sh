#!/usr/bin/env bash
# Self-check for available backends: opens raw-tty panes (no Codex) and asserts byte fidelity, capture and guards.
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
expect_dispatch_error() {
  local status=0
  bash "$S/dispatch.sh" selfcheck "$S" -m selfcheck "$@" >/dev/null 2>&1 || status=$?
  [[ $status -eq 2 ]] || { echo "FAIL: dispatch accepted invalid arguments or failed outside validation: $* (exit $status)" >&2; exit 1; }
}
expect_dispatch_error --resume invalid-uuid
expect_dispatch_error --resume
expect_dispatch_error --unknown

D=$(mktemp -d); P=; ts="cw-selfcheck-$$"
trap '[[ -z $P ]] || "$S/iterm.sh" close "$P" >/dev/null 2>&1 || true; tmux kill-session -t "$ts" 2>/dev/null || true; rm -rf "$D"' EXIT
python3 -I - "$D/p.txt" <<'PY'
import sys
open(sys.argv[1], 'w', encoding='utf-8').write(''.join('行%05d "q" `bt` $(x) \\n | & ;\n' % i for i in range(2000)))
PY
compare() { python3 -I - "$D/p.txt" "$1" <<'PY'
import sys
want, got = (open(f, 'rb').read() for f in sys.argv[1:3])
assert got.endswith(b'\r'), 'Enter missing'
got = got[:-1]
if got.startswith(b'\x1b[200~'): got = got[6:]
if got.endswith(b'\x1b[201~'): got = got[:-6]
assert got.replace(b'\r\n', b'\n').replace(b'\r', b'\n') == want, 'payload differs'
PY
}

python3 -I - "$S" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from wait import scan
ev = lambda ts, t, turn, **k: json.dumps({"timestamp": ts, "type": "event_msg", "payload": {"type": t, "turn_id": turn, **k}})
ri = lambda ts, t, **k: json.dumps({"timestamp": ts, "type": "response_item", "payload": {"type": t, **k}})
ask = lambda ts, name, cid: ri(ts, "function_call", name=name, call_id=cid, arguments='{"questions":[{"question":"db?"}]}')
old = [ev("T1", "task_started", "a"), ev("T2", "task_complete", "a", last_agent_message="old")]
b = [ev("T3", "task_started", "b")]
assert scan(old, "T3") is None, "earlier turn must not count"
assert scan(old + b, "T3") is None, "running turn"
assert scan(old + b + [ev("T4", "task_complete", "b", last_agent_message="new")], "T3") == ("completed", "new")
assert scan(old + b + [ev("T4", "turn_aborted", "b")], "T3") == ("aborted", "")
assert scan(old + b + ['{"partial'], "T3") is None, "partial line"
# Mid-turn answer: the marker moves past the turn start, the turn's end must still count.
assert scan(b + [ev("T6", "task_complete", "b", last_agent_message="x")], "T5") == ("completed", "x")
st = scan(b + [ask("T4", "request_user_input", "c1")], "T3")
assert st[0] == "needs_input" and json.loads(st[1])["kind"] == "blocking", st
assert scan(b + [ask("T4", "request_user_input", "c1")], "T3", {"c1"}) is None, "already reported"
assert scan(b + [ask("T4", "request_user_input", "c1"), ri("T5", "function_call_output", call_id="c1", output="{}")], "T3") is None, "answered"
assert json.loads(scan(b + [ask("T4", "request_user_input_async", "c2")], "T3")[1])["kind"] == "async"
assert scan(b + [ask("T4", "request_user_input_async", "c2"), ri("T5", "function_call_output", call_id="c2", output="ok"), ri("T6", "message", role="user")], "T3") is None, "async answered by message"
assert scan(b + [ask("T4", "request_user_input", "c3"), ri("T5", "message", role="user")], "T3")[0] == "needs_input", "message does not answer a menu"
assert scan(b + [ask("T4", "send_message_to_user_async", "c4"), ev("T5", "task_complete", "b", last_agent_message="done")], "T3") == ("completed", "done")
PY

if [[ -n ${ITERM_SESSION_ID:-} && -z ${TMUX:-} ]]; then
  lead=${ITERM_SESSION_ID#*:}
  P=$("$S/iterm.sh" split "$lead" selfcheck "stty raw -echo; cat > $D/r.bin")
  sleep 2
  "$S/iterm.sh" send "$P" "$D/p.txt" >/dev/null
  sleep 3
  compare "$D/r.bin"
  [[ $("$S/iterm.sh" info "$P") == selfcheck\|* ]] || { echo "FAIL tag" >&2; exit 1; }
  if "$S/send.sh" "$lead" "$D/p.txt" >/dev/null 2>&1; then echo "FAIL: send accepted non-worker" >&2; exit 1; fi
  if "$S/iterm.sh" close "$lead" >/dev/null 2>&1; then echo "FAIL: close accepted non-worker" >&2; exit 1; fi
  "$S/capture.sh" "$P" 5 >/dev/null
  "$S/iterm.sh" close "$P" >/dev/null; P=
  echo "iterm2 ok"
fi

if command -v tmux >/dev/null; then
  T=$(tmux new-session -d -P -F '#{pane_id}' -s "$ts" "stty raw -echo; exec cat > $D/t.bin")
  sleep 1
  if "$S/send.sh" "$T" "$D/p.txt" >/dev/null 2>&1; then echo "FAIL: send accepted untagged tmux pane" >&2; exit 1; fi
  tmux set-option -p -t "$T" @coworker selfcheck
  "$S/send.sh" "$T" "$D/p.txt" >/dev/null
  sleep 2
  compare "$D/t.bin"
  "$S/capture.sh" "$T" 5 >/dev/null
  tmux kill-session -t "$ts"
  echo "tmux ok"
fi
echo "selfcheck ok"
