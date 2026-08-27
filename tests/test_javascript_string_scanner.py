import unittest

from scripts.javascript_string_scanner import scan_javascript_strings


class JavaScriptStringScannerTests(unittest.TestCase):
    def test_scanner_preserves_offsets_and_ignores_comments(self):
        source = b'// "ignored"\nconst a="codex:open"; const b=\'thread\\/start\';'
        strings = scan_javascript_strings(source)
        self.assertEqual(
            [item.value for item in strings], ["codex:open", "thread/start"]
        )
        for item in strings:
            self.assertTrue(
                source[item.start : item.end].decode().startswith(item.quote)
            )

    def test_dynamic_template_is_not_reported_as_static(self):
        source = b"const a=`fixed-channel`; const b=`thread/${id}`;"
        self.assertEqual(
            [item.value for item in scan_javascript_strings(source)],
            ["fixed-channel"],
        )

    def test_nested_templates_and_apostrophes_in_expression_are_skipped(self):
        source = (
            b"const value=`before ${x==null?``:"
            b"`For the user's ${destination}`}`; const channel=\"after\";"
        )
        self.assertEqual(
            [item.value for item in scan_javascript_strings(source)], ["after"]
        )

    def test_common_escapes_are_decoded(self):
        source = br'const x="\x41\u0042\n\t\\\"";'
        self.assertEqual(scan_javascript_strings(source)[0].value, 'AB\n\t\\"')

    def test_unterminated_string_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "unterminated"):
            scan_javascript_strings(b'const x = "broken')


if __name__ == "__main__":
    unittest.main()
