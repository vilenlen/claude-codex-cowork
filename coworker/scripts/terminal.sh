#!/usr/bin/env bash
# macOS Terminal.app backend (AppleScript, no tmux). Terminal has no split panes, so each worker gets its own window
# laid out like tmux main-vertical. Ids are tty names such as ttys005; a worker is tagged by a file named after its tty
# under $TMPDIR/coworker/tags (a tab title cannot carry the tag: the shell prompt overwrites it).
# Usage: terminal.sh split   <task-name> <shell-line>   -> new tty id (next to the window running this script)
#        terminal.sh info    <id>                       -> "<worker-tag>|<job>"
#        terminal.sh send    <id> <prompt-file>
#        terminal.sh capture <id>                       -> screen text plus scrollback
#        terminal.sh keys    <id> <file>                -> types the file's bytes as-is, then Enter (Terminal always appends one)
#        terminal.sh tty     <id>                       -> tty device
#        terminal.sh close   <id>                       -> closes a tagged worker window only
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: $0 split|info|send|keys|capture|tty|close <id> ..." >&2; exit 2; }
act=$1 tags=${TMPDIR:-/tmp}/coworker/tags
kill_tty() { ps -t "$2" -o pid= 2>/dev/null | xargs kill -"$1" 2>/dev/null || true; }
if [[ $act == split ]]; then
  # Terminal exposes no session id, so find the lead's window by the tty of the nearest ancestor that has one.
  lead= p=$$
  while [[ $p -gt 1 ]]; do
    t=$(ps -o tty= -p "$p" | tr -d ' ')
    [[ -z $t || $t == '??' ]] || { lead=/dev/$t; break; }
    p=$(ps -o ppid= -p "$p" | tr -d ' ')
  done
  workers=$(cd "$tags" 2>/dev/null && ls -d ttys* 2>/dev/null | sed 's|^|/dev/|' || true)
  set -- split "$lead" "$2" "${3:?shell line required}" $workers
else
  tag=$(cat "$tags/$2" 2>/dev/null || true)
  [[ $act != close || -n $tag ]] || { echo "not a coworker session: $2" >&2; exit 2; }
  # Closing a window with a live process makes Terminal ask for confirmation; end the tty's processes first so it does not.
  # The window closes by itself once its shell dies, so a missing tab afterwards still means closed.
  [[ $act != close ]] || { kill_tty HUP "$2"; sleep 1; kill_tty KILL "$2"; sleep 1; rm -f "$tags/$2"; }
  set -- "$act" "/dev/$2" "${@:3}"
fi
# All arguments go through argv, never spliced into the script.
osa() { osascript - "$@" <<'EOF'
on findTab(tt)
	tell application "Terminal"
		repeat with w in windows
			repeat with t in tabs of w
				try
					if tty of t is tt then return {w, t}
				end try
			end repeat
		end repeat
	end tell
	return {}
end findTab

on run argv
	set act to item 1 of argv
	set sid to item 2 of argv
	set esc to character id 27
	set workers to {}
	if act is "split" and (count of argv) > 4 then set workers to items 5 thru -1 of argv
	if act is in {"send", "keys"} then set body to read (POSIX file (item 3 of argv)) as «class utf8»
	tell application "Terminal"
		if act is "split" then
			set hit to my findTab(sid)
			if hit is {} then
				set lw to front window
			else
				set lw to item 1 of hit
			end if
			-- First worker takes the right half of the lead window; later ones split the lowest worker.
			set lastW to missing value
			repeat with w in windows
				repeat with t in tabs of w
					if workers contains (tty of t) then
						if lastW is missing value then
							set lastW to w
						else if (item 4 of (bounds of w)) > (item 4 of (bounds of lastW)) then
							set lastW to w
						end if
					end if
				end repeat
			end repeat
			if lastW is missing value then
				set {x1, y1, x2, y2} to bounds of lw
				set mid to (x1 + x2) div 2
				set bounds of lw to {x1, y1, mid, y2}
				set nb to {mid, y1, x2, y2}
			else
				set {x1, y1, x2, y2} to bounds of lastW
				set mid to (y1 + y2) div 2
				set bounds of lastW to {x1, y1, x2, mid}
				set nb to {x1, mid, x2, y2}
			end if
			set n to do script (item 4 of argv)
			repeat 50 times
				try
					set ntty to tty of n
					exit repeat
				end try
				delay 0.1
			end repeat
			set bounds of item 1 of my findTab(ntty) to nb
			set index of lw to 1 -- keep keyboard focus on the lead
			return text 6 thru -1 of ntty
		end if
		set hit to my findTab(sid)
		if hit is {} then error "Terminal tab not found (closed?): " & sid
		set {w, t} to hit
		if act is "info" then
			set ps to processes of t
			if ps contains "codex" then
				set job to "codex"
			else if ps is {} then
				set job to ""
			else
				set job to last item of ps
			end if
			return job
		else if act is "send" then
			-- Bracketed paste keeps multiline text and shell metacharacters as one input message; Terminal appends the Enter.
			do script (esc & "[200~" & body & esc & "[201~") in t
			return "sent_to=" & sid
		else if act is "keys" then
			do script body in t
			return "keys_to=" & sid
		else if act is "capture" then
			return history of t
		else if act is "tty" then
			return tty of t
		else if act is "close" then
			close w saving no
			return "closed=" & sid
		end if
		error "unknown action: " & act
	end tell
end run
EOF
}
if [[ $act == capture ]]; then
  # The history is padded with blank screen rows; drop them so "last N lines" means the last N with content.
  osa "$@" | awk '{a[NR]=$0} END{n=NR; while(n>0 && a[n] ~ /^[[:space:]]*$/) n--; for(i=1;i<=n;i++) print a[i]}'
else
  out=$(osa "$@") || { [[ $act == close ]] && out="closed=$2"; }
  case $act in
    split) mkdir -p "$tags"; printf %s "$3" > "$tags/$out" ;;
  esac
  [[ $act != info ]] || out="$tag|$out"
  printf '%s\n' "$out"
fi
