#!/usr/bin/env zsh
# Load the same environment and aliases as the user's terminal before parsing the worker command.
export COWORK_WORKER=1
if [[ -f ${ZDOTDIR:-$HOME}/.zshrc ]]; then
  source "${ZDOTDIR:-$HOME}/.zshrc" || exit $?
fi
export COWORK_WORKER=1
case $1 in
  claude|claude-glink) unset CLAUDECODE ;;
  codex) ;;
  *) print -u2 'expected codex, claude or claude-glink'; exit 2 ;;
esac
cowork_worker=$1
shift
# Resolve the trusted user alias explicitly: zsh suppresses alias expansion after exec.
# Arguments remain positional parameters, never shell source (even quotes or $()).
eval "exec ${aliases[$cowork_worker]:-$cowork_worker} \"\$@\""
