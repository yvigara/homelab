#!/usr/bin/env python3
"""config-drift-watch — inotify-based real-time drift detection for Hermes config files.

WHY, WHEN A 15-MIN CRON ALSO EXISTS
    The cron catches drift within 15 minutes. This catches it within seconds, and it
    catches the case cron cannot: a change that is written and then reverted between two
    cron ticks. It also names WHO/WHEN by timestamping the event.

    Both run. The watcher is the fast path; the cron is the safety net (it survives a
    watcher crash, a restart, or a missed inotify event).

DESIGN NOTES
    * stdlib only — inotify via ctypes. The pod has no `inotifywait`, no `pyinotify`,
      no `watchdog`, and /opt/hermes is a read-only image, so nothing can be installed.
    * Watches the DIRECTORY, not the file. A whole-file write (which is what init.sh and
      `hermes config set` do) replaces the inode, so a file-level watch goes deaf after
      the first write. Directory + IN_MOVED_TO/IN_CLOSE_WRITE is the correct primitive.
    * DEBOUNCED. A single save can raise several events; one check per quiet period.
    * Runs the same config-drift.py checker, so there is exactly one definition of drift.

Usage:
    config-drift-watch.py                 # foreground, logs to stderr
    config-drift-watch.py --alert-cmd CMD # run CMD with the report on stdin when drift appears
    config-drift-watch.py --once          # single check, then exit (test mode)
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import os
import select
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHECKER = HERE / "config-drift.py"
PYTHON = "/opt/hermes/.venv/bin/python3" if Path("/opt/hermes/.venv/bin/python3").is_file() else sys.executable

DATA = Path(os.environ.get("HERMES_HOME", "/opt/data"))
WATCH_TARGETS = [DATA / "config.yaml"]
PROFILES = DATA / "profiles"

# inotify constants (linux/limits.h, sys/inotify.h)
IN_CLOSE_WRITE = 0x00000008
IN_MOVED_TO = 0x00000080
IN_CREATE = 0x00000100
IN_DELETE_SELF = 0x00000400
IN_MOVE_SELF = 0x00000800
WATCH_MASK = IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE_SELF | IN_MOVE_SELF

DEBOUNCE_SECONDS = 3.0
EVENT_SIZE = 16 + 255  # struct inotify_event + NAME_MAX


def log(msg: str) -> None:
    print(f"[config-drift-watch] {time.strftime('%Y-%m-%d %H:%M:%S')} {msg}",
          file=sys.stderr, flush=True)


def _libc():
    libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
    libc.inotify_init1.restype = ctypes.c_int
    libc.inotify_add_watch.restype = ctypes.c_int
    return libc


def watched_dirs() -> list[Path]:
    """Directories whose writes can change a config file we care about."""
    dirs = [d for d in (DATA, PROFILES) if d.is_dir()]
    if PROFILES.is_dir():
        dirs += [p for p in sorted(PROFILES.iterdir()) if p.is_dir()]
    return dirs


def run_check() -> tuple[int, str]:
    try:
        proc = subprocess.run(
            [PYTHON, str(CHECKER)], capture_output=True, text=True, timeout=180,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return 2, f"config-drift check failed: {exc}"
    return proc.returncode, (proc.stdout or "").strip()


def emit(alert_cmd: str | None, report: str) -> None:
    log("DRIFT: " + report.replace("\n", " | ")[:400])
    if alert_cmd:
        try:
            subprocess.run(alert_cmd, shell=True, input=report, text=True, timeout=120)
        except (subprocess.TimeoutExpired, OSError) as exc:
            log(f"alert command failed: {exc}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--alert-cmd", default=os.environ.get("CONFIG_DRIFT_ALERT_CMD"))
    ap.add_argument("--once", action="store_true")
    args = ap.parse_args()

    if not CHECKER.is_file():
        log(f"checker not found: {CHECKER}")
        return 2

    code, report = run_check()
    if args.once:
        print(report)
        return code
    if code == 1:
        emit(args.alert_cmd, report)

    libc = _libc()
    fd = libc.inotify_init1(0)
    if fd < 0:
        log(f"inotify_init1 failed: {os.strerror(ctypes.get_errno())}")
        return 2

    added = 0
    for d in watched_dirs():
        wd = libc.inotify_add_watch(fd, str(d).encode(), WATCH_MASK)
        if wd >= 0:
            added += 1
    log(f"watching {added} director{'y' if added == 1 else 'ies'} "
        f"(debounce {DEBOUNCE_SECONDS}s, alert={'yes' if args.alert_cmd else 'no'})")

    pending_since: float | None = None
    while True:
        ready, _, _ = select.select([fd], [], [], 1.0)
        if ready:
            os.read(fd, EVENT_SIZE * 64)
            if pending_since is None:
                pending_since = time.monotonic()
        if pending_since is not None and time.monotonic() - pending_since >= DEBOUNCE_SECONDS:
            pending_since = None
            code, report = run_check()
            if code == 1:
                emit(args.alert_cmd, report)
            elif code == 2:
                log(f"check error: {report[:200]}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0)
