#!/usr/bin/env python3
"""Reads bytes from stdin in raw mode and writes "epoch_ms hex" lines to stdout.

Used by test-send-prompt.sh to observe when each byte arrives from
tmux send-keys, so we can verify send-prompt.sh inserts a settle gap
between the last text byte and the Enter (\r).
"""
import os
import sys
import termios
import time
import tty

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    while True:
        b = os.read(fd, 1)
        if not b:
            break
        ms = int(time.time() * 1000)
        sys.stdout.write(f"{ms} {b.hex()}\n")
        sys.stdout.flush()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
