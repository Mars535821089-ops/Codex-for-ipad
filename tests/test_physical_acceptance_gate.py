import unittest
from pathlib import Path


class PhysicalAcceptanceGateTests(unittest.TestCase):
    @property
    def script(self) -> str:
        return (
            Path(__file__).parents[1] / "scripts/verify_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")

    def test_physical_device_access_requires_one_explicit_acceptance_gate(self) -> None:
        script = self.script
        gate = 'PHYSICAL_ACCEPTANCE="${CODEXPAD_RUN_PHYSICAL_ACCEPTANCE:-false}"'
        selector = 'python3 "$DEVICE_SELECTOR" --format json'
        device_test = "xcodebuild \\\n  -project"

        self.assertIn(gate, script)
        self.assertIn(
            'if [[ "$PHYSICAL_ACCEPTANCE" != "true" ]]; then',
            script,
        )
        self.assertIn(
            "Physical iPad acceptance was not explicitly requested; device left untouched",
            script,
        )
        self.assertLess(script.index(gate), script.index(selector))
        self.assertLess(script.index(gate), script.index(device_test))

    def test_verifier_contains_no_device_power_or_forced_restart_command(self) -> None:
        script = self.script.lower()

        self.assertNotIn("--terminate-existing", script)
        self.assertNotIn(" devicectl device reboot", script)
        self.assertNotIn(" devicectl device shutdown", script)
        self.assertNotIn(" simctl ", script)


if __name__ == "__main__":
    unittest.main()
