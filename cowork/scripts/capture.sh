#!/usr/bin/env bash
# Print the last N lines of a worker pane (tmux %N, Orca term_<uuid>, iTerm2 session UUID or Terminal.app tty id).
# Usage: capture.sh <pane-id> [lines=80]
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <pane-id> [lines]" >&2; exit 2; }
n=${2:-80}
if [[ $1 =~ ^%[0-9]+$ ]]; then
  tmux capture-pane -p -t "$1" -S "-$n"
elif [[ $1 =~ ^term_[-0-9A-Fa-f]+$ ]]; then
  "$(dirname "$0")/orca.sh" capture "$1" "$n"
elif [[ $1 =~ ^ttys[0-9]+$ ]]; then
  "$(dirname "$0")/terminal.sh" capture "$1" | tail -n "$n"
else
  "$(dirname "$0")/iterm.sh" capture "$1" | tail -n "$n"
fi
