#!/usr/bin/env python3
import subprocess
import sys
import os

os.environ['EXPO_TOKEN'] = 'wuHP7MsCQt_at86feHoq1QteFNIit5qQ6hUigE4L'

try:
    import pexpect

    child = pexpect.spawn('npx eas-cli build --platform android --profile preview', timeout=600)
    child.logfile = sys.stdout.buffer

    # Wait for the keystore generation prompt
    index = child.expect(['Generate a new Android Keystore?', pexpect.EOF, pexpect.TIMEOUT])

    if index == 0:
        child.sendline('y')
        child.expect(pexpect.EOF)

    child.close()
    sys.exit(child.exitstatus)

except ImportError:
    print("pexpect not available, trying subprocess")
    proc = subprocess.Popen(
        ['npx', 'eas-cli', 'build', '--platform', 'android', '--profile', 'preview'],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True
    )

    proc.stdin.write('y\n')
    proc.stdin.flush()
    proc.stdin.close()

    for line in proc.stdout:
        print(line, end='')

    proc.wait()
    sys.exit(proc.returncode)
