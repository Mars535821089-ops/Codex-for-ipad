import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class AutoUpdateDisabledContractTests(unittest.TestCase):
    def test_product_does_not_wire_app_updates_or_runtime_pollers(self):
        router = (
            ROOT
            / "CodexPad/CodexPad/Application/CodexDesktopInitialAppHostRouter.swift"
        ).read_text(encoding="utf-8")
        controller = (
            ROOT
            / "CodexPad/CodexPad/Application/CodexDesktopSurfaceController.swift"
        ).read_text(encoding="utf-8")
        configure = (ROOT / "scripts/configure_auto_update.sh").read_text(
            encoding="utf-8"
        )
        poller = (ROOT / "scripts/poll_ipad_update_requests.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn('"appUpdates"', router)
        self.assertIn("appUpdatesService", router)
        self.assertNotIn("CodexIPadUpdateRequestManager", controller)
        self.assertIn("AUTOMATIC_UPDATE_DISABLED", configure)
        self.assertIn("AUTOMATIC_UPDATE_DISABLED", poller)


if __name__ == "__main__":
    unittest.main()
