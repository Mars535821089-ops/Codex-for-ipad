#!/usr/bin/env python3
"""Run SwiftPM tests and contain Xcode beta's occasional post-success hang."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time


SUCCESS = re.compile(r"Test run with\s+\d+\s+tests.*\bpassed\b")
FAILURE = re.compile(r"\b[1-9]\d*\s+failed\b|\btest case failed\b|fatal error:", re.IGNORECASE)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-path", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--success-idle", type=float, default=15)
    args = parser.parse_args()

    def terminate_runner() -> None:
        os.killpg(process.pid, 15)
        subprocess.run(
            [
                "pkill",
                "-TERM",
                "-f",
                "swiftpm-testing-helper.*--package-path "
                + str(args.package_path),
            ],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    process = subprocess.Popen(
        ["swift", "test", "--package-path", str(args.package_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,
    )
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    started = last_output = time.monotonic()
    saw_success = False
    saw_failure = False
    passed_lines = 0

    while True:
        now = time.monotonic()
        if now - started > args.timeout:
            terminate_runner()
            print("Swift test runner exceeded its completion timeout.", file=sys.stderr)
            return 124
        if (
            not saw_failure
            and now - last_output >= args.success_idle
            and (saw_success or passed_lines >= 100)
        ):
            terminate_runner()
            process.wait(timeout=10)
            print(
                "Swift tests passed; contained post-success Xcode beta runner hang."
            )
            return 0

        events = selector.select(timeout=1)
        if not events:
            return_code = process.poll()
            if return_code is not None:
                return return_code
            continue
        line = process.stdout.readline()
        if line == "":
            return_code = process.wait()
            return return_code
        print(line, end="", flush=True)
        last_output = time.monotonic()
        saw_success = saw_success or SUCCESS.search(line) is not None
        saw_failure = saw_failure or FAILURE.search(line) is not None
        if " passed" in line:
            passed_lines += 1


if __name__ == "__main__":
    raise SystemExit(main())
