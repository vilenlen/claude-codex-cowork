#!/usr/bin/env python3
"""Offline regression checks for dispatch, Claude events and wait result routing."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('events', HERE / 'claude-events.py')
events = importlib.util.module_from_spec(spec)
spec.loader.exec_module(events)


def event(ts, kind, **fields):
    return json.dumps(dict(timestamp=ts, hook_event_name=kind, **fields))


class Workers(unittest.TestCase):
    def test_events(self):
        old = [event('T1', 'Stop', last_assistant_message='old')]
        self.assertIsNone(events.scan_events(old, 'T2'))
        ask = event('T3', 'PreToolUse', tool_name='AskUserQuestion', tool_input={'questions': ['which?']})
        state = events.scan_events(old + [ask, '{partial'], 'T2')
        self.assertEqual(json.loads(state[1])['kind'], 'claude_menu')
        self.assertIsNone(events.scan_events([ask], 'T2', {'T3'}))
        self.assertIsNone(events.scan_events([ask, event('T4', 'PostToolUse')], 'T2'))
        self.assertEqual(events.scan_events([event('T4', 'Stop', last_assistant_message='done'), event('T5', 'SessionEnd')], 'T2'), ('completed', 'done'))
        self.assertEqual(events.scan_events([event('T4', 'StopFailure', error='rate_limit')], 'T2'), ('aborted', 'rate_limit'))
        self.assertIsNone(events.scan_events([event('T4', 'Stop'), event('T5', 'UserPromptSubmit')], 'T2'))
        self.assertEqual(events.scan_events([event('T4', 'PermissionRequest')], 'T2')[0], 'needs_input')

    def test_dispatch_and_wait(self):
        with tempfile.TemporaryDirectory(prefix='cowork test ') as temp:
            root = Path(temp)
            env = dict(os.environ, PATH=temp + ':' + os.environ['PATH'], TMPDIR=temp,
                       TMUX='', ITERM_SESSION_ID='', TERM_PROGRAM='', CLAUDECODE='lead', TEST_ROOT=temp, ZDOTDIR=temp)
            (root / '.zshrc').write_text("alias cla='claude-glink --permission-mode bypassPermissions --add-dir \"alias dir\"'\n")
            cli = '''#!/usr/bin/env python3
import json, os, pathlib, sys
if any(flag in sys.argv for flag in ('--yolo', '--dangerously-bypass-approvals-and-sandbox')) and any(flag in sys.argv for flag in ('-a', '-s')):
 sys.exit('bypass conflicts with -a/-s')
pathlib.Path(os.environ['TEST_ROOT'], 'args.json').write_text(json.dumps([sys.argv[1:], os.getenv('CLAUDECODE'), os.getenv('COWORK_WORKER')]))
'''
            tmux = '''#!/usr/bin/env python3
import subprocess, sys
if sys.argv[1] == 'new-session':
 subprocess.run(['bash', '-c', sys.argv[-1]], check=True)
 print('%42')
'''
            for name, body in [('claude', cli), ('claude-glink', cli), ('cla', '#!/bin/sh\nexit 99\n'), ('codex', cli), ('tmux', tmux)]:
                (root / name).write_text(body)
                (root / name).chmod(0o755)
            uuid = '12345678-1234-1234-1234-123456789abc'
            def dispatch(*args, model='model with spaces'):
                model_args = [] if model is None else ['-m', model]
                return subprocess.run(['bash', str(HERE / 'dispatch.sh'), 'test', temp, *model_args, *args], cwd=temp, env=env, capture_output=True, text=True)
            for args in [('--worker', 'bad'), ('--worker',), ('--worker', 'codex'), ('-m',), ('-m', ''), ('-m', '--search'), ('--search',), ('--effort', 'minimal'), ('--worker', 'claude', '--search'), ('--worker', 'claude', '--effort', 'minimal')]:
                result = dispatch(*args, model=None)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse((root / 'args.json').exists(), 'invalid arguments launched a worker')
            alias_args = ['--permission-mode', 'bypassPermissions', '--add-dir', 'alias dir']
            for options, model in [((), 'opus'), (('--worker', 'cla'), 'opus'), (('-m', 'sonnet'), 'sonnet'), (('--worker', 'cla', '-m', 'custom model'), 'custom model')]:
                result = dispatch(*options, model=None)
                self.assertEqual(result.returncode, 0, result.stderr)
                args, nested, worker = json.loads((root / 'args.json').read_text())
                self.assertEqual(args[:6], alias_args + ['--model', model])
                self.assertIsNone(nested)
                self.assertEqual(worker, '1')
                self.assertEqual((root / 'cowork' / '%42.worker').read_text().splitlines()[0], 'claude')
            for entry in ('claude', 'claude-glink'):
                result = dispatch('--worker', entry, model=None)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((root / 'args.json').read_text())[0][:2], ['--model', 'opus'])
            result = dispatch('--resume', uuid, '--effort', 'high')
            self.assertEqual(result.returncode, 0, result.stderr)
            args, nested, worker = json.loads((root / 'args.json').read_text())
            self.assertIsNone(nested)
            self.assertEqual(worker, '1')
            self.assertEqual(args[:4], alias_args)
            args = args[4:]
            self.assertEqual(args[:2], ['--model', 'model with spaces'])
            self.assertEqual(args[-4:], ['--effort', 'high', '--resume', uuid])
            settings = json.loads(Path(args[3]).read_text())
            command = settings['hooks']['Stop'][0]['hooks'][0]['command']
            base = root / 'cowork'
            (base / '%42.sent').write_text('2000-01-01T00:00:00.000Z\n【CC指派】test\n')
            subprocess.run(['bash', '-c', command], input=json.dumps({'hook_event_name': 'Stop', 'last_assistant_message': '完成\n`literal` $(text)'}), text=True, check=True)
            result = subprocess.run(['python3', '-I', str(HERE / 'wait.py'), '%42', '2'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('status=completed', result.stdout)
            self.assertEqual((base / '%42.last.md').read_text(), '完成\n`literal` $(text)')
            result = dispatch('--worker', 'codex', '--search', '--resume', uuid)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads((root / 'args.json').read_text())[0]
            self.assertEqual(args[:5], ['resume', '-a', 'never', '-s', 'danger-full-access'])
            self.assertEqual(args[5:7], ['-m', 'model with spaces'])
            self.assertIn('--search', args)
            self.assertEqual((base / '%42.worker').read_text().splitlines()[0], 'codex')
            self.assertFalse((base / '%42.sent').exists())
            self.assertFalse((base / '%42.last.md').exists())
            # Native commands may be absent or broken: aliases defined by .zshrc must win.
            with (root / '.zshrc').open('a') as rc:
                rc.write("alias claude='claude-glink --dangerously-skip-permissions'\n")
            result = dispatch('--worker', 'claude')
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads((root / 'args.json').read_text())[0]
            self.assertEqual(args[:3], ['--dangerously-skip-permissions', '--model', 'model with spaces'])
            result = dispatch('--worker', 'claude-glink')
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads((root / 'args.json').read_text())[0]
            self.assertEqual(args[:2], ['--model', 'model with spaces'])
            self.assertEqual((base / '%42.worker').read_text().splitlines()[0], 'claude')

            # Shell metacharacters must survive as literal argument text.
            literal = 'model "quotes" `backticks` $(touch SHOULD_NOT_EXIST); *'
            result = subprocess.run(['zsh', str(HERE / 'worker-start.zsh'), 'cla', '--model', literal], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((root / 'args.json').read_text())[0][-1], literal)

            # Exercise the real dispatch/start boundary using only local CLI/tmux stubs.
            wrapped = root / 'codex current'
            wrapped.write_text(cli)
            wrapped.chmod(0o755)
            literal = 'model with spaces\n"quotes" \'single\' $(touch SHOULD_NOT_EXIST) `backticks`; *'
            defaults = ['-a', 'never', '-s', 'danger-full-access']
            for kind in ('command', 'alias', 'function'):
                for flag in ('', '--yolo', '--dangerously-bypass-approvals-and-sandbox'):
                    if kind == 'command' and flag:
                        continue
                    with self.subTest(kind=kind, flag=flag):
                        if kind == 'alias':
                            rc = f'alias codex=\'"$TEST_ROOT/codex current" {flag}\'\n'
                        elif kind == 'function':
                            rc = f'codex () {{ "$TEST_ROOT/codex current" {flag} "$@"; }}\n'
                        else:
                            rc = ''
                        (root / '.zshrc').write_text(rc)
                        (root / 'args.json').unlink(missing_ok=True)
                        result = dispatch('--worker', 'codex', '--search', '--effort', 'high', '--resume', uuid, model=literal)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        args = json.loads((root / 'args.json').read_text())[0]
                        expected = ([flag] if flag else []) + ['resume'] + ([] if flag else defaults)
                        self.assertEqual(args, expected + ['-m', literal, '--search', '-c', 'model_reasoning_effort=high', uuid])
                        self.assertFalse((root / 'SHOULD_NOT_EXIST').exists())


    def test_agy(self):
        with tempfile.TemporaryDirectory(prefix='cowork agy ') as temp:
            root = Path(temp)
            env = dict(os.environ, PATH=temp + ':' + os.environ['PATH'], TMPDIR=temp,
                       TMUX='', ITERM_SESSION_ID='', TERM_PROGRAM='', TEST_ROOT=temp, ZDOTDIR=temp)
            (root / 'agy').write_text('#!/usr/bin/env python3\nimport json, os, pathlib, sys\n'
                                      "pathlib.Path(os.environ['TEST_ROOT'], 'args.json').write_text(json.dumps(sys.argv[1:]))\n")
            (root / 'tmux').write_text("#!/usr/bin/env python3\nimport subprocess, sys\nif sys.argv[1] == 'new-session':\n subprocess.run(['bash', '-c', sys.argv[-1]], check=True)\n print('%42')\n")
            for name in ('agy', 'tmux'):
                (root / name).chmod(0o755)
            uuid = '12345678-1234-1234-1234-123456789abc'
            def dispatch(*args):
                return subprocess.run(['bash', str(HERE / 'dispatch.sh'), 'test', temp, '--worker', 'agy', *args], cwd=temp, env=env, capture_output=True, text=True)
            for args in [('--search',), ('--effort', 'minimal')]:
                self.assertEqual(dispatch(*args).returncode, 2)
            skip = '--dangerously-skip-permissions'
            # The flag is always present exactly once: added without a wrapper, kept (not duplicated) with one.
            for rc in ('', f"alias agy='\"$TEST_ROOT/agy\" {skip}'\n", f'agy () {{ "$TEST_ROOT/agy" {skip} "$@"; }}\n'):
                with self.subTest(rc=rc):
                    (root / '.zshrc').write_text(rc)
                    result = dispatch('-m', 'model x', '--effort', 'high', '--resume', uuid)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    args = json.loads((root / 'args.json').read_text())
                    self.assertEqual(args.count(skip), 1, args)
                    self.assertEqual(args[0], skip)
                    self.assertEqual(args[1], '--add-dir')
                    self.assertEqual(args[3:], ['--model', 'model x', '--effort', 'high', '--conversation', uuid])
            result = dispatch()
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads((root / 'args.json').read_text())
            self.assertEqual(args[3:], [], 'agy without -m keeps its saved model')
            base = root / 'cowork'
            self.assertEqual((base / '%42.worker').read_text().splitlines()[0], 'agy')
            hooks = json.loads((Path(args[2]) / '.agents' / 'hooks.json').read_text())['cowork']
            command = hooks['Stop'][0]['command']
            self.assertEqual(hooks['PostToolUse'][0]['hooks'][0]['command'], command)
            transcript = root / 'transcript.jsonl'
            transcript.write_text(''.join(json.dumps(s) + '\n' for s in [
                {'type': 'USER_INPUT', 'content': 'task'},
                {'type': 'PLANNER_RESPONSE', 'content': 'old'},
                {'type': 'PLANNER_RESPONSE', 'content': '完成\n`literal` $(text)'}]))
            def hook(**payload):
                result = subprocess.run(['bash', '-c', command], input=json.dumps(dict(conversationId=uuid, transcriptPath=str(transcript), **payload)), text=True, capture_output=True, check=True)
                self.assertEqual(json.loads(result.stdout), {})
            def wait():
                result = subprocess.run(['python3', '-I', str(HERE / 'wait.py'), '%42', '2'], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout
            (base / '%42.sent').write_text('2000-01-01T00:00:00.000Z\n【CC指派】test\n')
            hook(hookEventName='SessionStart')
            hook(hookEventName='PreInvocation', invocationNum=0)
            hook(hookEventName='PostToolUse', toolCall={'name': 'run_command'})
            hook(hookEventName='Stop', terminationReason='NO_TOOL_CALL', error='')
            self.assertIn('status=completed', wait())
            self.assertEqual((base / '%42.last.md').read_text(), '完成\n`literal` $(text)')
            hook(hookEventName='PreInvocation', invocationNum=0)
            hook(hookEventName='Stop', terminationReason='USER_CANCELED', error='')
            self.assertIn('status=aborted', wait())
            self.assertEqual((base / '%42.last.md').read_text(), 'USER_CANCELED')

    def test_worker_does_not_become_lead(self):
        result = subprocess.run(['bash', str(HERE / 'session-start.sh')], env=dict(os.environ, COWORK_WORKER='1', TMUX='yes'), capture_output=True)
        self.assertEqual(result.stdout, b'')
        self.assertEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
