#!/usr/bin/env bash
# Start an interactive Codex split/window (auto-detected: tmux, else iTerm2, else Terminal.app, else a detached tmux session); send the task separately after checking readiness.
# Usage: dispatch.sh <task-name> <project-dir> -m <model> [--effort <low|medium|high|xhigh>] [--search] [--resume <session-UUID>]
set -euo pipefail
[[ $# -ge 4 ]] || { echo "usage: $0 <task-name> <project-dir> -m <model> [--search] [--resume <session-UUID>]" >&2; exit 2; }
name=$1 dir=$2; shift 2
[[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad task name: $name" >&2; exit 2; }
[[ -d $dir ]] || { echo "missing project dir" >&2; exit 2; }
[[ $1 == -m && -n $2 ]] || { echo "explicit -m <model> is required" >&2; exit 2; }
model=$2; shift 2
search= resume= effort=
while [[ $# -gt 0 ]]; do
  case $1 in
    --search) search=1; shift ;;
    --effort)
      [[ $# -ge 2 && $2 =~ ^(minimal|low|medium|high|xhigh)$ ]] || { echo "--effort requires minimal|low|medium|high|xhigh" >&2; exit 2; }
      effort=$2; shift 2 ;;
    --resume)
      [[ $# -ge 2 ]] || { echo "--resume requires a session UUID" >&2; exit 2; }
      [[ $2 =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || { echo "bad session UUID: $2" >&2; exit 2; }
      resume=$2; shift 2 ;;
    *) echo "unknown argument: $1 (expected --search or --resume <session-UUID>)" >&2; exit 2 ;;
  esac
done
command -v codex >/dev/null || { echo "codex not found" >&2; exit 1; }
cmd='exec codex'
[[ -z $resume ]] || cmd+=' resume'
printf -v cmd '%s -a never -s danger-full-access -m %q' "$cmd" "$model"
[[ -z $search ]] || cmd+=' --search'
[[ -z $effort ]] || cmd+=" -c model_reasoning_effort=$effort"
[[ -z $resume ]] || cmd+=" $resume"
# Use bash without interactive aliases; never put the task in the startup command.
printf -v shcmd 'exec bash -c %q' "$cmd"
hint='Check this pane with scripts/capture.sh <pane>, then use scripts/send.sh <pane> <prompt-file>.'

if [[ -z ${TMUX:-} && -n ${ITERM_SESSION_ID:-} ]]; then
  printf -v line 'cd %q && %s' "$dir" "$shcmd"
  pane=$("$(dirname "$0")/iterm.sh" split "${ITERM_SESSION_ID#*:}" "$name" "$line")
  printf 'pane=%s\n%s\n' "$pane" "$hint"
  exit 0
fi
if [[ -z ${TMUX:-} && ${TERM_PROGRAM:-} == Apple_Terminal ]]; then
  printf -v line 'cd %q && %s' "$dir" "$shcmd"
  pane=$("$(dirname "$0")/terminal.sh" split "$name" "$line")
  printf 'pane=%s\n%s\n' "$pane" "$hint"
  exit 0
fi
command -v tmux >/dev/null || { echo "requires tmux, iTerm2 or Terminal.app" >&2; exit 1; }
if [[ -n ${TMUX:-} ]]; then
  lead=${TMUX_PANE:?}
  win=$(tmux display -p -t "$lead" '#{window_id}')
  if [[ $(tmux list-panes -t "$win" | wc -l) -eq 1 ]]; then
    pane=$(tmux split-window -h -d -P -F '#{pane_id}' -t "$lead" -c "$dir" "$shcmd")
  else
    last=$(tmux list-panes -t "$win" -F '#{pane_id}' | tail -1)
    pane=$(tmux split-window -v -d -P -F '#{pane_id}' -t "$last" -c "$dir" "$shcmd")
  fi
  tmux set -w -t "$win" main-pane-width 50% \; select-layout -t "$win" main-vertical >/dev/null
else
  session="codex-$name"
  pane=$(tmux new-session -d -P -F '#{pane_id}' -s "$session" -c "$dir" "$shcmd")
  printf 'attach: tmux attach-session -t %q\n' "$session"
fi
tmux select-pane -t "$pane" -T "codex:$name"
tmux set-option -p -t "$pane" @coworker "$name"
printf 'pane=%s\n%s\n' "$pane" "$hint"
