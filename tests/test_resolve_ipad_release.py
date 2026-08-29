import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts/resolve_ipad_release.py"


class ResolveIPadReleaseTests(unittest.TestCase):
    def make_fixture(self, root: Path) -> tuple[Path, Path, Path]:
        release_root = root / "artifacts/ipad-release/1.2.3/42/abcdef"
        export_root = release_root / "export"
        export_root.mkdir(parents=True)
        ipa = export_root / "Codex for ipad.ipa"
        info = {
            "CFBundleDisplayName": "Codex for ipad",
            "CFBundleIdentifier": "com.mars.codexpad",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "CFBundleExecutable": "Codex for ipad",
            "UIDeviceFamily": [2],
        }
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.writestr("Payload/Codex for ipad.app/Info.plist", plistlib.dumps(info))
            archive.writestr("Payload/Codex for ipad.app/Codex for ipad", b"arm64-test")

        ipa_bytes = ipa.read_bytes()
        manifest = release_root / "CodexPad-1.2.3-42.release.json"
        manifest.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "version": "1.2.3",
                    "build": "42",
                    "dmgSha256": "a" * 64,
                    "artifact": {
                        "fileName": ipa.name,
                        "sha256": hashlib.sha256(ipa_bytes).hexdigest(),
                        "sizeBytes": len(ipa_bytes),
                        "zipIntegrity": True,
                    },
                    "product": {
                        "architecture": "arm64",
                        "bundleIdentifier": "com.mars.codexpad",
                        "build": "42",
                        "deviceFamily": "iPad",
                        "name": "Codex for ipad",
                        "platform": "iphoneos",
                        "version": "1.2.3",
                    },
                    "verification": {
                        "bundleIdentityMatched": True,
                        "codesignValid": True,
                        "entitlementsValid": True,
                        "provisioningProfileValid": True,
                        "targetDeviceProvisioned": True,
                    },
                }
            ),
            encoding="utf-8",
        )
        probe = root / ".planning/codex-ipad-release/latest-official-probe-20260819.json"
        probe.parent.mkdir(parents=True)
        probe.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "application": {"version": "1.2.3", "build": "42"},
                    "download": {"sha256": "a" * 64},
                    "releaseMatch": {
                        "dmgSha256Matched": True,
                        "ipaPath": ipa.relative_to(root).as_posix(),
                        "ipaSha256": hashlib.sha256(ipa_bytes).hexdigest(),
                        "ipaSizeBytes": len(ipa_bytes),
                        "manifestPath": manifest.relative_to(root).as_posix(),
                    },
                }
            ),
            encoding="utf-8",
        )
        return probe, manifest, ipa

    def run_resolver(self, root: Path, probe: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--project-root",
                str(root),
                "--probe",
                str(probe),
                "--extract-root",
                str(root / "extract"),
                "--output",
                str(root / "resolved.json"),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_resolves_and_extracts_the_exact_manifest_bound_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            probe, _, ipa = self.make_fixture(root)

            result = self.run_resolver(root, probe)

            self.assertEqual(result.returncode, 0, result.stderr)
            resolved = json.loads((root / "resolved.json").read_text(encoding="utf-8"))
            self.assertEqual(resolved["version"], "1.2.3")
            self.assertEqual(resolved["build"], "42")
            self.assertEqual(resolved["ipaPath"], str(ipa.resolve()))
            app = Path(resolved["appPath"])
            self.assertTrue(app.is_dir())
            self.assertEqual(app.name, "Codex for ipad.app")

    def test_rejects_an_ipa_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            probe, _, ipa = self.make_fixture(root)
            tampered = bytearray(ipa.read_bytes())
            tampered[-1] ^= 0x01
            ipa.write_bytes(tampered)

            result = self.run_resolver(root, probe)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("IPA SHA-256 does not match", result.stderr)

    def test_rejects_release_paths_outside_the_project(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            probe, _, _ = self.make_fixture(root)
            payload = json.loads(probe.read_text(encoding="utf-8"))
            payload["releaseMatch"]["ipaPath"] = "../outside.ipa"
            probe.write_text(json.dumps(payload), encoding="utf-8")

            result = self.run_resolver(root, probe)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("release path escapes project root", result.stderr)


if __name__ == "__main__":
    unittest.main()
