#!/usr/bin/env python3
"""Session-local Claude hooks; no user configuration is modified."""
import json
import os
from pathlib import Path
import shlex
import sys
from datetime import datetime, timezone


def settings(directory):
    command = shlex.join([sys.executable, '-I', str(Path(__file__).resolve()), 'record', directory])
    hooks = {}
    for event in ('SessionStart', 'UserPromptSubmit', 'Stop', 'StopFailure', 'SessionEnd',
                  'Notification', 'PermissionRequest', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure'):
        entry = {'hooks': [{'type': 'command', 'command': command}]}
        if event in ('PreToolUse', 'PostToolUse', 'PostToolUseFailure'):
            entry['matcher'] = '.*'
        hooks[event] = [entry]
    return {'hooks': hooks}


def scan_events(lines, sent, seen=()):
    state = None
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get('timestamp', '') < sent:
            continue
        kind = event.get('hook_event_name')
        if kind == 'Stop':
            state = ('completed', event.get('last_assistant_message', ''))
        elif kind == 'StopFailure':
            state = ('aborted', event.get('error_details') or event.get('error', 'Claude API error'))
        elif kind == 'SessionEnd':
            # Preserve a completed result even if the window has already closed.
            state = state or ('exited', event.get('reason', ''))
        elif kind in ('UserPromptSubmit', 'PostToolUse', 'PostToolUseFailure'):
            state = None
        elif kind == 'PreToolUse':
            state = None
            if event.get('tool_name') == 'AskUserQuestion':
                state = ('needs_input', json.dumps({'kind': 'claude_menu',
                    'call_id': event['timestamp'], **event.get('tool_input', {})}, ensure_ascii=False))
        elif kind == 'PermissionRequest' or (kind == 'Notification' and event.get('notification_type') in ('permission_prompt', 'elicitation_dialog')):
            state = ('needs_input', json.dumps({'kind': 'claude_permission',
                'call_id': event['timestamp'], 'message': event.get('message', ''),
                'tool_name': event.get('tool_name'), 'tool_input': event.get('tool_input')}, ensure_ascii=False))
    if state and state[0] == 'needs_input' and json.loads(state[1])['call_id'] in seen:
        return None
    return state


def main():
    action, directory = sys.argv[1:]
    if action == 'settings':
        print(json.dumps(settings(directory)))
        return
    event = json.load(sys.stdin)
    if event.get('agent_id'):
        return  # Subagent tool activity must not clear the parent question/turn state.
    event['timestamp'] = datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    # Exclude tool results and other large fields; keep only routing and attention data.
    keep = ('timestamp', 'hook_event_name', 'session_id', 'transcript_path', 'cwd',
            'last_assistant_message', 'error', 'error_details', 'reason', 'notification_type', 'message', 'tool_name')
    record = {k: event[k] for k in keep if k in event}
    if event.get('tool_name') == 'AskUserQuestion' or event.get('hook_event_name') == 'PermissionRequest':
        record['tool_input'] = event.get('tool_input', {})
    data = (json.dumps(record, ensure_ascii=False) + '\n').encode()
    fd = os.open(str(Path(directory) / 'events.jsonl'), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)


if __name__ == '__main__':
    main()
