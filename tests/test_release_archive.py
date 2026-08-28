import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest

from scripts.release_identity import ReleaseIdentity
from scripts.build_desktop_ui_parity import SURFACE_DEFINITIONS
from scripts.release_archive import (
    MANIFEST_NAME,
    _require_lexical_relative_path,
    _tree_identity,
    archive_release,
    verify_release_archive,
    verify_live_release_snapshot,
)


XCUI_LOG_FILES = {
    "python": "python-tests.log",
    "swift": "swift-tests.log",
    "rust": "rust-tests.log",
    "xcui": "xcui-tests.log",
    "device-build": "device-build.log",
    "device-surface": "device-surface.json",
}


class ReleaseArchiveFixture:
    version = "26.721.81911"
    build = "5973"

    def __init__(
        self,
        temporary: str,
        *,
        include_entitlements: bool = True,
    ) -> None:
        self.root = Path(temporary) / "project"
        self.root.mkdir()
        self.dmg = self.root / ".downloads/ChatGPT-fixture.dmg"
        self.dmg.parent.mkdir()
        self.dmg.write_bytes(b"complete official fixture package\n")
        self.identity = ReleaseIdentity(
            self.version,
            self.build,
            hashlib.sha256(self.dmg.read_bytes()).hexdigest(),
        )
        self.app_asar = self.root / f"artifacts/app-asar-{self.version}"
        self.full_reverse = (
            self.root / f"artifacts/full-reverse-{self.version}"
        )
        self.version_root = self.root / f"versions/{self.version}"
        self.parity_evidence = (
            self.root / f"artifacts/parity-evidence/{self.version}"
        )
        self._seed_trees()
        self._seed_records(include_entitlements=include_entitlements)

    @property
    def release_root(self) -> Path:
        return self.root / self.identity.release_root

    @property
    def manifest_path(self) -> Path:
        return self.release_root / MANIFEST_NAME

    def read_manifest(self) -> dict:
        return json.loads(self.manifest_path.read_text(encoding="utf-8"))

    def write_manifest(self, value: dict) -> None:
        self.manifest_path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def read_archived_json(self, relative: str) -> dict:
        return json.loads(
            (self.release_root / relative).read_text(encoding="utf-8")
        )

    def write_archived_json(self, relative: str, value: dict) -> None:
        self._write_json(self.release_root / relative, value)

    @staticmethod
    def _write_json(path: Path, value: dict) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    @staticmethod
    def _sha256(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def _xcresult_tree_sha256(root: Path) -> str:
        digest = hashlib.sha256()
        for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                digest.update(b"L\0")
                digest.update(relative.encode())
                digest.update(b"\0")
                digest.update(os.readlink(path).encode())
                digest.update(b"\0")
            elif path.is_dir():
                digest.update(b"D\0")
                digest.update(relative.encode())
                digest.update(b"\0")
            elif path.is_file():
                digest.update(b"F\0")
                digest.update(relative.encode())
                digest.update(b"\0")
                digest.update(path.read_bytes())
                digest.update(b"\0")
            else:
                raise AssertionError(f"unsupported fixture entry: {relative}")
        return digest.hexdigest()

    def _evidence_entry(self, path: Path) -> dict[str, str]:
        return {
            "path": path.relative_to(self.root).as_posix(),
            "sha256": self._sha256(path),
        }

    def _map_evidence_paths_to_archive(self, value: object) -> object:
        parity_prefix = f"artifacts/parity-evidence/{self.version}/"
        contract_path = f"versions/{self.version}/desktop-ui-parity.json"
        if isinstance(value, list):
            return [self._map_evidence_paths_to_archive(item) for item in value]
        if isinstance(value, dict):
            mapped = {
                key: self._map_evidence_paths_to_archive(item)
                for key, item in value.items()
            }
            path = mapped.get("path")
            if isinstance(path, str):
                if path.startswith(parity_prefix):
                    mapped["path"] = (
                        "derived/parityEvidence/" + path[len(parity_prefix):]
                    )
                elif path == contract_path:
                    mapped["path"] = (
                        "derived/version/desktop-ui-parity.json"
                    )
            return mapped
        return value

    def refresh_archive_manifest(
        self,
        *,
        trees: tuple[str, ...] = (),
        records: tuple[str, ...] = (),
    ) -> None:
        manifest = self.read_manifest()
        for name in trees:
            row = manifest["derived"].get(name)
            if row is None:
                continue
            path = self.release_root / row["path"]
            manifest["derived"][name] = {
                "path": row["path"],
                **_tree_identity(path),
            }
        for name in records:
            row = manifest["records"][name]
            path = self.release_root / row["path"]
            manifest["records"][name] = {
                "path": row["path"],
                "bytes": path.stat().st_size,
                "sha256": self._sha256(path),
            }
        self.write_manifest(manifest)

    def prepare_internal_verifier_archive(self) -> None:
        archive_release(self.root, self.identity, self.dmg)
        archived_parity = self.release_root / "derived/parityEvidence"
        if not archived_parity.exists():
            shutil.copytree(
                self.parity_evidence,
                archived_parity,
                symlinks=True,
            )

        contract_relative = "derived/version/desktop-ui-parity.json"
        contract = self.read_archived_json(contract_relative)
        mapped_contract = self._map_evidence_paths_to_archive(contract)
        if not isinstance(mapped_contract, dict):
            raise AssertionError("mapped parity fixture is malformed")
        self.write_archived_json(contract_relative, mapped_contract)

        verification_relative = (
            f"records/ipad-verified-{self.version}.json"
        )
        verification = self.read_archived_json(verification_relative)
        mapped_verification = self._map_evidence_paths_to_archive(
            verification
        )
        if not isinstance(mapped_verification, dict):
            raise AssertionError("mapped verification fixture is malformed")
        mapped_verification["xcuiEvidence"]["parityContract"][
            "sha256"
        ] = self._sha256(self.release_root / contract_relative)
        self.write_archived_json(
            verification_relative,
            mapped_verification,
        )
        self.refresh_archive_manifest(
            trees=("version", "parityEvidence"),
            records=("ipadVerification",),
        )
        verify_release_archive(self.root, self.identity)

    def archived_evidence_targets(
        self,
    ) -> dict[str, tuple[str, Path, str]]:
        verification = self.release_root / "derived/parityEvidence/verification"
        targets: dict[str, tuple[str, Path, str]] = {
            "summary": (
                "file",
                verification / "xcui-summary.json",
                "parityEvidence",
            ),
            "desktop-parity-contract": (
                "file",
                self.release_root / "derived/version/desktop-ui-parity.json",
                "version",
            ),
            "xcresult": (
                "tree",
                verification / "CodexPadUITests.xcresult",
                "parityEvidence",
            ),
        }
        targets.update(
            {
                f"log-{name}": (
                    "file",
                    verification / filename,
                    "parityEvidence",
                )
                for name, filename in XCUI_LOG_FILES.items()
            }
        )
        return targets

    def _seed_parity_evidence(self) -> None:
        verification = self.parity_evidence / "verification"
        verification.mkdir(parents=True)
        for name, filename in XCUI_LOG_FILES.items():
            path = verification / filename
            if filename.endswith(".json"):
                self._write_json(path, {"status": "passed", "kind": name})
            else:
                path.write_text(f"{name}: passed\n", encoding="utf-8")

        self._write_json(
            verification / "xcui-summary.json",
            {
                "result": "Passed",
                "totalTestCount": 3,
                "passedTests": 3,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
                "startTime": 1.0,
                "finishTime": 2.0,
            },
        )
        xcresult = verification / "CodexPadUITests.xcresult"
        (xcresult / "Data").mkdir(parents=True)
        (xcresult / "Info.plist").write_bytes(b"xcresult info fixture\n")
        (xcresult / "Data/result.bin").write_bytes(b"xcresult data fixture\n")

        surface = self.parity_evidence / "S01"
        surface.mkdir()
        for filename in (
            "official-desktop.png",
            "ipad.png",
            "pixel-diff.png",
        ):
            (surface / filename).write_bytes(
                f"{filename} fixture\n".encode("ascii")
            )
        self._write_json(
            surface / "capture-metadata.json",
            {
                "schemaVersion": 1,
                "desktopVersion": self.version,
                "desktopBuild": self.build,
                "surfaceId": "S01",
            },
        )
        self._write_json(
            self.parity_evidence / "implementation-evidence.json",
            {
                "schemaVersion": 1,
                "desktopVersion": self.version,
                "desktopBuild": self.build,
            },
        )
        self._write_json(
            self.parity_evidence / "capture-manifest.json",
            {
                "schemaVersion": 1,
                "desktopVersion": self.version,
                "desktopBuild": self.build,
            },
        )

    def _desktop_parity_contract(self) -> dict:
        verification = self.parity_evidence / "verification"
        surface = self.parity_evidence / "S01"
        automated = [
            self._evidence_entry(verification / XCUI_LOG_FILES[name])
            for name in ("python", "swift", "rust", "xcui")
        ]
        device = [
            self._evidence_entry(
                verification / XCUI_LOG_FILES["device-build"]
            ),
            self._evidence_entry(
                verification / XCUI_LOG_FILES["device-surface"]
            ),
            self._evidence_entry(surface / "ipad.png"),
        ]
        visual = [
            self._evidence_entry(surface / "official-desktop.png"),
            self._evidence_entry(surface / "ipad.png"),
            self._evidence_entry(surface / "pixel-diff.png"),
            self._evidence_entry(surface / "capture-metadata.json"),
        ]
        runtime = {
            "officialDesktop": self._evidence_entry(
                surface / "official-desktop.png"
            ),
            "ipad": self._evidence_entry(surface / "ipad.png"),
            "pixelDiff": self._evidence_entry(surface / "pixel-diff.png"),
        }
        surfaces = []
        for index in range(1, 11):
            surfaces.append(
                {
                    "id": f"S{index:02d}",
                    "category": "fixture",
                    "name": f"Fixture surface {index}",
                    "routes": ["/fixture"],
                    "requiredStates": ["passed"],
                    "referenceStatus": "reference-indexed",
                    "desktopEvidence": [
                        {
                            "glob": "reference.js",
                            "file": "webview/assets/reference.js",
                            "bytes": len(b"desktop reference fixture\n"),
                            "sha256": hashlib.sha256(
                                b"desktop reference fixture\n"
                            ).hexdigest(),
                        }
                    ],
                    "implementationStatus": "matched",
                    "automatedTests": automated,
                    "simulatorEvidence": [],
                    "deviceEvidence": device,
                    "visualEvidence": visual,
                    "runtimeCaptureStatus": "runtime-capture-matched",
                    "runtimeCaptureEvidence": runtime,
                }
            )
        return {
            "schemaVersion": 2,
            "desktopVersion": self.version,
            "desktopBuild": self.build,
            "sourceIdentity": {
                "dmgSha256": self.identity.dmg_sha256,
                "desktopSurfaceTreeSha256": "1" * 64,
                "recoveredSourceIndexSha256": "2" * 64,
            },
            "target": "desktop-identical-ipad-surface",
            "visualContract": {
                "source": "visual/reference-inventory.json",
                "requiredComparison": (
                    "same-state official desktop / iPad / pixel diff"
                ),
                "status": "matched",
            },
            "summary": {
                "surfaceCount": 10,
                "referenceIndexed": 10,
                "missingReference": 0,
                "implementationMatched": 10,
                "implementationUnmatched": 0,
                "runtimeCaptureMatched": 10,
                "runtimeCapturePending": 0,
            },
            "surfaces": surfaces,
        }

    def _desktop_interaction_inventory(self) -> dict:
        payload = b"desktop reference fixture\n"
        digest = hashlib.sha256(payload).hexdigest()
        surfaces = []
        for definition in SURFACE_DEFINITIONS:
            surface_id = str(definition["id"])
            occurrence = {
                "file": "webview/assets/reference.js",
                "fileSha256": digest,
                "byteOffset": 0,
            }
            interaction = {
                "kind": "button",
                "id": f"fixture.{surface_id}.button",
                "defaultMessage": f"Fixture {surface_id}",
                "description": "Button label for fixture interaction",
                "occurrences": [occurrence],
            }
            surfaces.append(
                {
                    "id": surface_id,
                    "category": definition["category"],
                    "name": definition["name"],
                    "routes": list(definition["routes"]),
                    "requiredStates": list(definition["requiredStates"]),
                    "referenceStatus": "reference-indexed",
                    "missingEvidenceGlobs": [],
                    "sourceFiles": [
                        {
                            "path": "webview/assets/reference.js",
                            "bytes": len(payload),
                            "sha256": digest,
                        }
                    ],
                    "messageCount": 1,
                    "interactionCount": 1,
                    "messages": [
                        {
                            key: value
                            for key, value in interaction.items()
                            if key != "kind"
                        }
                    ],
                    "interactions": [interaction],
                }
            )
        return {
            "schemaVersion": 1,
            "desktopVersion": self.version,
            "desktopBuild": self.build,
            "sourceIdentity": {
                "desktopSurfaceTreeSha256": "1" * 64,
            },
            "extractionMode": "static-official-renderer-no-execution",
            "summary": {
                "surfaceCount": 10,
                "referenceIndexed": 10,
                "missingReference": 0,
                "evidenceFileCount": 1,
                "messageCount": 10,
                "interactionCount": 10,
                "surfacesWithInteractions": 10,
            },
            "surfaces": surfaces,
        }

    def _seed_trees(self) -> None:
        self._seed_parity_evidence()
        (self.app_asar / "webview").mkdir(parents=True)
        (self.app_asar / "empty-directory").mkdir()
        (self.app_asar / "webview/index.html").write_text(
            "<main>fixture renderer</main>\n",
            encoding="utf-8",
        )

        framework = (
            self.full_reverse
            / "bundle/Fixture.framework"
        )
        binary = framework / "Versions/A/Fixture"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"fixture framework binary\n")
        binary.chmod(0o755)
        (framework / "Versions/Current").symlink_to("A")
        (framework / "Fixture").symlink_to("Versions/Current/Fixture")
        self._write_json(
            self.full_reverse / "full-reverse-manifest.json",
            {
                "schemaVersion": 1,
                "version": self.version,
                "build": self.build,
            },
        )
        recovered_assets = (
            self.full_reverse
            / "recovered-electron-source/webview/assets"
        )
        recovered_assets.mkdir(parents=True)
        (recovered_assets / "reference.js").write_bytes(
            b"desktop reference fixture\n"
        )

        self.version_root.mkdir(parents=True)
        self._write_json(
            self.version_root / "manifest.json",
            {
                "schemaVersion": 1,
                "version": self.version,
                "build": self.build,
                "dmgSha256": self.identity.dmg_sha256,
            },
        )
        self._write_json(
            self.version_root / "desktop-ui-parity.json",
            self._desktop_parity_contract(),
        )
        self._write_json(
            self.version_root / "desktop-interaction-inventory.json",
            self._desktop_interaction_inventory(),
        )

    def _seed_records(self, *, include_entitlements: bool) -> None:
        artifacts = self.root / "artifacts"
        self._write_json(
            artifacts / f"manifest-{self.version}.json",
            {
                "version": self.version,
                "build": self.build,
                "dmg_sha256": self.identity.dmg_sha256,
                "extracted_path": f"artifacts/app-asar-{self.version}",
                "file_count": 1,
            },
        )
        self._write_json(
            artifacts / f"ipad-upgrade-{self.version}.json",
            {
                "desktopVersion": self.version,
                "desktopBuild": self.build,
                "modelCatalogGenerated": True,
                "buildMetadataGenerated": True,
                "codexCoreUpgraded": True,
                "xcframeworkRebuilt": True,
            },
        )
        verification = self.parity_evidence / "verification"
        xcresult = verification / "CodexPadUITests.xcresult"
        verification_record = {
                "desktopVersion": self.version,
                "desktopBuild": self.build,
                "productName": "Codex for ipad",
                "bundleVersionMatched": True,
                "bundleBuildMatched": True,
                "rustTests": "passed",
                "swiftTests": "passed",
                "swiftTestCount": 7,
                "xcuiTests": "passed",
                "xcuiTestCount": 3,
                "physicalDeviceTests": "passed",
                "physicalDeviceUDID": "00000000-0000000000000000",
                "physicalDeviceName": "Example iPad Pro",
                "physicalDeviceModel": "iPad Pro (12.9-inch) (5th generation)",
                "physicalDeviceOS": "26.0",
                "deviceBuild": "passed",
                "deviceArchitecture": "arm64",
                "desktopSurfaceCompleteTree": "passed",
                "sourceIdentity": {
                    "dmgSha256": self.identity.dmg_sha256,
                },
                "desktopSurface": {
                    "deviceBundleVerified": True,
                },
                "xcuiEvidence": {
                    "result": "Passed",
                    "totalTestCount": 3,
                    "passedTests": 3,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                    "startTime": 1.0,
                    "finishTime": 2.0,
                    "generatedAt": "2026-08-13T06:00:00Z",
                    "gitHead": "8" * 40,
                    "parityContract": self._evidence_entry(
                        self.version_root / "desktop-ui-parity.json"
                    ),
                    "summary": self._evidence_entry(
                        verification / "xcui-summary.json"
                    ),
                    "xcresult": {
                        "path": xcresult.relative_to(self.root).as_posix(),
                        "sha256": self._xcresult_tree_sha256(xcresult),
                        "hashAlgorithm": "sha256-xcresult-tree-v1",
                    },
                    "logs": {
                        name: self._evidence_entry(verification / filename)
                        for name, filename in XCUI_LOG_FILES.items()
                    },
                },
            }
        self._write_json(
            artifacts / f"ipad-verified-{self.version}.json",
            verification_record,
        )
        with (
            artifacts / f"Info-{self.version}.plist"
        ).open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleShortVersionString": self.version,
                    "CFBundleVersion": self.build,
                },
                stream,
            )
        if include_entitlements:
            with (
                artifacts / f"entitlements-{self.version}.plist"
            ).open("wb") as stream:
                plistlib.dump(
                    {"com.apple.security.app-sandbox": True},
                    stream,
                )


class ReleaseArchiveTests(unittest.TestCase):
    @staticmethod
    def _path_entries(value: object) -> list[dict]:
        entries: list[dict] = []
        if isinstance(value, list):
            for item in value:
                entries.extend(ReleaseArchiveTests._path_entries(item))
        elif isinstance(value, dict):
            if "path" in value:
                entries.append(value)
            for item in value.values():
                entries.extend(ReleaseArchiveTests._path_entries(item))
        return entries

    @staticmethod
    def _verification_evidence_entry(
        verification: dict,
        label: str,
    ) -> dict:
        evidence = verification["xcuiEvidence"]
        if label == "summary":
            return evidence["summary"]
        if label == "desktop-parity-contract":
            return evidence["parityContract"]
        if label == "xcresult":
            return evidence["xcresult"]
        return evidence["logs"][label.removeprefix("log-")]

    def test_archive_includes_self_contained_mapped_parity_evidence(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)

            manifest = archive_release(
                fixture.root,
                fixture.identity,
                fixture.dmg,
            )

            self.assertEqual(manifest["schemaVersion"], 2)
            parity_row = manifest["derived"]["parityEvidence"]
            self.assertEqual(
                parity_row["path"],
                "derived/parityEvidence",
            )
            self.assertEqual(
                {
                    key: parity_row[key]
                    for key in (
                        "rootMode",
                        "directoryCount",
                        "fileCount",
                        "symlinkCount",
                        "totalBytes",
                        "treeSha256",
                    )
                },
                _tree_identity(
                    fixture.release_root / "derived/parityEvidence"
                ),
            )

            archived_contract = fixture.read_archived_json(
                "derived/version/desktop-ui-parity.json"
            )
            archived_verification = fixture.read_archived_json(
                f"records/ipad-verified-{fixture.version}.json"
            )
            contract_paths = self._path_entries(archived_contract)
            verification_paths = self._path_entries(
                archived_verification["xcuiEvidence"]
            )
            self.assertTrue(contract_paths)
            self.assertEqual(
                {
                    entry["path"].split("/", 2)[0:2][1]
                    for entry in contract_paths
                },
                {"parityEvidence"},
            )
            self.assertEqual(
                archived_verification["xcuiEvidence"]["parityContract"][
                    "path"
                ],
                "derived/version/desktop-ui-parity.json",
            )
            for entry in contract_paths + verification_paths:
                relative = Path(entry["path"])
                self.assertFalse(relative.is_absolute())
                self.assertNotIn("..", relative.parts)
                target = fixture.release_root / relative
                if entry is archived_verification["xcuiEvidence"][
                    "xcresult"
                ]:
                    self.assertTrue(target.is_dir())
                    self.assertEqual(
                        fixture._xcresult_tree_sha256(target),
                        entry["sha256"],
                    )
                else:
                    self.assertTrue(target.is_file())
                    self.assertEqual(fixture._sha256(target), entry["sha256"])
            self.assertFalse(
                any(
                    entry["path"].startswith("artifacts/parity-evidence/")
                    or entry["path"].startswith("versions/")
                    for entry in contract_paths + verification_paths
                )
            )

            shutil.rmtree(fixture.parity_evidence)
            shutil.rmtree(fixture.version_root)
            self.assertEqual(
                verify_release_archive(fixture.root, fixture.identity),
                manifest,
            )

    def test_archive_requires_internal_official_interaction_inventory(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)
            fixture.prepare_internal_verifier_archive()
            inventory = (
                fixture.release_root
                / "derived/version/desktop-interaction-inventory.json"
            )
            inventory.unlink()
            fixture.refresh_archive_manifest(trees=("version",))

            with self.assertRaisesRegex(
                ValueError,
                "desktop interaction inventory",
            ):
                verify_release_archive(fixture.root, fixture.identity)

    def test_new_archive_rejects_simulator_only_verification(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)
            record_path = (
                fixture.root
                / f"artifacts/ipad-verified-{fixture.version}.json"
            )
            record = json.loads(record_path.read_text(encoding="utf-8"))
            record.pop("physicalDeviceTests")
            record["simulatorBuild"] = "passed"
            record["desktopSurface"]["simulatorBundleVerified"] = True
            fixture._write_json(record_path, record)

            with self.assertRaisesRegex(
                ValueError,
                "physicalDeviceTests",
            ):
                archive_release(
                    fixture.root,
                    fixture.identity,
                    fixture.dmg,
                )

    def test_legacy_schema_one_archive_is_read_only_compatible(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)
            manifest = archive_release(
                fixture.root,
                fixture.identity,
                fixture.dmg,
            )

            parity_tree = fixture.release_root / "derived/parityEvidence"
            if parity_tree.exists():
                shutil.rmtree(parity_tree)
            archived_version = fixture.release_root / "derived/version"
            shutil.rmtree(archived_version)
            shutil.copytree(fixture.version_root, archived_version)
            archived_verification = (
                fixture.release_root
                / f"records/ipad-verified-{fixture.version}.json"
            )
            shutil.copy2(
                fixture.root
                / f"artifacts/ipad-verified-{fixture.version}.json",
                archived_verification,
            )
            manifest["schemaVersion"] = 1
            manifest["derived"].pop("parityEvidence", None)
            fixture.write_manifest(manifest)
            fixture.refresh_archive_manifest(
                trees=("version",),
                records=("ipadVerification",),
            )
            (fixture.release_root / "derived/appAsar/.DS_Store").write_bytes(
                b"finder cache"
            )
            legacy_cache = (
                fixture.release_root
                / "derived/fullReverse/bundle/Fixture.framework/"
                "Versions/A/__pycache__/client.pyc"
            )
            legacy_cache.parent.mkdir(parents=True)
            legacy_cache.write_bytes(b"python bytecode cache")
            legacy = fixture.read_manifest()
            before = fixture.manifest_path.read_bytes()

            self.assertEqual(
                verify_release_archive(fixture.root, fixture.identity),
                legacy,
            )
            with self.assertRaisesRegex(ValueError, "conflicts"):
                archive_release(
                    fixture.root,
                    fixture.identity,
                    fixture.dmg,
                )
            self.assertEqual(fixture.manifest_path.read_bytes(), before)

    def test_new_archive_excludes_volatile_derived_cache_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)
            (fixture.app_asar / ".DS_Store").write_bytes(b"finder cache")
            cache = (
                fixture.full_reverse
                / "bundle/Fixture.framework/Versions/A/"
                "__pycache__/client.pyc"
            )
            cache.parent.mkdir(parents=True)
            cache.write_bytes(b"python bytecode cache")

            manifest = archive_release(
                fixture.root,
                fixture.identity,
                fixture.dmg,
            )

            self.assertFalse(
                (
                    fixture.release_root
                    / "derived/appAsar/.DS_Store"
                ).exists()
            )
            self.assertFalse(
                (
                    fixture.release_root
                    / "derived/fullReverse/bundle/Fixture.framework/"
                    "Versions/A/__pycache__"
                ).exists()
            )
            self.assertEqual(
                verify_release_archive(fixture.root, fixture.identity),
                manifest,
            )

    def test_current_archive_rejects_post_archive_volatile_pollution(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)
            archive_release(fixture.root, fixture.identity, fixture.dmg)
            (
                fixture.release_root / "derived/appAsar/.DS_Store"
            ).write_bytes(b"post archive finder cache")

            with self.assertRaisesRegex(ValueError, "tree hash mismatch"):
                verify_release_archive(fixture.root, fixture.identity)

    def test_live_snapshot_ignores_only_volatile_derived_cache_files(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)
            manifest = archive_release(
                fixture.root,
                fixture.identity,
                fixture.dmg,
            )
            (fixture.app_asar / ".DS_Store").write_bytes(b"finder cache")
            cache = (
                fixture.full_reverse
                / "bundle/Fixture.framework/Versions/A/"
                "__pycache__/client.pyc"
            )
            cache.parent.mkdir(parents=True)
            cache.write_bytes(b"python bytecode cache")

            verify_live_release_snapshot(
                fixture.root,
                fixture.identity,
                manifest,
            )

            (fixture.app_asar / "webview/index.html").write_text(
                "<main>tampered renderer</main>\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                ValueError,
                "live release tree does not match archive",
            ):
                verify_live_release_snapshot(
                    fixture.root,
                    fixture.identity,
                    manifest,
                )

    def test_verifier_rejects_missing_or_tampered_internal_evidence(
        self,
    ) -> None:
        for attack in ("missing", "tampered"):
            for label in (
                "summary",
                *(f"log-{name}" for name in XCUI_LOG_FILES),
                "desktop-parity-contract",
                "xcresult",
            ):
                with self.subTest(attack=attack, evidence=label):
                    with tempfile.TemporaryDirectory() as temporary:
                        fixture = ReleaseArchiveFixture(temporary)
                        fixture.prepare_internal_verifier_archive()
                        kind, target, tree = fixture.archived_evidence_targets()[
                            label
                        ]

                        if attack == "missing":
                            if kind == "tree":
                                shutil.rmtree(target)
                            else:
                                target.unlink()
                        elif kind == "tree":
                            (target / "Data/result.bin").write_bytes(
                                b"tampered XCResult data\n"
                            )
                        else:
                            target.write_bytes(b"tampered evidence\n")
                        fixture.refresh_archive_manifest(trees=(tree,))

                        with self.assertRaises(ValueError):
                            verify_release_archive(
                                fixture.root,
                                fixture.identity,
                            )

    def test_verifier_rejects_symlinked_internal_evidence(self) -> None:
        for label in (
            "summary",
            *(f"log-{name}" for name in XCUI_LOG_FILES),
            "desktop-parity-contract",
            "xcresult",
        ):
            with self.subTest(evidence=label):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = ReleaseArchiveFixture(temporary)
                    fixture.prepare_internal_verifier_archive()
                    kind, target, tree = fixture.archived_evidence_targets()[
                        label
                    ]

                    if kind == "tree":
                        substitute = target.parent / "XCResultSubstitute"
                        substitute.mkdir()
                        (substitute / "Info.plist").write_bytes(
                            b"substitute XCResult\n"
                        )
                        shutil.rmtree(target)
                        target.symlink_to(
                            substitute.name,
                            target_is_directory=True,
                        )
                    else:
                        substitute = target.parent / f"{target.name}.source"
                        substitute.write_bytes(target.read_bytes())
                        target.unlink()
                        target.symlink_to(substitute.name)
                    fixture.refresh_archive_manifest(trees=(tree,))

                    with self.assertRaises(ValueError):
                        verify_release_archive(
                            fixture.root,
                            fixture.identity,
                        )

    def test_verifier_rejects_symlink_nested_inside_xcresult(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)
            fixture.prepare_internal_verifier_archive()
            xcresult = (
                fixture.release_root
                / "derived/parityEvidence/verification/"
                "CodexPadUITests.xcresult"
            )
            nested = xcresult / "Data/result.bin"
            nested.unlink()
            nested.symlink_to("../Info.plist")

            verification_relative = (
                f"records/ipad-verified-{fixture.version}.json"
            )
            verification = fixture.read_archived_json(
                verification_relative
            )
            verification["xcuiEvidence"]["xcresult"]["sha256"] = (
                fixture._xcresult_tree_sha256(xcresult)
            )
            fixture.write_archived_json(
                verification_relative,
                verification,
            )
            fixture.refresh_archive_manifest(
                trees=("parityEvidence",),
                records=("ipadVerification",),
            )

            with self.assertRaisesRegex(ValueError, "symlink"):
                verify_release_archive(
                    fixture.root,
                    fixture.identity,
                )

    def test_verifier_rejects_internal_evidence_paths_outside_archive(
        self,
    ) -> None:
        for label in (
            "summary",
            *(f"log-{name}" for name in XCUI_LOG_FILES),
            "desktop-parity-contract",
            "xcresult",
        ):
            with self.subTest(evidence=label):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = ReleaseArchiveFixture(temporary)
                    fixture.prepare_internal_verifier_archive()
                    verification_relative = (
                        f"records/ipad-verified-{fixture.version}.json"
                    )
                    verification = fixture.read_archived_json(
                        verification_relative
                    )
                    entry = self._verification_evidence_entry(
                        verification,
                        label,
                    )
                    entry["path"] = "../../../../outside-release-evidence"
                    fixture.write_archived_json(
                        verification_relative,
                        verification,
                    )
                    fixture.refresh_archive_manifest(
                        records=("ipadVerification",),
                    )

                    with self.assertRaises(ValueError):
                        verify_release_archive(
                            fixture.root,
                            fixture.identity,
                        )

    def test_verifier_rejects_noncanonical_internal_evidence_paths(
        self,
    ) -> None:
        for malicious in (
            "/tmp/outside-release-evidence",
            "derived/parityEvidence//verification/xcui-summary.json",
            "derived/parityEvidence/./verification/xcui-summary.json",
            r"derived\parityEvidence\verification\xcui-summary.json",
            "",
        ):
            with self.subTest(path=malicious):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = ReleaseArchiveFixture(temporary)
                    fixture.prepare_internal_verifier_archive()
                    relative = (
                        f"records/ipad-verified-{fixture.version}.json"
                    )
                    verification = fixture.read_archived_json(relative)
                    verification["xcuiEvidence"]["summary"][
                        "path"
                    ] = malicious
                    fixture.write_archived_json(relative, verification)
                    fixture.refresh_archive_manifest(
                        records=("ipadVerification",),
                    )

                    with self.assertRaises(ValueError):
                        verify_release_archive(
                            fixture.root,
                            fixture.identity,
                        )

    def test_lexical_path_validator_rejects_raw_dot_components(self) -> None:
        with self.assertRaisesRegex(ValueError, "escapes"):
            _require_lexical_relative_path(
                "derived/parityEvidence/./verification/xcui-summary.json",
                label="fixture evidence",
            )

    def test_archive_survives_transfer_cleanup_and_preserves_symlinks(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)

            manifest = archive_release(
                fixture.root,
                fixture.identity,
                fixture.dmg,
            )

            self.assertEqual(
                fixture.release_root,
                fixture.root / fixture.identity.release_root,
            )
            self.assertEqual(manifest, fixture.read_manifest())
            self.assertEqual(
                (
                    fixture.release_root
                    / "official/ChatGPT.dmg"
                ).read_bytes(),
                fixture.dmg.read_bytes(),
            )
            current = (
                fixture.release_root
                / "derived/fullReverse/bundle/"
                "Fixture.framework/Versions/Current"
            )
            executable = (
                fixture.release_root
                / "derived/fullReverse/bundle/"
                "Fixture.framework/Fixture"
            )
            self.assertTrue(current.is_symlink())
            self.assertEqual(os.readlink(current), "A")
            self.assertTrue(executable.is_symlink())
            self.assertEqual(
                os.readlink(executable),
                "Versions/Current/Fixture",
            )
            self.assertGreater(
                manifest["derived"]["fullReverse"]["symlinkCount"],
                0,
            )

            fixture.dmg.unlink()

            self.assertEqual(
                verify_release_archive(
                    fixture.root,
                    fixture.identity,
                ),
                manifest,
            )

    def test_entitlements_are_optional_but_required_records_are_not(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(
                temporary,
                include_entitlements=False,
            )
            archive_release(fixture.root, fixture.identity, fixture.dmg)
            manifest = fixture.read_manifest()
            self.assertNotIn("entitlements", manifest["records"])
            self.assertNotIn(
                "desktopParityVerification",
                manifest["records"],
            )
            verify_release_archive(fixture.root, fixture.identity)

            manifest["records"].pop("ipadVerification")
            fixture.write_manifest(manifest)
            with self.assertRaisesRegex(ValueError, "incomplete"):
                verify_release_archive(fixture.root, fixture.identity)

    def test_archive_is_idempotent_and_conflicting_source_never_replaces_it(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)
            first = archive_release(
                fixture.root,
                fixture.identity,
                fixture.dmg,
            )
            archived_renderer = (
                fixture.release_root
                / "derived/appAsar/webview/index.html"
            )
            archived_before = archived_renderer.read_bytes()

            second = archive_release(
                fixture.root,
                fixture.identity,
                fixture.dmg,
            )
            self.assertEqual(second, first)

            (fixture.app_asar / "webview/index.html").write_text(
                "<main>different source</main>\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "conflicts"):
                archive_release(
                    fixture.root,
                    fixture.identity,
                    fixture.dmg,
                )
            self.assertEqual(archived_renderer.read_bytes(), archived_before)
            self.assertEqual(
                verify_release_archive(
                    fixture.root,
                    fixture.identity,
                ),
                first,
            )

    def test_wrong_package_hash_creates_no_release_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)
            wrong = ReleaseIdentity(
                fixture.version,
                fixture.build,
                "0" * 64,
            )

            with self.assertRaisesRegex(ValueError, "hash"):
                archive_release(fixture.root, wrong, fixture.dmg)

            self.assertFalse((fixture.root / wrong.release_root).exists())

    def test_archive_tampering_is_detected(self) -> None:
        cases = (
            "official",
            "derived-file",
            "symlink",
            "record",
        )
        for case in cases:
            with self.subTest(case=case):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = ReleaseArchiveFixture(temporary)
                    archive_release(
                        fixture.root,
                        fixture.identity,
                        fixture.dmg,
                    )
                    if case == "official":
                        path = (
                            fixture.release_root
                            / "official/ChatGPT.dmg"
                        )
                        path.write_bytes(b"tampered package\n")
                    elif case == "derived-file":
                        path = (
                            fixture.release_root
                            / "derived/appAsar/webview/index.html"
                        )
                        path.write_text(
                            "tampered renderer\n",
                            encoding="utf-8",
                        )
                    elif case == "symlink":
                        path = (
                            fixture.release_root
                            / "derived/fullReverse/bundle/"
                            "Fixture.framework/Versions/Current"
                        )
                        path.unlink()
                        path.symlink_to("B")
                    else:
                        path = (
                            fixture.release_root
                            / "records/"
                            f"ipad-verified-{fixture.version}.json"
                        )
                        path.write_text("{}\n", encoding="utf-8")

                    with self.assertRaises(ValueError):
                        verify_release_archive(
                            fixture.root,
                            fixture.identity,
                        )

    def test_manifest_cannot_redirect_official_or_record_paths(self) -> None:
        cases = ("official-absolute", "official-parent", "record-parent")
        for case in cases:
            with self.subTest(case=case):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = ReleaseArchiveFixture(temporary)
                    archive_release(
                        fixture.root,
                        fixture.identity,
                        fixture.dmg,
                    )
                    manifest = fixture.read_manifest()
                    if case == "official-absolute":
                        manifest["officialPackage"]["path"] = str(
                            fixture.dmg
                        )
                    elif case == "official-parent":
                        manifest["officialPackage"]["path"] = (
                            "../../../../../../.downloads/"
                            "ChatGPT-fixture.dmg"
                        )
                    else:
                        manifest["records"]["infoPlist"]["path"] = (
                            "records/../release-manifest.json"
                        )
                    fixture.write_manifest(manifest)

                    with self.assertRaises(ValueError):
                        verify_release_archive(
                            fixture.root,
                            fixture.identity,
                        )

    def test_manifest_record_set_and_strict_metric_types_are_enforced(
        self,
    ) -> None:
        cases = ("extra-record", "missing-record", "boolean-metric")
        for case in cases:
            with self.subTest(case=case):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = ReleaseArchiveFixture(temporary)
                    archive_release(
                        fixture.root,
                        fixture.identity,
                        fixture.dmg,
                    )
                    manifest = fixture.read_manifest()
                    if case == "extra-record":
                        manifest["records"]["unexpected"] = dict(
                            manifest["records"]["infoPlist"]
                        )
                    elif case == "missing-record":
                        manifest["records"].pop(
                            "importManifest"
                        )
                    else:
                        manifest["derived"]["appAsar"][
                            "fileCount"
                        ] = True
                    fixture.write_manifest(manifest)

                    with self.assertRaises(ValueError):
                        verify_release_archive(
                            fixture.root,
                            fixture.identity,
                        )

    def test_official_row_is_bound_to_top_level_release_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)
            archive_release(fixture.root, fixture.identity, fixture.dmg)
            archived_dmg = (
                fixture.release_root / "official/ChatGPT.dmg"
            )
            archived_dmg.write_bytes(b"self-consistent replacement\n")
            replacement_hash = hashlib.sha256(
                archived_dmg.read_bytes()
            ).hexdigest()
            manifest = fixture.read_manifest()
            manifest["officialPackage"]["bytes"] = archived_dmg.stat().st_size
            manifest["officialPackage"]["sha256"] = replacement_hash
            fixture.write_manifest(manifest)

            with self.assertRaisesRegex(ValueError, "official package"):
                verify_release_archive(
                    fixture.root,
                    fixture.identity,
                )

    def test_malformed_existing_archive_and_symlink_root_are_never_replaced(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)
            fixture.release_root.mkdir(parents=True)
            sentinel = fixture.release_root / "sentinel"
            sentinel.write_text("keep\n", encoding="utf-8")
            fixture.manifest_path.write_text("[]\n", encoding="utf-8")

            with self.assertRaises((ValueError, TypeError)):
                archive_release(
                    fixture.root,
                    fixture.identity,
                    fixture.dmg,
                )
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep\n")

        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseArchiveFixture(temporary)
            outside = Path(temporary) / "outside"
            outside.mkdir()
            sentinel = outside / "sentinel"
            sentinel.write_text("keep\n", encoding="utf-8")
            fixture.release_root.parent.mkdir(parents=True)
            fixture.release_root.symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(ValueError, "escapes"):
                archive_release(
                    fixture.root,
                    fixture.identity,
                    fixture.dmg,
                )
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep\n")


if __name__ == "__main__":
    unittest.main()
