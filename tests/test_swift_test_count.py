from __future__ import annotations

import unittest

from scripts.swift_test_count import count_passed_swift_tests


class SwiftTestCountTests(unittest.TestCase):
    def test_counts_swift_testing_success_lines_when_xctest_summary_is_zero(
        self,
    ) -> None:
        output = "\n".join(
            (
                "Executed 0 tests, with 0 failures in 0.000 seconds",
                "✔ Test plainTest() passed after 0.001 seconds.",
                "✔ Test case passing 1 argument value → 1 passed after 0.001 seconds.",
                "✔ Test case passing 1 argument value → 2 passed after 0.001 seconds.",
                "✔ Test parameterized(value:) with 2 test cases passed after 0.001 seconds.",
            )
        )

        self.assertEqual(count_passed_swift_tests(output), 3)

    def test_uses_positive_legacy_summary_count(self) -> None:
        self.assertEqual(
            count_passed_swift_tests(
                "Test run with 205 tests in 3 suites passed\n"
            ),
            205,
        )


if __name__ == "__main__":
    unittest.main()
