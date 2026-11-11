import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

RUNNER = pathlib.Path(__file__).with_name('run-maestro.py')


class MaestroTeardownTests(unittest.TestCase):
    def run_fixture(self, content, summary, timeout=1, stale=False, exit_code=None):
        with tempfile.TemporaryDirectory() as directory:
            report = pathlib.Path(directory) / 'junit.xml'
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
                [sys.executable, str(RUNNER), str(timeout), str(report)],
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


if __name__ == '__main__':
    unittest.main()
