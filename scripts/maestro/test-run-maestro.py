import contextlib
import os
import pathlib
import subprocess
import shutil
import signal
import sys
import tempfile
import time
import unittest

RUNNER = pathlib.Path(__file__).with_name('run-maestro.py')


def wait_until(predicate):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError('Timed out waiting for fake Maestro')


def process_running(pid):
    status = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True, check=False)
    return status.returncode == 0 and not status.stdout.lstrip().startswith('Z')


class MaestroTeardownTests(unittest.TestCase):
    def run_fixture(self, content, summary, timeout=1, stale=False, exit_code=None):
        with tempfile.TemporaryDirectory() as directory:
            runner = pathlib.Path(directory) / 'scripts/maestro/run-maestro.py'
            runner.parent.mkdir(parents=True)
            shutil.copyfile(RUNNER, runner)
            report = pathlib.Path(directory) / 'maestro-results/junit.xml'
            report.parent.mkdir()
            if stale:
                report.write_text(content)
            script = (
                'import pathlib, time, sys\n'
                + ('' if stale else f'pathlib.Path({str(report)!r}).write_text({content!r})\n')
                + f'print({summary!r}, flush=True)\n'
                + (f'sys.exit({exit_code})' if exit_code is not None else 'time.sleep(30)')
            )
            fake_maestro = pathlib.Path(directory) / 'maestro'
            fake_maestro.write_text(f'#!{sys.executable}\n' + script)
            fake_maestro.chmod(0o755)
            return subprocess.run(
                [sys.executable, str(runner), str(timeout), 'manual-zip', 'emulator-5554'],
                env={**os.environ, 'PATH': directory + os.pathsep + os.environ['PATH']},
                capture_output=True, timeout=15,
            ).returncode

    def test_stalled_successful_teardown(self):
        self.assertEqual(self.run_fixture('<testsuite tests="1"><testcase/></testsuite>', '1/1 Flow Passed', timeout=10), 0)

    def test_failed_report_cannot_pass(self):
        self.assertEqual(self.run_fixture('<testsuite><testcase><failure/></testcase></testsuite>', '1/1 Flow Passed'), 124)

    def test_individual_pass_is_not_suite_success(self):
        self.assertEqual(self.run_fixture('<testsuite><testcase/></testsuite>', '[Passed] first-flow'), 124)

    def test_stale_report_is_removed(self):
        self.assertEqual(self.run_fixture('<testsuite><testcase/></testsuite>', '1/1 Flow Passed', stale=True), 124)

    def test_cli_failure_is_preserved(self):
        self.assertEqual(self.run_fixture('<testsuite><testcase/></testsuite>', '1/1 Flow Passed', exit_code=7), 7)

    def check_cancellation(self, ignore_term=False, descendant=False, repeat=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            runner = root / 'scripts/maestro/run-maestro.py'
            runner.parent.mkdir(parents=True)
            shutil.copyfile(RUNNER, runner)
            pid_file = root / 'maestro.pid'
            child_pid_file = root / 'child.pid'
            ready_file = root / 'ready'
            term_file = root / 'terminated'
            child_script = (
                'import os, pathlib, signal, time\n'
                'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                f'pathlib.Path({str(child_pid_file)!r}).write_text(str(os.getpid()))\n'
                'time.sleep(30)\n'
            )
            script = (
                'import os, pathlib, signal, subprocess, sys, time\n'
                + (f'signal.signal(signal.SIGTERM, lambda *_: pathlib.Path({str(term_file)!r}).touch())\n'
                   if ignore_term else '')
                + f'pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid()))\n'
                + (f'subprocess.Popen([sys.executable, "-c", {child_script!r}])\n' if descendant else '')
                + 'print("Maestro running", flush=True)\n'
                + f'pathlib.Path({str(ready_file)!r}).touch()\n'
                + 'time.sleep(30)\n'
            )
            fake_maestro = root / 'maestro'
            fake_maestro.write_text(f'#!{sys.executable}\n' + script)
            fake_maestro.chmod(0o755)
            process = subprocess.Popen(
                [sys.executable, str(runner), '10', 'manual-zip', 'emulator-5554'],
                env={**os.environ, 'PATH': directory + os.pathsep + os.environ['PATH']},
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
            )
            try:
                wait_until(ready_file.exists)
                if descendant:
                    wait_until(lambda: child_pid_file.exists() and child_pid_file.read_text())
                maestro_pid = int(pid_file.read_text())
                process.terminate()
                if repeat:
                    wait_until(term_file.exists)
                    process.terminate()
                process.wait(timeout=6)
                self.assertFalse(process_running(maestro_pid), 'Detached Maestro survived wrapper cancellation')
                self.assertEqual(process.returncode, 143)
                # A surviving descendant also holds the inherited stdout pipe open.
                output, _ = process.communicate(timeout=2)
                self.assertIn(b'Maestro running', output)
                if descendant:
                    child_pid = int(child_pid_file.read_text())
                    wait_until(lambda: not process_running(child_pid))
            finally:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                if pid_file.exists():
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(int(pid_file.read_text()), signal.SIGKILL)
                process.communicate(timeout=5)

    def test_sigterm_stops_detached_maestro(self):
        self.check_cancellation()

    def test_repeated_sigterm_still_kills_uncooperative_maestro(self):
        self.check_cancellation(ignore_term=True, repeat=True)

    def test_sigterm_kills_descendant_after_maestro_exits(self):
        self.check_cancellation(descendant=True)


if __name__ == '__main__':
    unittest.main()
