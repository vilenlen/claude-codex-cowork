#!/usr/bin/env zsh
# Load the same environment and aliases as the user's terminal before parsing the worker command.
export COWORK_WORKER=1
if [[ -f ${ZDOTDIR:-$HOME}/.zshrc ]]; then
  source "${ZDOTDIR:-$HOME}/.zshrc" || exit $?
fi
export COWORK_WORKER=1
case $1 in
  cla|claude|claude-glink) unset CLAUDECODE ;;
  codex) ;;
  *) print -u2 'expected cla, codex, claude or claude-glink'; exit 2 ;;
esac
cowork_worker=$1
shift
# shortcut: inspect literal flags in direct wrappers only; dynamic/conditional wrappers need explicit handling.
# Prefer the alias, matching invocation below; otherwise inspect the function without executing it.
if [[ $cowork_worker == codex && ${aliases[codex]:-${functions[codex]}} == *(--yolo|--dangerously-bypass-approvals-and-sandbox)* ]]; then
  cowork_args=()
  while (( $# )); do
    case $1 in
      -a|-s) shift 2 ;;
      *) cowork_args+=("$1"); shift ;;
    esac
  done
  set -- "${cowork_args[@]}"
fi
# Resolve the trusted user alias explicitly: zsh suppresses alias expansion after exec.
# Arguments remain positional parameters, never shell source (even quotes or $()).
eval "exec ${aliases[$cowork_worker]:-$cowork_worker} \"\$@\""
