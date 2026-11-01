#!/usr/bin/env bash
# iTerm2 backend (AppleScript, no tmux). Session IDs are iTerm2 UUIDs (the part after ':' in $ITERM_SESSION_ID).
# Usage: iterm.sh split   <lead-id> <task-name> <shell-line>   -> new session id
#        iterm.sh info    <id>                                  -> "<worker-tag>|<jobName>"
#        iterm.sh send    <id> <prompt-file>
#        iterm.sh capture <id>                                  -> screen text plus scrollback
#        iterm.sh keys    <id> <file>                           -> types the file's bytes as-is (no paste markers, no Enter)
#        iterm.sh tty     <id>                                  -> tty device
#        iterm.sh close   <id>                                  -> closes a tagged worker session only
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: $0 split|info|send|keys|capture|tty|close <session-id> ..." >&2; exit 2; }
# All arguments go through argv, never spliced into the script.
exec osascript - "$@" <<'EOF'
on run argv
	set act to item 1 of argv
	set sid to item 2 of argv
	set esc to character id 27
	if act is in {"send", "keys"} then set body to read (POSIX file (item 3 of argv)) as «class utf8»
	tell application "iTerm2"
		repeat with w in windows
			repeat with t in tabs of w
				repeat with s in sessions of t
					if id of s is sid then
						if act is "split" then
							-- Layout like tmux main-vertical: first worker to the right of lead, later ones stacked under the last worker.
							set lastWorker to missing value
							repeat with x in sessions of t
								tell x to set tag to variable named "user.coworker"
								if tag is not missing value then set lastWorker to x
							end repeat
							if lastWorker is missing value then
								tell s to set n to (split vertically with default profile)
							else
								tell lastWorker to set n to (split horizontally with default profile)
							end if
							tell n
								set variable named "user.coworker" to (item 3 of argv)
								set name to "codex:" & (item 3 of argv)
								write text (item 4 of argv)
							end tell
							return id of n
						else if act is "info" then
							tell s to set {tag, job} to {variable named "user.coworker", variable named "jobName"}
							if tag is missing value then set tag to ""
							if job is missing value then set job to ""
							return tag & "|" & job
						else if act is "send" then
							-- Bracketed paste keeps multiline text and shell metacharacters as one input message.
							tell s
								write text (esc & "[200~" & body & esc & "[201~") newline no
								delay 0.3
								write text (character id 13) newline no
							end tell
							return "sent_to=" & sid
						else if act is "keys" then
							tell s to write text body newline no
							return "keys_to=" & sid
						else if act is "capture" then
							return contents of s
						else if act is "tty" then
							return tty of s
						else if act is "close" then
							tell s to set tag to variable named "user.coworker"
							if tag is missing value then error "not a coworker session: " & sid
							tell s to close
							return "closed=" & sid
						end if
						error "unknown action: " & act
					end if
				end repeat
			end repeat
		end repeat
	end tell
	error "iTerm2 session not found (closed?): " & sid
end run
EOF
