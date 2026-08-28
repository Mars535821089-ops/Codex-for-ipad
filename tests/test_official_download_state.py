import importlib.util
import hashlib
import json
import os
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path

from scripts.official_download_state import ReleaseIdentity
from scripts.build_ipad_release import production_input_fingerprint
from scripts.ipad_verification_evidence import _tree_sha256
from scripts.release_archive import _tree_identity, archive_release
from tests.desktop_interaction_inventory_fixture import (
    REFERENCE_PAYLOAD,
    write_desktop_interaction_inventory,
)


ROOT = Path(__file__).parents[1]
MODULE_PATH = ROOT / "scripts" / "official_download_state.py"
XCUI_LOG_FILES = {
    "python": "python-tests.log",
    "swift": "swift-tests.log",
    "rust": "rust-tests.log",
    "xcui": "xcui-tests.log",
    "device-build": "device-build.log",
    "device-surface": "device-surface.json",
}


def load_module():
    spec = importlib.util.spec_from_file_location(
        "official_download_state",
        MODULE_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("official download state module could not be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class OfficialDownloadStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_module()
        self.remote = {
            "checked_at": "20260730T000000Z",
            "official_url": "https://example.invalid/ChatGPT.dmg",
            "status_code": 200,
            "etag": '"current-etag"',
            "last_modified": "Thu, 30 Jul 2026 00:00:00 GMT",
            "content_length": 8,
        }

    @staticmethod
    def _write_json(path: Path, payload: dict[str, object]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload) + "\n", encoding="utf-8")

    @staticmethod
    def _evidence_entry(root: Path, path: Path) -> dict[str, str]:
        return {
            "path": path.relative_to(root).as_posix(),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }

    def _seed_parity_evidence(
        self,
        root: Path,
        *,
        version: str,
        build: str,
        package_hash: str,
    ) -> dict[str, object]:
        evidence_root = root / f"artifacts/parity-evidence/{version}"
        verification = evidence_root / "verification"
        verification.mkdir(parents=True)
        for name, filename in XCUI_LOG_FILES.items():
            path = verification / filename
            if filename.endswith(".json"):
                self._write_json(
                    path,
                    {"status": "passed", "kind": name},
                )
            else:
                path.write_text(f"{name}: passed\n", encoding="utf-8")
        summary = verification / "xcui-summary.json"
        summary_payload = {
            "result": "Passed",
            "totalTestCount": 1,
            "passedTests": 1,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
            "startTime": 1.0,
            "finishTime": 2.0,
        }
        self._write_json(summary, summary_payload)
        xcresult = verification / "CodexPadUITests.xcresult"
        xcresult.mkdir()
        (xcresult / "Info.plist").write_bytes(b"xcresult fixture\n")

        capture = evidence_root / "S01/ipad.png"
        capture.parent.mkdir()
        capture.write_bytes(b"ipad capture fixture\n")
        capture_entry = self._evidence_entry(root, capture)
        contract = {
            "schemaVersion": 2,
            "desktopVersion": version,
            "desktopBuild": build,
            "sourceIdentity": {
                "dmgSha256": package_hash,
                "desktopSurfaceTreeSha256": "1" * 64,
                "recoveredSourceIndexSha256": "2" * 64,
            },
            "surfaces": [
                {
                    "desktopEvidence": [
                        {
                            "file": "webview/assets/reference.js",
                            "bytes": len(b"desktop reference fixture\n"),
                            "sha256": hashlib.sha256(
                                b"desktop reference fixture\n"
                            ).hexdigest(),
                        }
                    ],
                    "visualEvidence": [capture_entry],
                    "runtimeCaptureEvidence": {"ipad": capture_entry},
                }
            ],
        }
        contract_path = root / f"versions/{version}/desktop-ui-parity.json"
        self._write_json(contract_path, contract)
        return {
            **summary_payload,
            "generatedAt": "2026-08-13T06:00:00Z",
            "gitHead": "8" * 40,
            "parityContract": self._evidence_entry(root, contract_path),
            "summary": self._evidence_entry(root, summary),
            "xcresult": {
                "path": xcresult.relative_to(root).as_posix(),
                "sha256": _tree_sha256(xcresult),
                "hashAlgorithm": "sha256-xcresult-tree-v1",
            },
            "logs": {
                name: self._evidence_entry(root, verification / filename)
                for name, filename in XCUI_LOG_FILES.items()
            },
        }

    def _seed_local_current(
        self,
        root: Path,
        *,
        version: str = "26.721.81911",
        build: str = "5973",
        content_addressed: bool = True,
    ) -> Path:
        package_bytes = b"fixture package"
        package_hash = hashlib.sha256(package_bytes).hexdigest()
        xcui_evidence = self._seed_parity_evidence(
            root,
            version=version,
            build=build,
            package_hash=package_hash,
        )
        latest = root / "artifacts/latest-official.json"
        release_root = (
            f"artifacts/releases/{version}/{build}/{package_hash}"
        )
        records = {
            latest: {
                "official_url": self.remote["official_url"],
                "version": version,
                "build": build,
                "size": 15,
                "sha256": package_hash,
                "reverse_imported": True,
                "ipad_upgrade_verified": True,
            },
            root / f"artifacts/manifest-{version}.json": {
                "version": version,
                "build": build,
                "dmg_sha256": package_hash,
                "extracted_path": f"artifacts/app-asar-{version}",
                "file_count": 1,
            },
            root / f"artifacts/full-reverse-{version}/full-reverse-manifest.json": {
                "version": version,
                "build": build,
            },
            root / f"artifacts/ipad-upgrade-{version}.json": {
                "desktopVersion": version,
                "desktopBuild": build,
                "modelCatalogGenerated": True,
                "buildMetadataGenerated": True,
                "codexCoreUpgraded": True,
                "xcframeworkRebuilt": True,
            },
            root / f"artifacts/ipad-verified-{version}.json": {
                "desktopVersion": version,
                "desktopBuild": build,
                "productName": "Codex for ipad",
                "bundleVersionMatched": True,
                "bundleBuildMatched": True,
                "rustTests": "passed",
                "swiftTests": "passed",
                "swiftTestCount": 7,
                "xcuiTests": "passed",
                "xcuiTestCount": 1,
                "physicalDeviceTests": "passed",
                "physicalDeviceUDID": "00000000-0000000000000000",
                "physicalDeviceName": "Example iPad Pro",
                "physicalDeviceModel": "iPad Pro (12.9-inch) (5th generation)",
                "physicalDeviceOS": "26.0",
                "deviceBuild": "passed",
                "deviceArchitecture": "arm64",
                "desktopSurfaceCompleteTree": "passed",
                "sourceIdentity": {
                    "dmgSha256": package_hash,
                },
                "desktopSurface": {
                    "deviceBundleVerified": True,
                },
                "xcuiEvidence": xcui_evidence,
            },
            root / f"versions/{version}/manifest.json": {
                "version": version,
                "build": build,
                "dmgSha256": package_hash,
            },
            root / f"versions/{version}/desktop-surface-manifest.json": {
                "desktopVersion": version,
                "desktopBuild": build,
                "resourceTreeSha256": hashlib.sha256(b"surface").hexdigest(),
            },
        }
        for path, payload in records.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                json.dumps(payload) + "\n",
                encoding="utf-8",
            )
        webview = (
            root
            / f"artifacts/full-reverse-{version}/app-asar/webview/index.html"
        )
        webview.parent.mkdir(parents=True)
        webview.write_text("<html>Codex</html>\n", encoding="utf-8")
        recovered_reference = (
            root
            / f"artifacts/full-reverse-{version}/"
            "recovered-electron-source/webview/assets/reference.js"
        )
        recovered_reference.parent.mkdir(parents=True)
        recovered_reference.write_bytes(REFERENCE_PAYLOAD)
        write_desktop_interaction_inventory(
            root,
            version=version,
            build=build,
        )
        extracted = root / f"artifacts/app-asar-{version}/index.html"
        extracted.parent.mkdir(parents=True)
        extracted.write_text("<html>Codex</html>\n", encoding="utf-8")
        info = root / f"artifacts/Info-{version}.plist"
        with info.open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleShortVersionString": version,
                    "CFBundleVersion": build,
                },
                stream,
            )
        if content_addressed:
            dmg = root / ".downloads/ChatGPT-fixture.dmg"
            dmg.parent.mkdir()
            dmg.write_bytes(package_bytes)
            archive_release(
                root,
                ReleaseIdentity(version, build, package_hash),
                dmg,
            )
            manifest = root / release_root / "release-manifest.json"
            latest_payload = json.loads(latest.read_text(encoding="utf-8"))
            latest_payload.update(
                {
                    "releaseRoot": release_root,
                    "releaseManifestSha256": hashlib.sha256(
                        manifest.read_bytes()
                    ).hexdigest(),
                }
            )
            ipa_root = (
                root
                / "artifacts/ipad-release"
                / version
                / build
                / package_hash[:16]
            )
            ipa = ipa_root / "export/Codex for ipad.ipa"
            ipa.parent.mkdir(parents=True)
            ipa.write_bytes(b"signed IPA fixture")
            ipa_manifest = ipa_root / "CodexPad.release.json"
            ipa_manifest.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "version": version,
                        "build": build,
                        "dmgSha256": package_hash,
                        "configuration": "Release",
                        "distributionMethod": "debugging",
                        "productionInputFingerprint": (
                            production_input_fingerprint(root)
                        ),
                        "artifact": {
                            "fileName": ipa.name,
                            "sha256": hashlib.sha256(
                                ipa.read_bytes()
                            ).hexdigest(),
                            "sizeBytes": ipa.stat().st_size,
                            "zipIntegrity": True,
                        },
                        "product": {
                            "architecture": "arm64",
                            "build": build,
                            "deviceFamily": "iPad",
                            "platform": "iphoneos",
                            "version": version,
                        },
                        "verification": {
                            "bundleIdentityMatched": True,
                            "codesignValid": True,
                            "entitlementsValid": True,
                            "provisioningProfileValid": True,
                            "targetDeviceProvisioned": True,
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            latest_payload.update(
                {
                    "ipaPath": ipa.relative_to(root).as_posix(),
                    "ipaSha256": hashlib.sha256(
                        ipa.read_bytes()
                    ).hexdigest(),
                    "ipaReleaseManifestPath": ipa_manifest.relative_to(
                        root
                    ).as_posix(),
                    "ipaReleaseManifestSha256": hashlib.sha256(
                        ipa_manifest.read_bytes()
                    ).hexdigest(),
                }
            )
            latest.write_text(
                json.dumps(latest_payload) + "\n",
                encoding="utf-8",
            )
        return latest

    def _convert_release_archive_to_legacy(
        self,
        root: Path,
        latest: Path,
    ) -> None:
        latest_payload = json.loads(latest.read_text(encoding="utf-8"))
        release_root = root / latest_payload["releaseRoot"]
        manifest_path = release_root / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        parity_tree = release_root / "derived/parityEvidence"
        if parity_tree.exists():
            shutil.rmtree(parity_tree)

        version = latest_payload["version"]
        archived_version = release_root / "derived/version"
        shutil.rmtree(archived_version)
        shutil.copytree(root / f"versions/{version}", archived_version)
        archived_verification = (
            release_root / f"records/ipad-verified-{version}.json"
        )
        shutil.copy2(
            root / f"artifacts/ipad-verified-{version}.json",
            archived_verification,
        )
        manifest["schemaVersion"] = 1
        manifest["derived"].pop("parityEvidence", None)
        manifest["derived"]["version"] = {
            "path": "derived/version",
            **_tree_identity(archived_version),
        }
        manifest["records"]["ipadVerification"] = {
            "path": f"records/ipad-verified-{version}.json",
            "bytes": archived_verification.stat().st_size,
            "sha256": hashlib.sha256(
                archived_verification.read_bytes()
            ).hexdigest(),
        }
        manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        latest_payload["releaseManifestSha256"] = hashlib.sha256(
            manifest_path.read_bytes()
        ).hexdigest()
        latest.write_text(
            json.dumps(latest_payload) + "\n",
            encoding="utf-8",
        )

    def test_parse_headers_uses_final_redirect_response(self) -> None:
        headers = """\
HTTP/1.1 302 Found
content-length: 0
etag: "redirect"

HTTP/1.1 200 OK
content-length: 8
etag: "current-etag"
last-modified: Thu, 30 Jul 2026 00:00:00 GMT
"""
        record = self.module.parse_headers(
            headers,
            self.remote["official_url"],
            checked_at="20260730T000000Z",
        )
        self.assertEqual(record, self.remote)

    def test_parse_headers_rejects_final_non_success_response(self) -> None:
        headers = """\
HTTP/1.1 302 Found
content-length: 0
location: https://example.invalid/replacement

HTTP/1.1 503 Service Unavailable
content-length: 8
etag: "error-document"
last-modified: Thu, 30 Jul 2026 00:00:00 GMT
"""
        with self.assertRaisesRegex(ValueError, "HTTP status 503"):
            self.module.parse_headers(
                headers,
                self.remote["official_url"],
                checked_at="20260730T000000Z",
            )

    def test_parse_headers_requires_a_response_status(self) -> None:
        with self.assertRaisesRegex(ValueError, "HTTP response status"):
            self.module.parse_headers(
                "content-length: 8\netag: \"current-etag\"\n",
                self.remote["official_url"],
                checked_at="20260730T000000Z",
            )

    def test_remote_requires_size_and_stable_identity(self) -> None:
        for override in (
            {"content_length": 0},
            {"etag": "", "last_modified": ""},
            {"official_url": ""},
        ):
            record = {**self.remote, **override}
            with self.subTest(override=override):
                with self.assertRaises(ValueError):
                    self.module.validate_remote(record)

    def test_matching_sidecar_and_size_selects_complete_package(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            package = directory / "ChatGPT-20260730T000000Z.dmg"
            package.write_bytes(b"12345678")
            self.module.write_sidecar(package, self.remote)

            selected = self.module.select_reusable_package(
                directory,
                self.remote,
            )

            self.assertEqual(selected, package)
            sidecar = json.loads(
                self.module.sidecar_path(package).read_text(encoding="utf-8")
            )
            self.assertEqual(
                sidecar,
                {
                    **self.remote,
                    "package_sha256": hashlib.sha256(b"12345678").hexdigest(),
                },
            )

    def test_same_length_package_with_changed_bytes_is_not_reused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            package = directory / "ChatGPT-20260730T000000Z.dmg"
            package.write_bytes(b"12345678")
            self.module.write_sidecar(package, self.remote)
            package.write_bytes(b"87654321")

            selected = self.module.select_reusable_package(
                directory,
                self.remote,
            )

            self.assertIsNone(selected)

    def test_stale_untracked_or_wrong_size_packages_are_not_reused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            untracked = directory / "ChatGPT-20260729T000000Z.dmg"
            untracked.write_bytes(b"12345678")
            stale = directory / "ChatGPT-20260729T010000Z.dmg"
            stale.write_bytes(b"12345678")
            self.module.write_sidecar(
                stale,
                {**self.remote, "etag": '"old-etag"'},
            )
            truncated = directory / "ChatGPT-20260729T020000Z.dmg"
            truncated.write_bytes(b"1234")
            self.module.sidecar_path(truncated).write_text(
                json.dumps(self.remote),
                encoding="utf-8",
            )

            self.assertIsNone(
                self.module.select_reusable_package(directory, self.remote)
            )

    def test_cleanup_removes_only_proven_incomplete_official_parts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            incomplete = directory / "ChatGPT-incomplete.dmg.part"
            complete_size = directory / "ChatGPT-complete-size.dmg.part"
            oversized = directory / "ChatGPT-oversized.dmg.part"
            complete_package = directory / "ChatGPT-retained.dmg"
            sidecar = directory / "ChatGPT-retained.dmg.remote.json"
            unrelated_part = directory / "codex-source.tar.gz.part"
            part_directory = directory / "ChatGPT-directory.dmg.part"
            symlink_target = directory / "symlink-target"
            symlink_part = directory / "ChatGPT-symlink.dmg.part"

            incomplete.write_bytes(b"short")
            complete_size.write_bytes(b"12345678")
            oversized.write_bytes(b"123456789")
            complete_package.write_bytes(b"12345678")
            sidecar.write_text("{}\n", encoding="utf-8")
            unrelated_part.write_bytes(b"short")
            part_directory.mkdir()
            symlink_target.write_bytes(b"short")
            symlink_part.symlink_to(symlink_target)

            removed = self.module.cleanup_incomplete_parts(
                directory,
                content_length=8,
            )

            self.assertEqual(removed, [incomplete])
            self.assertFalse(incomplete.exists())
            for retained in (
                complete_size,
                oversized,
                complete_package,
                sidecar,
                unrelated_part,
                part_directory,
                symlink_target,
            ):
                with self.subTest(retained=retained):
                    self.assertTrue(retained.exists())
            self.assertTrue(symlink_part.is_symlink())

    def test_cleanup_requires_a_provable_remote_content_length(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            incomplete = directory / "ChatGPT-incomplete.dmg.part"
            incomplete.write_bytes(b"short")

            for content_length in (None, True, 0, -1):
                with self.subTest(content_length=content_length):
                    with self.assertRaisesRegex(
                        ValueError,
                        "content length",
                    ):
                        self.module.cleanup_incomplete_parts(
                            directory,
                            content_length=content_length,
                        )
                    self.assertTrue(incomplete.exists())

    def test_remote_comparison_ignores_check_time_only(self) -> None:
        later = {**self.remote, "checked_at": "20260730T010000Z"}
        self.assertTrue(self.module.same_remote(self.remote, later))
        self.assertFalse(
            self.module.same_remote(
                self.remote,
                {**later, "etag": '"replacement"'},
            )
        )

    def test_release_identity_is_immutable_and_content_addressed(self) -> None:
        package_hash = hashlib.sha256(b"fixture package").hexdigest()
        identity = self.module.ReleaseIdentity(
            version="26.721.81911",
            build="5973",
            dmg_sha256=package_hash,
        )

        self.assertEqual(
            identity.release_root,
            (
                "artifacts/releases/26.721.81911/5973/"
                f"{package_hash}"
            ),
        )
        with self.assertRaises(AttributeError):
            identity.build = "5974"
        with self.assertRaises(AttributeError):
            del identity.build

    def test_release_identity_type_is_shared_by_archive_and_state_modules(
        self,
    ) -> None:
        import importlib

        archive_module = importlib.import_module("scripts.release_archive")
        identity_module = importlib.import_module("scripts.release_identity")

        self.assertIs(
            self.module.ReleaseIdentity,
            identity_module.ReleaseIdentity,
        )
        self.assertIs(
            archive_module.ReleaseIdentity,
            identity_module.ReleaseIdentity,
        )

    def test_release_identity_strictly_rejects_malformed_components(self) -> None:
        package_hash = hashlib.sha256(b"fixture package").hexdigest()
        valid = {
            "version": "26.721.81911",
            "build": "5973",
            "dmg_sha256": package_hash,
        }
        for override in (
            {"version": "../26.721.81911"},
            {"version": "26"},
            {"build": "0"},
            {"build": "05973"},
            {"build": 5973},
            {"dmg_sha256": package_hash.upper()},
            {"dmg_sha256": package_hash[:-1]},
        ):
            with self.subTest(override=override):
                with self.assertRaises(ValueError):
                    self.module.ReleaseIdentity(**{**valid, **override})

    def test_child_manifest_must_match_all_release_identity_fields(self) -> None:
        package_hash = hashlib.sha256(b"fixture package").hexdigest()
        identity = self.module.ReleaseIdentity(
            version="26.721.81911",
            build="5973",
            dmg_sha256=package_hash,
        )
        manifest = {
            "version": identity.version,
            "build": identity.build,
            "dmgSha256": identity.dmg_sha256,
        }

        self.module.require_matching_release_identity(
            manifest,
            identity,
            label="child manifest",
        )

        for key, replacement in (
            ("version", "26.721.81912"),
            ("build", "5974"),
            ("dmgSha256", hashlib.sha256(b"replacement").hexdigest()),
        ):
            with self.subTest(key=key):
                with self.assertRaisesRegex(ValueError, "does not match"):
                    self.module.require_matching_release_identity(
                        {**manifest, key: replacement},
                        identity,
                        label="child manifest",
                    )

    def test_local_current_requires_consistent_upgrade_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = self._seed_local_current(root)

            record = self.module.validate_local_current(root, latest)

            self.assertEqual(record["version"], "26.721.81911")
            self.assertEqual(record["build"], "5973")

    def test_local_current_rejects_legacy_record_without_archive_anchors(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = self._seed_local_current(
                root,
                content_addressed=False,
            )
            payload = json.loads(latest.read_text(encoding="utf-8"))
            self.assertNotIn("releaseRoot", payload)
            self.assertNotIn("releaseManifestSha256", payload)

            with self.assertRaisesRegex(
                ValueError,
                "release archive anchors are missing",
            ):
                self.module.validate_local_current(root, latest)

    def test_local_current_still_requires_exact_package_identity(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = self._seed_local_current(
                root,
                content_addressed=True,
            )
            imported = root / "artifacts/manifest-26.721.81911.json"
            payload = json.loads(imported.read_text(encoding="utf-8"))
            payload["dmg_sha256"] = hashlib.sha256(
                b"different package"
            ).hexdigest()
            imported.write_text(json.dumps(payload), encoding="utf-8")

            with self.assertRaisesRegex(
                ValueError,
                "live release record does not match archive: importManifest",
            ):
                self.module.validate_local_current(root, latest)

    def test_local_current_rejects_incomplete_release_archive_anchors(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            for anchor_name in (
                "releaseRoot",
                "releaseManifestSha256",
            ):
                with self.subTest(anchor_name=anchor_name):
                    root = Path(temporary) / anchor_name
                    latest = self._seed_local_current(
                        root,
                        content_addressed=False,
                    )
                    payload = json.loads(
                        latest.read_text(encoding="utf-8")
                    )
                    if anchor_name == "releaseRoot":
                        payload[anchor_name] = (
                            "artifacts/releases/"
                            f"{payload['version']}/"
                            f"{payload['build']}/"
                            f"{payload['sha256']}"
                        )
                    else:
                        payload[anchor_name] = "0" * 64
                    latest.write_text(
                        json.dumps(payload),
                        encoding="utf-8",
                    )

                    with self.assertRaisesRegex(
                        ValueError,
                        "release archive anchors are incomplete",
                    ):
                        self.module.validate_local_current(root, latest)

    def test_local_current_accepts_exact_content_addressed_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = self._seed_local_current(root, content_addressed=True)

            record = self.module.validate_local_current(root, latest)

            self.assertIn("releaseRoot", record)
            self.assertIn("releaseManifestSha256", record)

    def test_local_current_accepts_anchored_legacy_schema_one_archive(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = self._seed_local_current(root, content_addressed=True)
            self._convert_release_archive_to_legacy(root, latest)

            record = self.module.validate_local_current(root, latest)

            self.assertEqual(record["version"], "26.721.81911")

    def test_local_current_rejects_release_manifest_external_hash_mismatch(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = self._seed_local_current(root, content_addressed=True)
            payload = json.loads(latest.read_text(encoding="utf-8"))
            payload["releaseManifestSha256"] = "0" * 64
            latest.write_text(json.dumps(payload), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "manifest hash"):
                self.module.validate_local_current(root, latest)

    def test_local_current_fully_verifies_archived_payload_trees(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = self._seed_local_current(root, content_addressed=True)
            payload = json.loads(latest.read_text(encoding="utf-8"))
            archived_renderer = (
                root
                / payload["releaseRoot"]
                / "derived/appAsar/index.html"
            )
            archived_renderer.write_text(
                "<html>tampered archive</html>\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "tree hash mismatch"):
                self.module.validate_local_current(root, latest)

    def test_local_current_rejects_live_tree_content_mismatch(
        self,
    ) -> None:
        for tree_name, relative_path in (
            ("appAsar", "artifacts/app-asar-26.721.81911/index.html"),
            (
                "fullReverse",
                "artifacts/full-reverse-26.721.81911/"
                "app-asar/webview/index.html",
            ),
        ):
            with self.subTest(tree_name=tree_name):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    latest = self._seed_local_current(
                        root,
                        content_addressed=True,
                    )
                    (root / relative_path).write_text(
                        "<html>tampered live tree</html>\n",
                        encoding="utf-8",
                    )

                    with self.assertRaisesRegex(
                        ValueError,
                        "live release tree does not match archive",
                    ):
                        self.module.validate_local_current(root, latest)

    def test_local_current_rejects_live_record_content_mismatch(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = self._seed_local_current(
                root,
                content_addressed=True,
            )
            verification = (
                root / "artifacts/ipad-verified-26.721.81911.json"
            )
            payload = json.loads(
                verification.read_text(encoding="utf-8")
            )
            payload["unexpectedMutation"] = True
            verification.write_text(
                json.dumps(payload),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                ValueError,
                "live release record does not match archive",
            ):
                self.module.validate_local_current(root, latest)

    def test_local_current_rejects_release_root_path_escape_or_alias(self) -> None:
        for release_root in (
            "../outside",
            "artifacts/releases/26.721.81911/5973/../replacement",
            "/tmp/outside",
        ):
            with self.subTest(release_root=release_root):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    latest = self._seed_local_current(
                        root,
                        content_addressed=True,
                    )
                    payload = json.loads(
                        latest.read_text(encoding="utf-8")
                    )
                    payload["releaseRoot"] = release_root
                    latest.write_text(
                        json.dumps(payload),
                        encoding="utf-8",
                    )

                    with self.assertRaisesRegex(
                        ValueError,
                        "releaseRoot",
                    ):
                        self.module.validate_local_current(root, latest)

    def test_local_current_rejects_release_root_symlink_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "project"
            root.mkdir()
            latest = self._seed_local_current(
                root,
                content_addressed=True,
            )
            payload = json.loads(latest.read_text(encoding="utf-8"))
            release = root / payload["releaseRoot"]
            outside = base / "outside-release"
            release.rename(outside)
            release.symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(ValueError, "releaseRoot"):
                self.module.validate_local_current(root, latest)

    def test_local_current_rejects_release_manifest_build_or_sha_mismatch(
        self,
    ) -> None:
        for key, replacement in (
            ("build", "5974"),
            ("dmgSha256", hashlib.sha256(b"replacement").hexdigest()),
        ):
            with self.subTest(key=key):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    latest = self._seed_local_current(
                        root,
                        content_addressed=True,
                    )
                    latest_payload = json.loads(
                        latest.read_text(encoding="utf-8")
                    )
                    manifest = (
                        root
                        / latest_payload["releaseRoot"]
                        / "release-manifest.json"
                    )
                    payload = json.loads(
                        manifest.read_text(encoding="utf-8")
                    )
                    payload[key] = replacement
                    manifest.write_text(
                        json.dumps(payload),
                        encoding="utf-8",
                    )

                    with self.assertRaisesRegex(
                        ValueError,
                        "does not match",
                    ):
                        self.module.validate_local_current(root, latest)

    def test_local_current_rejects_missing_or_mismatched_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = self._seed_local_current(root)
            verified = root / "artifacts/ipad-verified-26.721.81911.json"
            verified.unlink()

            with self.assertRaisesRegex(ValueError, "is missing"):
                self.module.validate_local_current(root, latest)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = self._seed_local_current(root)
            imported = root / "artifacts/manifest-26.721.81911.json"
            payload = json.loads(imported.read_text(encoding="utf-8"))
            payload["build"] = "9999"
            imported.write_text(json.dumps(payload), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "does not match"):
                self.module.validate_local_current(root, latest)

    def test_local_current_rejects_malformed_latest_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            latest = self._seed_local_current(root)
            payload = json.loads(latest.read_text(encoding="utf-8"))
            payload["sha256"] = "not-a-hash"
            latest.write_text(json.dumps(payload), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "latest official"):
                self.module.validate_local_current(root, latest)


if __name__ == "__main__":
    unittest.main()
