#!/usr/bin/env bash
# Send literal text to an already-started worker pane after the caller checks readiness.
# Usage: send.sh <pane-id> <prompt-file>
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 <pane-id> <prompt-file>" >&2; exit 2; }
pane=$1 prompt=$2
[[ -s $prompt ]] || { echo "empty/missing prompt file" >&2; exit 2; }
# wait.py ignores turns that ended before this marker (ms precision), so an earlier task_complete can't satisfy it.
# The prompt's first line lets wait.py find this pane's rollout log.
mark() { mkdir -p "${TMPDIR:-/tmp}/cowork"; { python3 -I -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).isoformat(timespec="milliseconds")[:23] + "Z")'; grep -m1 '[^[:space:]]' "$prompt"; } > "${TMPDIR:-/tmp}/cowork/$pane.sent"; }
if [[ $pane =~ ^[0-9A-Fa-f-]{36}$ ]]; then
  # iTerm2 session UUID.
  IFS='|' read -r worker job < <("$(dirname "$0")/iterm.sh" info "$pane") || { echo "iTerm2 session not found" >&2; exit 1; }
  [[ -n $worker ]] || { echo "target is not a cowork pane" >&2; exit 2; }
  # Allowlist: during startup the job is transiently zsh/login/id/node and pasted text would land in the shell.
  [[ $job == codex || $job == claude || $job == claude-glink || $job == agy ]] || { echo "worker not running in this pane yet or exited (job=${job:-none})" >&2; exit 1; }
  mark
  "$(dirname "$0")/iterm.sh" send "$pane" "$prompt"
  exit 0
fi
if [[ $pane =~ ^term_[-0-9A-Fa-f]+$ ]]; then
  # Orca terminal handle; handles are UUIDs, so the worker record is a reliable marker.
  [[ -f ${TMPDIR:-/tmp}/cowork/$pane.worker ]] || { echo "target is not a cowork pane" >&2; exit 2; }
  IFS='|' read -r worker job < <("$(dirname "$0")/orca.sh" info "$pane") || { echo "Orca terminal not found" >&2; exit 1; }
  [[ $worker == claude || $worker == codex || $worker == agy ]] || { echo "target is not a cowork pane" >&2; exit 2; }
  [[ $job == codex || $job == claude || $job == claude-glink || $job == agy ]] || { echo "worker not running in this pane yet or exited (agent=${job:-none})" >&2; exit 1; }
  mark
  "$(dirname "$0")/orca.sh" send "$pane" "$prompt"
  exit 0
fi
if [[ $pane =~ ^ttys[0-9]+$ ]]; then
  # Terminal.app tty id.
  IFS='|' read -r worker job < <("$(dirname "$0")/terminal.sh" info "$pane") || { echo "Terminal tab not found" >&2; exit 1; }
  [[ -n $worker ]] || { echo "target is not a cowork pane" >&2; exit 2; }
  [[ $job == codex || $job == claude || $job == claude-glink || $job == agy ]] || { echo "worker not running in this pane yet or exited (job=${job:-none})" >&2; exit 1; }
  mark
  "$(dirname "$0")/terminal.sh" send "$pane" "$prompt"
  exit 0
fi
[[ $pane =~ ^%[0-9]+$ ]] || { echo "invalid pane id" >&2; exit 2; }
worker=$(tmux show-option -p -v -t "$pane" @cowork 2>/dev/null || true)
[[ -n $worker ]] || { echo "target is not a cowork pane" >&2; exit 2; }
[[ $(tmux display -p -t "$pane" '#{pane_dead}') == 0 ]] || { echo "worker pane has exited" >&2; exit 1; }
case $(tmux display -p -t "$pane" '#{pane_current_command}') in
  bash|zsh|sh|fish|dash) echo "target is a shell, not a running worker session" >&2; exit 1 ;;
esac
mark
buffer="cowork-$$"
trap 'tmux delete-buffer -b "$buffer" 2>/dev/null || true' EXIT
# Bracketed paste keeps multiline text and shell metacharacters as one input message.
# The Enter must be its own input write well after the paste: a young worker TUI drains
# queued stdin in one batch and takes a CR glued to the paste as a composer newline
# instead of the submit key. The TUI ignores Enter on an empty composer, so the later
# Enter is harmless when the paste's arrival already looked complete.
tmux load-buffer -b "$buffer" "$prompt"
tmux paste-buffer -r -p -b "$buffer" -t "$pane"
sleep 1
tmux send-keys -t "$pane" Enter
printf 'sent_to=%s\n' "$pane"
