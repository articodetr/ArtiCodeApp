#!/usr/bin/env python3
import os
import pty
import sys
import select

os.environ['EXPO_TOKEN'] = 'wuHP7MsCQt_at86feHoq1QteFNIit5qQ6hUigE4L'

def run_eas_build():
    master, slave = pty.openpty()

    pid = os.fork()
    if pid == 0:
        # Child process
        os.close(master)
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(slave)

        os.execvp('npx', ['npx', 'eas-cli', 'build', '--platform', 'android', '--profile', 'preview'])
    else:
        # Parent process
        os.close(slave)

        try:
            while True:
                ready, _, _ = select.select([master, sys.stdin], [], [], 1.0)

                if master in ready:
                    try:
                        data = os.read(master, 1024)
                        if not data:
                            break
                        output = data.decode('utf-8', errors='ignore')
                        sys.stdout.write(output)
                        sys.stdout.flush()

                        # Auto-respond to prompts
                        if 'Would you like' in output and 'create' in output:
                            os.write(master, b'y\n')
                        elif 'Generate a new Android Keystore' in output:
                            os.write(master, b'y\n')
                    except OSError:
                        break

        except KeyboardInterrupt:
            pass
        finally:
            os.close(master)
            pid, status = os.waitpid(pid, 0)
            exit_code = os.WEXITSTATUS(status)
            sys.exit(exit_code)

if __name__ == '__main__':
    run_eas_build()
