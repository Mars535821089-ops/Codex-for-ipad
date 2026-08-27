from pathlib import Path
import unittest


ROOT = Path(__file__).parents[1]


class IPadAppHostSemanticsVerifierContractTests(unittest.TestCase):
    def test_upgrade_verifier_requires_semantic_placeholder_gate(self) -> None:
        verifier = (ROOT / "scripts/verify_ipad_upgrade.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("audit_ipad_apphost_semantics.py", verifier)
        self.assertIn("audit_desktop_apphost_api.py", verifier)
        self.assertNotIn(
            '.update-state/desktop-apphost-coverage-$VERSION.json',
            verifier,
        )
        self.assertIn("desktop-apphost-coverage.json", verifier)
        self.assertIn("ipad-apphost-semantics.json", verifier)
        self.assertIn("--require-no-placeholders", verifier)
        self.assertIn(
            '--log "apphost-semantics=$APPHOST_SEMANTICS_LOG"',
            verifier,
        )


if __name__ == "__main__":
    unittest.main()
