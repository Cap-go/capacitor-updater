#!/usr/bin/env python3
"""Sample the updater app process. Memory excludes separate WebView/network processes.

Android: /proc counters at 100 ms. iOS simulator: host proc_pid_rusage at 20 ms.
Write raw JSONL; join samples to server hostStartedAt/hostFinishedAt windows.
"""
import argparse
import ctypes
import json
import os
import signal
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--platform', choices=['android', 'ios'], required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--serial', default='emulator-5610')
parser.add_argument('--udid', default='EDFC80C4-6DA0-4966-B9C4-8C439106E328')
args = parser.parse_args()


def emit(output, sample):
    output.write(json.dumps(sample, separators=(',', ':')) + '\n')
    output.flush()


with open(args.output, 'a', encoding='utf-8') as output:
    if args.platform == 'android':
        adb = os.path.expanduser('~/Library/Android/sdk/platform-tools/adb')
        # One persistent ADB connection avoids a new transport per sample.
        script = '''while true; do
          sample_pid=$(pidof app.capgo.updater)
          if [ -n "$sample_pid" ]; then
            echo "BEGIN $sample_pid"
            cat /proc/$sample_pid/stat /proc/$sample_pid/status /proc/$sample_pid/smaps_rollup 2>/dev/null
            echo END
          fi
          sleep 0.1
        done'''
        child = subprocess.Popen([adb, '-s', args.serial, 'shell', script], stdout=subprocess.PIPE, text=True)
        signal.signal(signal.SIGTERM, lambda *_: child.terminate())
        record = None
        try:
            for line in child.stdout:
                line = line.strip()
                if line.startswith('BEGIN '):
                    record = {'ts': time.time() * 1000, 'pid': int(line.split()[1])}
                elif line == 'END' and record:
                    if 'cpuMs' in record and 'rssBytes' in record:
                        emit(output, record)
                    record = None
                elif record is not None:
                    if ') ' in line and line[0].isdigit():
                        fields = line.rsplit(') ', 1)[1].split()
                        # Linux stat fields 14/15, after pid+comm, at USER_HZ=100 on Android.
                        record['cpuMs'] = (int(fields[11]) + int(fields[12])) * 10
                    elif line.startswith('VmRSS:'):
                        record['rssBytes'] = int(line.split()[1]) * 1024
                    elif line.startswith('Pss:'):
                        record['pssBytes'] = int(line.split()[1]) * 1024
                    elif line.startswith('Threads:'):
                        record['threads'] = int(line.split()[1])
        finally:
            child.terminate()
            child.wait(timeout=5)
    else:
        fields = ['user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins',
                  'wired_size', 'resident_size', 'phys_footprint', 'proc_start_abstime', 'proc_exit_abstime']

        class Usage(ctypes.Structure):
            _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(field, ctypes.c_uint64) for field in fields]

        proc = ctypes.CDLL('/usr/lib/libproc.dylib')
        proc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        pid = None
        last_find = 0
        while True:
            if pid is None and time.monotonic() - last_find >= .5:
                last_find = time.monotonic()
                app = subprocess.run(['xcrun', 'simctl', 'get_app_container', args.udid,
                                      'app.capgo.updater', 'app'], capture_output=True, text=True)
                if app.returncode == 0:
                    executable = app.stdout.strip() + '/App'
                    processes = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
                    pid = next((int(line.split()[0]) for line in processes.splitlines()
                                if line.strip().split(maxsplit=1)[-1] == executable), None)
            if pid is not None:
                usage = Usage()
                if proc.proc_pid_rusage(pid, 0, ctypes.byref(usage)) == 0:
                    emit(output, {'ts': time.time() * 1000, 'pid': pid,
                                  'cpuMs': (usage.user_time + usage.system_time) / 1_000_000,
                                  'rssBytes': usage.resident_size,
                                  'footprintBytes': usage.phys_footprint})
                else:
                    pid = None
            time.sleep(.02)
