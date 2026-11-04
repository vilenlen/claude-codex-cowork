#!/usr/bin/env bash
# Print the last N lines of a Codex pane (tmux %N or iTerm2 session UUID), including scrollback.
# Usage: capture.sh <pane-id> [lines=80]
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <pane-id> [lines]" >&2; exit 2; }
n=${2:-80}
if [[ $1 =~ ^%[0-9]+$ ]]; then
  tmux capture-pane -p -t "$1" -S "-$n"
elif [[ $1 =~ ^ttys[0-9]+$ ]]; then
  "$(dirname "$0")/terminal.sh" capture "$1" | tail -n "$n"
else
  "$(dirname "$0")/iterm.sh" capture "$1" | tail -n "$n"
fi
