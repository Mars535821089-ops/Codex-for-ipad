from __future__ import annotations

import json
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SELECTOR = ROOT / "scripts/select_physical_ipad.py"
VERIFIER = ROOT / "scripts/verify_ipad_upgrade.sh"
PROJECT = ROOT / "CodexPad/CodexPad.xcodeproj/project.pbxproj"
APP = ROOT / "CodexPad/CodexPad/App/CodexPadApp.swift"
ONBOARDING_UI_TESTS = (
    ROOT
    / "CodexPad/Tests/CodexPadUITests/CodexPadOnboardingUITests.swift"
)
PARITY_CAPTURE_UI_TESTS = (
    ROOT
    / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
)
DESKTOP_SURFACE_CONTROLLER = (
    ROOT
    / "CodexPad/CodexPad/Application/CodexDesktopSurfaceController.swift"
)
DESKTOP_SURFACE_VIEW = (
    ROOT
    / "CodexPad/CodexPad/Presentation/CodexDesktopSurfaceView.swift"
)
IOS_AUTHENTICATION_SESSION = (
    ROOT
    / "CodexPad/CodexPad/Application/CodexIOSAuthenticationSession.swift"
)
ACCOUNT_REFRESH_ADAPTER = (
    ROOT
    / "CodexPad/CodexPad/Application/CodexAccountCredentialRefreshAdapter.swift"
)
OFFICIAL_PROVIDER_CLIENT = (
    ROOT
    / "CodexPad/CodexPad/ProtocolBridge/CodexOfficialProviderClient.swift"
)
DESKTOP_WEBVIEW_HOST = (
    ROOT
    / "CodexPad/CodexPad/Application/CodexDesktopWebViewHost.swift"
)


class IPadExecutionContractTests(unittest.TestCase):
    def test_current_account_navigation_uses_current_composer_labels_and_budget(
        self,
    ) -> None:
        text = ONBOARDING_UI_TESTS.read_text(encoding="utf-8")
        start = text.index(
            "func testCurrentAccountThreadSidebarAndNewChatComposerAreNavigable()"
        )
        end = text.index("\n    @MainActor\n    func ", start + 1)
        flow = text[start:end]

        self.assertIn("executionTimeAllowance = 300", flow)
        self.assertIn('label CONTAINS[c] %@', flow)
        self.assertIn('"ChatGPT"', flow)

    def test_full_physical_verifier_disables_interactive_failure_diagnostics(
        self,
    ) -> None:
        verifier = VERIFIER.read_text(encoding="utf-8")

        self.assertIn("-collect-test-diagnostics never", verifier)
        self.assertIn("-parallel-testing-enabled NO", verifier)
        self.assertIn("-disable-concurrent-destination-testing", verifier)

    def test_browser_and_browsing_state_share_page_restore_state_and_port(self) -> None:
        controller = DESKTOP_SURFACE_CONTROLLER.read_text(encoding="utf-8")
        assembly_start = controller.index(
            "let browserPageRestoreState ="
        )
        router_start = controller.index(
            "return CodexDesktopInitialAppHostRouter(",
            assembly_start,
        )
        assembly = controller[assembly_start : router_start + 2_500]

        self.assertEqual(
            assembly.count("let browserPageRestoreState ="),
            1,
        )
        self.assertRegex(
            assembly,
            re.compile(
                r"CodexDesktopBrowserAppHostService\(\s*"
                r"pageRestoreState: browserPageRestoreState,"
            ),
        )
        self.assertRegex(
            assembly,
            re.compile(
                r"CodexDesktopBrowsingStateAppHostService\(\s*"
                r"pageRestoreState:\s*browserPageRestoreState,"
            ),
        )
        self.assertIn(
            "browsingStateService:\n"
            "                            browsingStateService",
            assembly,
        )
        browsing_start = assembly.index(
            "let browsingStateService ="
        )
        browsing_end = assembly.index(
            "return CodexDesktopInitialAppHostRouter(",
            browsing_start,
        )
        browsing_factory = assembly[browsing_start:browsing_end]
        self.assertIn(
            "callbackDispatcher.send(\n"
            "                                    portID: portID,",
            browsing_factory,
        )

    def test_surface_json_conversion_used_from_sendable_callback_is_nonisolated(
        self,
    ) -> None:
        controller = DESKTOP_SURFACE_CONTROLLER.read_text(encoding="utf-8")
        self.assertIn(
            "private nonisolated static func codexJSONValue(",
            controller,
        )

    def test_project_query_converts_rpc_values_before_json_value_bridge(self) -> None:
        controller = DESKTOP_SURFACE_CONTROLLER.read_text(encoding="utf-8")
        self.assertRegex(
            controller,
            re.compile(
                r"return rpcValue\(\s*"
                r"from:\s*\.object\(\s*"
                r"projects\.mapValues\s*\{\s*value\s+in",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            controller,
            re.compile(
                r"Self\.codexJSONValue\(value\)\s*\?\?\s*\.null",
                re.MULTILINE,
            ),
        )

    def test_reserved_settings_shortcut_retains_swiftui_app_settings_command(
        self,
    ) -> None:
        app = APP.read_text(encoding="utf-8")
        surface = DESKTOP_SURFACE_VIEW.read_text(encoding="utf-8")

        self.assertIn("CodexDesktopNativeShortcutBinding.released", surface)
        self.assertIn("wantsPriorityOverSystemBehavior = true", surface)
        self.assertIn("CommandGroup(replacing: .appSettings)", app)
        self.assertIn(
            'command("Settings", ",", .command, .settings)',
            app,
        )

    def test_released_surface_owns_priority_shortcuts_on_view_controller_chain(
        self,
    ) -> None:
        surface = DESKTOP_SURFACE_VIEW.read_text(encoding="utf-8")

        self.assertIn("UIViewControllerRepresentable", surface)
        self.assertIn("override var keyCommands: [UIKeyCommand]?", surface)
        self.assertIn("wantsPriorityOverSystemBehavior = true", surface)
        self.assertIn("controller.performNativeShortcut(shortcut)", surface)
        self.assertNotIn(
            "private struct CodexDesktopWebView: UIViewRepresentable",
            surface,
        )

    def test_released_surface_expands_main_webview_to_the_scene_bounds(
        self,
    ) -> None:
        surface = DESKTOP_SURFACE_VIEW.read_text(encoding="utf-8")

        main_surface_start = surface.index("if let host = controller.host")
        overlay_start = surface.index(
            "if controller.isAvatarOverlayPresented",
            main_surface_start,
        )
        main_surface = surface[main_surface_start:overlay_start]

        self.assertIn("CodexDesktopWebView(", main_surface)
        self.assertIn("maxWidth: .infinity", main_surface)
        self.assertIn("maxHeight: .infinity", main_surface)

    def test_hardware_shortcut_controller_handles_commands_without_stealing_web_content_focus(
        self,
    ) -> None:
        surface = DESKTOP_SURFACE_VIEW.read_text(encoding="utf-8")
        controller_start = surface.index(
            "private final class CodexDesktopHardwareShortcutViewController"
        )
        container_start = surface.index(
            "private final class CodexDesktopHardwareShortcutContainerView"
        )
        controller = surface[controller_start:container_start]

        self.assertIn("override var keyCommands: [UIKeyCommand]?", controller)
        self.assertIn("override func pressesBegan(", controller)
        self.assertIn("performDesktopShortcut", controller)
        self.assertIn("dispatchHardwareShortcut", controller)
        self.assertIn("recordHardwareShortcutDiagnostic", controller)
        self.assertNotIn("becomeFirstResponder()", controller)

    def test_webview_direct_parent_owns_hardware_shortcuts_on_responder_chain(
        self,
    ) -> None:
        surface = DESKTOP_SURFACE_VIEW.read_text(encoding="utf-8")

        self.assertIn(
            "private final class CodexDesktopHardwareShortcutContainerView: UIView",
            surface,
        )
        self.assertIn(
            "let rootView = CodexDesktopHardwareShortcutContainerView(",
            surface,
        )
        self.assertIn("rootView.addSubview(webView)", surface)
        self.assertIn("override var keyCommands: [UIKeyCommand]?", surface)
        self.assertIn("override func pressesBegan(", surface)
        self.assertIn("command.wantsPriorityOverSystemBehavior = true", surface)
        self.assertIn("onHardwareShortcut(shortcut)", surface)

    def test_model_selector_queries_tolerate_webkit_element_type_changes(
        self,
    ) -> None:
        onboarding = ONBOARDING_UI_TESTS.read_text(encoding="utf-8")
        parity = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")

        for source in (onboarding, parity):
            self.assertIn(
                "readySurface.descendants(matching: .any)\n"
                "            .allElementsBoundByIndex",
                source,
            )
        self.assertNotIn(
            "let modelSelector = readySurface.otherElements",
            onboarding,
        )
        self.assertNotIn(
            "let modelSelector = readySurface.otherElements",
            parity,
        )

    def test_physical_ipad_has_focused_side_chat_shortcut_regression(self) -> None:
        parity = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")

        self.assertIn(
            "func testSideChatShortcutOnPhysicalIPad()",
            parity,
        )
        start = parity.index("func testSideChatShortcutOnPhysicalIPad()")
        end = parity.index("\n    @MainActor", start + 1)
        focused_test = parity[start:end]
        self.assertIn(
            'app.typeKey("s", modifierFlags: [.command, .option])',
            focused_test,
        )
        self.assertIn(
            "The focused Side Chat shortcut did not open its renderer panel.",
            focused_test,
        )
        self.assertNotIn("captureOfficialRenderer(", focused_test)

    def test_physical_ipad_has_focused_terminal_shortcut_regression(self) -> None:
        parity = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")

        self.assertIn(
            "func testTerminalShortcutOnPhysicalIPad()",
            parity,
        )
        start = parity.index("func testTerminalShortcutOnPhysicalIPad()")
        end = parity.index("\n    @MainActor", start + 1)
        focused_test = parity[start:end]
        self.assertIn(
            'app.typeKey("`", modifierFlags: .control)',
            focused_test,
        )
        self.assertIn("selectParityWorkspace(in: surface)", focused_test)
        self.assertIn(
            "providerBoundaryTerminalError(in: surface)",
            focused_test,
        )
        self.assertLess(
            focused_test.index("selectParityWorkspace(in: surface)"),
            focused_test.index('app.typeKey("`", modifierFlags: .control)'),
        )
        self.assertLess(
            focused_test.index("providerBoundaryTerminalError(in: surface)"),
            focused_test.index('app.typeKey("`", modifierFlags: .control)'),
        )
        self.assertIn(
            "The focused Terminal shortcut did not create its renderer panel.",
            focused_test,
        )
        self.assertNotIn("captureOfficialRenderer(", focused_test)

    def test_current_account_appearance_uses_released_semantic_theme_labels(
        self,
    ) -> None:
        onboarding = ONBOARDING_UI_TESTS.read_text(encoding="utf-8")

        for label in (
            "Theme",
            "主题",
            "Use system theme",
            "System theme",
            "Light theme",
            "Dark theme",
        ):
            self.assertIn(f'"{label}"', onboarding)
        self.assertIn(
            '"Settings Appearance accessibility inventory"', onboarding
        )
        self.assertIn('"Settings Appearance before assertion"', onboarding)
        inventory = onboarding.index(
            '"Settings Appearance accessibility inventory"'
        )
        screenshot = onboarding.index(
            '"Settings Appearance before assertion"'
        )
        assertion = onboarding.index(
            '"Opening Appearance did not expose a desktop Theme option."'
        )
        self.assertLess(inventory, assertion)
        self.assertLess(screenshot, assertion)

    def test_provider_boundary_acceptance_reports_any_verified_terminal_provider_error(
        self,
    ) -> None:
        parity = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")

        self.assertIn("providerBoundaryTerminalError", parity)
        for fragment in (
            "saved sign-in credential was rejected",
            "model is not supported",
            "invalid api key",
            "incorrect api key",
            "authentication",
            "unauthorized",
            "bad request",
            "providertransportfailure",
            "provider request timed out",
        ):
            self.assertIn(f'"{fragment}"', parity.lower())

    def test_onboarding_ui_tests_accept_the_released_localized_workspace_labels(
        self,
    ) -> None:
        onboarding = ONBOARDING_UI_TESTS.read_text(encoding="utf-8")

        for label in (
            "Pull requests",
            "拉取请求",
            "Scheduled",
            "已安排",
            "Plugins",
            "插件",
            "Send",
            "发送",
        ):
            self.assertIn(f'"{label}"', onboarding)
        self.assertIn("releasedProviderBoundaryTerminalError", onboarding)

    def test_signed_out_ui_tests_force_a_non_destructive_signed_out_surface(
        self,
    ) -> None:
        onboarding = ONBOARDING_UI_TESTS.read_text(encoding="utf-8")

        for method in (
            "testColdLaunchRoutesPrimaryLoginThroughDeviceCodeInsideApp",
            "testColdLaunchExpandsOfficialAPIKeySignInWithoutSubmittingCredentials",
            "testSignedOutSurfaceExposesTheReleasedLoginButtonInventory",
        ):
            start = onboarding.index(f"func {method}()")
            next_method = onboarding.find("\n    @MainActor\n    func ", start + 1)
            body = onboarding[start: next_method if next_method != -1 else None]
            self.assertIn(
                'app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"',
                body,
            )
            self.assertIn(
                'app.launchEnvironment["CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"]',
                body,
            )

    def test_placeholder_api_key_submit_accepts_released_localized_label(
        self,
    ) -> None:
        onboarding = ONBOARDING_UI_TESTS.read_text(encoding="utf-8")
        start = onboarding.index(
            "private func signIntoReleasedSurfaceWithPlaceholder("
        )
        end = onboarding.index(
            "func testPlaceholderCredentialCreatesThreadBeforeProviderRejectsTurn()",
            start,
        )
        body = onboarding[start:end]

        self.assertIn('"Continue"', body)
        self.assertIn('"继续"', body)
        self.assertIn("NSPredicate", body)

    def test_navigation_acceptance_respects_account_capability_gating(self) -> None:
        onboarding = ONBOARDING_UI_TESTS.read_text(encoding="utf-8")
        start = onboarding.index(
            "func testAuthenticatedReleasedPrimaryNavigationButtonsOpenTheirDesktopSurfaces()"
        )
        end = onboarding.index("\n    @MainActor\n    func ", start + 1)
        placeholder_body = onboarding[start:end]

        current_start = onboarding.index(
            "func testCurrentAccountFeatureGatedPrimaryNavigation()"
        )
        current_end = onboarding.index(
            "\n    @MainActor\n    func ", current_start + 1
        )
        current_body = onboarding[current_start:current_end]

        self.assertNotIn('"Pull requests"', placeholder_body)
        self.assertNotIn('"Pull Request"', placeholder_body)
        self.assertIn('"Scheduled"', placeholder_body)
        self.assertIn('"Plugins"', placeholder_body)
        self.assertIn('"ChatGPT"', placeholder_body)
        self.assertIn('"Pull requests"', current_body)
        self.assertIn('"Pull Request"', current_body)
        self.assertIn("if pullRequests.exists", current_body)
        self.assertIn(
            'readySurface.waitForExistence(timeout: 90)',
            current_body,
        )
        self.assertIn("readySurface.descendants(matching: .any)", placeholder_body)
        for label in ("Hide sidebar", "隐藏边栏", "Show sidebar", "显示边栏", "Search", "搜索"):
            self.assertIn(f'"{label}"', placeholder_body)

    def test_authentication_browser_acceptance_uses_released_close_control(
        self,
    ) -> None:
        onboarding = ONBOARDING_UI_TESTS.read_text(encoding="utf-8")
        start = onboarding.index(
            "func testColdLaunchRoutesPrimaryLoginThroughDeviceCodeInsideApp()"
        )
        end = onboarding.index(
            "func testColdLaunchExpandsOfficialAPIKeySignInWithoutSubmittingCredentials()",
            start,
        )
        body = onboarding[start:end]

        self.assertIn('otherElements["CodexAuthenticationBrowser"]', body)
        self.assertIn('"Close"', body)
        self.assertIn('"关闭"', body)
        self.assertIn("authenticationBrowser.descendants(matching: .any)", body)

    def test_real_provider_turn_does_not_add_a_fixed_post_completion_delay(
        self,
    ) -> None:
        parity = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")
        start = parity.index(
            "func testSavedChatGPTAccountCompletesOneRealTurnOnPhysicalIPad()"
        )
        end = parity.index(
            "func testAPIKeyTransportErrorTerminatesThinkingOnPhysicalIPad()",
            start,
        )
        real_provider_turn = parity[start:end]

        self.assertNotIn("addingTimeInterval(10)", real_provider_turn)

    def test_side_chat_acceptance_recognizes_released_localized_tab_labels(
        self,
    ) -> None:
        parity = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")

        for label in (
            "Side chat",
            "Side chat [0-9]+",
            "侧边聊天",
            "侧边聊天 [0-9]+",
            "Chat sidebar options",
            "聊天侧边栏选项",
            "No chats",
            "无聊天",
        ):
            self.assertIn(f'"{label}"', parity)
        self.assertIn('"Failed to open side chat"', parity)
        self.assertIn('"打开侧边聊天失败"', parity)

    def test_official_provider_uses_native_urlsession_with_rust_wire_contract(
        self,
    ) -> None:
        client = OFFICIAL_PROVIDER_CLIENT.read_text(encoding="utf-8")

        self.assertIn(
            "codex_core_native_official_stream_create(",
            client,
        )
        self.assertIn("session.bytes(for: urlRequest)", client)
        self.assertIn(
            "codex_core_native_official_stream_begin_response_json(",
            client,
        )
        self.assertIn(
            "codex_core_native_official_stream_push_body(",
            client,
        )
        self.assertIn(
            "codex_core_native_official_stream_end_body(",
            client,
        )
        self.assertIn(
            "codex_core_native_official_stream_finish(",
            client,
        )
        self.assertNotIn(
            "codex_core_stream_official_response_json(",
            client,
        )
        self.assertIn("private var providerStreamTail", client)
        self.assertIn("await previousStream?.value", client)

    def test_official_renderer_stream_maps_provider_transport_error(self) -> None:
        controller = DESKTOP_SURFACE_CONTROLLER.read_text(encoding="utf-8")
        start = controller.index(
            "private func streamConversationThroughOfficialProvider("
        )
        end = controller.index(
            "private static func chatGPTMessageEvent(",
            start,
        )
        implementation = controller[start:end]

        self.assertIn(
            "var providerTransportPayload: CodexJSONValue?",
            implementation,
        )
        self.assertIn(
            "providerTransportPayload = payload",
            implementation,
        )
        self.assertRegex(
            implementation,
            re.compile(
                r"CodexDesktopTurnSessionRunner\s*"
                r"\.displayedProviderError\(\s*"
                r"original:\s*error,\s*"
                r"transportPayload:\s*providerTransportPayload"
            ),
        )

    def test_official_renderer_stream_terminates_transport_error_immediately(
        self,
    ) -> None:
        controller = DESKTOP_SURFACE_CONTROLLER.read_text(encoding="utf-8")
        start = controller.index(
            "private func streamConversationThroughOfficialProvider("
        )
        end = controller.index(
            "private static func chatGPTMessageEvent(",
            start,
        )
        implementation = controller[start:end]
        transport_case = implementation.index(
            ') where eventType == "provider_transport_error":'
        )
        next_case = implementation.index(
            "case let .assistantTextDelta",
            transport_case,
        )
        branch = implementation[transport_case:next_case]

        self.assertIn("transportAction(", branch)
        self.assertIn(".refreshCredentials", branch)
        self.assertIn(".fail", branch)
        self.assertIn("throw", branch)
        self.assertIn("CodexOfficialProviderStreamDiagnostic.make(", implementation)
        self.assertRegex(
            implementation,
            re.compile(
                r'terminalReason:\s*"provider_transport_error"'
            ),
        )
        self.assertRegex(
            implementation,
            re.compile(
                r'"error":\s*\.string\(\s*'
                r"String\(describing:\s*displayedError\)"
            ),
        )

    def test_appshot_capture_is_wired_to_the_ipad_webview_only(self) -> None:
        controller = DESKTOP_SURFACE_CONTROLLER.read_text(encoding="utf-8")

        self.assertIn(
            "private lazy var appshotCaptureCoordinator =",
            controller,
        )
        self.assertIn(
            "return try await self.captureAppshotSnapshot()",
            controller,
        )
        self.assertRegex(
            controller,
            re.compile(
                r"appshotCaptureStarter:\s*"
                r"appshotCaptureCoordinator"
            ),
        )
        self.assertIn(
            "appshotHotkeyOperation:",
            controller,
        )
        self.assertIn(
            'case "requestFinalUpdate":',
            controller,
        )
        self.assertIn(
            'case "getState":',
            controller,
        )
        self.assertRegex(
            controller,
            re.compile(
                r"CodexDesktopPeripheralAppHostService\s*"
                r"\.unsupportedAppshotState"
            ),
        )
        self.assertIn(
            'case "setHotkey":',
            controller,
        )
        self.assertRegex(
            controller,
            re.compile(
                r"\.requestFinalUpdate\(\s*"
                r"requestID:\s*requestID\s*\)"
            ),
        )
        self.assertIn(
            "host?.webView",
            controller,
        )
        self.assertIn(
            ".takeSnapshot(with: nil)",
            controller,
        )
        self.assertIn(
            '"data:image/png;base64,"',
            controller,
        )
        self.assertNotIn("NSWorkspace", controller)
        self.assertNotIn("open -n", controller)
        self.assertNotIn("/Applications/ChatGPT.app", controller)

    def test_surface_network_routes_share_account_refresh_adapter(self) -> None:
        controller = DESKTOP_SURFACE_CONTROLLER.read_text(encoding="utf-8")
        adapter = ACCOUNT_REFRESH_ADAPTER.read_text(encoding="utf-8")

        self.assertIn(
            "private lazy var credentialRefreshAdapter:",
            controller,
        )
        self.assertIn(
            "CodexAccountCredentialRefreshAdapter(",
            controller,
        )
        self.assertGreaterEqual(
            len(
                re.findall(
                    r"refreshCredentials:\s*\{\s*"
                    r"\[credentialRefreshAdapter\]\s+in",
                    controller,
                )
            ),
            2,
        )
        self.assertRegex(
            controller,
            re.compile(
                r"try await credentialRefreshAdapter\s*"
                r"\.refresh\(\)"
            ),
        )
        self.assertIn(
            'method: "account/updated"',
            adapter,
        )

    def test_official_provider_stream_retries_expired_chatgpt_credentials_once(
        self,
    ) -> None:
        controller = DESKTOP_SURFACE_CONTROLLER.read_text(encoding="utf-8")
        start = controller.index(
            "private func streamConversationThroughOfficialProvider("
        )
        end = controller.index(
            "private static func chatGPTMessageEvent(",
            start,
        )
        implementation = controller[start:end]

        self.assertIn(
            "var retryGate = CodexOfficialProviderCredentialRetryGate()",
            implementation,
        )
        self.assertIn(
            "retryGate.observe(event)",
            implementation,
        )
        self.assertIn(
            "retryGate.consumeRetryIfEligible(",
            implementation,
        )
        self.assertRegex(
            implementation,
            re.compile(
                r"currentCredentials\s*=\s*try await\s*"
                r"credentialRefreshAdapter\s*\.refresh\(\)"
            ),
        )
        self.assertRegex(
            implementation,
            re.compile(
                r"CodexOfficialResponseRequest\(\s*"
                r"requestID:.*?"
                r"accessToken:\s*currentCredentials\.accessToken",
                re.DOTALL,
            ),
        )

    def _run_selector(
        self,
        devices: list[object],
        *,
        output_format: str | None = None,
        selected_udid: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary) / "devices.json"
            fixture.write_text(json.dumps(devices), encoding="utf-8")
            arguments = [
                    "/usr/bin/python3",
                    str(SELECTOR),
                    "--devices-json",
                    str(fixture),
                ]
            if output_format is not None:
                arguments.extend(["--format", output_format])
            if selected_udid is not None:
                arguments.extend(["--udid", selected_udid])
            return subprocess.run(
                arguments,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
            )

    def test_selector_chooses_only_available_physical_ipad(self) -> None:
        selected_udid = "00000000-0000000000000000"
        result = self._run_selector(
            [
                {
                    "name": "iPad Pro 13-inch (M5)",
                    "identifier": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                    "available": True,
                    "simulator": True,
                    "platform": "com.apple.platform.iphonesimulator",
                    "modelName": "iPad Pro 13-inch (M5)",
                    "operatingSystemVersion": "27.0",
                },
                {
                    "name": "Example iPad Pro",
                    "identifier": selected_udid,
                    "available": True,
                    "simulator": False,
                    "platform": "com.apple.platform.iphoneos",
                    "modelName": "iPad Pro (12.9-inch) (5th generation)",
                    "operatingSystemVersion": "26.0",
                },
                {
                    "name": "Unavailable iPad",
                    "identifier": "00008101-000E11111111111E",
                    "available": False,
                    "simulator": False,
                    "platform": "com.apple.platform.iphoneos",
                    "modelName": "iPad Pro",
                    "operatingSystemVersion": "26.0",
                },
            ]
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), selected_udid)

    def test_selector_reports_actual_physical_device(self) -> None:
        selected_udid = "00000000-0000000000000000"
        result = self._run_selector(
            [{
                "name": "Example iPad Pro",
                "identifier": selected_udid,
                "available": True,
                "simulator": False,
                "platform": "com.apple.platform.iphoneos",
                "modelName": "iPad Pro (12.9-inch) (5th generation)",
                "operatingSystemVersion": "26.0",
            }],
            output_format="json",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "udid": selected_udid,
                "name": "Example iPad Pro",
                "modelName": "iPad Pro (12.9-inch) (5th generation)",
                "operatingSystemVersion": "26.0",
            },
        )

    def test_selector_rejects_missing_duplicate_or_malformed_physical_targets(self) -> None:
        fixtures = (
            [],
            [
                {"name": "iPad A", "identifier": "00000000-0000000000000000", "available": True, "simulator": False, "platform": "com.apple.platform.iphoneos", "modelName": "iPad Pro", "operatingSystemVersion": "26.0"},
                {"name": "iPad B", "identifier": "00008101-000E11111111111E", "available": True, "simulator": False, "platform": "com.apple.platform.iphoneos", "modelName": "iPad Air", "operatingSystemVersion": "26.0"},
            ],
            [{"name": "iPad", "identifier": "../My Mac", "available": True, "simulator": False, "platform": "com.apple.platform.iphoneos", "modelName": "iPad Pro", "operatingSystemVersion": "26.0"}],
        )

        for devices in fixtures:
            with self.subTest(devices=devices):
                result = self._run_selector(devices)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_selector_accepts_explicit_udid_when_multiple_ipads_are_connected(self) -> None:
        selected_udid = "00000000-0000000000000000"
        devices = [
            {"name": "iPad A", "identifier": selected_udid, "available": True, "simulator": False, "platform": "com.apple.platform.iphoneos", "modelName": "iPad Pro", "operatingSystemVersion": "26.0"},
            {"name": "iPad B", "identifier": "00008101-000E11111111111E", "available": True, "simulator": False, "platform": "com.apple.platform.iphoneos", "modelName": "iPad Air", "operatingSystemVersion": "26.0"},
        ]
        result = self._run_selector(devices, selected_udid=selected_udid)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), selected_udid)

    def test_updater_uses_static_validation_without_touching_a_device_by_default(self) -> None:
        updater = (ROOT / "scripts/update_latest.sh").read_text(encoding="utf-8")

        self.assertIn(
            'STATIC_VERIFY_SCRIPT="$PROJECT_ROOT/scripts/verify_ipad_upgrade_static.sh"',
            updater,
        )
        self.assertIn(
            'CODEXPAD_RUN_PHYSICAL_ACCEPTANCE',
            updater,
        )
        self.assertIn(
            '"$STATIC_VERIFY_SCRIPT" "$VERSION" "$BUILD" "$SHA256"',
            updater,
        )
        self.assertIn(
            '"$VERIFY_SCRIPT" "$VERSION" "$BUILD" "$SHA256"',
            updater,
        )
        self.assertNotIn(
            'CODEXPAD_RUN_PHYSICAL_ACCEPTANCE=true',
            updater,
        )

    def test_static_stage_commits_only_the_rollback_snapshot_before_exit(self) -> None:
        updater = (ROOT / "scripts/update_latest.sh").read_text(encoding="utf-8")
        stage_marker = 'Static release staged at $STAGED_RELEASE_RECORD'
        commit_marker = 'python3 "$TRANSACTION_HELPER" commit'
        active_marker = 'TRANSACTION_ACTIVE=false'
        stage_offset = updater.index(stage_marker)
        commit_offset = updater.index(commit_marker, stage_offset)
        active_offset = updater.index(active_marker, commit_offset)
        exit_offset = updater.index('exit 0', active_offset)
        self.assertLess(stage_offset, commit_offset)
        self.assertLess(commit_offset, active_offset)
        self.assertLess(active_offset, exit_offset)
        self.assertIn('latest-official.json', updater[stage_offset:commit_offset])
        self.assertIn('transfer package remains retained', updater[stage_offset:commit_offset])

    def test_physical_acceptance_promotes_exact_staged_candidate_before_archive(self) -> None:
        updater = (ROOT / "scripts/update_latest.sh").read_text(encoding="utf-8")
        self.assertIn('STAGE_RELEASE_HELPER="$PROJECT_ROOT/scripts/stage_ipad_release.py"', updater)
        promote_marker = '"$STAGE_RELEASE_HELPER" promote'
        self.assertIn(promote_marker, updater)
        promote_offset = updater.index(promote_marker)
        archive_offset = updater.index('RELEASE_ARCHIVE_HELPER" archive', promote_offset)
        self.assertLess(promote_offset, archive_offset)
        self.assertIn('ipad-verified-$VERSION.json', updater[promote_offset:archive_offset])

    def test_removed_background_update_check_fails_closed_without_touching_device(self) -> None:
        checker = (ROOT / "scripts/check_and_update_latest.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("AUTOMATIC_UPDATE_DISABLED", checker)
        self.assertNotIn("xcrun devicectl", checker)
        self.assertNotIn("curl ", checker)
        self.assertNotIn("python3 ", checker)
        self.assertNotIn("bash ", checker)

    def test_static_verifier_writes_non_physical_identity_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            scripts = root / "scripts"
            scripts.mkdir(parents=True)
            verifier = scripts / "verify_ipad_upgrade_static.sh"
            shutil.copy2(ROOT / "scripts/verify_ipad_upgrade_static.sh", verifier)
            verifier.chmod(0o755)
            version = "26.814.41957"
            build = "6744"
            dmg_sha256 = "a" * 64

            result = subprocess.run(
                [str(verifier), version, build, dmg_sha256],
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            record = json.loads(
                (root / f"artifacts/ipad-static-validated-{version}.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(record["desktopVersion"], version)
            self.assertEqual(record["desktopBuild"], build)
            self.assertEqual(record["sourceIdentity"]["dmgSha256"], dmg_sha256)
            self.assertEqual(record["validationMode"], "static")
            self.assertEqual(record["physicalDeviceTests"], "not-run")
            self.assertIs(record["checks"]["shellSyntax"], True)
            self.assertIs(record["checks"]["pythonSyntax"], True)
            self.assertEqual(record["swiftTests"], "not-run")
            self.assertEqual(record["rustTests"], "not-run")
            self.assertEqual(record["uiTests"], "not-run")

    def test_verifier_runs_ui_tests_on_explicit_selected_ipad(self) -> None:
        text = VERIFIER.read_text(encoding="utf-8")

        self.assertIn("select_physical_ipad.py", text)
        self.assertIn(
            'DEVICE_DESTINATION="platform=iOS,id=$DEVICE_UDID"',
            text,
        )
        self.assertRegex(
            text,
            re.compile(
                r'xcodebuild \\\n'
                r'(?:.*\n)*?'
                r'  -destination "\$DEVICE_DESTINATION" \\\n'
                r'(?:.*\n)*?'
                r'  test',
            ),
        )
        self.assertIn('"$XCUI_EVIDENCE_HELPER" record', text)
        self.assertIn('"physicalDeviceTests": "passed"', text)
        self.assertIn('"physicalDeviceUDID": physical_device["udid"]', text)
        self.assertNotIn("select_ipad_simulator.py", text)
        self.assertNotIn("iphonesimulator", text)
        self.assertNotIn("iOS Simulator", text)
        self.assertNotIn('"simulatorBuild"', text)

    def test_verifier_invalidates_then_records_fresh_xcresult_evidence(
        self,
    ) -> None:
        text = VERIFIER.read_text(encoding="utf-8")

        self.assertIn(
            'XCUI_EVIDENCE_HELPER="$PROJECT_ROOT/scripts/'
            'ipad_verification_evidence.py"',
            text,
        )
        self.assertIn(
            'XCUI_SUMMARY="$VERIFICATION_LOG_DIR/xcui-summary.json"',
            text,
        )
        self.assertIn(
            'VERIFICATION_RECORD="$PROJECT_ROOT/artifacts/'
            'ipad-verified-$VERSION.json"',
            text,
        )
        invalidation = text.index(
            '"$XCUI_EVIDENCE_HELPER" invalidate'
        )
        first_verifier = text.index('python3 "$BRIDGE_API_VERIFIER"')
        ui_test = text.index("-only-testing:CodexPadUITests")
        result_cleanup = text.index('rm -rf "$XCUI_RESULT"')
        summary_cleanup = text.index('rm -f "$XCUI_SUMMARY"')
        summary = text.index(
            "xcresulttool get test-results summary",
            ui_test,
        )
        record = text.index(
            '"$XCUI_EVIDENCE_HELPER" record',
            summary,
        )
        self.assertLess(invalidation, first_verifier)
        self.assertLess(first_verifier, ui_test)
        self.assertLess(result_cleanup, ui_test)
        self.assertLess(summary_cleanup, ui_test)
        self.assertLess(ui_test, summary)
        self.assertLess(summary, record)
        self.assertLess(
            text.index("export_xcresult_parity_captures.py", summary),
            record,
        )
        self.assertLess(
            text.rindex('python3 "$SURFACE_VERIFIER"'),
            record,
        )
        self.assertNotIn('"xcuiTests": "passed"', text)
        head_recheck = text.index(
            'CURRENT_HEAD="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"',
            summary,
        )
        self.assertLess(head_recheck, record)
        self.assertIn(
            '[[ "$CURRENT_HEAD" == "$SOURCE_HEAD" ]]',
            text[head_recheck:record],
        )
        self.assertIn('--source-head "$SOURCE_HEAD"', text)
        self.assertIn(
            '--contract "$PROJECT_ROOT/versions/$VERSION/'
            'desktop-ui-parity.json"',
            text,
        )
        for log_name in (
            "python",
            "swift",
            "rust",
            "xcui",
            "device-build",
            "device-surface",
        ):
            self.assertIn(f'--log "{log_name}=', text)

    def test_parity_ui_test_owns_required_named_captures_per_surface(
        self,
    ) -> None:
        text = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")
        required_names = {
            "S01": "03__api-key-expanded",
            "S02": "00__sidebar-expanded",
            "S03": "00__home-chat",
            "S04": "09__error",
            "S05": "01__side-chat",
            "S06": "09__empty",
            "S07": "00__created",
            "S08": "00__search",
            "S09": "05__loading",
            "S10": "00__command-palette",
        }
        names = re.findall(
            r'"CODEXPAD_PARITY_(S(?:0[1-9]|10))__([^"]+)"',
            text,
        )

        self.assertIn(
            "final class CodexPadParityCaptureUITests: XCTestCase",
            text,
        )
        self.assertIn(
            "func testCapturesOfficialRendererParitySurfaces()",
            text,
        )
        self.assertTrue(
            set(required_names.items()).issubset(set(names)),
            "The baseline parity capture for one or more surfaces is missing.",
        )
        self.assertEqual(len({surface for surface, _ in names}), 10)
        self.assertIn(("S01", "00__launch"), names)
        self.assertIn(("S01", "01__signed-out"), names)
        self.assertIn(("S01", "02__device-code"), names)
        self.assertIn(("S01", "04__project-selection"), names)
        self.assertIn(("S01", "05__first-run"), names)
        capture_helper = re.search(
            r"private func captureOfficialRenderer\(.*?\n    \}\n\n    @MainActor\n    private func attachInteractionInventory",
            text,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(
            capture_helper,
            "The parity test must centralize renderer screenshots in its capture helper.",
        )
        self.assertEqual(
            capture_helper.group(0).count("XCTAttachment(screenshot: app.screenshot())"),
            1,
        )
        self.assertIn(
            'app.launchEnvironment["CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"]',
            text,
        )
        self.assertIn(
            'app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"',
            text,
        )
        self.assertIn(
            'apiKeyField.typeText("sk-codexpad-ui-test-placeholder")',
            text,
        )
        self.assertNotIn("CodexSurfaces", text)
        self.assertNotIn("NativeRecovery", text)
        project = PROJECT.read_text(encoding="utf-8")
        self.assertIn(
            "CodexPadParityCaptureUITests.swift in Sources",
            project,
        )

    def test_parity_ui_test_recovers_from_ipados_command_comma_capture(
        self,
    ) -> None:
        text = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")

        self.assertIn(
            'bundleIdentifier: "com.apple.Preferences"',
            text,
        )
        self.assertIn(
            '"iPadOS captured parity Command-comma"',
            text,
        )
        self.assertIn(
            "openSettingsThroughReleasedProfileMenu(in: readySurface)",
            text,
        )
        self.assertIn(
            "private func openSettingsThroughReleasedProfileMenu(",
            text,
        )
        self.assertIn('"Open profile menu"', text)
        self.assertIn('"Settings"', text)

    def test_parity_ui_test_recognizes_localized_released_settings(
        self,
    ) -> None:
        text = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")

        self.assertIn(
            "private func releasedSettingsSearch(",
            text,
        )
        self.assertIn("surface.searchFields.matching(", text)
        self.assertIn('"Search settings…"', text)
        self.assertIn('"Search settings"', text)
        self.assertIn('"搜索设置…"', text)
        self.assertIn('"搜索设置"', text)
        self.assertIn(
            "private func releasedSettingsNavigationMarker(",
            text,
        )
        self.assertIn('"General"', text)
        self.assertIn('"常规"', text)
        self.assertIn('"Appearance"', text)
        self.assertIn('"外观"', text)
        self.assertIn(
            "if !releasedSettingsOpen {",
            text,
        )

    def test_parity_ui_test_recognizes_localized_command_menu(
        self,
    ) -> None:
        text = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")

        self.assertIn(
            "private func releasedCommandMenuSearch(",
            text,
        )
        self.assertIn('"Search"', text)
        self.assertIn('"搜索聊天或运行命令"', text)
        self.assertIn('"命令菜单"', text)
        self.assertIn(
            "releasedCommandMenuSearch(",
            text,
        )

    def test_parity_ui_test_does_not_query_is_hittable_in_xcui_predicates(
        self,
    ) -> None:
        text = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")

        self.assertNotIn("isHittable == YES", text)
        self.assertIn(
            "descendants.cells.allElementsBoundByIndex.first(where:",
            text,
        )

    def test_parity_ui_test_emits_ordered_interaction_acceptance_evidence(
        self,
    ) -> None:
        text = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")
        expected = [
            "S01|03__api-key-expanded|/login|api-key-expanded",
            "S02|00__sidebar-expanded|/|sidebar-expanded",
            "S03|00__home-chat|/|home-chat",
            "S04|09__error|/local/:conversationId|error",
            "S05|01__side-chat|/local/:conversationId|side-chat",
            "S07|00__created|/local/:conversationId|created",
            "S10|00__command-palette|*|command-palette",
        ]

        positions = [text.index(f'"{entry}"') for entry in expected]
        self.assertEqual(positions, sorted(positions))
        # Resolve helper invocations inside the main parity flow rather than
        # the private helper declarations that appear later in this file.
        main_start = text.index(
            "func testCapturesOfficialRendererParitySurfaces()"
        )
        main_end = text.index("\n    @MainActor\n    func ", main_start + 1)
        main_flow = text[main_start:main_end]

        review_capture_call = main_start + main_flow.index(
            "captureS06ReviewStates("
        )
        self.assertGreater(
            review_capture_call,
            text.index('"S05|01__side-chat|/local/:conversationId|side-chat"'),
        )
        self.assertLess(
            review_capture_call,
            text.index('"S07|00__created|/local/:conversationId|created"'),
        )
        settings_capture_call = main_start + main_flow.index(
            "captureS08SettingsStates("
        )
        self.assertGreater(
            settings_capture_call,
            text.index('"S07|00__created|/local/:conversationId|created"'),
        )
        secondary_capture_call = main_start + main_flow.index(
            "captureS09SecondaryProductStates("
        )
        # S09 deliberately runs before S08: the physical Settings sweep can
        # strand the released WebView in a nested document, so secondary
        # product evidence is captured from a clean primary-shell restart.
        self.assertLess(secondary_capture_call, settings_capture_call)
        self.assertLess(
            secondary_capture_call,
            text.index('"S10|00__command-palette|*|command-palette"'),
        )
        self.assertLess(
            main_start + main_flow.index("captureS01ConditionalLaunchStates("),
            text.index('"S01|03__api-key-expanded|/login|api-key-expanded"'),
        )
        self.assertGreater(
            main_start + main_flow.index("captureS02SidebarRuntimeStates("),
            text.index('"S02|00__sidebar-expanded|/|sidebar-expanded"'),
        )
        self.assertGreater(
            main_start + main_flow.index("captureS04ConditionalConversationStates("),
            text.index('"S04|09__error|/local/:conversationId|error"'),
        )
        self.assertGreater(
            main_start + main_flow.index("captureS10GlobalInteractionStates("),
            text.index('"S10|00__command-palette|*|command-palette"'),
        )
        # The full-flow test and the focused current-account S08 test both
        # emit this marker; require the contract marker without assuming a
        # single source occurrence.
        self.assertGreaterEqual(
            text.count('"S08|00__search|/settings|search"'),
            1,
        )
        self.assertIn('"S06|09__empty|/diff|empty"', text)
        self.assertTrue(all(text.count(f'"{entry}"') == 1 for entry in expected))
        self.assertIn(
            'interactionEvidence.name = "Physical iPad interaction acceptance"',
            text,
        )
        self.assertIn("let interactionEvidence = XCTAttachment(", text)
        self.assertIn(
            'string: interactionAcceptance.joined(separator: "\\n")',
            text,
        )
        project = PROJECT.read_text(encoding="utf-8")
        self.assertIn(
            "CodexPadParityCaptureUITests.swift */",
            project,
        )

    def test_parity_ui_test_rejects_zero_action_review_and_secondary_surfaces(
        self,
    ) -> None:
        text = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")
        main_start = text.index(
            "func testCapturesOfficialRendererParitySurfaces()"
        )
        main_end = text.index("\n    @MainActor\n    func ", main_start + 1)
        main_flow = text[main_start:main_end]

        for surface_id, capture_call in (
            ("S06", "captureS06ReviewStates("),
            ("S09", "captureS09SecondaryProductStates("),
        ):
            call = main_flow.index(capture_call)
            assertion = main_flow.index(
                f'interactionAcceptance.contains {{ $0.hasPrefix("{surface_id}|") }}'
            )
            self.assertGreater(assertion, call)
            self.assertIn(
                f'"No observed {surface_id} interaction was captured."',
                main_flow,
            )

    def test_focused_s09_ui_test_exports_interaction_acceptance(self) -> None:
        text = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")
        start = text.index(
            "func testCapturesS09SecondaryProductStatesOnPhysicalIPad()"
        )
        end = text.index("\n    @MainActor\n    func ", start + 1)
        flow = text[start:end]

        self.assertIn("let interactionEvidence = XCTAttachment(", flow)
        self.assertIn(
            'string: interactionAcceptance.joined(separator: "\\n")',
            flow,
        )
        self.assertIn(
            'interactionEvidence.name = "Physical iPad interaction acceptance"',
            flow,
        )
        self.assertIn("interactionEvidence.lifetime = .keepAlways", flow)
        self.assertIn("add(interactionEvidence)", flow)

    def test_parity_ui_test_attaches_hashed_interaction_inventory_per_surface(
        self,
    ) -> None:
        text = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")

        self.assertIn("import CryptoKit", text)
        self.assertIn('"CODEXPAD_INVENTORY_"', text)
        self.assertIn("interactionInventory", text)
        self.assertIn("SHA256.hash", text)
        self.assertIn("XCTAttachment(data:", text)
        self.assertIn('tag + "\\0" + role + "\\0" + label', text)
        self.assertGreaterEqual(text.count("captureOfficialRenderer("), 11)
        self.assertEqual(
            text.count("attachInteractionInventory("),
            2,
        )

    def test_long_running_parity_capture_owns_an_explicit_execution_allowance(
        self,
    ) -> None:
        text = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")
        start = text.index("func testCapturesOfficialRendererParitySurfaces()")
        end = text.index("\n    @MainActor\n    func ", start + 1)
        flow = text[start:end]

        self.assertIn("executionTimeAllowance = 1_800", flow)

    def test_volatile_renderer_states_skip_full_accessibility_inventory(
        self,
    ) -> None:
        text = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")

        self.assertIn("includeInteractionInventory: Bool = true", text)
        for capture in (
            "CODEXPAD_PARITY_S04__02__working",
            "CODEXPAD_PARITY_S04__01__streaming",
            "CODEXPAD_PARITY_S04__03__queued",
        ):
            call = re.search(
                rf'captureOfficialRenderer\(\s*"{capture}".*?\)',
                text,
                flags=re.DOTALL,
            )
            self.assertIsNotNone(call, capture)
            self.assertIn("includeInteractionInventory: false", call.group(0))

    def test_physical_verifier_allows_the_long_parity_capture_to_finish(self) -> None:
        text = VERIFIER.read_text(encoding="utf-8")

        self.assertIn("-test-timeouts-enabled YES", text)
        self.assertIn("-default-test-execution-time-allowance 1800", text)
        self.assertIn("-maximum-test-execution-time-allowance 1800", text)

    def test_interaction_inventory_does_not_requery_each_snapshot_element(
        self,
    ) -> None:
        text = PARITY_CAPTURE_UI_TESTS.read_text(encoding="utf-8")
        start = text.index("private func attachInteractionInventory(")
        end = text.index("\n    @MainActor\n    private func ", start + 1)
        inventory = text[start:end]
        label_start = text.index("private func normalizedInventoryLabel(")
        label_end = text.index("\n    @MainActor\n    private func ", label_start + 1)
        label_helper = text[label_start:label_end]

        self.assertNotIn("where element.exists", inventory)
        self.assertNotIn("element.frame", inventory)
        self.assertIn("let accessibilityLabel = element.label", label_helper)
        self.assertEqual(label_helper.count("element.label"), 1)

    def test_verifier_exports_parity_captures_after_successful_xcui(
        self,
    ) -> None:
        text = VERIFIER.read_text(encoding="utf-8")
        exporter = (
            'python3 "$PROJECT_ROOT/scripts/'
            'export_xcresult_parity_captures.py"'
        )

        self.assertIn(
            'IPAD_PARITY_CAPTURE_DIR="$PROJECT_ROOT/artifacts/'
            'parity-runtime/$VERSION/$BUILD/ipad"',
            text,
        )
        self.assertIn(exporter, text)
        self.assertIn('--xcresult "$XCUI_RESULT"', text)
        self.assertIn('--output "$IPAD_PARITY_CAPTURE_DIR"', text)
        self.assertIn('--desktop-version "$VERSION"', text)
        self.assertIn('--desktop-build "$BUILD"', text)
        ui_test = text.index("-only-testing:CodexPadUITests")
        exporter_call = text.index(exporter)
        signed_app_check = text.index('[[ -d "$APP" ]]', exporter_call)
        self.assertLess(ui_test, exporter_call)
        self.assertLess(exporter_call, signed_app_check)

    def test_fresh_oauth_manual_input_is_reported_as_a_skipped_manual_gate(
        self,
    ) -> None:
        text = ONBOARDING_UI_TESTS.read_text(encoding="utf-8")

        self.assertIn(
            "lastBrowserState.requiresManualCredentialInput",
            text,
        )
        self.assertIn(
            "Fresh OAuth requires manual credential input on this device.",
            text,
        )
        self.assertRegex(
            text,
            re.compile(
                r"if lastBrowserState\.requiresManualCredentialInput"
                r"\s+\{\s+throw XCTSkip"
            ),
        )
        method_start = text.index(
            "func testFreshOAuthLoginCommitsCredentialsAndSurvivesColdRelaunch()"
        )
        launch = text.index("app.launch()", method_start)
        prelaunch = text[method_start:launch]
        self.assertIn("CODEXPAD_RUN_FRESH_OAUTH_UI_TEST", prelaunch)
        self.assertIn("throw XCTSkip", prelaunch)

    def test_verifier_uses_automatic_personal_team_signing_for_device_tests(
        self,
    ) -> None:
        text = VERIFIER.read_text(encoding="utf-8")

        self.assertIn("-allowProvisioningUpdates", text)
        self.assertIn('DEVELOPMENT_TEAM="$TEAM_ID"', text)
        self.assertIn("CODE_SIGN_STYLE=Automatic", text)
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", text)

    def test_source_has_no_desktop_gui_or_mac_destination_entrypoint(
        self,
    ) -> None:
        source_files = [
            *sorted((ROOT / "scripts").glob("*.sh")),
            *sorted((ROOT / "scripts").glob("*.py")),
            *sorted((ROOT / "CodexPad/CodexPad").rglob("*.swift")),
            *sorted((ROOT / "CodexCore/src").rglob("*.rs")),
        ]
        common_forbidden = (
            re.compile(r"\bosascript\b"),
            re.compile(r"\bNSWorkspace\b"),
            re.compile(r"\bNSRunningApplication\b"),
            re.compile(r"platform=macOS"),
            re.compile(r"\bMy Mac\b"),
            re.compile(r"-sdk\s+macosx"),
            re.compile(r"variant=Mac Catalyst"),
            re.compile(r"/Applications/(?:Codex|ChatGPT)\.app/Contents/MacOS"),
        )
        shell_forbidden = (
            re.compile(
                r"(?:^|[;&|]\s*)(?:/usr/bin/)?open(?:\s|$)",
                re.MULTILINE,
            ),
            re.compile(
                r"(?:^|[;&|]\s*)xed(?:\s|$)",
                re.MULTILINE,
            ),
        )
        python_forbidden = (
            re.compile(
                r"\bsubprocess\.(?:run|call|Popen)\s*\("
                r"[^\n]*(?:['\"](?:/usr/bin/)?open['\"]|['\"]xed['\"])",
            ),
            re.compile(
                r"\bos\.(?:system|popen)\s*\("
                r"[^\n]*(?:/usr/bin/)?(?:open|xed)\s",
            ),
        )

        violations = []
        for path in source_files:
            text = path.read_text(encoding="utf-8", errors="ignore")
            patterns = list(common_forbidden)
            if path.suffix == ".sh":
                patterns.extend(shell_forbidden)
            elif path.suffix == ".py":
                patterns.extend(python_forbidden)
            for pattern in patterns:
                if pattern.search(text):
                    violations.append(
                        f"{path.relative_to(ROOT)}: {pattern.pattern}"
                    )
        self.assertEqual(violations, [])

    def test_generated_project_is_ipad_only_for_app_and_ui_tests(self) -> None:
        text = PROJECT.read_text(encoding="utf-8")

        self.assertGreaterEqual(
            text.count('SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";'),
            4,
        )
        self.assertGreaterEqual(text.count("TARGETED_DEVICE_FAMILY = 2;"), 4)
        self.assertGreaterEqual(text.count("SUPPORTS_MACCATALYST = NO;"), 4)
        self.assertGreaterEqual(
            text.count("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;"),
            4,
        )
        self.assertNotIn("SDKROOT = macosx;", text)

    def test_ios_oauth_driver_is_in_sources_and_uses_custom_plist(self) -> None:
        text = PROJECT.read_text(encoding="utf-8")
        self.assertIn(
            "CodexIOSAuthenticationSession.swift in Sources",
            text,
        )
        self.assertIn(
            "CodexIOSAuthenticationSession.swift */",
            text,
        )
        self.assertGreaterEqual(
            text.count("INFOPLIST_FILE = CodexPad/Resources/Info.plist;"),
            2,
        )
        self.assertGreaterEqual(
            text.count("GENERATE_INFOPLIST_FILE = NO;"),
            2,
        )

    def test_ios_production_login_uses_ready_loopback_listener_and_in_app_browser(
        self,
    ) -> None:
        controller = DESKTOP_SURFACE_CONTROLLER.read_text(encoding="utf-8")
        initializer = controller[
            controller.index("public init(") : controller.index(
                "public init("
            )
            + 4_000
        ]
        login_configuration = controller[
            controller.index("private func configureLoginCoordinator(") :
            controller.index("private func configureLoginCoordinator(")
            + 2_000
        ]
        ios_authentication_session = IOS_AUTHENTICATION_SESSION.read_text(
            encoding="utf-8"
        )

        self.assertIn(
            "authenticationPresentationPolicy:\n"
            "                            .inAppOnly",
            initializer,
        )
        self.assertIn(
            "CodexDesktopLoopbackLoginDriver(",
            login_configuration,
        )
        self.assertIn(
            "CodexLoopbackHTTPServerFactory()",
            login_configuration,
        )
        self.assertIn(
            "successRedirectPolicy: .localOnly",
            login_configuration,
        )
        self.assertNotIn(
            "CodexIOSAuthenticationSessionDriver(",
            login_configuration,
        )
        self.assertNotIn(
            'callbackURLScheme: "http"',
            ios_authentication_session,
        )

    def test_oauth_callback_plist_declares_codex_scheme_and_ipad_architecture(
        self,
    ) -> None:
        info_path = ROOT / "CodexPad/CodexPad/Resources/Info.plist"
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
        schemes = [
            scheme
            for entry in info.get("CFBundleURLTypes", [])
            for scheme in entry.get("CFBundleURLSchemes", [])
        ]
        self.assertIn("codex", schemes)
        self.assertEqual(info["UIRequiredDeviceCapabilities"], ["arm64"])
        self.assertTrue(
            info["NSAppTransportSecurity"]["NSAllowsLocalNetworking"]
        )

    def test_voice_capture_declares_privacy_usage_and_webview_permission_delegate(
        self,
    ) -> None:
        info_path = ROOT / "CodexPad/CodexPad/Resources/Info.plist"
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
        self.assertTrue(info["NSMicrophoneUsageDescription"].strip())

        host = DESKTOP_WEBVIEW_HOST.read_text(encoding="utf-8")
        self.assertIn("WKUIDelegate", host)
        self.assertIn("webView.uiDelegate = self", host)
        self.assertIn("requestMediaCapturePermissionFor", host)
        self.assertIn("decisionHandler: @escaping @MainActor", host)
        self.assertIn("decisionHandler(.grant)", host)

    def test_voice_overlay_receives_persisted_atom_sync_on_its_own_webview(
        self,
    ) -> None:
        controller = DESKTOP_SURFACE_CONTROLLER.read_text(encoding="utf-8")
        callback = controller[
            controller.index("private func configureAvatarOverlayHostCallbacks(") :
            controller.index("private func presentAvatarOverlayIfNeeded()")
        ]

        self.assertIn("replyHost: overlayHost", callback)
        self.assertIn(
            "try overlayHost.markHomeDataLoaded()",
            callback,
        )
        self.assertIn("avatar-overlay home-data-ready", callback)
        self.assertIn("replyHost: CodexDesktopWebViewHost? = nil", controller)
        self.assertIn("await send(response, replyingTo: replyHost)", controller)
        self.assertIn("replyingTo: replyHost", controller)

        mcp_case = controller[
            controller.index("case let .mcpRequest(request):") :
            controller.index("case let .mcpResponse(hostID, response):")
        ]
        self.assertIn(
            "await send(routed.response, replyingTo: replyHost)",
            mcp_case,
        )
        self.assertNotIn("await send(routed.response)\n", mcp_case)


if __name__ == "__main__":
    unittest.main()
