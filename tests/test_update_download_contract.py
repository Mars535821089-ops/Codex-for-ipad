import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]


class UpdateDownloadContractTests(unittest.TestCase):
    def test_remote_probes_and_download_share_resilient_official_transport(
        self,
    ) -> None:
        checker = (ROOT / "scripts" / "check_and_update_latest.sh").read_text(
            encoding="utf-8"
        )
        updater = (ROOT / "scripts" / "update_latest.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("AUTOMATIC_UPDATE_DISABLED", checker)
        self.assertNotIn("official_curl", checker)
        self.assertIn("official_curl_transport.sh", updater)
        self.assertIn('source "$OFFICIAL_CURL_TRANSPORT"', updater)
        self.assertIn('official_curl "$OFFICIAL_URL"', updater)
        self.assertGreaterEqual(updater.count("--http1.1"), 2)
        self.assertEqual(updater.count('official_curl "$OFFICIAL_URL"'), 2)

    def test_updater_reuses_only_helper_verified_complete_package(self) -> None:
        updater = (ROOT / "scripts" / "update_latest.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("official_download_state.py", updater)
        self.assertIn("select-reusable", updater)
        self.assertIn("write-sidecar", updater)
        self.assertNotIn(
            "find \"$DOWNLOAD_DIR\" -maxdepth 1 -type f "
            "-name 'ChatGPT-*.dmg' \\\n    -print |",
            updater,
        )

    def test_success_cleanup_preserves_complete_packages_and_uses_state_helper(
        self,
    ) -> None:
        updater = (ROOT / "scripts" / "update_latest.sh").read_text(
            encoding="utf-8"
        )
        verification = updater.index('"$VERIFY_SCRIPT" "$VERSION" "$BUILD"')
        final_probe = updater.index(
            "Confirming the archived official package is still current"
        )
        direct_cleanup = updater.index(
            'rm -f -- "$DMG" "$DMG.remote.json" "$PART"'
        )
        incomplete_cleanup = updater.index(
            '"$DOWNLOAD_STATE_HELPER" cleanup-incomplete-parts'
        )

        self.assertLess(verification, final_probe)
        self.assertLess(final_probe, direct_cleanup)
        self.assertLess(final_probe, incomplete_cleanup)
        self.assertNotIn(
            'find "$DOWNLOAD_DIR" -maxdepth 1 -type f',
            updater[direct_cleanup:],
        )
        self.assertIn('--remote "$FINAL_REMOTE_FILE"', updater[incomplete_cleanup:])
        self.assertIn(
            '--download-directory "$DOWNLOAD_DIR"',
            updater[incomplete_cleanup:],
        )

    def test_success_cleanup_starts_only_after_transaction_commit(self) -> None:
        updater = (ROOT / "scripts" / "update_latest.sh").read_text(
            encoding="utf-8"
        )

        commit = updater.rindex('python3 "$TRANSACTION_HELPER" commit')
        direct_package_cleanup = updater.index(
            'rm -f -- "$DMG" "$DMG.remote.json" "$PART"'
        )
        incomplete_part_cleanup = updater.index(
            '"$DOWNLOAD_STATE_HELPER" cleanup-incomplete-parts'
        )

        self.assertLess(commit, direct_package_cleanup)
        self.assertLess(commit, incomplete_part_cleanup)

    def test_signed_ipa_gate_runs_after_parity_and_before_archive_commit(self) -> None:
        updater = (ROOT / "scripts" / "update_latest.sh").read_text(
            encoding="utf-8"
        )

        parity = updater.index('"$VERIFY_SCRIPT" "$VERSION" "$BUILD"')
        desktop_parity = updater.index('python3 "$DESKTOP_PARITY_GATE"')
        ipa_gate = updater.index(
            '"$IPA_RELEASE_GATE" build-and-validate'
        )
        archive = updater.index(
            'python3 "$RELEASE_ARCHIVE_HELPER" archive'
        )
        commit = updater.rindex('python3 "$TRANSACTION_HELPER" commit')

        self.assertLess(parity, ipa_gate)
        self.assertLess(parity, desktop_parity)
        self.assertLess(desktop_parity, ipa_gate)
        self.assertLess(ipa_gate, archive)
        self.assertLess(archive, commit)
        self.assertIn('"ipaPath": "$IPA_PATH"', updater)
        self.assertIn('"ipaSha256": "$IPA_SHA256"', updater)

    def test_current_release_capture_input_is_assembled_after_device_verification(
        self,
    ) -> None:
        updater = (ROOT / "scripts" / "update_latest.sh").read_text(
            encoding="utf-8"
        )

        verification = updater.index('"$VERIFY_SCRIPT" "$VERSION" "$BUILD"')
        assembly = updater.index('python3 "$PARITY_CAPTURE_ASSEMBLER"')
        evidence = updater.index('python3 "$RELEASE_PARITY_BUILDER"')

        self.assertLess(verification, assembly)
        self.assertLess(assembly, evidence)
        self.assertIn(
            '--official-manifest "$OFFICIAL_PARITY_MANIFEST"', updater
        )
        self.assertIn('--ipad-manifest "$IPAD_PARITY_MANIFEST"', updater)
        self.assertIn('--output "$PARITY_CAPTURE_INPUT"', updater)

    def test_automatic_update_never_launches_a_second_desktop_codex_instance(
        self,
    ) -> None:
        updater = (ROOT / "scripts" / "update_latest.sh").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("capture_official_desktop_parity.sh", updater)
        self.assertNotIn("OFFICIAL_DESKTOP_CAPTURE", updater)
        self.assertNotIn("CodexParityCapture", updater)

        official_manifest_check = updater.index(
            'if [[ ! -f "$OFFICIAL_PARITY_MANIFEST" ]]'
        )
        verification = updater.index('"$VERIFY_SCRIPT" "$VERSION" "$BUILD"')
        assembly = updater.index('python3 "$PARITY_CAPTURE_ASSEMBLER"')

        upgrade = updater.index('"$UPGRADE_SCRIPT" "$VERSION" "$BUILD"')

        self.assertLess(upgrade, official_manifest_check)
        self.assertLess(official_manifest_check, verification)
        self.assertLess(verification, assembly)

    def test_desktop_capture_entrypoint_is_permanently_disabled(self) -> None:
        script = ROOT / "scripts" / "capture_official_desktop_parity.sh"
        environment = os.environ.copy()
        environment["CODEX_ALLOW_DESKTOP_PARITY_CAPTURE"] = "true"

        result = subprocess.run(
            [
                str(script),
                "/tmp/does-not-exist-ChatGPT.dmg",
                "0.0.0",
                "0",
            ],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )

        self.assertEqual(result.returncode, 78)
        self.assertIn("permanently disabled", result.stderr)
        self.assertNotIn("Official DMG is missing", result.stderr)

    def test_apphost_coverage_gate_scans_all_native_service_implementations(
        self,
    ) -> None:
        updater = (ROOT / "scripts" / "update_latest.sh").read_text(
            encoding="utf-8"
        )

        reverse_import = updater.index('"$IMPORT_SCRIPT" "$DMG"')
        apphost_audit = updater.index(
            'python3 "$APPHOST_API_AUDITOR"'
        )
        ipad_upgrade = updater.index('"$UPGRADE_SCRIPT" "$VERSION" "$BUILD"')

        self.assertLess(reverse_import, apphost_audit)
        self.assertLess(apphost_audit, ipad_upgrade)
        self.assertIn(
            '--official-main "$DEST/.vite/build"',
            updater[apphost_audit:ipad_upgrade],
        )
        self.assertIn(
            '--official-renderer "$DEST/webview/assets"',
            updater[apphost_audit:ipad_upgrade],
        )
        self.assertIn(
            '--ipad-router "$PROJECT_ROOT/CodexPad/CodexPad/Application"',
            updater[apphost_audit:ipad_upgrade],
        )
        self.assertIn("--require-complete", updater[apphost_audit:ipad_upgrade])

    def test_sidecar_is_written_only_after_image_and_signature_checks(self) -> None:
        updater = (ROOT / "scripts" / "update_latest.sh").read_text(
            encoding="utf-8"
        )

        verify = updater.index('hdiutil verify "$DMG"')
        codesign = updater.index("codesign --verify")
        assess = updater.index("spctl --assess")
        sidecar = updater.index("write-sidecar")

        self.assertLess(verify, sidecar)
        self.assertLess(codesign, sidecar)
        self.assertLess(assess, sidecar)

    def test_replacement_invalidates_a_same_name_sidecar_before_move(self) -> None:
        updater = (ROOT / "scripts" / "update_latest.sh").read_text(
            encoding="utf-8"
        )

        invalidate = updater.index('unlink "$DMG.remote.json"')
        replace = updater.index('mv "$PART" "$DMG"')

        self.assertLess(invalidate, replace)

    def test_updater_uses_one_exit_trap_and_an_independent_upgrade_lock(self) -> None:
        updater = (ROOT / "scripts" / "update_latest.sh").read_text(
            encoding="utf-8"
        )

        self.assertEqual(updater.count("trap cleanup EXIT"), 1)
        self.assertNotIn("trap cleanup_remote_probes", updater)
        self.assertNotIn("trap cleanup_attached_image", updater)
        self.assertIn("upgrade.lock", updater)
        self.assertNotIn('LOCK_DIR="$STATE_DIR/update.lock"', updater)


if __name__ == "__main__":
    unittest.main()
