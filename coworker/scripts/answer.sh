#!/usr/bin/env bash
# Answer a blocking Codex question menu (request_user_input) by keystrokes, one line per question in order.
# Usage: answer.sh <pane-id> <answers-file>
#   line = "<option-number>" or "<option-number> <note>"; the note is typed into the option's notes field (tab).
#   For a free-text answer pick the "None of the above" option (last number) and put the text in the note.
# Async questions (request_user_input_async) have no menu: answer them with send.sh <pane-id> <message-file>.
set -euo pipefail
[[ $# -eq 2 && -s $2 ]] || { echo "usage: $0 <pane-id> <answers-file>" >&2; exit 2; }
pane=$1 file=$2 here=$(dirname "$0")
grep -qvE '^[1-9][0-9]?( .*)?$' "$file" && { echo "each line must be '<n>' or '<n> <note>'" >&2; exit 2; }
"$here/capture.sh" "$pane" 30 | grep -q 'enter to submit' || { echo "no Codex question menu on screen" >&2; exit 1; }
if [[ $pane =~ ^%[0-9]+$ ]]; then
  [[ -n $(tmux show-option -p -v -t "$pane" @coworker 2>/dev/null) ]] || { echo "target is not a coworker pane" >&2; exit 2; }
  key() { tmux send-keys -t "$pane" "$1"; }
  note() { printf %s "$1" | tmux load-buffer -b "cw-note-$$" -; tmux paste-buffer -r -p -d -b "cw-note-$$" -t "$pane"; }
else
  [[ $("$here/iterm.sh" info "$pane") == ?*\|codex ]] || { echo "target is not a running coworker pane" >&2; exit 2; }
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  key() { case $1 in Down) printf '\033[B' ;; Tab) printf '\t' ;; Enter) printf '\r' ;; esac > "$tmp"; "$here/iterm.sh" keys "$pane" "$tmp" >/dev/null; }
  note() { printf '\033[200~%s\033[201~' "$1" > "$tmp"; "$here/iterm.sh" keys "$pane" "$tmp" >/dev/null; }
fi
pause() { perl -e 'select(undef, undef, undef, 0.4)'; }
# The menu starts each question on option 1; Down moves, Tab opens notes, Enter submits (the last Enter submits all).
while IFS= read -r line || [[ -n $line ]]; do
  n=${line%% *}
  for ((i = 1; i < n; i++)); do key Down; pause; done
  if [[ $line == *' '* ]]; then key Tab; pause; note "${line#* }"; pause; fi
  key Enter; pause
done < "$file"
printf 'answered=%s questions=%s\n' "$pane" "$(grep -c . "$file")"
