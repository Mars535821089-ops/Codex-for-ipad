from __future__ import annotations

import datetime as dt
import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

from scripts.build_ipad_release import (
    BUNDLE_IDENTIFIER,
    PRODUCT_NAME,
    ReleasePaths,
    build_archive_command,
    build_export_command,
    build_release,
    create_dry_run_plan,
    export_options,
    load_release_identity,
    release_cli_payload,
    production_input_fingerprint,
    validate_xcode_27,
    verify_ipa,
)


VERSION = "26.727.51351"
BUILD = "6119"
DMG_SHA256 = hashlib.sha256(b"official desktop fixture").hexdigest()
TEAM_ID = "XXXXXXXXXX"
TARGET_DEVICE_ID = "PRIVATE-TARGET-DEVICE-ID"


def plist_bytes(value: dict[str, object]) -> bytes:
    return plistlib.dumps(value, fmt=plistlib.FMT_XML)


class ReleaseFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        (root / "CodexPad/CodexPad.xcodeproj").mkdir(parents=True)
        self.identity_record = root / "artifacts" / f"manifest-{VERSION}.json"
        self.identity_record.parent.mkdir(parents=True)
        self.identity_record.write_text(
            json.dumps(
                {
                    "version": VERSION,
                    "build": BUILD,
                    "dmg_sha256": DMG_SHA256,
                }
            ),
            encoding="utf-8",
        )
        self.ipa = root / "fixture.ipa"
        self.expiration = dt.datetime(
            2026,
            8,
            10,
            12,
            0,
            tzinfo=dt.timezone.utc,
        )
        self._write_ipa()

    def _write_ipa(
        self,
        *,
        bundle_identifier: str = BUNDLE_IDENTIFIER,
        version: str = VERSION,
        build: str = BUILD,
    ) -> None:
        with zipfile.ZipFile(
            self.ipa,
            "w",
            compression=zipfile.ZIP_DEFLATED,
        ) as archive:
            app = f"Payload/{PRODUCT_NAME}.app"
            archive.writestr(
                f"{app}/Info.plist",
                plist_bytes(
                    {
                        "CFBundleIdentifier": bundle_identifier,
                        "CFBundleShortVersionString": version,
                        "CFBundleVersion": build,
                        "CFBundleExecutable": PRODUCT_NAME,
                        "DTPlatformName": "iphoneos",
                        "MinimumOSVersion": "18.0",
                        "UIDeviceFamily": [2],
                    }
                ),
            )
            archive.writestr(f"{app}/{PRODUCT_NAME}", b"mach-o fixture")
            archive.writestr(
                f"{app}/embedded.mobileprovision",
                b"cms fixture",
            )

    def command_runner(
        self,
        command: list[str],
        *,
        capture_output: bool = False,
    ) -> bytes:
        executable = Path(command[0]).name
        if executable == "lipo":
            return b"arm64\n"
        if executable == "xcodebuild" and command[1:] == ["-version"]:
            return b"Xcode 27.0\nBuild version 27A5218g\n"
        if executable == "codesign" and "--entitlements" in command:
            return plist_bytes(
                {
                    "application-identifier": (
                        f"{TEAM_ID}.{BUNDLE_IDENTIFIER}"
                    ),
                    "com.apple.developer.team-identifier": TEAM_ID,
                    "get-task-allow": True,
                    "keychain-access-groups": [
                        f"{TEAM_ID}.{BUNDLE_IDENTIFIER}"
                    ],
                }
            )
        if executable == "codesign":
            return b""
        if executable == "security":
            return plist_bytes(
                {
                    "ExpirationDate": self.expiration,
                    "ProvisionedDevices": [TARGET_DEVICE_ID, "OTHER-DEVICE"],
                    "TeamIdentifier": [TEAM_ID],
                    "Entitlements": {
                        "application-identifier": (
                            f"{TEAM_ID}.{BUNDLE_IDENTIFIER}"
                        ),
                        "com.apple.developer.team-identifier": TEAM_ID,
                        "get-task-allow": True,
                        "keychain-access-groups": [f"{TEAM_ID}.*"],
                    },
                }
            )
        raise AssertionError(f"unexpected command: {command!r}")


class BuildIpadReleaseTests(unittest.TestCase):
    def test_production_fingerprint_tracks_sources_but_ignores_build_products(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "CodexPad/CodexPad/App/CodexPadApp.swift"
            source.parent.mkdir(parents=True)
            source.write_text("one\n", encoding="utf-8")
            first = production_input_fingerprint(root)

            product = root / "CodexCore/target/debug/libcodex_core.a"
            product.parent.mkdir(parents=True)
            product.write_bytes(b"generated")
            self.assertEqual(production_input_fingerprint(root), first)

            source.write_text("two\n", encoding="utf-8")
            self.assertNotEqual(production_input_fingerprint(root), first)

    def test_requires_xcode_27_for_the_release_export(self) -> None:
        self.assertEqual(
            validate_xcode_27(b"Xcode 27.0\nBuild version 27A5218g\n"),
            "27.0",
        )
        for output in (
            b"Xcode 26.4\nBuild version 16F6\n",
            b"Xcode 28.0\nBuild version 28A1\n",
            b"not xcode\n",
        ):
            with self.subTest(output=output):
                with self.assertRaisesRegex(ValueError, "Xcode 27"):
                    validate_xcode_27(output)

    def test_loads_shared_exact_release_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseFixture(Path(temporary))

            identity = load_release_identity(fixture.identity_record)

            self.assertEqual(identity.version, VERSION)
            self.assertEqual(identity.build, BUILD)
            self.assertEqual(identity.dmg_sha256, DMG_SHA256)
            self.assertEqual(
                identity.__class__.__module__,
                "scripts.release_identity",
            )

    def test_release_commands_archive_release_and_export_debugging(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = ReleaseFixture(root)
            identity = load_release_identity(fixture.identity_record)
            paths = ReleasePaths.for_identity(
                root,
                root / "build" / "ipad-release",
                identity,
            )

            archive = build_archive_command(
                paths,
                identity,
                TEAM_ID,
                target_device_id=TARGET_DEVICE_ID,
            )
            export = build_export_command(paths)

            self.assertEqual(archive[-1], "archive")
            self.assertIn("-configuration", archive)
            self.assertEqual(
                archive[archive.index("-configuration") + 1],
                "Release",
            )
            self.assertEqual(
                archive[archive.index("-destination") + 1],
                "generic/platform=iOS",
            )
            self.assertNotIn(TARGET_DEVICE_ID, archive)
            self.assertIn("-allowProvisioningUpdates", archive)
            self.assertIn("-allowProvisioningDeviceRegistration", archive)
            self.assertIn(f"DEVELOPMENT_TEAM={TEAM_ID}", archive)
            self.assertIn(
                f"PRODUCT_BUNDLE_IDENTIFIER={BUNDLE_IDENTIFIER}",
                archive,
            )
            self.assertIn(f"MARKETING_VERSION={VERSION}", archive)
            self.assertIn(f"CURRENT_PROJECT_VERSION={BUILD}", archive)
            self.assertIn("-exportArchive", export)
            self.assertEqual(
                export_options(TEAM_ID),
                {
                    "destination": "export",
                    "method": "debugging",
                    "signingStyle": "automatic",
                    "stripSwiftSymbols": True,
                    "teamID": TEAM_ID,
                    "thinning": "<none>",
                },
            )

    def test_verifies_ipa_without_persisting_sensitive_profile_data(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = ReleaseFixture(Path(temporary))
            identity = load_release_identity(fixture.identity_record)

            result = verify_ipa(
                fixture.ipa,
                identity,
                team_id=TEAM_ID,
                target_device_id=TARGET_DEVICE_ID,
                command_runner=fixture.command_runner,
                now=dt.datetime(
                    2026,
                    8,
                    3,
                    12,
                    0,
                    tzinfo=dt.timezone.utc,
                ),
            )

            self.assertEqual(
                result["artifact"]["sha256"],
                hashlib.sha256(fixture.ipa.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                result["artifact"]["fileName"],
                fixture.ipa.name,
            )
            self.assertEqual(
                result["product"],
                {
                    "architecture": "arm64",
                    "bundleIdentifier": BUNDLE_IDENTIFIER,
                    "build": BUILD,
                    "deviceFamily": "iPad",
                    "minimumOSVersion": "18.0",
                    "name": PRODUCT_NAME,
                    "platform": "iphoneos",
                    "version": VERSION,
                },
            )
            self.assertEqual(
                result["verification"]["provisioningProfileExpiration"],
                "2026-08-10T12:00:00Z",
            )
            self.assertTrue(
                result["verification"]["targetDeviceProvisioned"]
            )
            serialized = json.dumps(result, sort_keys=True)
            self.assertNotIn(TARGET_DEVICE_ID, serialized)
            self.assertNotIn("OTHER-DEVICE", serialized)
            self.assertNotIn("ProvisionedDevices", serialized)
            self.assertNotIn("TeamIdentifier", serialized)
            self.assertNotIn("application-identifier", serialized)

    def test_rejects_mismatched_or_unsafe_ipa_inputs(self) -> None:
        cases = (
            ("bundle", "bundle identifier"),
            ("architecture", "arm64"),
            ("expired", "expired"),
            ("device", "target device"),
            ("entitlements", "entitlements"),
        )
        for case, message in cases:
            with self.subTest(case=case):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = ReleaseFixture(Path(temporary))
                    identity = load_release_identity(fixture.identity_record)
                    if case == "bundle":
                        fixture._write_ipa(
                            bundle_identifier="com.example.wrong"
                        )

                    def runner(
                        command: list[str],
                        *,
                        capture_output: bool = False,
                    ) -> bytes:
                        executable = Path(command[0]).name
                        if case == "architecture" and executable == "lipo":
                            return b"x86_64\n"
                        if case == "expired" and executable == "security":
                            fixture.expiration = dt.datetime(
                                2026,
                                8,
                                1,
                                tzinfo=dt.timezone.utc,
                            )
                        value = fixture.command_runner(
                            command,
                            capture_output=capture_output,
                        )
                        if case == "device" and executable == "security":
                            profile = plistlib.loads(value)
                            profile["ProvisionedDevices"] = ["OTHER-DEVICE"]
                            return plist_bytes(profile)
                        if (
                            case == "entitlements"
                            and executable == "codesign"
                            and "--entitlements" in command
                        ):
                            entitlements = plistlib.loads(value)
                            entitlements["get-task-allow"] = False
                            return plist_bytes(entitlements)
                        return value

                    with self.assertRaisesRegex(ValueError, message):
                        verify_ipa(
                            fixture.ipa,
                            identity,
                            team_id=TEAM_ID,
                            target_device_id=TARGET_DEVICE_ID,
                            command_runner=runner,
                            now=dt.datetime(
                                2026,
                                8,
                                3,
                                tzinfo=dt.timezone.utc,
                            ),
                        )

    def test_dry_run_redacts_device_id_and_performs_no_commands(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = ReleaseFixture(root)
            identity = load_release_identity(fixture.identity_record)
            paths = ReleasePaths.for_identity(
                root,
                root / "build" / "ipad-release",
                identity,
            )

            plan = create_dry_run_plan(
                paths,
                identity,
                team_id=TEAM_ID,
                target_device_id=TARGET_DEVICE_ID,
                install_device="Example iPad",
            )

            serialized = json.dumps(plan, sort_keys=True)
            self.assertNotIn(TARGET_DEVICE_ID, serialized)
            self.assertNotIn("Example iPad", serialized)
            self.assertEqual(plan["distributionMethod"], "debugging")
            self.assertEqual(
                plan["archiveCommand"][
                    plan["archiveCommand"].index("-destination") + 1
                ],
                "generic/platform=iOS",
            )
            self.assertNotIn("id=<redacted>", plan["archiveCommand"])
            self.assertTrue(plan["targetDeviceCheck"])
            self.assertTrue(plan["installOverExisting"])
            self.assertFalse(plan["uninstall"])
            self.assertFalse(plan["clearContainer"])
            self.assertFalse(plan["clearKeychain"])

    def test_orchestration_writes_sanitized_manifest_and_install_is_opt_in(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = ReleaseFixture(root)
            identity = load_release_identity(fixture.identity_record)
            paths = ReleasePaths.for_identity(
                root,
                root / "build" / "ipad-release",
                identity,
            )
            commands: list[list[str]] = []

            def runner(
                command: list[str],
                *,
                capture_output: bool = False,
            ) -> bytes:
                commands.append(command)
                if "archive" == command[-1]:
                    archive_path = Path(
                        command[command.index("-archivePath") + 1]
                    )
                    archive_path.mkdir(parents=True)
                    return b""
                if "-exportArchive" in command:
                    export_path = Path(
                        command[command.index("-exportPath") + 1]
                    )
                    export_path.mkdir(parents=True)
                    target = export_path / fixture.ipa.name
                    target.write_bytes(fixture.ipa.read_bytes())
                    return b""
                if (
                    Path(command[0]).name == "xcrun"
                    and command[1:2] == ["devicectl"]
                ):
                    return b"installed"
                return fixture.command_runner(
                    command,
                    capture_output=capture_output,
                )

            manifest = build_release(
                paths,
                identity,
                team_id=TEAM_ID,
                target_device_id=TARGET_DEVICE_ID,
                install_device=None,
                command_runner=runner,
                project_sync_checker=lambda _root, _identity: None,
                now=dt.datetime(
                    2026,
                    8,
                    3,
                    12,
                    0,
                    tzinfo=dt.timezone.utc,
                ),
            )

            self.assertEqual(
                manifest,
                json.loads(paths.manifest.read_text(encoding="utf-8")),
            )
            self.assertFalse(manifest["installOverExisting"]["requested"])
            self.assertFalse(manifest["installOverExisting"]["performed"])
            self.assertFalse(
                any(
                    Path(command[0]).name == "xcrun"
                    and command[1:2] == ["devicectl"]
                    for command in commands
                )
            )
            serialized = paths.manifest.read_text(encoding="utf-8")
            self.assertNotIn(TARGET_DEVICE_ID, serialized)
            self.assertNotIn("@", serialized)

            install_command_words = {
                "uninstall",
                "erase",
                "keychain",
                "terminate-existing",
            }
            flattened = " ".join(word for command in commands for word in command)
            for word in install_command_words:
                self.assertNotIn(word, flattened.lower())

    def test_cli_payload_names_the_exact_ipa_instead_of_export_directory(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = ReleaseFixture(root)
            identity = load_release_identity(fixture.identity_record)
            paths = ReleasePaths.for_identity(
                root,
                root / "build" / "ipad-release",
                identity,
            )
            paths.export.mkdir(parents=True)
            ipa = paths.export / "Codex for ipad.ipa"
            ipa.write_bytes(fixture.ipa.read_bytes())
            manifest = {
                "artifact": {
                    "fileName": ipa.name,
                    "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
                }
            }

            payload = release_cli_payload(paths, manifest)

            self.assertEqual(payload["ipa"], str(ipa.resolve()))
            self.assertEqual(payload["manifest"], str(paths.manifest.resolve()))
            self.assertTrue(Path(payload["ipa"]).is_file())

    def test_install_over_existing_uses_only_devicectl_install(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = ReleaseFixture(root)
            identity = load_release_identity(fixture.identity_record)
            paths = ReleasePaths.for_identity(
                root,
                root / "build" / "ipad-release",
                identity,
            )
            commands: list[list[str]] = []

            def runner(
                command: list[str],
                *,
                capture_output: bool = False,
            ) -> bytes:
                commands.append(command)
                if command[-1] == "archive":
                    archive_path = Path(
                        command[command.index("-archivePath") + 1]
                    )
                    archive_path.mkdir(parents=True)
                    return b""
                if "-exportArchive" in command:
                    export_path = Path(
                        command[command.index("-exportPath") + 1]
                    )
                    export_path.mkdir(parents=True)
                    (export_path / fixture.ipa.name).write_bytes(
                        fixture.ipa.read_bytes()
                    )
                    return b""
                if (
                    Path(command[0]).name == "xcrun"
                    and command[1:2] == ["devicectl"]
                ):
                    return b"installed"
                return fixture.command_runner(
                    command,
                    capture_output=capture_output,
                )

            manifest = build_release(
                paths,
                identity,
                team_id=TEAM_ID,
                target_device_id=TARGET_DEVICE_ID,
                install_device="Example iPad",
                command_runner=runner,
                project_sync_checker=lambda _root, _identity: None,
                now=dt.datetime(
                    2026,
                    8,
                    3,
                    tzinfo=dt.timezone.utc,
                ),
            )

            device_commands = [
                command
                for command in commands
                if (
                    Path(command[0]).name == "xcrun"
                    and command[1:2] == ["devicectl"]
                )
            ]
            self.assertEqual(len(device_commands), 1)
            self.assertEqual(
                device_commands[0][1:6],
                ["devicectl", "device", "install", "app", "--device"],
            )
            self.assertEqual(device_commands[0][6], TARGET_DEVICE_ID)
            self.assertTrue(manifest["installOverExisting"]["requested"])
            self.assertTrue(manifest["installOverExisting"]["performed"])
            self.assertTrue(
                manifest["installOverExisting"][
                    "containerAndKeychainPreserved"
                ]
            )
            self.assertTrue(
                manifest["installOverExisting"][
                    "targetBoundToProvisioningProfile"
                ]
            )


if __name__ == "__main__":
    unittest.main()
