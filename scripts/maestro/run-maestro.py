#!/usr/bin/env python3
"""Bound Maestro teardown after its final summary and successful JUnit report."""
import os
import re
import selectors
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


def report_passed(report):
    try:
        root = ET.parse(report).getroot()
        cases = list(root.iter('testcase'))
        return bool(cases) and not any(
            list(root.iter(tag)) for tag in ('failure', 'error', 'skipped')
        ) and all(
            int(suite.get('failures', '0')) == 0 and int(suite.get('errors', '0')) == 0
            for suite in root.iter('testsuite')
        )
    except (OSError, ET.ParseError, ValueError):
        return False


def run(timeout, report, arguments):
    if not 0 < timeout <= 600:
        raise ValueError('Maestro timeout must be between 0 and 600 seconds')
    # A report from an earlier attempt must never authorize success.
    try:
        os.remove(report)
    except FileNotFoundError:
        pass
    process = subprocess.Popen(["maestro", "test", *arguments], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    passed_at = None
    summary_passed = False
    output = ''
    try:
        while process.poll() is None:
            for key, _ in selector.select(0.2):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                output = (output + chunk.decode('utf-8', errors='replace'))[-8192:]
                summary_passed = bool(re.search(r'\b(\d+)/\1 Flow Passed\b', output))
            if summary_passed and report_passed(report):
                passed_at = passed_at or time.monotonic()
                if time.monotonic() - passed_at >= 5:
                    print('Maestro flow and JUnit report passed; stopping stalled CLI teardown.', flush=True)
                    return 0
            else:
                passed_at = None
            if time.monotonic() >= deadline:
                return 124
        return process.returncode
    finally:
        selector.close()
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        os.set_blocking(process.stdout.fileno(), False)
        remaining = process.stdout.read()
        if remaining:
            sys.stdout.buffer.write(remaining)
        process.stdout.close()


if __name__ == '__main__':
    sys.exit(run(float(sys.argv[1]), sys.argv[2], sys.argv[3:]))
