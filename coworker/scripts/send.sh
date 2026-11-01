#!/usr/bin/env bash
# Send literal text to an already-started Codex pane after the caller checks readiness.
# Usage: send.sh <pane-id> <prompt-file>
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 <pane-id> <prompt-file>" >&2; exit 2; }
pane=$1 prompt=$2
[[ -s $prompt ]] || { echo "empty/missing prompt file" >&2; exit 2; }
# wait.py ignores turns that ended before this marker (ms precision), so an earlier task_complete can't satisfy it.
# The prompt's first line lets wait.py find this pane's rollout log.
mark() { mkdir -p "${TMPDIR:-/tmp}/coworker"; { python3 -I -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).isoformat(timespec="milliseconds")[:23] + "Z")'; grep -m1 '[^[:space:]]' "$prompt"; } > "${TMPDIR:-/tmp}/coworker/$pane.sent"; }
if [[ $pane =~ ^[0-9A-Fa-f-]{36}$ ]]; then
  # iTerm2 session UUID.
  IFS='|' read -r worker job < <("$(dirname "$0")/iterm.sh" info "$pane") || { echo "iTerm2 session not found" >&2; exit 1; }
  [[ -n $worker ]] || { echo "target is not a coworker pane" >&2; exit 2; }
  # Allowlist: during startup the job is transiently zsh/login/id/node and pasted text would land in the shell.
  [[ $job == codex ]] || { echo "Codex not running in this pane yet or exited (job=${job:-none})" >&2; exit 1; }
  mark
  "$(dirname "$0")/iterm.sh" send "$pane" "$prompt"
  exit 0
fi
[[ $pane =~ ^%[0-9]+$ ]] || { echo "invalid pane id" >&2; exit 2; }
worker=$(tmux show-option -p -v -t "$pane" @coworker 2>/dev/null || true)
[[ -n $worker ]] || { echo "target is not a coworker pane" >&2; exit 2; }
[[ $(tmux display -p -t "$pane" '#{pane_dead}') == 0 ]] || { echo "Codex pane has exited" >&2; exit 1; }
case $(tmux display -p -t "$pane" '#{pane_current_command}') in
  bash|zsh|sh|fish|dash) echo "target is a shell, not a running Codex session" >&2; exit 1 ;;
esac
mark
buffer="coworker-$$"
trap 'tmux delete-buffer -b "$buffer" 2>/dev/null || true' EXIT
# Bracketed paste keeps multiline text and shell metacharacters as one input message.
tmux load-buffer -b "$buffer" "$prompt"
tmux paste-buffer -r -p -b "$buffer" -t "$pane"
sleep 0.3
tmux send-keys -t "$pane" Enter
printf 'sent_to=%s\n' "$pane"
