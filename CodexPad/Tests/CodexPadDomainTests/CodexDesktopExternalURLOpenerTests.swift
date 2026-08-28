import CodexPadProtocolBridge
import Foundation
import Testing

@testable import CodexPadApplication

@MainActor
private final class RecordingAuthenticationBrowser:
    CodexDesktopAuthenticationBrowserPresenting
{
    var accepted = true
    private(set) var presentedURLs: [URL] = []
    private(set) var dismissalCount = 0

    func presentAuthentication(at url: URL) -> Bool {
        presentedURLs.append(url)
        return accepted
    }

    func dismissAuthentication() {
        dismissalCount += 1
    }
}

private func desktopAuthenticationWrapperURL(
    authorizeURL: String,
    additionalQueryItems: [URLQueryItem] = []
) -> String {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "chatgpt.com"
    components.path = "/codex/desktop-auth"
    components.queryItems = [
        URLQueryItem(
            name: "authorize_url",
            value: authorizeURL
        )
    ] + additionalQueryItems
    return components.url!.absoluteString
}

@MainActor
@Test
func desktopExternalURLOpenerPreservesHTTPSURLVerbatim() {
    let requestedURL =
        "https://example.test/a%2Fb?query=a%20b&plus=a+b#result"
    var openedURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener { url in
        openedURLs.append(url.absoluteString)
    }

    let accepted = opener.open(
        CodexDesktopOpenInBrowserRequest(
            url: requestedURL,
            initiator: "external_link",
            openTarget: "system-browser",
            source: "manual"
        )
    )

    #expect(accepted)
    #expect(openedURLs == [requestedURL])
}

@MainActor
@Test
func desktopExternalURLOpenerAddsReleasedChatGPTUniversalLinkOptOut() {
    var openedURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener { url in
        openedURLs.append(url.absoluteString)
    }

    let accepted = opener.open(
        CodexDesktopOpenInBrowserRequest(
            url:
                "https://chatgpt.com/c/thread-1"
                + "?model=codex#answer",
            initiator: "external_link",
            openTarget: "system-browser",
            source: "manual"
        )
    )

    #expect(accepted)
    #expect(
        openedURLs == [
            "https://chatgpt.com/c/thread-1"
                + "?model=codex&no_universal_links=1#answer"
        ]
    )
}

@MainActor
@Test
func desktopExternalURLOpenerSetsExistingChatGPTUniversalLinkOptOut() {
    var openedURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener { url in
        openedURLs.append(url.absoluteString)
    }

    let accepted = opener.open(
        CodexDesktopOpenInBrowserRequest(
            url:
                "https://chatgpt.com/c/thread-1"
                + "?no_universal_links=0"
                + "&model=codex"
                + "&no_universal_links=2#answer",
            initiator: "external_link",
            openTarget: "system-browser",
            source: "manual"
        )
    )

    #expect(accepted)
    #expect(
        openedURLs == [
            "https://chatgpt.com/c/thread-1"
                + "?no_universal_links=1&model=codex#answer"
        ]
    )
}

@MainActor
@Test
func desktopExternalURLOpenerDoesNotRewriteOtherHostsOrHTTPChatGPT() {
    let requestedURLs = [
        "https://auth.chatgpt.com/login?next=%2Fc%2Fthread-1",
        "http://chatgpt.com/c/thread-1?model=codex",
    ]
    var openedURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener { url in
        openedURLs.append(url.absoluteString)
    }

    for requestedURL in requestedURLs {
        let accepted = opener.open(
            CodexDesktopOpenInBrowserRequest(
                url: requestedURL,
                initiator: "external_link",
                openTarget: "system-browser",
                source: "manual"
            )
        )

        #expect(accepted)
    }

    #expect(openedURLs == requestedURLs)
}

@MainActor
@Test
func desktopExternalURLOpenerRejectsNonHTTPURLsWithoutCallingUIKit() {
    var openedURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener { url in
        openedURLs.append(url.absoluteString)
    }

    for requestedURL in [
        "file:///private/tmp/report.html",
        "mailto:hello@example.test",
        "codex://thread/thread-1",
    ] {
        let accepted = opener.open(
            CodexDesktopOpenInBrowserRequest(
                url: requestedURL,
                initiator: "external_link",
                openTarget: "system-browser",
                source: "manual"
            )
        )

        #expect(!accepted)
    }

    #expect(openedURLs.isEmpty)
}

@MainActor
@Test
func desktopExternalURLOpenerPresentsReleasedOAuthAuthorizeInApp() {
    let authURL =
        "https://auth.openai.com/oauth/authorize"
        + "?response_type=code&state=state-1"
    let authenticationBrowser = RecordingAuthenticationBrowser()
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    let accepted = opener.open(
        CodexDesktopOpenInBrowserRequest(
            url: authURL,
            initiator: "open_in_browser_bridge",
            openTarget: "external-browser",
            source: "login"
        )
    )

    #expect(accepted)
    #expect(
        authenticationBrowser.presentedURLs.map(\.absoluteString)
            == [authURL]
    )
    #expect(systemURLs.isEmpty)
}

@MainActor
@Test
func desktopExternalURLOpenerPresentsReleasedDeviceVerificationInApp() {
    let authURL = "https://auth.openai.com/codex/device"
    let authenticationBrowser = RecordingAuthenticationBrowser()
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    let accepted = opener.open(
        CodexDesktopOpenInBrowserRequest(
            url: authURL,
            initiator: "open_in_browser_bridge",
            openTarget: "external-browser",
            source: "login"
        )
    )

    #expect(accepted)
    #expect(
        authenticationBrowser.presentedURLs.map(\.absoluteString)
            == [authURL]
    )
    #expect(systemURLs.isEmpty)
}

@MainActor
@Test
func desktopExternalURLOpenerKeepsOAuthNearMissesInSystemBrowser() {
    let requestedURLs = [
        "http://auth.openai.com/oauth/authorize?state=state-1",
        "https://auth.openai.com.example.test/oauth/authorize"
            + "?state=state-1",
        "https://auth.openai.com/oauth/token?state=state-1",
        "https://auth.openai.com:444/oauth/authorize?state=state-1",
    ]
    let authenticationBrowser = RecordingAuthenticationBrowser()
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    for requestedURL in requestedURLs {
        let accepted = opener.open(
            CodexDesktopOpenInBrowserRequest(
                url: requestedURL,
                initiator: "open_in_browser_bridge",
                openTarget: "external-browser",
                source: "login"
            )
        )
        #expect(accepted)
    }

    #expect(authenticationBrowser.presentedURLs.isEmpty)
    #expect(systemURLs == requestedURLs)
}

@MainActor
@Test
func desktopExternalURLOpenerRequiresReleasedExternalBrowserTarget() {
    let authURL =
        "https://auth.openai.com/oauth/authorize"
        + "?response_type=code&state=state-1"
    let authenticationBrowser = RecordingAuthenticationBrowser()
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    let accepted = opener.open(
        CodexDesktopOpenInBrowserRequest(
            url: authURL,
            initiator: "open_in_browser_bridge",
            openTarget: "in-app-browser",
            source: "login"
        )
    )

    #expect(accepted)
    #expect(authenticationBrowser.presentedURLs.isEmpty)
    #expect(systemURLs == [authURL])
}

@MainActor
@Test
func desktopExternalURLOpenerFallsBackWhenInAppPresentationHasNoWindow() {
    let authURL =
        "https://auth.openai.com/oauth/authorize"
        + "?response_type=code&state=state-1"
    let authenticationBrowser = RecordingAuthenticationBrowser()
    authenticationBrowser.accepted = false
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    let accepted = opener.open(
        CodexDesktopOpenInBrowserRequest(
            url: authURL,
            initiator: "open_in_browser_bridge",
            openTarget: "external-browser",
            source: "login"
        )
    )

    #expect(accepted)
    #expect(
        authenticationBrowser.presentedURLs.map(\.absoluteString)
            == [authURL]
    )
    #expect(systemURLs == [authURL])
}

@MainActor
@Test
func desktopExternalURLOpenerPresentsReleasedDesktopAuthWrapperInApp() {
    let authURL =
        "https://auth.openai.com/oauth/authorize"
        + "?response_type=code&state=state-1"
    let wrapperURL = desktopAuthenticationWrapperURL(
        authorizeURL: authURL
    )
    let authenticationBrowser = RecordingAuthenticationBrowser()
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    let accepted = opener.open(
        CodexDesktopOpenInBrowserRequest(
            url: wrapperURL,
            initiator: "open_in_browser_bridge",
            openTarget: "external-browser",
            source: "login"
        )
    )

    #expect(accepted)
    #expect(
        authenticationBrowser.presentedURLs.map(\.absoluteString)
            == [wrapperURL]
    )
    #expect(systemURLs.isEmpty)
}

@MainActor
@Test
func desktopExternalURLOpenerPresentsReleasedStreamlinedDesktopAuthWrapperInApp()
{
    let authURL =
        "https://auth.openai.com/oauth/authorize"
        + "?response_type=code&state=state-1"
    let wrapperURL = desktopAuthenticationWrapperURL(
        authorizeURL: authURL,
        additionalQueryItems: [
            URLQueryItem(
                name: "codex_streamlined_login",
                value: "true"
            )
        ]
    )
    let authenticationBrowser = RecordingAuthenticationBrowser()
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    let accepted = opener.open(
        CodexDesktopOpenInBrowserRequest(
            url: wrapperURL,
            initiator: "open_in_browser_bridge",
            openTarget: "external-browser",
            source: "login"
        )
    )

    #expect(accepted)
    #expect(
        authenticationBrowser.presentedURLs.map(\.absoluteString)
            == [wrapperURL]
    )
    #expect(systemURLs.isEmpty)
}

@MainActor
@Test
func desktopExternalURLOpenerKeepsDesktopAuthWrapperNearMissesInSystemBrowser() {
    let authURL =
        "https://auth.openai.com/oauth/authorize"
        + "?response_type=code&state=state-1"
    let encodedAuthURL = authURL.addingPercentEncoding(
        withAllowedCharacters: .alphanumerics
    )!
    let requestedURLs = [
        "http://chatgpt.com/codex/desktop-auth"
            + "?authorize_url=\(encodedAuthURL)",
        "https://chatgpt.com.example.test/codex/desktop-auth"
            + "?authorize_url=\(encodedAuthURL)",
        "https://chatgpt.com:444/codex/desktop-auth"
            + "?authorize_url=\(encodedAuthURL)",
        "https://user@chatgpt.com/codex/desktop-auth"
            + "?authorize_url=\(encodedAuthURL)",
        "https://user:password@chatgpt.com/codex/desktop-auth"
            + "?authorize_url=\(encodedAuthURL)",
        "https://chatgpt.com/codex/desktop-auth/extra"
            + "?authorize_url=\(encodedAuthURL)",
        "https://chatgpt.com/codex/desktop-auth",
        desktopAuthenticationWrapperURL(
            authorizeURL: authURL,
            additionalQueryItems: [
                URLQueryItem(
                    name: "authorize_url",
                    value: authURL
                )
            ]
        ),
        desktopAuthenticationWrapperURL(
            authorizeURL: authURL,
            additionalQueryItems: [
                URLQueryItem(name: "source", value: "desktop")
            ]
        ),
        desktopAuthenticationWrapperURL(
            authorizeURL:
                "http://auth.openai.com/oauth/authorize"
                + "?state=state-1"
        ),
        desktopAuthenticationWrapperURL(
            authorizeURL:
                "https://auth.openai.com.example.test/oauth/authorize"
                + "?state=state-1"
        ),
        desktopAuthenticationWrapperURL(
            authorizeURL:
                "https://auth.openai.com/oauth/token"
                + "?state=state-1"
        ),
        desktopAuthenticationWrapperURL(
            authorizeURL:
                "https://auth.openai.com:444/oauth/authorize"
                + "?state=state-1"
        ),
        desktopAuthenticationWrapperURL(
            authorizeURL: authURL,
            additionalQueryItems: [
                URLQueryItem(
                    name: "codex_streamlined_login",
                    value: "false"
                )
            ]
        ),
        desktopAuthenticationWrapperURL(
            authorizeURL: authURL,
            additionalQueryItems: [
                URLQueryItem(
                    name: "codex_streamlined_login",
                    value: "true"
                ),
                URLQueryItem(
                    name: "codex_streamlined_login",
                    value: "true"
                ),
            ]
        ),
    ]
    let authenticationBrowser = RecordingAuthenticationBrowser()
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    for requestedURL in requestedURLs {
        let accepted = opener.open(
            CodexDesktopOpenInBrowserRequest(
                url: requestedURL,
                initiator: "open_in_browser_bridge",
                openTarget: "external-browser",
                source: "login"
            )
        )
        #expect(accepted)
    }

    #expect(authenticationBrowser.presentedURLs.isEmpty)
    #expect(systemURLs.count == requestedURLs.count)
}

@MainActor
@Test
func desktopExternalURLOpenerRequiresExternalBrowserTargetForWrapper() {
    let wrapperURL = desktopAuthenticationWrapperURL(
        authorizeURL:
            "https://auth.openai.com/oauth/authorize"
            + "?response_type=code&state=state-1"
    )
    let authenticationBrowser = RecordingAuthenticationBrowser()
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    let accepted = opener.open(
        CodexDesktopOpenInBrowserRequest(
            url: wrapperURL,
            initiator: "open_in_browser_bridge",
            openTarget: "in-app-browser",
            source: "login"
        )
    )

    #expect(accepted)
    #expect(authenticationBrowser.presentedURLs.isEmpty)
    #expect(systemURLs.count == 1)
}

@MainActor
@Test
func desktopExternalURLOpenerInAppOnlyNeverFallsBackForReleasedAuthentication() {
    let authURL =
        "https://auth.openai.com/oauth/authorize"
        + "?response_type=code&state=state-1"
    let wrapperURL = desktopAuthenticationWrapperURL(
        authorizeURL: authURL
    )
    let authenticationBrowser = RecordingAuthenticationBrowser()
    authenticationBrowser.accepted = false
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser,
        authenticationPresentationPolicy: .inAppOnly
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    for requestedURL in [authURL, wrapperURL] {
        let accepted = opener.open(
            CodexDesktopOpenInBrowserRequest(
                url: requestedURL,
                initiator: "open_in_browser_bridge",
                openTarget: "external-browser",
                source: "login"
            )
        )
        #expect(!accepted)
    }

    #expect(
        authenticationBrowser.presentedURLs.map(\.absoluteString)
            == [authURL, wrapperURL]
    )
    #expect(systemURLs.isEmpty)
}

@MainActor
@Test
func desktopExternalURLOpenerInAppOnlyStillOpensNonAuthenticationURLs() {
    let requestedURL =
        "https://example.test/codex/desktop-auth"
        + "?authorize_url=not-an-auth-url"
    let authenticationBrowser = RecordingAuthenticationBrowser()
    authenticationBrowser.accepted = false
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser,
        authenticationPresentationPolicy: .inAppOnly
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    let accepted = opener.open(
        CodexDesktopOpenInBrowserRequest(
            url: requestedURL,
            initiator: "open_in_browser_bridge",
            openTarget: "external-browser",
            source: "login"
        )
    )

    #expect(accepted)
    #expect(authenticationBrowser.presentedURLs.isEmpty)
    #expect(systemURLs == [requestedURL])
}

@MainActor
@Test
func desktopExternalURLOpenerAcknowledgesSessionDriverOwnedAuthenticationOnce()
{
    let authURL =
        "https://auth.openai.com/oauth/authorize"
        + "?response_type=code&state=state-1"
    let wrapperURL = desktopAuthenticationWrapperURL(
        authorizeURL: authURL
    )
    let authenticationBrowser = RecordingAuthenticationBrowser()
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser,
        authenticationPresentationPolicy: .sessionDriverOwned
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    for requestedURL in [authURL, wrapperURL] {
        let accepted = opener.open(
            CodexDesktopOpenInBrowserRequest(
                url: requestedURL,
                initiator: "open_in_browser_bridge",
                openTarget: "external-browser",
                source: "login"
            )
        )
        #expect(accepted)
    }

    #expect(authenticationBrowser.presentedURLs.isEmpty)
    #expect(systemURLs.isEmpty)
}

@MainActor
@Test
func desktopExternalURLOpenerSessionDriverOwnedStillOpensOrdinaryURLs() {
    let requestedURL = "https://example.test/docs"
    let authenticationBrowser = RecordingAuthenticationBrowser()
    var systemURLs: [String] = []
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser,
        authenticationPresentationPolicy: .sessionDriverOwned
    ) { url in
        systemURLs.append(url.absoluteString)
    }

    let accepted = opener.open(
        CodexDesktopOpenInBrowserRequest(
            url: requestedURL,
            initiator: "external_link",
            openTarget: "system-browser",
            source: "manual"
        )
    )

    #expect(accepted)
    #expect(authenticationBrowser.presentedURLs.isEmpty)
    #expect(systemURLs == [requestedURL])
}

@MainActor
@Test
func desktopExternalURLOpenerForwardsAuthenticationCompletion() {
    let authenticationBrowser = RecordingAuthenticationBrowser()
    let opener = CodexDesktopExternalURLOpener(
        authenticationBrowser: authenticationBrowser
    ) { _ in }

    opener.dismissAuthentication()

    #expect(authenticationBrowser.dismissalCount == 1)
}
