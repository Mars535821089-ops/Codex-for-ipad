from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

from scripts.ipad_release_gate import (
    build_and_validate,
    load_target_device_id,
    validate_release_gate,
)
from scripts.build_ipad_release import production_input_fingerprint
from scripts.release_identity import ReleaseIdentity


class IpadReleaseGateTests(unittest.TestCase):
    def _seed(self, root: Path) -> tuple[ReleaseIdentity, Path, Path]:
        identity = ReleaseIdentity(
            "26.727.51351",
            "6119",
            hashlib.sha256(b"official DMG").hexdigest(),
        )
        release_root = (
            root
            / "artifacts/ipad-release"
            / identity.version
            / identity.build
            / identity.dmg_sha256[:16]
        )
        export = release_root / "export"
        export.mkdir(parents=True)
        ipa = export / "Codex for ipad.ipa"
        ipa.write_bytes(b"signed IPA fixture")
        manifest = release_root / "CodexPad.release.json"
        payload = {
            "schemaVersion": 1,
            "version": identity.version,
            "build": identity.build,
            "dmgSha256": identity.dmg_sha256,
            "configuration": "Release",
            "distributionMethod": "debugging",
            "artifact": {
                "fileName": ipa.name,
                "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
                "sizeBytes": ipa.stat().st_size,
                "zipIntegrity": True,
            },
            "product": {
                "architecture": "arm64",
                "build": identity.build,
                "deviceFamily": "iPad",
                "platform": "iphoneos",
                "version": identity.version,
            },
            "verification": {
                "bundleIdentityMatched": True,
                "codesignValid": True,
                "entitlementsValid": True,
                "provisioningProfileValid": True,
                "targetDeviceProvisioned": True,
            },
        }
        payload["productionInputFingerprint"] = production_input_fingerprint(root)
        manifest.write_text(
            json.dumps(payload) + "\n",
            encoding="utf-8",
        )
        return identity, manifest, ipa

    def test_accepts_exact_signed_ipa_and_returns_content_anchors(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            identity, manifest, ipa = self._seed(root)

            gate = validate_release_gate(root, identity, manifest)

            self.assertEqual(
                gate["ipaPath"],
                ipa.relative_to(root).as_posix(),
            )
            self.assertEqual(
                gate["ipaSha256"],
                hashlib.sha256(ipa.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                gate["ipaReleaseManifestPath"],
                manifest.relative_to(root).as_posix(),
            )
            self.assertEqual(
                gate["ipaReleaseManifestSha256"],
                hashlib.sha256(manifest.read_bytes()).hexdigest(),
            )

    def test_rejects_identity_hash_path_and_signature_gate_mismatches(self) -> None:
        for case in ("identity", "hash", "path", "signature"):
            with self.subTest(case=case):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    identity, manifest, ipa = self._seed(root)
                    payload = json.loads(manifest.read_text(encoding="utf-8"))
                    if case == "identity":
                        payload["build"] = "6120"
                    elif case == "hash":
                        payload["artifact"]["sha256"] = "0" * 64
                    elif case == "path":
                        payload["artifact"]["fileName"] = "../outside.ipa"
                    else:
                        payload["verification"]["codesignValid"] = False
                    manifest.write_text(
                        json.dumps(payload) + "\n",
                        encoding="utf-8",
                    )

                    with self.assertRaises(ValueError):
                        validate_release_gate(root, identity, manifest)

    def test_rejects_manifest_without_current_production_input_fingerprint(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            identity, manifest, _ipa = self._seed(root)
            payload = json.loads(manifest.read_text(encoding="utf-8"))
            payload.pop("productionInputFingerprint")
            manifest.write_text(json.dumps(payload) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "production input"):
                validate_release_gate(root, identity, manifest)

    def test_rejects_ipa_after_a_production_input_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            identity, manifest, _ipa = self._seed(root)
            source = root / "CodexCore/src/lib.rs"
            source.parent.mkdir(parents=True)
            source.write_text("changed source\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "production input"):
                validate_release_gate(root, identity, manifest)

    def test_stale_existing_release_is_rebuilt_instead_of_reused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            identity, manifest, _ipa = self._seed(root)
            identity_record = root / "identity.json"
            identity_record.write_text(
                json.dumps(
                    {
                        "version": identity.version,
                        "build": identity.build,
                        "dmg_sha256": identity.dmg_sha256,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            validator = mock.Mock(
                side_effect=[
                    ValueError("production input is stale"),
                    {"ipaPath": "fixture.ipa"},
                ],
            )
            with mock.patch(
                "scripts.ipad_release_gate.build_release"
            ) as build, mock.patch(
                "scripts.ipad_release_gate.validate_release_gate",
                validator,
            ), mock.patch(
                "scripts.ipad_release_gate._discover_team_id",
                return_value="XXXXXXXXXX",
            ), mock.patch(
                "scripts.ipad_release_gate.load_target_device_id",
                return_value="PRIVATE-TARGET-DEVICE-ID",
            ):
                build_and_validate(
                    root,
                    identity_record,
                    root / "artifacts/ipad-release",
                )
            self.assertTrue(build.called)

    def test_rebuild_failure_restores_previous_release_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            identity, manifest, _ipa = self._seed(root)
            release_root = manifest.parent
            sentinel = release_root / "previous-release.txt"
            sentinel.write_text("previous release\n", encoding="utf-8")
            identity_record = root / "identity.json"
            identity_record.write_text(
                json.dumps(
                    {
                        "version": identity.version,
                        "build": identity.build,
                        "dmg_sha256": identity.dmg_sha256,
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            def fail_after_partial_build(paths, *_args, **_kwargs) -> None:
                paths.root.mkdir(parents=True)
                (paths.root / "partial-build.txt").write_text(
                    "partial\n",
                    encoding="utf-8",
                )
                raise RuntimeError("release build failed")

            with mock.patch(
                "scripts.ipad_release_gate.validate_release_gate",
                side_effect=ValueError("production input is stale"),
            ), mock.patch(
                "scripts.ipad_release_gate.build_release",
                side_effect=fail_after_partial_build,
            ), mock.patch(
                "scripts.ipad_release_gate._discover_team_id",
                return_value="XXXXXXXXXX",
            ), mock.patch(
                "scripts.ipad_release_gate.load_target_device_id",
                return_value="PRIVATE-TARGET-DEVICE-ID",
            ):
                with self.assertRaisesRegex(RuntimeError, "release build failed"):
                    build_and_validate(
                        root,
                        identity_record,
                        root / "artifacts/ipad-release",
                    )

            self.assertEqual(
                sentinel.read_text(encoding="utf-8"),
                "previous release\n",
            )
            self.assertFalse((release_root / "partial-build.txt").exists())
            self.assertEqual(
                list(release_root.parent.glob(f".{release_root.name}.stale-*")),
                [],
            )

    def test_successful_rebuild_discards_non_directory_stale_root(self) -> None:
        for stale_kind in ("file", "symlink"):
            with self.subTest(stale_kind=stale_kind):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    identity, manifest, _ipa = self._seed(root)
                    release_root = manifest.parent
                    legacy_target = root / "legacy-release-target"
                    legacy_target.mkdir()
                    (legacy_target / "retained.txt").write_text(
                        "retained\n",
                        encoding="utf-8",
                    )
                    shutil.rmtree(release_root)
                    if stale_kind == "file":
                        release_root.write_text(
                            "stale release root\n",
                            encoding="utf-8",
                        )
                    else:
                        release_root.symlink_to(legacy_target, target_is_directory=True)

                    identity_record = root / "identity.json"
                    identity_record.write_text(
                        json.dumps(
                            {
                                "version": identity.version,
                                "build": identity.build,
                                "dmg_sha256": identity.dmg_sha256,
                            }
                        )
                        + "\n",
                        encoding="utf-8",
                    )

                    def build_fixture(paths, *_args, **_kwargs) -> None:
                        paths.root.mkdir(parents=True)
                        (paths.root / "new-release.txt").write_text(
                            "new release\n",
                            encoding="utf-8",
                        )

                    validator = mock.Mock(
                        side_effect=[
                            ValueError("production input is stale"),
                            {"ipaPath": "fixture.ipa"},
                        ],
                    )
                    with mock.patch(
                        "scripts.ipad_release_gate.validate_release_gate",
                        validator,
                    ), mock.patch(
                        "scripts.ipad_release_gate.build_release",
                        side_effect=build_fixture,
                    ), mock.patch(
                        "scripts.ipad_release_gate._discover_team_id",
                        return_value="XXXXXXXXXX",
                    ), mock.patch(
                        "scripts.ipad_release_gate.load_target_device_id",
                        return_value="PRIVATE-TARGET-DEVICE-ID",
                    ):
                        result = build_and_validate(
                            root,
                            identity_record,
                            root / "artifacts/ipad-release",
                        )

                    self.assertEqual(result, {"ipaPath": "fixture.ipa"})
                    self.assertFalse(release_root.is_symlink())
                    self.assertEqual(
                        (release_root / "new-release.txt").read_text(
                            encoding="utf-8"
                        ),
                        "new release\n",
                    )
                    self.assertEqual(
                        (legacy_target / "retained.txt").read_text(
                            encoding="utf-8"
                        ),
                        "retained\n",
                    )
                    self.assertEqual(
                        list(
                            release_root.parent.glob(
                                f".{release_root.name}.stale-*"
                            )
                        ),
                        [],
                    )

    def test_target_device_id_uses_runtime_or_private_local_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = root / ".update-state/ipad-target-device-id"
            state.parent.mkdir()
            state.write_text("PRIVATE-DEVICE-ID\n", encoding="utf-8")
            state.chmod(0o600)
            with mock.patch.dict(
                "os.environ",
                {"CODEX_IPAD_TARGET_DEVICE_ID": ""},
            ):
                self.assertEqual(
                    load_target_device_id(root),
                    "PRIVATE-DEVICE-ID",
                )
            with mock.patch.dict(
                "os.environ",
                {"CODEX_IPAD_TARGET_DEVICE_ID": "RUNTIME-DEVICE-ID"},
            ):
                self.assertEqual(
                    load_target_device_id(root),
                    "RUNTIME-DEVICE-ID",
                )

            state.chmod(0o644)
            with mock.patch.dict(
                "os.environ",
                {"CODEX_IPAD_TARGET_DEVICE_ID": ""},
            ):
                with self.assertRaisesRegex(ValueError, "0600"):
                    load_target_device_id(root)
