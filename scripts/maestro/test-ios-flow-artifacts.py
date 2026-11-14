import os
import pathlib
import signal
import subprocess
import tempfile
import unittest

RUNNER = pathlib.Path(__file__).with_name('run-ios-live-update.sh').read_text()


def runner_function(name):
    # Execute the checked-in function with fake device commands, without starting a simulator.
    start = RUNNER.index(f'{name}() {{\n')
    end = RUNNER.index('\n}\n', start) + 3
    return RUNNER[start:end]


FLOW_FIXTURE = r'''
MAESTRO_TEST_RETRIES=2
MAESTRO_TIMEOUT_SECONDS=10
MAESTRO_WORKSPACE_CONFIG=fake-config
SIMULATOR_ID=fake-device
APP_ID=fake-app
run_with_timeout() {
  local report='' debug=''
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) report="$2"; shift ;;
      --debug-output) debug="$2"; shift ;;
    esac
    shift
  done
  mkdir -p "$debug"
  printf 'attempt %s\n' "$attempt" > "$debug/maestro.log"
  echo "output attempt $attempt"
  if [[ "$attempt" == 2 && "$TEST_END" == cancel ]]; then
    kill -TERM "$$"
    return 143
  fi
  printf '<testsuite name="attempt-%s"/>\n' "$attempt" > "$report"
  if [[ "$attempt" == 1 ]]; then
    printf 'failed hierarchy\n' > "$debug/commands.json"
    printf 'failed screenshot\n' > "$debug/failure.png"
    return 7
  fi
  [[ "$TEST_END" == pass ]] || return 9
}
flow_has_retryable_failure() { return 0; }
run_cleanup_command() { :; }
reset_ios_maestro_driver() { :; }
boot_simulator() { :; }
reinstall_example_app() { :; }
sleep() { :; }
'''


class IOSFlowArtifactTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = pathlib.Path(directory.name)
        self.results = self.root / 'results'
        self.results.mkdir()
        self.artifacts = self.root / 'assets'
        self.artifacts.mkdir()

    def run_shell(self, script, ending='pass'):
        return subprocess.run(
            ['bash', '-c', 'set -euo pipefail\n' + script],
            env={**os.environ, 'RESULTS_DIR': str(self.results),
                 'ARTIFACT_DIR': str(self.artifacts), 'TEST_END': ending},
            capture_output=True, text=True, timeout=10,
        )

    def run_flow(self, ending='pass', count=1):
        return self.run_shell(
            FLOW_FIXTURE + runner_function('run_flow')
            + '\nrun_flow legacy-true-first-release fake-flow\n' * count,
            ending,
        )

    def assert_failed_evidence(self, count=1):
        screenshots = list(self.results.rglob('failure.png'))
        self.assertEqual(len(screenshots), count)
        for screenshot in screenshots:
            debug = screenshot.parent
            self.assertEqual(screenshot.read_text(), 'failed screenshot\n')
            self.assertEqual((debug / 'commands.json').read_text(), 'failed hierarchy\n')
            self.assertIn('attempt-1', (debug.parent / 'junit.xml').read_text())
            self.assertEqual((debug.parent / 'console.log').read_text(), 'output attempt 1\n')

    def test_successful_retry_keeps_first_failure(self):
        result = self.run_flow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_failed_evidence()
        self.assertEqual(len(list(self.results.rglob('junit.xml'))), 2)

    def test_cancelled_retry_keeps_first_failure_and_partial_log(self):
        result = self.run_flow('cancel')
        self.assertEqual(result.returncode, -signal.SIGTERM, result.stderr)
        self.assert_failed_evidence()
        logs = sorted(path.read_text() for path in self.results.rglob('maestro.log'))
        self.assertEqual(logs, ['attempt 1\n', 'attempt 2\n'])

    def test_exhausted_retries_keep_failure_status_and_reports(self):
        result = self.run_flow('fail')
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assert_failed_evidence()
        self.assertEqual(len(list(self.results.rglob('junit.xml'))), 2)

    def test_outer_retry_of_same_label_keeps_all_attempts(self):
        result = self.run_flow(count=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_failed_evidence(count=2)
        self.assertEqual(len(list(self.results.rglob('junit.xml'))), 4)

    def test_server_log_is_available_before_cleanup(self):
        result = self.run_shell(r'''
ensure_server_port_available() { :; }
start_fake_capgo_server() { echo 'server event' > "$1"; SERVER_PID="$$"; }
wait_for_server() { return 0; }
sleep() { :; }
''' + runner_function('start_fake_server') + '\nstart_fake_server\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.results / 'fake-capgo-server-ios.log').read_text(), 'server event\n')


if __name__ == '__main__':
    unittest.main()
