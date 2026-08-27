import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class PhysicalRealChatUIContractTests(unittest.TestCase):
    def test_real_chat_waits_on_native_stream_state_before_one_response_query(self):
        source = (
            ROOT
            / "CodexPad/Tests/CodexPadUITests/CodexPadOnboardingUITests.swift"
        ).read_text(encoding="utf-8")
        test_body = source.split(
            "func testCurrentAccountCanSendReceiveAndRestoreARealThread() throws {",
            1,
        )[1].split(
            "func testFreshOAuthLoginCommitsCredentialsAndSurvivesColdRelaunch()",
            1,
        )[0]

        self.assertIn('"CodexLastFetchStreamState"', test_body)
        self.assertIn('state == "complete"', test_body)
        self.assertIn('state == "error"', test_body)
        self.assertNotIn("response.waitForExistence(timeout: 180)", test_body)
        self.assertEqual(test_body.count("response.exists"), 1)

    def test_native_surface_exposes_fetch_stream_state_anchor(self):
        source = (
            ROOT
            / "CodexPad/CodexPad/Presentation/CodexDesktopSurfaceView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn('"CodexLastFetchStreamState"', source)
        self.assertIn("controller.lastFetchStreamState", source)

    def test_physical_parity_chat_uses_native_stream_state(self):
        source = (
            ROOT
            / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
        ).read_text(encoding="utf-8")
        test_body = source.split(
            "func testSavedChatGPTAccountCompletesOneRealTurnOnPhysicalIPad() {",
            1,
        )[1].split(
            "func testAPIKeyTransportErrorTerminatesThinkingOnPhysicalIPad()",
            1,
        )[0]

        self.assertIn('"CodexLastFetchStreamState"', test_body)
        self.assertIn('state == "complete"', test_body)
        self.assertIn('state == "error"', test_body)
        self.assertNotIn("completedReply.waitForExistence", test_body)
        self.assertEqual(test_body.count("completedReply.exists"), 1)

    def test_official_provider_preserves_ipados_system_proxy_routing(self):
        source = (
            ROOT
            / "CodexPad/CodexPad/ProtocolBridge/CodexOfficialProviderClient.swift"
        ).read_text(encoding="utf-8")

        make_session = source.split(
            "static func makeSession(proxyURL: String?) -> URLSession {", 1
        )[1].split("return URLSession(configuration: configuration)", 1)[0]

        self.assertNotIn("connectionProxyDictionary", make_session)
        self.assertNotIn("kCFNetworkProxiesHTTPEnable", make_session)
        self.assertIn("system proxy", make_session)

    def test_released_conversation_stream_preserves_ipados_system_routing(self):
        source = (
            ROOT
            / "CodexPad/CodexPad/Application/CodexDesktopNetworkFetchClient.swift"
        ).read_text(encoding="utf-8")

        make_session = source.split(
            "public static func makeDefaultSession() -> URLSession {", 1
        )[1].split("return URLSession(configuration: configuration)", 1)[0]

        self.assertNotIn("connectionProxyDictionary", make_session)
        self.assertNotIn("kCFNetworkProxiesHTTPEnable", make_session)
        self.assertIn("system proxy", make_session)
        self.assertIn("/f/conversation", make_session)

    def test_released_composer_locator_covers_observed_physical_ipad_labels(self):
        source = (
            ROOT
            / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
        ).read_text(encoding="utf-8")
        fixture = json.loads(
            (
                ROOT
                / "tests/fixtures/ios-fix/real-chat-composer-locator-pre.json"
            ).read_text(encoding="utf-8")
        )

        self.assertIn("private func releasedComposer", source)
        self.assertIn('"ChatGPT"', source)
        for label in fixture["observedComposer"]["labels"]:
            self.assertIn("ChatGPT", label)

    def test_all_real_chat_paths_use_the_shared_composer_locator(self):
        source = (
            ROOT
            / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
        ).read_text(encoding="utf-8")

        self.assertEqual(source.count("let composer = releasedComposer(in:"), 3)


if __name__ == "__main__":
    unittest.main()
