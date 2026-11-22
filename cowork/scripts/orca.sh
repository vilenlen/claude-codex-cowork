#!/usr/bin/env bash
# Orca backend (Orca terminal CLI). Pane ids are runtime terminal handles (term_<uuid>).
# The cowork marker is the per-pane worker record under ${TMPDIR:-/tmp}/cowork/<handle>.worker;
# handles are UUIDs, so a stale record can never match a reused pane.
# Usage: orca.sh split   <lead-handle> <task-name> <shell-line>   -> new terminal handle
#        orca.sh info    <handle>                                 -> "<worker>|<agentIdentity>"
#        orca.sh send    <handle> <prompt-file>
#        orca.sh keys    <handle> <keyseq-file>                   -> raw bytes, no paste markers, no Enter
#        orca.sh capture <handle> [rows]                          -> rendered screen
#        orca.sh tty     <handle>                                 -> handle while the terminal exists
#        orca.sh close   <handle>                                 -> closes a recorded worker pane only
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: $0 split|info|send|keys|capture|tty|close <handle> ..." >&2; exit 2; }
action=$1 handle=$2
here=$(cd "$(dirname "$0")" && pwd)
base=${TMPDIR:-/tmp}/cowork

cli() {
  if [[ -n ${ORCA_CLI_BIN_DIR:-} && -x $ORCA_CLI_BIN_DIR/orca ]]; then
    "$ORCA_CLI_BIN_DIR/orca" "$@"
  else
    command orca "$@"
  fi
}
field() { python3 -I -c 'import json,sys
try:
    o = json.load(sys.stdin)
    for k in sys.argv[1].split("."):
        o = o.get(k)
    print(o if isinstance(o, str) else "")
except Exception:
    sys.exit(1)' "$1"; }

case $action in
split)
  [[ $# -eq 4 ]] || { echo "usage: $0 split <lead-handle> <task-name> <shell-line>" >&2; exit 2; }
  name=$3 line=$4
  tabid=$(cli terminal show --terminal "$handle" --json | field result.terminal.tabId)
  [[ -n $tabid ]] || { echo "Orca lead terminal not found" >&2; exit 1; }
  # Layout like tmux main-vertical: first worker beside the lead, later ones below the last worker.
  # Orca names directions vim-style (verified: vertical = side-by-side, horizontal = stacked).
  target=$handle dir=vertical
  last=$(cli terminal list --json | python3 -I -c 'import json, os, sys
tab, base = sys.argv[1], os.path.join(os.environ.get("TMPDIR", "/tmp"), "cowork")
last = ""
for t in json.load(sys.stdin)["result"]["terminals"]:
    if t.get("tabId") == tab and os.path.isfile(os.path.join(base, t["handle"] + ".worker")):
        last = t["handle"]  # list order is creation order, so the last tagged pane is the newest worker
print(last)' "$tabid") || last=
  [[ -z $last ]] || { target=$last; dir=horizontal; }
  out=$(cli terminal split --terminal "$target" --direction "$dir" --command "$line" --json 2>&1) || {
    # A timeout may still leave the pane open; the error names the leafId to wait for instead of splitting again.
    leaf=$(printf '%s\n' "$out" | grep -oE -- '--retry-split[ =:]+[0-9a-f-]{36}' | grep -oE -- '[0-9a-f-]{36}' | head -1) || true
    if [[ -n $leaf ]]; then
      out=$(cli terminal split --terminal "$target" --retry-split "$leaf" --json 2>&1) || { printf '%s\n' "$out" >&2; exit 1; }
    else
      printf '%s\n' "$out" >&2; exit 1
    fi
  }
  new=$(printf '%s' "$out" | field result.split.handle)
  [[ -n $new ]] || { printf '%s\n' "$out" >&2; exit 1; }
  cli terminal set-pane-title --terminal "$new" --title "cowork:$name" >/dev/null 2>&1 || true
  printf '%s\n' "$new"
  ;;
info)
  worker=$(head -n1 "$base/$handle.worker" 2>/dev/null) || worker=
  identity=$(cli terminal show --terminal "$handle" --json | field result.terminal.agentIdentity) || { echo "Orca terminal not found" >&2; exit 1; }
  printf '%s|%s\n' "${worker:-}" "${identity:-}"
  ;;
send)
  [[ $# -eq 3 ]] || { echo "usage: $0 send <handle> <prompt-file>" >&2; exit 2; }
  # Trailing newlines of the file are lost to command substitution; the appended Enter submits the prompt anyway.
  payload=$(cat "$3")
  cli terminal send --terminal "$handle" --text "$payload" --enter >/dev/null
  printf 'sent_to=%s\n' "$handle"
  ;;
keys)
  [[ $# -eq 3 ]] || { echo "usage: $0 keys <handle> <keyseq-file>" >&2; exit 2; }
  payload=$(cat "$3")
  cli terminal send --terminal "$handle" --text "$payload" >/dev/null
  printf 'keys_to=%s\n' "$handle"
  ;;
capture)
  rows=${3:-80}
  # Screen mode: TUIs repaint lines, so the rendered frame is the honest capture.
  cli terminal read --terminal "$handle" --screen --limit "$rows" --json | python3 -I -c 'import json,sys
try:
    t = json.load(sys.stdin)["result"]["terminal"]
except Exception:
    sys.exit(1)
print("\n".join(t.get("tail") or []))'
  ;;
tty)
  cli terminal read --terminal "$handle" --limit 1 --json 2>/dev/null | field result.terminal.handle | grep . || true
  ;;
close)
  worker=$(head -n1 "$base/$handle.worker" 2>/dev/null) || worker=
  [[ -n $worker ]] || { echo "not a cowork terminal: $handle" >&2; exit 2; }
  cli terminal close --terminal "$handle" >/dev/null
  rm -f "$base/$handle.worker"
  printf 'closed=%s\n' "$handle"
  ;;
*)
  echo "unknown action: $action" >&2; exit 2 ;;
esac
