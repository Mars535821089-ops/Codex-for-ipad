from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class ImportPipelineContractTests(unittest.TestCase):
    @staticmethod
    def _copy_apply_script(root: Path) -> Path:
        scripts = root / "scripts"
        scripts.mkdir(parents=True)
        source = Path(__file__).parents[1] / "scripts/apply_ipad_upgrade.sh"
        destination = scripts / source.name
        shutil.copy2(source, destination)
        return destination

    @staticmethod
    def _run_apply(
        script: Path,
        version: str,
        build: str,
        *,
        source_only: bool = False,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        arguments = [str(script)]
        if source_only:
            arguments.append("--source-only")
        arguments.extend((version, build))
        return subprocess.run(
            arguments,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, **(environment or {})},
            timeout=10,
        )

    @staticmethod
    def _write_executable(path: Path, body: str) -> None:
        path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
        path.chmod(0o755)

    def _prepare_import_sandbox(
        self,
        root: Path,
        *,
        version: str,
        build: str,
    ) -> tuple[Path, Path, Path, dict[str, str]]:
        scripts = root / "scripts"
        scripts.mkdir(parents=True)
        importer = scripts / "import_dmg.sh"
        shutil.copy2(
            Path(__file__).parents[1] / "scripts/import_dmg.sh",
            importer,
        )

        dmg = root / "incoming" / "ChatGPT.dmg"
        dmg.parent.mkdir()
        dmg.write_bytes(b"fixture-dmg-v2\n")
        mount = root / "mounted"
        app = mount / "Fixture.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        (app / "Contents/Info.plist").write_text(
            "fixture\n",
            encoding="utf-8",
        )
        (resources / "app.asar").write_bytes(b"fresh-asar-v2\n")
        self._write_executable(
            resources / "codex",
            """
            #!/usr/bin/env bash
            printf '%s\n' 'codex 1.2.3'
            """,
        )

        fake_bin = root / "fake-bin"
        fake_bin.mkdir()
        self._write_executable(
            fake_bin / "hdiutil",
            """
            #!/usr/bin/env bash
            if [[ "$1" == "attach" ]]; then
              printf '%s\n' 'fixture attach plist'
            fi
            """,
        )
        self._write_executable(
            fake_bin / "plutil",
            """
            #!/usr/bin/env bash
            set -euo pipefail
            if [[ "$1" == "-extract" && "$2" == "system-entities" ]]; then
              printf '[{"mount-point":"%s"}]\n' "$FAKE_MOUNT"
            elif [[ "$1" == "-convert" ]]; then
              cat
            elif [[ "$1" == "-extract" \
              && "$2" == "CFBundleIdentifier" ]]; then
              printf '%s\n' 'com.openai.codex'
            elif [[ "$1" == "-extract" \
              && "$2" == "CFBundleShortVersionString" ]]; then
              printf '%s\n' "$FAKE_VERSION"
            elif [[ "$1" == "-extract" \
              && "$2" == "CFBundleVersion" ]]; then
              printf '%s\n' "$FAKE_BUILD"
            else
              exit 2
            fi
            """,
        )
        self._write_executable(
            fake_bin / "npx",
            """
            #!/usr/bin/env bash
            set -euo pipefail
            [[ "${FAIL_NPX:-0}" != "1" ]] || exit 41
            asar="${@: -2:1}"
            destination="${@: -1}"
            mkdir -p "$destination/webview/assets"
            cp "$asar" "$destination/extracted-asar.txt"
            printf '%s\n' '<html>fresh</html>' \
              >"$destination/webview/index.html"
            printf '%s\n' 'fresh renderer' \
              >"$destination/webview/assets/app.js"
            """,
        )
        self._write_executable(
            fake_bin / "codesign",
            """
            #!/usr/bin/env bash
            if [[ "$1" == "--verify" && "${FAIL_CODESIGN:-0}" == "1" ]]; then
              exit 45
            fi
            if [[ "$1" == "-dvv" ]]; then
              printf '%s\n' 'Identifier=com.openai.codex' >&2
              printf '%s\n' 'TeamIdentifier=2DC432GLL2' >&2
            fi
            exit 0
            """,
        )
        self._write_executable(
            fake_bin / "spctl",
            """
            #!/usr/bin/env bash
            [[ "${FAIL_SPCTL:-0}" != "1" ]]
            """,
        )

        self._write_executable(
            scripts / "import_official_source.sh",
            """
            #!/usr/bin/env bash
            set -euo pipefail
            root="$(cd "$(dirname "$0")/.." && pwd)"
            version="$2"
            build="$3"
            mkdir -p "$root/artifacts/upstream/codex-rust-v1.2.3"
            mkdir -p "$root/versions/$version"
            printf '{"desktopVersion":"%s","desktopBuild":"%s"}\n' \
              "$version" "$build" \
              >"$root/versions/$version/official-source.json"
            """,
        )
        self._write_executable(
            scripts / "generate_protocol_snapshot.sh",
            """
            #!/usr/bin/env bash
            set -euo pipefail
            root="$(cd "$(dirname "$0")/.." && pwd)"
            mkdir -p "$root/versions/$FAKE_VERSION/protocol"
            printf '{"fresh":true}\n' \
              >"$root/versions/$FAKE_VERSION/protocol/index.json"
            """,
        )
        (scripts / "reverse_full_bundle.py").write_text(
            textwrap.dedent(
                """
                import json
                import os
                import shutil
                import sys
                from pathlib import Path

                if os.environ.get("FAIL_HELPER") == Path(__file__).name:
                    raise SystemExit(42)
                args = sys.argv
                output = Path(args[args.index("--output") + 1])
                asar = Path(args[args.index("--asar-root") + 1])
                output.mkdir(parents=True, exist_ok=True)
                shutil.copytree(
                    asar / "webview",
                    output / "app-asar/webview",
                    dirs_exist_ok=True,
                )
                preload = (
                    output
                    / "recovered-electron-source/.vite/build/preload.js"
                )
                preload.parent.mkdir(parents=True, exist_ok=True)
                preload.write_text("fresh preload\\n", encoding="utf-8")
                (output / "full-reverse-manifest.json").write_text(
                    json.dumps(
                        {
                            "fresh": True,
                            "recoveredSourceIndexSha256": "c" * 64,
                        }
                    ) + "\\n",
                    encoding="utf-8",
                )
                """
            ).lstrip(),
            encoding="utf-8",
        )
        generic_helper = textwrap.dedent(
            """
            import json
            import os
            import sys
            from pathlib import Path

            if os.environ.get("FAIL_HELPER") == Path(__file__).name:
                raise SystemExit(42)
            args = sys.argv
            output = Path(args[args.index("--output") + 1])
            output.parent.mkdir(parents=True, exist_ok=True)
            payload = {"fresh": True, "producer": Path(__file__).name}
            if Path(__file__).name == "build_desktop_surface_manifest.py":
                payload["resourceTreeSha256"] = "b" * 64
            output.write_text(
                json.dumps(payload) + "\\n",
                encoding="utf-8",
            )
            """
        ).lstrip()
        for name in (
            "extract_electron_ipc.py",
            "extract_visual_reference.py",
            "electron_bundle_inventory.py",
            "build_feature_inventory.py",
            "build_desktop_surface_manifest.py",
            "build_desktop_interaction_inventory.py",
            "build_desktop_ui_parity.py",
        ):
            (scripts / name).write_text(generic_helper, encoding="utf-8")
        (scripts / "carry_forward_feature_evidence.py").write_text(
            textwrap.dedent(
                """
                import json
                import os
                import sys
                from pathlib import Path

                if os.environ.get("FAIL_HELPER") == Path(__file__).name:
                    raise SystemExit(42)
                args = sys.argv
                inventory = Path(args[args.index("--inventory") + 1])
                payload = json.loads(inventory.read_text(encoding="utf-8"))
                payload["evidenceCarried"] = True
                inventory.write_text(
                    json.dumps(payload) + "\\n",
                    encoding="utf-8",
                )
                """
            ).lstrip(),
            encoding="utf-8",
        )

        environment = {
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "FAKE_MOUNT": str(mount),
            "FAKE_VERSION": version,
            "FAKE_BUILD": build,
        }
        return importer, dmg, resources / "app.asar", environment

    def test_reverse_import_requires_protocol_snapshot(self) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/import_dmg.sh"
        ).read_text(encoding="utf-8")

        generation = script.index('"$PROTOCOL_SCRIPT" "$DMG"')
        success = script.index('echo "Imported $VERSION ($BUILD)"')

        self.assertLess(generation, success)
        self.assertIn(
            '[[ -f "$PROJECT_ROOT/versions/$VERSION/protocol/index.json" ]]',
            script,
        )

    def test_direct_import_verifies_container_signature_and_identity_first(
        self,
    ) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/import_dmg.sh"
        ).read_text(encoding="utf-8")

        verify_image = script.index('hdiutil verify "$DMG"')
        attach = script.index("hdiutil attach -readonly")
        verify_signature = script.index("codesign --verify")
        assess = script.index("spctl --assess")
        identity = script.index(
            '[[ "$TEAM_ID" == "$EXPECTED_TEAM_ID" ]]'
        )
        extract = script.index(
            'npx -y @electron/asar@4.0.1 extract "$ASAR" "$STAGE"'
        )
        execute_embedded = script.index('"$SOURCE_SCRIPT" "$APP"')

        self.assertLess(verify_image, attach)
        self.assertLess(verify_signature, extract)
        self.assertLess(assess, extract)
        self.assertLess(identity, extract)
        self.assertLess(identity, execute_embedded)

    def test_direct_import_signature_failure_does_not_extract_or_execute(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            importer, dmg, _, environment = self._prepare_import_sandbox(
                root,
                version="99.42.11",
                build="7005",
            )
            result = subprocess.run(
                [str(importer), str(dmg)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={**environment, "FAIL_CODESIGN": "1"},
                timeout=15,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(
                (root / "artifacts/app-asar-99.42.11").exists()
            )
            self.assertFalse(
                (root / "versions/99.42.11/official-source.json").exists()
            )

    def test_existing_asar_is_replaced_by_fresh_staged_extraction(self) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/import_dmg.sh"
        ).read_text(encoding="utf-8")

        self.assertNotIn(
            'echo "ASAR already imported: $DEST"',
            script,
        )
        self.assertIn(
            'npx -y @electron/asar@4.0.1 extract "$ASAR" "$STAGE"',
            script,
        )
        extraction = script.index(
            'npx -y @electron/asar@4.0.1 extract "$ASAR" "$STAGE"'
        )
        promotion = script.index('mv "$STAGE" "$DEST"')
        self.assertLess(extraction, promotion)
        self.assertIn('mv "$DEST" "$PREVIOUS_DEST"', script)
        self.assertIn('mv "$PREVIOUS_DEST" "$DEST"', script)

    def test_feature_inventory_is_regenerated_for_every_import(self) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/import_dmg.sh"
        ).read_text(encoding="utf-8")

        self.assertNotIn(
            'if [[ ! -f "$VERSION_ROOT/feature-inventory.json" ]]',
            script,
        )
        self.assertIn(
            '--output "$VERSION_ROOT/feature-inventory.json"',
            script,
        )

    def test_import_runtime_replaces_stale_asar_and_feature_inventory(
        self,
    ) -> None:
        version = "99.42.10"
        build = "7004"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            importer, dmg, asar, environment = self._prepare_import_sandbox(
                root,
                version=version,
                build=build,
            )
            destination = root / f"artifacts/app-asar-{version}"
            destination.mkdir(parents=True)
            (destination / "stale.txt").write_text(
                "stale\n",
                encoding="utf-8",
            )
            feature = root / f"versions/{version}/feature-inventory.json"
            feature.parent.mkdir(parents=True)
            feature.write_text('{"fresh":false}\n', encoding="utf-8")

            result = subprocess.run(
                [str(importer), str(dmg)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                timeout=15,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((destination / "stale.txt").exists())
            self.assertEqual(
                (destination / "extracted-asar.txt").read_bytes(),
                asar.read_bytes(),
            )
            self.assertEqual(
                json.loads(feature.read_text(encoding="utf-8")),
                {
                    "evidenceCarried": True,
                    "fresh": True,
                    "producer": "build_feature_inventory.py",
                },
            )
            self.assertEqual(
                list((root / "artifacts").glob(".asar-*.previous.*")),
                [],
            )
            self.assertEqual(
                list((root / "artifacts").glob(".asar-*.??????")),
                [],
            )

    def test_import_runtime_restores_previous_asar_on_downstream_failure(
        self,
    ) -> None:
        version = "99.42.10"
        build = "7004"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            importer, dmg, _asar, environment = self._prepare_import_sandbox(
                root,
                version=version,
                build=build,
            )
            destination = root / f"artifacts/app-asar-{version}"
            destination.mkdir(parents=True)
            old_file = destination / "old.txt"
            old_file.write_bytes(b"old-import-must-survive\n")
            before = {
                path.relative_to(destination).as_posix(): path.read_bytes()
                for path in destination.rglob("*")
                if path.is_file()
            }
            environment["FAIL_HELPER"] = "build_feature_inventory.py"

            result = subprocess.run(
                [str(importer), str(dmg)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                timeout=15,
            )

            self.assertEqual(result.returncode, 42)
            after = {
                path.relative_to(destination).as_posix(): path.read_bytes()
                for path in destination.rglob("*")
                if path.is_file()
            }
            self.assertEqual(after, before)
            self.assertEqual(
                list((root / "artifacts").glob(".asar-*.previous.*")),
                [],
            )
            self.assertEqual(
                list((root / "artifacts").glob(".asar-*.??????")),
                [],
            )

    def test_import_also_requires_official_source_provenance(self) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/import_dmg.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('"$SOURCE_SCRIPT" "$APP" "$VERSION" "$BUILD"', script)
        self.assertIn(
            'versions/$VERSION/official-source.json',
            script,
        )

    def test_import_builds_full_reverse_before_ipad_upgrade(self) -> None:
        importer = (
            Path(__file__).parents[1] / "scripts/import_dmg.sh"
        ).read_text(encoding="utf-8")
        updater = (
            Path(__file__).parents[1] / "scripts/update_latest.sh"
        ).read_text(encoding="utf-8")

        reverse = importer.index('python3 "$FULL_REVERSE_SCRIPT"')
        imported = importer.index('echo "Imported $VERSION ($BUILD)"')
        upgrade = updater.index('"$UPGRADE_SCRIPT" "$VERSION" "$BUILD"')

        self.assertLess(reverse, imported)
        self.assertGreater(upgrade, 0)
        self.assertIn("full-reverse-manifest.json", importer)

    def test_import_builds_electron_visual_and_feature_inventories(self) -> None:
        importer = (
            Path(__file__).parents[1] / "scripts/import_dmg.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('"$IPC_SCRIPT"', importer)
        self.assertIn('"$VISUAL_SCRIPT"', importer)
        self.assertIn('"$BUNDLE_SCRIPT"', importer)
        self.assertIn('"$FEATURE_SCRIPT"', importer)
        self.assertIn("electron/ipc-inventory.json", importer)
        self.assertIn("visual/reference-inventory.json", importer)
        self.assertIn("electron/bundle-index.json", importer)
        self.assertIn("feature-inventory.json", importer)

    def test_import_builds_official_static_interaction_inventory(self) -> None:
        importer = (
            Path(__file__).parents[1] / "scripts/import_dmg.sh"
        ).read_text(encoding="utf-8")

        self.assertIn('INTERACTION_INVENTORY_SCRIPT=', importer)
        self.assertIn('"$INTERACTION_INVENTORY_SCRIPT"', importer)
        self.assertIn(
            '--output "$VERSION_ROOT/desktop-interaction-inventory.json"',
            importer,
        )
        self.assertIn(
            '--desktop-surface-tree-sha256 "$SURFACE_TREE_SHA256"',
            importer,
        )

    def test_import_persists_exact_dmg_hash_in_source_identity(self) -> None:
        importer = (
            Path(__file__).parents[1] / "scripts/import_dmg.sh"
        ).read_text(encoding="utf-8")
        source_importer = (
            Path(__file__).parents[1]
            / "scripts/import_official_source.sh"
        ).read_text(encoding="utf-8")

        self.assertIn(
            '"$SOURCE_SCRIPT" "$APP" "$VERSION" "$BUILD" "$DMG_SHA256"',
            importer,
        )
        self.assertIn('"dmgSha256": "$DMG_SHA256"', source_importer)

    def test_import_pins_the_complete_desktop_surface_and_ui_contract(
        self,
    ) -> None:
        importer = (
            Path(__file__).parents[1] / "scripts/import_dmg.sh"
        ).read_text(encoding="utf-8")

        self.assertIn('"$SURFACE_MANIFEST_SCRIPT"', importer)
        self.assertIn('"$UI_PARITY_SCRIPT"', importer)
        self.assertIn(
            '--webview-root "$FULL_REVERSE/app-asar/webview"',
            importer,
        )
        self.assertIn(
            '--preload '
            '"$FULL_REVERSE/recovered-electron-source/.vite/build/preload.js"',
            importer,
        )
        self.assertIn(
            '--recovered-root '
            '"$FULL_REVERSE/recovered-electron-source"',
            importer,
        )
        self.assertIn(
            '--output "$VERSION_ROOT/desktop-surface-manifest.json"',
            importer,
        )
        self.assertIn(
            '--output "$VERSION_ROOT/desktop-ui-parity.json"',
            importer,
        )
        self.assertIn('--source-dmg-sha256 "$DMG_SHA256"', importer)
        self.assertIn(
            '--desktop-surface-tree-sha256 "$SURFACE_TREE_SHA256"',
            importer,
        )
        self.assertIn(
            '--recovered-source-index-sha256 '
            '"$RECOVERED_SOURCE_INDEX_SHA256"',
            importer,
        )

    def test_successful_updater_deletes_transfer_files_only_after_verification(
        self,
    ) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/update_latest.sh"
        ).read_text(encoding="utf-8")
        verification = script.index(
            '"$VERIFY_SCRIPT" "$VERSION" "$BUILD" "$SHA256"'
        )
        deletion = script.index(
            'rm -f -- "$DMG" "$DMG.remote.json" "$PART"'
        )
        self.assertLess(verification, deletion)
        self.assertNotIn(
            'find "$DOWNLOAD_DIR" -maxdepth 1 -type f',
            script[deletion:],
        )
        self.assertIn("Reusing retained complete official package", script)

    def test_official_source_cache_is_reverified_before_reuse(self) -> None:
        script = (
            Path(__file__).parents[1]
            / "scripts/import_official_source.sh"
        ).read_text(encoding="utf-8")

        identity_probe = script.index("git ls-remote")
        cache_branch = script.index('if [[ ! -d "$DEST" ]]')
        cache_verify = script.index(
            'python3 "$CACHE_HELPER" verify',
            cache_branch,
        )
        provenance = script.index('"sourceTreeSha256":')

        self.assertLess(identity_probe, cache_branch)
        self.assertLess(cache_verify, provenance)
        self.assertIn('"sourceArchiveSha256":', script)

    def test_updater_archives_then_rechecks_remote_before_commit(self):
        script = (
            Path(__file__).parents[1] / "scripts/update_latest.sh"
        ).read_text(encoding="utf-8")

        verification = script.index(
            '"$VERIFY_SCRIPT" "$VERSION" "$BUILD" "$SHA256"',
        )
        archive = script.index(
            'python3 "$RELEASE_ARCHIVE_HELPER" archive',
            verification,
        )
        final_remote = script.index(
            'python3 "$DOWNLOAD_STATE_HELPER" assert-same',
            archive,
        )
        latest = script.index(
            'python3 - "$ARTIFACTS/latest-official.json"',
            final_remote,
        )
        local_current = script.index(
            'python3 "$DOWNLOAD_STATE_HELPER" assert-local-current',
            latest,
        )
        commit = script.index(
            'python3 "$TRANSACTION_HELPER" commit',
            local_current,
        )
        self.assertLess(verification, archive)
        self.assertLess(archive, final_remote)
        self.assertLess(final_remote, latest)
        self.assertLess(latest, local_current)
        self.assertLess(local_current, commit)
        self.assertNotIn("PARITY_VERIFY_SCRIPT", script)
        self.assertIn('"releaseRoot": "$RELEASE_ROOT"', script)
        self.assertIn(
            '"releaseManifestSha256": "$RELEASE_MANIFEST_SHA256"',
            script,
        )

    def test_updater_rebuilds_feature_coverage_before_parity_gate(self):
        script = (
            Path(__file__).parents[1] / "scripts/update_latest.sh"
        ).read_text(encoding="utf-8")

        first_audit = script.index('python3 "$FEATURE_COVERAGE_AUDITOR"')
        merge = script.index('python3 "$FEATURE_COVERAGE_MERGER"', first_audit)
        final_audit = script.index(
            'python3 "$FEATURE_COVERAGE_AUDITOR"',
            first_audit + 1,
        )
        parity = script.index('python3 "$DESKTOP_PARITY_GATE"', final_audit)

        self.assertLess(first_audit, merge)
        self.assertLess(merge, final_audit)
        self.assertLess(final_audit, parity)
        self.assertIn(
            '--coverage "$VERSION_ROOT/feature-coverage-audit.json"',
            script,
        )
        self.assertIn(
            '--protocol "$FEATURE_PROTOCOL_SOURCE"',
            script,
        )
        self.assertIn(
            '--inventory "$VERSION_ROOT/feature-inventory.json"',
            script,
        )
        self.assertIn(
            '--output "$VERSION_ROOT/feature-coverage-audit.json"',
            script,
        )
        for root in (
            "$PROJECT_ROOT/CodexPad/CodexPad",
            "$PROJECT_ROOT/CodexCore",
        ):
            self.assertIn(f'--production-root "{root}"', script)
        for root in (
            "$PROJECT_ROOT/CodexPad/Tests",
            "$PROJECT_ROOT/tests",
        ):
            self.assertIn(f'--test-root "{root}"', script)

    def test_upgrade_rolls_back_source_pins_on_failure(self) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/apply_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("restore_on_failure()", script)
        self.assertIn('cp "$BACKUP/Cargo.toml" "$CARGO_TOML"', script)
        self.assertIn('cargo check --locked', script)

    def test_upgrade_regenerates_model_catalog_from_recovered_official_source(
        self,
    ) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/apply_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")
        generation = script.index('"$MODEL_CATALOG_SCRIPT"')
        build = script.index('"$PROJECT_ROOT/scripts/build_codex_core_xcframework.sh"')
        self.assertLess(generation, build)
        self.assertIn("models-manager/models.json", script)
        self.assertIn("model-catalog.json", script)
        self.assertIn("CodexModelCatalog.generated.swift", script)
        self.assertIn(
            'MODEL_RUST_JSON="$PROJECT_ROOT/CodexCore/resources/models.json"',
            script,
        )
        self.assertIn('--rust-json-output "$MODEL_RUST_JSON"', script)
        self.assertIn(
            '--official-cargo-toml "$OFFICIAL_CARGO_TOML"',
            script,
        )
        self.assertIn(
            '--rust-client-version-output "$MODEL_CLIENT_VERSION"',
            script,
        )

    def test_upgrade_rolls_back_embedded_rust_model_catalog_on_failure(
        self,
    ) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/apply_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")

        self.assertIn(
            'cp "$MODEL_RUST_JSON" "$BACKUP/models.json"',
            script,
        )
        self.assertIn(
            'cp "$BACKUP/models.json" "$MODEL_RUST_JSON"',
            script,
        )
        self.assertIn('rm -f "$MODEL_RUST_JSON"', script)
        self.assertIn(
            'cp "$MODEL_CLIENT_VERSION" "$BACKUP/client-version.txt"',
            script,
        )
        self.assertIn(
            'cp "$BACKUP/client-version.txt" "$MODEL_CLIENT_VERSION"',
            script,
        )

    def test_upgrade_regenerates_runtime_build_metadata_before_xcode_project(
        self,
    ) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/apply_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")
        generation = script.index('"$BUILD_METADATA_SCRIPT"')
        project = script.index(
            'scripts/generate_codexpad_xcode_project.py'
        )

        self.assertLess(generation, project)
        self.assertIn('CodexBuildMetadata.generated.swift', script)
        self.assertIn('--source "$SOURCE_RECORD"', script)
        self.assertIn('--swift-output "$BUILD_METADATA_SWIFT"', script)

    def test_upgrade_rolls_back_generated_runtime_build_metadata_on_failure(
        self,
    ) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/apply_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")

        self.assertIn(
            'cp "$BUILD_METADATA_SWIFT" '
            '"$BACKUP/CodexBuildMetadata.generated.swift"',
            script,
        )
        self.assertIn(
            'cp "$BACKUP/CodexBuildMetadata.generated.swift" '
            '"$BUILD_METADATA_SWIFT"',
            script,
        )
        self.assertIn('rm -f "$BUILD_METADATA_SWIFT"', script)

    def test_upgrade_regenerates_experimental_feature_catalog_before_xcode_project(
        self,
    ) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/apply_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")
        generation = script.index('"$FEATURE_CATALOG_SCRIPT"')
        project = script.index(
            'scripts/generate_codexpad_xcode_project.py'
        )

        self.assertLess(generation, project)
        self.assertIn("codex-rs/features/src/lib.rs", script)
        self.assertIn(
            "CodexExperimentalFeatureCatalog.generated.swift",
            script,
        )
        self.assertIn('--source "$FEATURE_SOURCE"', script)
        self.assertIn('--output "$FEATURE_SWIFT"', script)

    def test_upgrade_rolls_back_generated_experimental_feature_catalog(
        self,
    ) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/apply_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")

        self.assertIn(
            'cp "$FEATURE_SWIFT" '
            '"$BACKUP/CodexExperimentalFeatureCatalog.generated.swift"',
            script,
        )
        self.assertIn(
            'cp "$BACKUP/CodexExperimentalFeatureCatalog.generated.swift" '
            '"$FEATURE_SWIFT"',
            script,
        )
        self.assertIn('rm -f "$FEATURE_SWIFT"', script)

    def test_upgrade_syncs_official_recommended_skills_before_xcode_project(
        self,
    ) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/apply_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")
        synchronization = script.index(
            'python3 "$SKILL_SYNC_SCRIPT"'
        )
        project = script.index(
            'scripts/generate_codexpad_xcode_project.py'
        )

        self.assertLess(synchronization, project)
        self.assertIn(
            'SKILL_SOURCE="$PROJECT_ROOT/artifacts/full-reverse-$VERSION/'
            'bundle-resources/skills"',
            script,
        )
        self.assertIn(
            'SKILL_DEST="$PROJECT_ROOT/CodexPad/CodexPad/Application/'
            'Resources/skills"',
            script,
        )
        self.assertIn('--source "$SKILL_SOURCE"', script)
        self.assertIn('--destination "$SKILL_DEST"', script)
        self.assertIn('"recommendedSkillsBundled": True', script)

    def test_upgrade_rolls_back_bundled_recommended_skills(self) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/apply_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")

        self.assertIn(
            'cp -R "$SKILL_DEST" "$BACKUP/recommended-skills"',
            script,
        )
        self.assertIn(
            'cp -R "$BACKUP/recommended-skills" "$SKILL_DEST"',
            script,
        )
        self.assertIn('rm -rf "$SKILL_DEST"', script)

    def test_upgrade_embeds_and_verifies_the_imported_desktop_version(self) -> None:
        upgrade = (
            Path(__file__).parents[1] / "scripts/apply_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")
        verifier = (
            Path(__file__).parents[1] / "scripts/verify_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")

        self.assertIn('--desktop-version "$VERSION"', upgrade)
        self.assertIn('--desktop-build "$BUILD"', upgrade)
        self.assertIn("CFBundleShortVersionString", verifier)
        self.assertIn("CFBundleVersion", verifier)

    def test_upgrade_verifier_builds_and_tests_only_arm64_physical_ipad(
        self,
    ) -> None:
        verifier = (
            Path(__file__).parents[1] / "scripts/verify_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")

        self.assertIn('-destination "$DEVICE_DESTINATION"', verifier)
        self.assertIn("-sdk iphoneos", verifier)
        self.assertIn("Debug-iphoneos", verifier)
        self.assertIn('"physicalDeviceTests": "passed"', verifier)
        self.assertNotIn("Debug-iphonesimulator", verifier)
        self.assertNotIn("Simulator", verifier)
        self.assertNotIn("x86_64", verifier)
        self.assertIn(
            'file "$APP/Codex for ipad" | grep -q \'arm64\'',
            verifier,
        )
        self.assertIn("codesign --verify --deep --strict", verifier)

    def test_upgrade_verifier_checks_complete_physical_device_surface(
        self,
    ) -> None:
        verifier = (
            Path(__file__).parents[1] / "scripts/verify_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("verify_desktop_surface_bundle.py", verifier)
        self.assertIn(
            '"$APP/CodexDesktopSurface"',
            verifier,
        )
        self.assertNotIn("SIMULATOR_APP", verifier)
        self.assertIn('"desktopSurfaceCompleteTree": "passed"', verifier)

    def test_upgrade_verifier_requires_complete_static_interaction_plan_before_xcode(
        self,
    ) -> None:
        verifier = (
            Path(__file__).parents[1] / "scripts/verify_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("parity_capture_plan.py", verifier)
        self.assertIn("audit_ipad_interaction_coverage.py", verifier)
        self.assertIn("--require-complete", verifier)
        self.assertIn(
            '"$PROJECT_ROOT/versions/$VERSION/desktop-interaction-inventory.json"',
            verifier,
        )
        self.assertIn(
            '"$PROJECT_ROOT/CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"',
            verifier,
        )
        audit = verifier.index('"$INTERACTION_COVERAGE_AUDITOR"')
        xcode = verifier.index("xcodebuild \\")
        self.assertLess(audit, xcode)

    def test_upgrade_verifier_records_control_level_static_gap_before_xcode(
        self,
    ) -> None:
        verifier = (
            Path(__file__).parents[1] / "scripts/verify_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("audit_ipad_control_coverage.py", verifier)
        self.assertIn('CONTROL_COVERAGE_LOG="$VERIFICATION_LOG_DIR/', verifier)
        self.assertIn(
            '"$PROJECT_ROOT/artifacts/full-reverse-$VERSION/app-asar/webview"',
            verifier,
        )
        self.assertIn('"$PROJECT_ROOT/CodexPad/CodexPad"', verifier)
        self.assertIn(
            '"$PROJECT_ROOT/CodexPad/Tests/CodexPadUITests"',
            verifier,
        )
        xcode = verifier.index("xcodebuild \\")
        control_audit = verifier[
            verifier.index('python3 "$CONTROL_COVERAGE_AUDITOR"') : xcode
        ]
        self.assertIn("--require-assets-complete", control_audit)
        self.assertIn('--log "static-controls=$CONTROL_COVERAGE_LOG"', verifier)
        audit = verifier.index('"$CONTROL_COVERAGE_AUDITOR"')
        self.assertLess(audit, xcode)

    def test_upgrade_verifier_keeps_manual_visual_certification_separate(
        self,
    ) -> None:
        verifier = (
            Path(__file__).parents[1] / "scripts/verify_ipad_upgrade.sh"
        ).read_text(encoding="utf-8")

        xcode = verifier.index("xcodebuild \\")
        record = verifier.index('python3 - \\\n')
        self.assertLess(xcode, record)
        self.assertNotIn("PARITY_EVIDENCE_BUILDER", verifier)
        self.assertNotIn("PARITY_VERIFIER", verifier)
        self.assertNotIn("capture-input", verifier)
        self.assertNotIn('"desktopParityRelease": {', verifier)
        self.assertIn('"sourceIdentity": {', verifier)
        self.assertIn('"dmgSha256": dmg_sha256', verifier)
        self.assertIn(
            "\"$DMG_SHA256\" \\\n  \"$SWIFT_TEST_COUNT\" <<'PY'",
            verifier,
        )

    def test_upgrade_verifier_atomically_merges_existing_device_evidence(
        self,
    ) -> None:
        version = "26.721.81911"
        build = "5973"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            scripts = root / "scripts"
            scripts.mkdir(parents=True)
            verifier = scripts / "verify_ipad_upgrade.sh"
            shutil.copy2(
                Path(__file__).parents[1] / "scripts/verify_ipad_upgrade.sh",
                verifier,
            )
            shutil.copy2(
                Path(__file__).parents[1]
                / "scripts/verify_desktop_surface_bundle.py",
                scripts / "verify_desktop_surface_bundle.py",
            )
            shutil.copy2(
                Path(__file__).parents[1] / "scripts/protocol_manifest.py",
                scripts / "protocol_manifest.py",
            )
            shutil.copy2(
                Path(__file__).parents[1]
                / "scripts/select_physical_ipad.py",
                scripts / "select_physical_ipad.py",
            )
            shutil.copy2(
                Path(__file__).parents[1]
                / "scripts/ipad_verification_evidence.py",
                scripts / "ipad_verification_evidence.py",
            )
            shutil.copy2(
                Path(__file__).parents[1] / "scripts/swift_test_count.py",
                scripts / "swift_test_count.py",
            )
            shutil.copy2(
                Path(__file__).parents[1]
                / "scripts/verify_desktop_bridge_api.py",
                scripts / "verify_desktop_bridge_api.py",
            )
            self._write_executable(
                scripts / "audit_desktop_apphost_api.py",
                """
                #!/usr/bin/env python3
                import json
                import sys
                from pathlib import Path
                output = Path(sys.argv[sys.argv.index("--output") + 1])
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text(json.dumps({"status": "passed"}) + "\\n", encoding="utf-8")
                """,
            )
            self._write_executable(
                scripts / "audit_ipad_apphost_semantics.py",
                """
                #!/usr/bin/env python3
                import json
                import sys
                from pathlib import Path
                output = Path(sys.argv[sys.argv.index("--output") + 1])
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text(json.dumps({"status": "passed"}) + "\\n", encoding="utf-8")
                """,
            )
            shutil.copy2(
                Path(__file__).parents[1]
                / "scripts/export_xcresult_parity_captures.py",
                scripts / "export_xcresult_parity_captures.py",
            )
            shutil.copy2(
                Path(__file__).parents[1]
                / "scripts/parity_capture_plan.py",
                scripts / "parity_capture_plan.py",
            )
            shutil.copy2(
                Path(__file__).parents[1]
                / "scripts/audit_ipad_interaction_coverage.py",
                scripts / "audit_ipad_interaction_coverage.py",
            )
            shutil.copy2(
                Path(__file__).parents[1]
                / "scripts/audit_ipad_control_coverage.py",
                scripts / "audit_ipad_control_coverage.py",
            )
            shutil.copy2(
                Path(__file__).parents[1]
                / "scripts/build_desktop_ui_parity.py",
                scripts / "build_desktop_ui_parity.py",
            )
            preload_parent = (
                root / "artifacts" / f"full-reverse-{version}"
                / "recovered-electron-source" / ".vite" / "build"
            )
            preload_parent.mkdir(parents=True, exist_ok=True)
            (preload_parent / "preload.js").write_text(
                "const { contextBridge } = require('electron');\n"
                "const BRIDGE = { foo: () => 1 };\n"
                "contextBridge.exposeInMainWorld(\"electronBridge\", BRIDGE);\n",
                encoding="utf-8",
            )
            bridge_parent = (
                root / "CodexPad" / "CodexPad" / "ProtocolBridge"
            )
            bridge_parent.mkdir(parents=True, exist_ok=True)
            (bridge_parent / "CodexDesktopBridgeScript.swift").write_text(
                "// test fixture\nconst bridge = { foo: 1 }\n",
                encoding="utf-8",
            )
            (root / "versions" / version).mkdir(parents=True, exist_ok=True)
            (root / "versions" / version / "desktop-ui-parity.json").write_text(
                '{"desktopVersion":"fixture"}\n',
                encoding="utf-8",
            )
            (root / "versions" / version / "desktop-interaction-inventory.json").write_text(
                json.dumps({
                    "desktopVersion": version,
                    "desktopBuild": build,
                    "sourceIdentity": {
                        "desktopSurfaceTreeSha256": "fixture"
                    },
                    "surfaces": [{"interactionCount": 111}],
                }) + "\n",
                encoding="utf-8",
            )
            from scripts.parity_capture_plan import capture_specs

            parity_ui_tests = (
                root
                / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
            )
            parity_ui_tests.parent.mkdir(parents=True, exist_ok=True)
            parity_ui_tests.write_text(
                "\n".join(
                    f'interactionAcceptance.append("{spec["surfaceId"]}|'
                    f'{spec["captureKey"]}|{spec["route"]}|{spec["state"]}")'
                    for spec in capture_specs()
                ) + "\n",
                encoding="utf-8",
            )
            (root / "CodexPad").mkdir(exist_ok=True)
            (root / "CodexCore").mkdir(exist_ok=True)
            (root / "CodexCore" / "Cargo.toml").write_text(
                "[package]\nname = \"codex-core\"\n",
                encoding="utf-8",
            )
            surface_fixture = root / "surface-fixture"
            (surface_fixture / "assets").mkdir(parents=True)
            payloads = {
                "assets/app.js": b"console.log('Codex')",
                "index.html": b"<html>Codex</html>",
            }
            critical_files = []
            total_bytes = 0
            tree = hashlib.sha256()
            for relative, payload in payloads.items():
                path = surface_fixture / relative
                path.write_bytes(payload)
                digest = hashlib.sha256(payload).hexdigest()
                size = len(payload)
                critical_files.append(
                    {
                        "path": relative,
                        "role": (
                            "entry"
                            if relative == "index.html"
                            else "module-entry"
                        ),
                        "bytes": size,
                        "sha256": digest,
                    }
                )
                tree.update(relative.encode())
                tree.update(b"\0")
                tree.update(str(size).encode())
                tree.update(b"\0")
                tree.update(digest.encode())
                tree.update(b"\n")
                total_bytes += size
            (surface_fixture / "desktop-surface-manifest.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "desktopVersion": version,
                        "desktopBuild": build,
                        "productName": "Codex",
                        "ipadProductName": "Codex for ipad",
                        "resourceDirectoryName": "CodexDesktopSurface",
                        "resourceFileCount": len(payloads),
                        "resourceTotalBytes": total_bytes,
                        "resourceTreeSha256": tree.hexdigest(),
                        "entry": {"path": "index.html"},
                        "criticalFiles": critical_files,
                    }
                ),
                encoding="utf-8",
            )

            artifacts = root / "artifacts"
            artifacts.mkdir(parents=True, exist_ok=True)
            record_path = artifacts / f"ipad-verified-{version}.json"
            preserved_evidence = {
                "deviceValidation": {
                    "status": "passed",
                    "futureEvidence": {"preserve": True},
                },
                "installation": {"status": "passed"},
                "launch": {"status": "passed"},
                "screenshots": [{"path": "artifacts/device-home.png"}],
                "unrecognizedEvidence": {"formatVersion": 2},
            }
            existing_record = {
                "desktopVersion": version,
                "desktopBuild": build,
                **preserved_evidence,
                "rustTests": "stale",
                "swiftTests": "stale",
                "swiftTestCount": 199,
                "physicalDeviceTests": "stale",
            }
            record_path.write_text(
                json.dumps(existing_record, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            original_inode = artifacts / "original-record.json"
            os.link(record_path, original_inode)

            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            fake_commands = {
                "swift": (
                    "#!/usr/bin/env bash\n"
                    "printf '%s\\n' "
                    "'Test run with 205 tests in 3 suites passed'\n"
                ),
                "cargo": (
                    "#!/usr/bin/env bash\n"
                    "printf '%s\\n' 'fixture cargo tests passed'\n"
                ),
                "xcodebuild": (
                    "#!/usr/bin/env bash\n"
                    "set -euo pipefail\n"
                    "printf '%s\\n' 'fixture xcodebuild output'\n"
                    "derived=''\n"
                    "result=''\n"
                    "while [[ $# -gt 0 ]]; do\n"
                    "  if [[ \"$1\" == '-derivedDataPath' ]]; then\n"
                    "    derived=\"$2\"\n"
                    "    shift 2\n"
                    "  elif [[ \"$1\" == '-resultBundlePath' ]]; then\n"
                    "    result=\"$2\"\n"
                    "    shift 2\n"
                    "  else\n"
                    "    shift\n"
                    "  fi\n"
                    "done\n"
                    "if [[ -n \"$result\" ]]; then\n"
                    "  mkdir -p \"$result\"\n"
                    "  printf '%s\\n' fixture >\"$result/Info.plist\"\n"
                    "fi\n"
                    "app=\"$derived/Build/Products/Debug-iphoneos/"
                    "Codex for ipad.app\"\n"
                    "root=\"$(cd \"$derived/../..\" && pwd)\"\n"
                    "mkdir -p \"$app\"\n"
                    ": >\"$app/Info.plist\"\n"
                    ": >\"$app/Codex for ipad\"\n"
                    "rm -rf \"$app/CodexDesktopSurface\"\n"
                    "cp -R \"$root/surface-fixture\" "
                    "\"$app/CodexDesktopSurface\"\n"
                ),
                "xcrun": (
                    "#!/usr/bin/env bash\n"
                    "set -euo pipefail\n"
                    "if [[ \"$*\" == 'xcdevice list --timeout 5' ]]; then\n"
                    "  cat <<'JSON'\n"
                    '[{"name":"Mars iPad","identifier":"00000000-0000000000000000",'
                    '"available":true,"simulator":false,'
                    '"platform":"com.apple.platform.iphoneos",'
                    '"modelName":"iPad Pro (12.9-inch) (5th generation)",'
                    '"operatingSystemVersion":"26.0"}]\n'
                    "JSON\n"
                    "  exit 0\n"
                    "fi\n"
                    "if [[ \"$1\" == 'xcresulttool' ]]; then\n"
                    "  if [[ \"$*\" == *'get test-results summary'* ]]; then\n"
                    "    cat <<'JSON'\n"
                    '{"result":"Passed","totalTestCount":1,'
                    '"passedTests":1,"failedTests":0,'
                    '"skippedTests":0,"expectedFailures":0,'
                    '"startTime":1700000000.0,'
                    '"finishTime":1700000001.0}\n'
                    "JSON\n"
                    "    exit 0\n"
                    "  fi\n"
                    "  output=''\n"
                    "  while [[ $# -gt 0 ]]; do\n"
                    "    if [[ \"$1\" == '--output-path' ]]; then output=\"$2\"; shift 2; else shift; fi\n"
                    "  done\n"
                    "  mkdir -p \"$output\"\n"
                    "  OUTPUT=\"$output\" python3 - <<'PY'\n"
                    "import hashlib, json, os\n"
                    "from pathlib import Path\n"
                    "import struct, zlib\n"
                    "from scripts.parity_capture_plan import capture_specs\n"
                    "root = Path(os.environ['OUTPUT'])\n"
                    "def write_png(path, width, height, rgb):\n"
                    "    raw = b''.join(b'\\x00' + bytes(rgb) * width for _ in range(height))\n"
                    "    def chunk(kind, payload):\n"
                    "        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)\n"
                    "    data = b'\\x89PNG\\r\\n\\x1a\\n'\n"
                    "    data += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))\n"
                    "    data += chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')\n"
                    "    Path(path).write_bytes(data)\n"
                    "rows = []\n"
                    "specs = capture_specs()\n"
                    "for index, spec in enumerate(specs, start=1):\n"
                    "    surface = spec['surfaceId']\n"
                    "    capture_key = spec['captureKey']\n"
                    "    name = f'attachment-{index:02d}.png'\n"
                    "    write_png(root / name, 640 + index, 480 + index, (index * 17 % 255, 40, 80))\n"
                    "    inventory_name = f'inventory-{index:02d}.json'\n"
                    "    inventory = {'controlCount': index + 2, 'keyboardAccessibleCount': index + 1, 'byTag': {'BUTTON': index + 1, 'INPUT': 1}, 'labelFingerprints': [hashlib.sha256(f'{surface}-{capture_key}-label'.encode('utf-8')).hexdigest()]}\n"
                    "    (root / inventory_name).write_text(json.dumps(inventory), encoding='utf-8')\n"
                    "    rows.append({'testIdentifier': f'CodexPadParityCaptureUITests/testCapture{surface}_{capture_key}()', 'attachments': [{'configurationName': 'Parity Capture', 'deviceId': 'fixture-ipad-udid', 'deviceName': 'iPad Pro 13-inch (M5)', 'exportedFileName': name, 'isAssociatedWithFailure': False, 'suggestedHumanReadableName': f'CODEXPAD_PARITY_{surface}__{capture_key}.png', 'timestamp': 1700000000 + index}, {'configurationName': 'Parity Capture', 'deviceId': 'fixture-ipad-udid', 'deviceName': 'iPad Pro 13-inch (M5)', 'exportedFileName': inventory_name, 'isAssociatedWithFailure': False, 'suggestedHumanReadableName': f'CODEXPAD_INVENTORY_{surface}__{capture_key}.json', 'timestamp': 1700000000 + index}]})\n"
                    "actions = ['|'.join((spec['surfaceId'], spec['captureKey'], spec['route'], spec['state'])) for spec in specs]\n"
                    "interaction = 'interaction-acceptance.txt'\n"
                    "(root / interaction).write_text('\\n'.join(actions) + '\\n', encoding='utf-8')\n"
                    "rows.append({'testIdentifier': 'CodexPadParityCaptureUITests/testCaptureReleasedDesktopSurfaces()', 'attachments': [{'configurationName': 'Interaction Acceptance', 'deviceId': 'fixture-ipad-udid', 'deviceName': 'iPad Pro 13-inch (M5)', 'exportedFileName': interaction, 'isAssociatedWithFailure': False, 'suggestedHumanReadableName': 'Physical iPad interaction acceptance', 'timestamp': 1700000020}]})\n"
                    "(root / 'manifest.json').write_text(json.dumps(rows), encoding='utf-8')\n"
                    "PY\n"
                    "  exit 0\n"
                    "fi\n"
                    "exit 2\n"
                ),
                "git": (
                    "#!/usr/bin/env bash\n"
                    "set -euo pipefail\n"
                    "[[ \"$*\" == *'rev-parse HEAD'* ]]\n"
                    "printf '%040d\\n' 8\n"
                ),
                "plutil": (
                    "#!/usr/bin/env bash\n"
                    "case \"$2\" in\n"
                    f"  CFBundleDisplayName) printf '%s\\n' 'Codex for ipad' ;;\n"
                    f"  CFBundleShortVersionString) printf '%s\\n' '{version}' ;;\n"
                    f"  CFBundleVersion) printf '%s\\n' '{build}' ;;\n"
                    "  *) exit 1 ;;\n"
                    "esac\n"
                ),
                "file": (
                    "#!/usr/bin/env bash\n"
                    "printf '%s\\n' 'fixture executable: Mach-O 64-bit arm64'\n"
                ),
                "codesign": (
                    "#!/usr/bin/env bash\n"
                    "if [[ \"$1\" == '-dvv' ]]; then\n"
                    "  printf '%s\\n' 'Authority=Apple Development: Fixture' >&2\n"
                    "fi\n"
                ),
            }
            for name, body in fake_commands.items():
                command = fake_bin / name
                command.write_text(body, encoding="utf-8")
                command.chmod(0o755)
            fixture_tests = root / "tests"
            fixture_tests.mkdir()
            (fixture_tests / "test_verifier_fixture.py").write_text(
                "import unittest\n\n"
                "\n"
                "class VerifierFixtureTests(unittest.TestCase):\n"
                "    def test_fixture_is_valid(self) -> None:\n"
                "        self.assertTrue(True)\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [str(verifier), version, build, "a" * 64],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    **os.environ,
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "DEVELOPMENT_TEAM": "XXXXXXXXXX",
                    "CODEXPAD_RUN_PHYSICAL_ACCEPTANCE": "true",
                },
                timeout=10,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            merged_record = json.loads(record_path.read_text(encoding="utf-8"))
            self.assertEqual(
                {
                    key: merged_record.get(key)
                    for key in preserved_evidence
                },
                preserved_evidence,
            )
            self.assertEqual(
                {
                    key: merged_record.get(key)
                    for key in (
                        "rustTests",
                        "swiftTests",
                        "swiftTestCount",
                        "xcuiTests",
                        "physicalDeviceTests",
                        "physicalDeviceUDID",
                        "physicalDeviceName",
                        "physicalDeviceModel",
                        "physicalDeviceOS",
                        "deviceBuild",
                        "deviceArchitecture",
                        "desktopSurfaceCompleteTree",
                        "sourceIdentity",
                    )
                },
                {
                    "rustTests": "passed",
                    "swiftTests": "passed",
                    "swiftTestCount": 205,
                    "xcuiTests": "passed",
                    "physicalDeviceTests": "passed",
                    "physicalDeviceUDID": "00000000-0000000000000000",
                    "physicalDeviceName": "Mars iPad",
                    "physicalDeviceModel": (
                        "iPad Pro (12.9-inch) (5th generation)"
                    ),
                    "physicalDeviceOS": "26.0",
                    "deviceBuild": "passed",
                    "deviceArchitecture": "arm64",
                    "desktopSurfaceCompleteTree": "passed",
                    "sourceIdentity": {
                        "dmgSha256": "a" * 64,
                    },
                },
            )
            self.assertEqual(
                merged_record["desktopSurface"],
                {
                    "entry": "index.html",
                    "criticalFileCount": 2,
                    "resourceFileCount": 2,
                    "resourceTotalBytes": total_bytes,
                    "resourceTreeSha256": tree.hexdigest(),
                    "deviceBundleVerified": True,
                },
            )
            self.assertEqual(
                json.loads(original_inode.read_text(encoding="utf-8")),
                existing_record,
            )

    def test_upgrade_rejects_malformed_version_and_build_before_using_paths(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            script = self._copy_apply_script(root)

            malformed_version = self._run_apply(script, "../26.721", "5973")
            malformed_build = self._run_apply(script, "26.721.81911", "59x73")

            self.assertEqual(malformed_version.returncode, 64)
            self.assertIn("desktop version is malformed", malformed_version.stderr)
            self.assertEqual(malformed_build.returncode, 64)
            self.assertIn("desktop build is malformed", malformed_build.stderr)
            self.assertFalse((root / "versions").exists())

    def test_upgrade_rejects_source_provenance_version_or_build_mismatch(
        self,
    ) -> None:
        version = "26.721.81911"
        build = "5973"
        source_commit = "a" * 40
        for field, wrong_value in (
            ("desktopVersion", "26.721.00000"),
            ("desktopBuild", "9999"),
        ):
            with self.subTest(field=field):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary) / "project"
                    script = self._copy_apply_script(root)
                    record = {
                        "desktopVersion": version,
                        "desktopBuild": build,
                        "sourceCommit": source_commit,
                    }
                    record[field] = wrong_value
                    source = root / "versions" / version / "official-source.json"
                    source.parent.mkdir(parents=True)
                    source.write_text(json.dumps(record), encoding="utf-8")

                    result = self._run_apply(script, version, build)

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("does not match requested", result.stderr)
                    self.assertFalse((root / "CodexCore").exists())

    def test_source_only_upgrade_integrates_generated_sources_without_building(
        self,
    ) -> None:
        version = "26.803.81509"
        build = "6415"
        source_commit = "a" * 40
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            script = self._copy_apply_script(root)
            scripts = root / "scripts"

            source_record = root / "versions" / version / "official-source.json"
            source_record.parent.mkdir(parents=True)
            source_record.write_text(
                json.dumps(
                    {
                        "desktopVersion": version,
                        "desktopBuild": build,
                        "embeddedCliVersion": "0.147.0-alpha.6.6",
                        "sourceCommit": source_commit,
                    }
                ),
                encoding="utf-8",
            )
            cargo_toml = root / "CodexCore" / "Cargo.toml"
            cargo_toml.parent.mkdir(parents=True)
            cargo_toml.write_text(
                'codex-api = { git = "https://example.invalid", '
                f'rev = "{"b" * 40}" }}\n'
                'codex-client = { package = "codex-http-client", '
                'git = "https://example.invalid", '
                f'rev = "{"b" * 40}" }}\n'
                'codex-protocol = { git = "https://example.invalid", '
                f'rev = "{"b" * 40}" }}\n',
                encoding="utf-8",
            )
            provider = root / "CodexCore" / "src" / "official_provider.rs"
            provider.parent.mkdir(parents=True)
            provider.write_text(
                f'const OFFICIAL_SOURCE_COMMIT: &str = "{"b" * 40}";\n',
                encoding="utf-8",
            )
            (root / "CodexCore" / "Cargo.lock").write_text(
                "lock\n",
                encoding="utf-8",
            )
            model_source = (
                root
                / f"artifacts/full-reverse-{version}/official-codex-source/"
                "codex-rs/models-manager/models.json"
            )
            model_source.parent.mkdir(parents=True)
            model_source.write_text('{"models":[]}\n', encoding="utf-8")
            (model_source.parents[1] / "Cargo.toml").write_text(
                "[workspace.package]\nversion = \"0.147.0-alpha.6.6\"\n",
                encoding="utf-8",
            )
            feature_source = (
                root
                / f"artifacts/full-reverse-{version}/official-codex-source/"
                "codex-rs/features/src/lib.rs"
            )
            feature_source.parent.mkdir(parents=True)
            feature_source.write_text(
                "pub const FEATURES: &[FeatureSpec] = &[];\n",
                encoding="utf-8",
            )
            skill_source = (
                root
                / f"artifacts/full-reverse-{version}/bundle-resources/skills"
            )
            skill_source.mkdir(parents=True)
            icon_source = root / "versions" / version / "app-icons"
            icon_source.mkdir()

            generator_outputs = {
                "generate_model_catalog.py": (
                    "import pathlib,sys\n"
                    "for flag in "
                    "('--json-output','--swift-output','--rust-json-output',"
                    "'--rust-client-version-output'):\n"
                    " p=pathlib.Path(sys.argv[sys.argv.index(flag)+1]);"
                    " p.parent.mkdir(parents=True,exist_ok=True);"
                    " p.write_text('generated model\\n')\n"
                ),
                "generate_build_metadata.py": (
                    "import pathlib,sys\n"
                    "p=pathlib.Path(sys.argv[sys.argv.index('--swift-output')+1]);"
                    "p.parent.mkdir(parents=True,exist_ok=True);"
                    "p.write_text('generated metadata\\n')\n"
                ),
                "generate_experimental_feature_catalog.py": (
                    "import pathlib,sys\n"
                    "p=pathlib.Path(sys.argv[sys.argv.index('--output')+1]);"
                    "p.parent.mkdir(parents=True,exist_ok=True);"
                    "p.write_text('generated features\\n')\n"
                ),
            }
            for name, body in generator_outputs.items():
                (scripts / name).write_text(body, encoding="utf-8")

            self._write_executable(
                scripts / "sync_official_app_icon.sh",
                """
                root="$(cd "$(dirname "$0")/.." && pwd)"
                destination="$root/CodexPad/CodexPad/Resources/Assets.xcassets/AppIcon.appiconset"
                mkdir -p "$destination"
                printf 'icon\n' >"$destination/Contents.json"
                """,
            )
            (scripts / "sync_official_recommended_skills.py").write_text(
                "import pathlib,sys\n"
                "p=pathlib.Path(sys.argv[sys.argv.index('--destination')+1]);"
                "p.mkdir(parents=True,exist_ok=True);"
                "(p/'fixture').write_text('skill\\n')\n",
                encoding="utf-8",
            )
            (scripts / "generate_codexpad_xcode_project.py").write_text(
                "import pathlib,sys\n"
                "p=pathlib.Path(sys.argv[sys.argv.index('--project-root')+1]);"
                "(p/'CodexPad.xcodeproj').mkdir(parents=True,exist_ok=True);"
                "(p/'CodexPad.xcodeproj/project.pbxproj').write_text("
                "'generated project\\n')\n",
                encoding="utf-8",
            )
            build_marker = root / "build-was-called"
            self._write_executable(
                scripts / "build_codex_core_xcframework.sh",
                f"printf called >{build_marker!s}\nexit 91\n",
            )

            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            cargo_log = root / "cargo.log"
            self._write_executable(
                fake_bin / "cargo",
                """
                printf '%s\n' "$*" >>"$CARGO_LOG"
                exit 0
                """,
            )

            result = self._run_apply(
                script,
                version,
                build,
                source_only=True,
                environment={
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "CARGO_LOG": str(cargo_log),
                },
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            cargo_text = cargo_toml.read_text(encoding="utf-8")
            self.assertEqual(cargo_text.count(f'rev = "{source_commit}"'), 3)
            cargo_invocations = cargo_log.read_text(encoding="utf-8")
            self.assertIn("update", cargo_invocations)
            self.assertNotIn("test", cargo_invocations)
            self.assertNotIn("check", cargo_invocations)
            self.assertFalse(build_marker.exists())
            self.assertTrue(
                (
                    root
                    / "CodexPad/CodexPad.xcodeproj/project.pbxproj"
                ).is_file()
            )
            report = json.loads(
                (
                    root / f"artifacts/ipad-upgrade-{version}.json"
                ).read_text(encoding="utf-8")
            )
            self.assertTrue(report["sourceIntegrationComplete"])
            self.assertFalse(report["xcframeworkRebuilt"])

    def test_failed_upgrade_removes_icon_created_when_destination_was_absent(
        self,
    ) -> None:
        version = "26.721.81911"
        build = "5973"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            script = self._copy_apply_script(root)
            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            cargo = fake_bin / "cargo"
            cargo.write_text(
                "#!/usr/bin/env bash\n"
                'cp "$CARGO_MANIFEST_UNDER_TEST" "$CARGO_CAPTURE"\n'
                "exit 0\n",
                encoding="utf-8",
            )
            cargo.chmod(0o755)

            source_record = root / "versions" / version / "official-source.json"
            source_record.parent.mkdir(parents=True)
            source_record.write_text(
                json.dumps(
                    {
                        "desktopVersion": version,
                        "desktopBuild": build,
                        "embeddedCliVersion": "0.0.0",
                        "sourceCommit": "a" * 40,
                    }
                ),
                encoding="utf-8",
            )
            cargo_toml = root / "CodexCore" / "Cargo.toml"
            cargo_toml.parent.mkdir(parents=True)
            cargo_toml.write_text(
                'codex-api = { git = "https://example.invalid", '
                f'rev = "{"b" * 40}" }}\n'
                'codex-client = { package = "codex-http-client", '
                'git = "https://example.invalid", '
                f'rev = "{"b" * 40}" }}\n'
                'codex-protocol = { git = "https://example.invalid", '
                f'rev = "{"b" * 40}" }}\n',
                encoding="utf-8",
            )
            cargo_capture = root / "cargo-during-upgrade.toml"
            provider = root / "CodexCore" / "src" / "official_provider.rs"
            provider.parent.mkdir(parents=True)
            provider.write_text(
                f'const OFFICIAL_SOURCE_COMMIT: &str = "{"b" * 40}";\n',
                encoding="utf-8",
            )
            (root / "CodexCore" / "Cargo.lock").write_text(
                "lock\n",
                encoding="utf-8",
            )
            model_source = (
                root
                / f"artifacts/full-reverse-{version}/official-codex-source/"
                "codex-rs/models-manager/models.json"
            )
            model_source.parent.mkdir(parents=True)
            model_source.write_text('{"models":[]}\n', encoding="utf-8")
            (model_source.parents[1] / "Cargo.toml").write_text(
                "[workspace.package]\nversion = \"0.0.0\"\n",
                encoding="utf-8",
            )
            feature_source = (
                root
                / f"artifacts/full-reverse-{version}/official-codex-source/"
                "codex-rs/features/src/lib.rs"
            )
            feature_source.parent.mkdir(parents=True, exist_ok=True)
            feature_source.write_text(
                "pub const FEATURES: &[FeatureSpec] = &[];\n",
                encoding="utf-8",
            )
            skill_source = (
                root
                / f"artifacts/full-reverse-{version}/bundle-resources/"
                "skills/skills/.curated/fixture"
            )
            skill_source.mkdir(parents=True)
            (skill_source / "SKILL.md").write_text(
                "---\nname: fixture\n---\n",
                encoding="utf-8",
            )

            for name, body in {
                "generate_model_catalog.py": (
                    "import pathlib,sys\n"
                    "args=sys.argv\n"
                    "for flag in "
                    "('--json-output','--swift-output','--rust-json-output',"
                    "'--rust-client-version-output'):\n"
                    " p=pathlib.Path(args[args.index(flag)+1]);"
                    " p.parent.mkdir(parents=True,exist_ok=True);"
                    " p.write_text('generated\\n')\n"
                ),
                "generate_build_metadata.py": (
                    "import pathlib,sys\n"
                    "p=pathlib.Path(sys.argv[sys.argv.index('--swift-output')+1]);"
                    "p.parent.mkdir(parents=True,exist_ok=True);"
                    "p.write_text('generated\\n')\n"
                ),
                "generate_experimental_feature_catalog.py": (
                    "import pathlib,sys\n"
                    "p=pathlib.Path(sys.argv[sys.argv.index('--output')+1]);"
                    "p.parent.mkdir(parents=True,exist_ok=True);"
                    "p.write_text('generated\\n')\n"
                ),
            }.items():
                (root / "scripts" / name).write_text(body, encoding="utf-8")
            for name in ("build_codex_core_xcframework.sh",):
                helper = root / "scripts" / name
                helper.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
                helper.chmod(0o755)
            shutil.copy2(
                Path(__file__).parents[1]
                / "scripts/sync_official_recommended_skills.py",
                root / "scripts/sync_official_recommended_skills.py",
            )

            sync = root / "scripts" / "sync_official_app_icon.sh"
            sync.write_text(
                "#!/usr/bin/env bash\n"
                "set -e\n"
                'root="$(cd "$(dirname "$0")/.." && pwd)"\n'
                'dest="$root/CodexPad/CodexPad/Resources/Assets.xcassets/'
                'AppIcon.appiconset"\n'
                'mkdir -p "$dest"\n'
                'printf new >"$dest/AppIcon.png"\n',
                encoding="utf-8",
            )
            sync.chmod(0o755)
            generator = root / "scripts" / "generate_codexpad_xcode_project.py"
            generator.write_text("raise SystemExit(42)\n", encoding="utf-8")

            icon_destination = (
                root
                / "CodexPad/CodexPad/Resources/Assets.xcassets/"
                "AppIcon.appiconset"
            )
            self.assertFalse(icon_destination.exists())
            skill_destination = (
                root
                / "CodexPad/CodexPad/Application/Resources/skills"
            )
            self.assertFalse(skill_destination.exists())

            result = self._run_apply(
                script,
                version,
                build,
                environment={
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "CARGO_MANIFEST_UNDER_TEST": str(cargo_toml),
                    "CARGO_CAPTURE": str(cargo_capture),
                },
            )

            self.assertEqual(result.returncode, 42)
            self.assertEqual(
                cargo_capture.read_text(encoding="utf-8").count(
                    f'rev = "{"a" * 40}"'
                ),
                3,
            )
            self.assertFalse(icon_destination.exists())
            self.assertFalse(skill_destination.exists())

    def test_updater_commit_supplies_trusted_project_root(self) -> None:
        updater = (
            Path(__file__).parents[1] / "scripts/update_latest.sh"
        ).read_text(encoding="utf-8")
        commit = updater[updater.index(
            'python3 "$TRANSACTION_HELPER" commit'
        ):]

        self.assertIn('--root "$PROJECT_ROOT"', commit)
        self.assertLess(
            commit.index('--root "$PROJECT_ROOT"'),
            commit.index('--transaction-dir "$TRANSACTION_DIR"'),
        )


if __name__ == "__main__":
    unittest.main()
