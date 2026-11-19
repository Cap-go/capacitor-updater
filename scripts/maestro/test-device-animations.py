import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

HELPER = pathlib.Path(__file__).with_name('disable-device-animations.sh')
KEYS = ['window_animation_scale', 'transition_animation_scale', 'animator_duration_scale']
FAKE_ADB = r'''
import json, os, pathlib, sys

path = pathlib.Path(os.environ['FAKE_ADB_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
serial = os.environ.get('FAKE_ADB_DEFAULT_DEVICE', 'original-device')
if args[:1] == ['-s']:
    serial, args = args[1], args[2:]
state['calls'].append([serial, *args])
path.write_text(json.dumps(state))
if args == ['get-serialno']:
    print(serial, end='\r\n')
    sys.exit(0)

assert args[:2] == ['shell', 'settings'], args
operation, namespace, key = args[2:5]
assert namespace == 'global', namespace
settings = state['devices'][serial]
if operation == 'get':
    if key == os.environ.get('FAKE_ADB_FAIL_READ'):
        sys.exit(2)
    value = settings.get(key, 'null')
    if key == os.environ.get('FAKE_ADB_INVALID_READ'):
        value = 'settings service unavailable'
    print(value, end='\r\n')
elif operation == 'put':
    if key == os.environ.get('FAKE_ADB_FAIL_DISABLE') and args[5] == '0':
        sys.exit(2)
    if key == os.environ.get('FAKE_ADB_FAIL_RESTORE') and args[5] != '0':
        sys.exit(2)
    settings[key] = args[5]
elif operation == 'delete':
    settings.pop(key, None)
else:
    raise AssertionError(operation)
path.write_text(json.dumps(state))
'''


class DeviceAnimationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = pathlib.Path(directory.name)
        self.state_path = self.directory / 'state.json'
        self.disabled_path = self.directory / 'disabled.json'
        self.original = {
            'original-device': {'window_animation_scale': '0.5', 'animator_duration_scale': '2.0'},
            'other-device': dict.fromkeys(KEYS, '1.5'),
        }
        self.state_path.write_text(json.dumps({'devices': self.original, 'calls': []}))
        adb = self.directory / 'adb'
        adb.write_text(f'#!{sys.executable}\n' + FAKE_ADB)
        adb.chmod(0o755)
        self.env = {
            **os.environ,
            'PATH': str(self.directory) + os.pathsep + os.environ['PATH'],
            'ANDROID_SERIAL': '',
            'CAPGO_MAESTRO_ANDROID_DEVICE_ID': '',
            'FAKE_ADB_STATE': str(self.state_path),
            'FAKE_ADB_DISABLED_STATE': str(self.disabled_path),
        }

    def run_shell(self, script):
        return subprocess.run(
            ['bash', '-c', 'set -euo pipefail\n' + script, 'animation-test', str(HELPER)],
            env=self.env, capture_output=True, text=True, timeout=30,
        )

    def run_with_cleanup(self, body):
        return self.run_shell('''
source "$1"
trap restore_android_animation_settings EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
disable_android_emulator_animations
''' + body)

    def state(self):
        return json.loads(self.state_path.read_text())

    def test_restores_original_values_once_across_retries_and_device_change(self):
        result = self.run_with_cleanup('''
export ANDROID_SERIAL=other-device
export FAKE_ADB_DEFAULT_DEVICE=other-device
disable_android_emulator_animations
cp "$FAKE_ADB_STATE" "$FAKE_ADB_DISABLED_STATE"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        disabled = json.loads(self.disabled_path.read_text())['devices']
        self.assertEqual(disabled['original-device'], dict.fromkeys(KEYS, '0'))
        self.assertEqual(disabled['other-device'], self.original['other-device'])
        self.assertEqual(self.state()['devices'], self.original)
        reads = [call for call in self.state()['calls'] if call[1:4] == ['shell', 'settings', 'get']]
        self.assertEqual(len(reads), 3)

    def test_restores_after_failure_and_signals_without_changing_exit_status(self):
        for body, status in [('exit 7', 7), ('kill -TERM "$$"', 143), ('kill -INT "$$"', 130)]:
            with self.subTest(body=body):
                result = self.run_with_cleanup(body)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(self.state()['devices'], self.original)

    def test_unreadable_or_invalid_settings_prevent_all_changes(self):
        for failure in ['FAKE_ADB_FAIL_READ', 'FAKE_ADB_INVALID_READ']:
            with self.subTest(failure=failure):
                self.env[failure] = 'transition_animation_scale'
                result = self.run_with_cleanup('exit 0')
                self.env.pop(failure)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.state()['devices'], self.original)
                writes = [call for call in self.state()['calls'] if call[3:4] in [['put'], ['delete']]]
                self.assertEqual(writes, [])

    def test_partial_disable_failure_still_restores_all_values(self):
        self.env['FAKE_ADB_FAIL_DISABLE'] = 'transition_animation_scale'
        result = self.run_with_cleanup('exit 7')
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(self.state()['devices'], self.original)

    def test_restore_failure_does_not_skip_other_settings_or_mask_test_failure(self):
        self.env['FAKE_ADB_FAIL_RESTORE'] = 'window_animation_scale'
        result = self.run_with_cleanup('exit 7')
        self.assertEqual(result.returncode, 7, result.stderr)
        expected = {**self.original['original-device'], 'window_animation_scale': '0'}
        self.assertEqual(self.state()['devices']['original-device'], expected)
        self.assertIn('Could not access device animation settings', result.stderr)

    def test_explicit_device_selection_and_original_zero(self):
        self.original['other-device']['window_animation_scale'] = '0'
        self.state_path.write_text(json.dumps({'devices': self.original, 'calls': []}))
        self.env['CAPGO_MAESTRO_ANDROID_DEVICE_ID'] = 'other-device'
        result = self.run_with_cleanup('exit 0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state()['devices'], self.original)
        self.assertTrue(all(call[0] == 'other-device' for call in self.state()['calls']))


if __name__ == '__main__':
    unittest.main()
