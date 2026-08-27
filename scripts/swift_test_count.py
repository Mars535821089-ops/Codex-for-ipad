#!/usr/bin/env python3
"""Extract a trustworthy passed-test count from SwiftPM test output."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


MODERN_SUMMARY = re.compile(r"Test run with\s+(\d+)\s+tests")
XCTEST_SUMMARY = re.compile(r"Executed\s+(\d+)\s+tests")
SWIFT_TEST_SUCCESS = re.compile(
    r"^✔ Test (?!.* with \d+ test cases passed after ).* passed after ",
    re.MULTILINE,
)


def count_passed_swift_tests(output: str) -> int:
    modern_counts = [
        int(value) for value in MODERN_SUMMARY.findall(output)
    ]
    if modern_counts and max(modern_counts) > 0:
        return max(modern_counts)

    xctest_counts = [
        int(value) for value in XCTEST_SUMMARY.findall(output)
    ]
    xctest_count = max(xctest_counts, default=0)
    swift_testing_count = len(SWIFT_TEST_SUCCESS.findall(output))
    total = xctest_count + swift_testing_count
    if total <= 0:
        raise ValueError("Swift test count was not found in verifier output")
    return total


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    try:
        print(count_passed_swift_tests(args.log.read_text(encoding="utf-8")))
    except (OSError, UnicodeError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
