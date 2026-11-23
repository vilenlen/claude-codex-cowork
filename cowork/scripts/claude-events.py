#!/usr/bin/env python3
"""Session-local Claude and agy (Antigravity CLI) hooks; no user configuration is modified."""
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


def agy_hooks(directory):
    """Antigravity CLI hooks.json, loaded from <directory>/.agents when the worker starts with --add-dir <directory>."""
    hook = {'type': 'command', 'command': shlex.join([sys.executable, '-I', str(Path(__file__).resolve()), 'record', directory])}
    return {'cowork': {'SessionStart': [hook], 'PreInvocation': [hook], 'Stop': [hook],
                       'PostToolUse': [{'matcher': '*', 'hooks': [hook]}]}}


def agy_record(event):
    """Map an agy (camelCase) hook payload onto the Claude event names scan_events understands."""
    kind = event.get('hookEventName')
    # PreInvocation fires before every model call of a turn; like UserPromptSubmit it means the turn is running.
    record = {'hook_event_name': {'PreInvocation': 'UserPromptSubmit'}.get(kind, kind),
              'session_id': event.get('conversationId'), 'transcript_path': event.get('transcriptPath'), 'cwd': event.get('cwd')}
    if kind == 'PostToolUse':
        record['tool_name'] = (event.get('toolCall') or {}).get('name')
    elif kind == 'Stop':
        reason = event.get('terminationReason', '')
        if event.get('error') or reason in ('ERROR', 'USER_CANCELED'):
            record.update(hook_event_name='StopFailure', error=event.get('error') or reason)
        else:
            # The Stop payload carries no reply text; the last planner response of the transcript is the final answer.
            reply = ''
            try:
                with open(event.get('transcriptPath') or '', encoding='utf-8') as f:
                    for line in f:
                        step = json.loads(line)
                        if step.get('type') == 'PLANNER_RESPONSE':
                            reply = step.get('content', '')
            except (OSError, ValueError):
                pass
            record['last_assistant_message'] = reply
    return record


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
    if action in ('settings', 'agy-hooks'):
        print(json.dumps((settings if action == 'settings' else agy_hooks)(directory)))
        return
    event = json.load(sys.stdin)
    if event.get('agent_id'):
        return  # Subagent tool activity must not clear the parent question/turn state.
    if 'hookEventName' in event:
        print('{}')  # agy requires a JSON object on stdout; an empty one changes nothing.
        event = agy_record(event)
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
