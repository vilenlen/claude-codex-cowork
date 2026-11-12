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
            (root / '.zshrc').write_text('')
            cli = '''#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ['TEST_ROOT'], 'args.json').write_text(json.dumps([sys.argv[1:], os.getenv('CLAUDECODE'), os.getenv('COWORK_WORKER')]))
'''
            tmux = '''#!/usr/bin/env python3
import subprocess, sys
if sys.argv[1] == 'new-session':
 subprocess.run(['bash', '-c', sys.argv[-1]], check=True)
 print('%42')
'''
            for name, body in [('claude', cli), ('codex', cli), ('tmux', tmux)]:
                (root / name).write_text(body)
                (root / name).chmod(0o755)
            uuid = '12345678-1234-1234-1234-123456789abc'
            def dispatch(*args):
                return subprocess.run(['bash', str(HERE / 'dispatch.sh'), 'test', temp, '-m', 'model with spaces', *args], env=env, capture_output=True, text=True)
            for args in [('--worker', 'bad'), ('--worker',), ('--worker', 'claude', '--search'), ('--worker', 'claude', '--effort', 'minimal')]:
                self.assertEqual(dispatch(*args).returncode, 2)
            result = dispatch('--worker', 'claude', '--resume', uuid, '--effort', 'high')
            self.assertEqual(result.returncode, 0, result.stderr)
            args, nested, worker = json.loads((root / 'args.json').read_text())
            self.assertIsNone(nested)
            self.assertEqual(worker, '1')
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
            result = dispatch('--search', '--resume', uuid)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads((root / 'args.json').read_text())[0]
            self.assertEqual(args[:5], ['resume', '-a', 'never', '-s', 'danger-full-access'])
            self.assertIn('--search', args)
            self.assertFalse((base / '%42.sent').exists())
            self.assertFalse((base / '%42.last.md').exists())
            # Native commands may be absent or broken: aliases defined by .zshrc must win.
            (root / 'claude-glink').write_text(cli)
            (root / 'claude-glink').chmod(0o755)
            (root / '.zshrc').write_text("alias claude='claude-glink --dangerously-skip-permissions'\n")
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
            result = subprocess.run(['zsh', str(HERE / 'worker-start.zsh'), 'claude', '--model', literal], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((root / 'args.json').read_text())[0][-1], literal)


    def test_worker_does_not_become_lead(self):
        result = subprocess.run(['bash', str(HERE / 'session-start.sh')], env=dict(os.environ, COWORK_WORKER='1', TMUX='yes'), capture_output=True)
        self.assertEqual(result.stdout, b'')
        self.assertEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
