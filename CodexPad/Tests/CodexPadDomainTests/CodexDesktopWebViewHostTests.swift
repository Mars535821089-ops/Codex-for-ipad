import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopAppShellShortcutStateParsesReleasedRendererPayload() {
    let state = CodexDesktopAppShellShortcutState(
        payload: .object([
            "bottomPanelBrowserCanZoom": .bool(false),
            "bottomPanelBrowserConversationId": .null,
            "bottomPanelBrowserTabId": .null,
            "canAcceptAppshotShortcut": .bool(true),
            "canRedoAppAction": .bool(false),
            "canUndoAppAction": .bool(true),
            "bottomPanelCanCloseActiveTab": .bool(false),
            "focusArea": .string("main"),
            "focusedEditable": .string("composer"),
            "imagePreviewOpen": .bool(false),
            "isNewChatRoute": .bool(true),
            "terminalFocused": .bool(false),
            "threadNavigationShortcutLocked": .bool(true),
            "rightPanelBrowserCanZoom": .bool(false),
            "rightPanelBrowserConversationId": .null,
            "rightPanelBrowserTabId": .null,
            "rightPanelCanCloseActiveTab": .bool(false),
        ])
    )

    #expect(state?.focusArea == "main")
    #expect(state?.focusedEditable == "composer")
    #expect(state?.canAcceptAppshotShortcut == true)
    #expect(state?.canUndoAppAction == true)
    #expect(state?.threadNavigationShortcutLocked == true)
    #expect(state?.bottomPanelBrowserConversationID == nil)
    #expect(state?.rightPanelBrowserTabID == nil)
}

@Test
func desktopAppShellShortcutStateRejectsIncompletePayload() {
    #expect(
        CodexDesktopAppShellShortcutState(
            payload: .object(["focusArea": .string("main")])
        ) == nil
    )
}

@Test
func desktopWebViewContractPinsTheReleasedRendererHostBoundary() {
    let contract = CodexDesktopWebViewContract.official

    #expect(contract.surfaceDirectoryName == "CodexDesktopSurface")
    #expect(contract.entryFilename == "index.html")
    #expect(contract.applicationScheme == "app")
    #expect(contract.applicationHost == "-")
    #expect(contract.messageHandlerName == "codexDesktopBridge")
    #expect(contract.viewMessageChannel == "view-message")
    #expect(contract.injectionPhase == .documentStart)
    #expect(contract.injectForMainFrameOnly)
    #expect(
        contract.hostReceiveFunctionBody
            == "window.__codexDesktopHost.receive(message)"
    )
    #expect(contract.hostReceiveArgumentName == "message")
}

@Test
func desktopIPadLoginAdapterRoutesReleasedEntryAndPrimaryActionToDeviceCode()
    throws
{
    let releasedLoginRoute = #"""
    let P=N,F=async()=>{},I=F;
    const primary={handleChatGptSignIn:P,isChatGptSignInPending:c};
    const secondary={handleChatGptDeviceCodeSignIn:I};
    function Zt(){let e=(0,Qt.c)(3);{let t;return e[1]===Symbol.for(`react.memo_cache_sentinel`)?(t=(0,$t.jsx)(qt,{}),e[1]=t):t=e[1],t}let t;return e[2]===Symbol.for(`react.memo_cache_sentinel`)?(t=(0,$t.jsx)(rt,{}),e[2]=t):t=e[2],t}
    """#

    let adapted = try CodexDesktopIPadLoginResourceAdapter.adapt(
        Data(releasedLoginRoute.utf8),
        resourceFilename: "login-route-3tZFeNXg.js"
    )
    let source = try #require(String(data: adapted, encoding: .utf8))

    #expect(source.contains("handleChatGptSignIn:I"))
    #expect(!source.contains("handleChatGptSignIn:P"))
    #expect(source.contains("handleChatGptDeviceCodeSignIn:I"))
    #expect(!source.contains("(t=(0,$t.jsx)(qt,{})"))
    #expect(source.contains("(t=(0,$t.jsx)(rt,{})"))
}

@Test
func desktopIPadLoginAdapterLeavesUnrelatedJavaScriptUntouched() throws {
    let source = Data("const route = 'settings';".utf8)

    let adapted = try CodexDesktopIPadLoginResourceAdapter.adapt(
        source,
        resourceFilename: "settings-route.js"
    )

    #expect(adapted == source)
}

@Test
func desktopWebViewResourceLocatorKeepsReadAccessAtTheSurfaceDirectory()
    throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let surface = root.appendingPathComponent(
        "CodexDesktopSurface",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: surface,
        withIntermediateDirectories: true
    )
    let entry = surface.appendingPathComponent("index.html")
    try Data("<!doctype html>".utf8).write(to: entry)
    defer {
        try? fileManager.removeItem(at: root)
    }

    let plan = try CodexDesktopWebViewResourceLocator.resolve(
        bundleResourceURL: root
    )

    #expect(plan.entryURL == entry.standardizedFileURL)
    #expect(plan.readAccessURL == surface.standardizedFileURL)
    #expect(plan.requestURL.absoluteString == "app://-/index.html")
}

@Test
func desktopWebViewResourceLocatorCanOpenTheReleasedAvatarOverlayRoute()
    throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let surface = root.appendingPathComponent(
        "CodexDesktopSurface",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: surface,
        withIntermediateDirectories: true
    )
    let entry = surface.appendingPathComponent("index.html")
    try Data("<!doctype html>".utf8).write(to: entry)
    defer { try? fileManager.removeItem(at: root) }

    let plan = try CodexDesktopWebViewResourceLocator.resolve(
        bundleResourceURL: root,
        initialRoute: "/avatar-overlay"
    )

    #expect(plan.entryURL == entry.standardizedFileURL)
    #expect(plan.readAccessURL == surface.standardizedFileURL)
    #expect(
        plan.requestURL.absoluteString
            == "app://-/avatar-overlay"
    )
}

@Test
func desktopWebViewResourceResolverServesEntryDocumentForReleasedRoutes()
    throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let entry = root.appendingPathComponent("index.html")
    try Data("<!doctype html>".utf8).write(to: entry)
    defer { try? fileManager.removeItem(at: root) }

    for route in ["/avatar-overlay", "/local/thread-123"] {
        let resource = try CodexDesktopWebViewAppResourceResolver.resolve(
            requestURL: #require(URL(string: "app://-" + route)),
            surfaceDirectoryURL: root
        )
        #expect(resource.fileURL == entry.standardizedFileURL)
        #expect(resource.mimeType == "text/html")
    }
}

@Test
func desktopLastActiveLocalThreadStoreRestoresOnlyAnExistingLocalThread()
    throws
{
    let suiteName =
        "CodexDesktopLastActiveLocalThreadStoreTests."
        + UUID().uuidString
    let defaults = try #require(
        UserDefaults(suiteName: suiteName)
    )
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = CodexDesktopLastActiveLocalThreadStore(
        userDefaults: defaults
    )

    store.recordRendererPath("/local/thread-123")

    #expect(store.threadID == "thread-123")
    #expect(
        store.restoredInitialRoute { $0 == "thread-123" }
            == "/local/thread-123"
    )
}

@Test
func desktopLastActiveLocalThreadStoreRejectsMissingNonlocalAndDeletedRoutes()
    throws
{
    let suiteName =
        "CodexDesktopLastActiveLocalThreadStoreTests."
        + UUID().uuidString
    let defaults = try #require(
        UserDefaults(suiteName: suiteName)
    )
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = CodexDesktopLastActiveLocalThreadStore(
        userDefaults: defaults
    )

    #expect(store.restoredInitialRoute { _ in true } == nil)

    store.recordRendererPath("/settings")
    #expect(store.threadID == nil)

    store.recordRendererPath("/local/deleted-thread")
    #expect(store.restoredInitialRoute { _ in false } == nil)
    #expect(store.threadID == nil)
}

@Test
func desktopLastActiveLocalThreadStoreIgnoresBootstrapPathUntilRouteResolves()
    throws
{
    let suiteName =
        "CodexDesktopLastActiveLocalThreadStoreTests."
        + UUID().uuidString
    let defaults = try #require(
        UserDefaults(suiteName: suiteName)
    )
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = CodexDesktopLastActiveLocalThreadStore(
        userDefaults: defaults
    )

    store.recordRendererPath("/local/thread-123")
    store.recordRendererPath("/index.html")

    #expect(store.threadID == "thread-123")
}

@Test
func desktopLastActiveLocalThreadStoreRecordsRedactedAnchorTransitions()
    throws
{
    let suiteName =
        "CodexDesktopLastActiveLocalThreadStoreTests."
        + UUID().uuidString
    let defaults = try #require(
        UserDefaults(suiteName: suiteName)
    )
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = CodexDesktopLastActiveLocalThreadStore(
        userDefaults: defaults
    )

    store.recordRendererPath("/local/thread-123")
    #expect(
        defaults.string(
            forKey:
                CodexDesktopLastActiveLocalThreadStore.diagnosticKey
        ) == "source=renderer-route path=local anchor=present"
    )

    store.recordRendererPath("/")
    #expect(
        defaults.string(
            forKey:
                CodexDesktopLastActiveLocalThreadStore.diagnosticKey
        ) == "source=renderer-route path=home anchor=missing"
    )

    store.recordDurableThreadID("thread-456")
    #expect(store.threadID == "thread-456")
    #expect(
        defaults.string(
            forKey:
                CodexDesktopLastActiveLocalThreadStore.diagnosticKey
        ) == "source=conversation-commit path=local anchor=present"
    )
}

@Test
func desktopLastActiveLocalThreadStoreDoesNotRestoreArchivedThread()
    throws
{
    let suiteName =
        "CodexDesktopLastActiveLocalThreadStoreTests."
        + UUID().uuidString
    let defaults = try #require(
        UserDefaults(suiteName: suiteName)
    )
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = CodexDesktopLastActiveLocalThreadStore(
        userDefaults: defaults
    )

    store.recordDurableThreadID("thread-archived")

    #expect(
        store.restoredInitialRoute(
            threadExists: { _ in true },
            threadIsArchived: { $0 == "thread-archived" }
        ) == nil
    )
    #expect(store.threadID == nil)
    #expect(
        defaults.string(
            forKey:
                CodexDesktopLastActiveLocalThreadStore.diagnosticKey
        ) == "source=restore path=archived-thread anchor=missing"
    )
}

@Test
func desktopRestoredLocalThreadRouteFeedsTheReleasedInitialRouteQuery()
    throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let surface = root.appendingPathComponent(
        "CodexDesktopSurface",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: surface,
        withIntermediateDirectories: true
    )
    try Data("<!doctype html>".utf8).write(
        to: surface.appendingPathComponent("index.html")
    )
    defer { try? fileManager.removeItem(at: root) }

    let plan = try CodexDesktopWebViewResourceLocator.resolve(
        bundleResourceURL: root,
        initialRoute: "/local/thread-123"
    )

    #expect(
        plan.requestURL.absoluteString
            == "app://-/local/thread-123"
    )
}

@Test
func desktopEntryDocumentPinsRelativeModulesToTheAppOriginBeforeRouteRestore()
    throws
{
    let source = """
        <!doctype html>
        <html>
          <head>
            <!-- PROD_BASE_TAG_HERE -->
            <script type="module" src="./assets/index.js"></script>
          </head>
        </html>
        """

    let prepared = try CodexDesktopWebViewEntryDocument.prepare(
        Data(source.utf8)
    )
    let html = try #require(String(data: prepared, encoding: .utf8))
    let baseRange = try #require(
        html.range(of: #"<base href="app://-/">"#)
    )
    let moduleRange = try #require(
        html.range(of: #"src="./assets/index.js""#)
    )

    #expect(html.contains(#"<base href="app://-/">"#))
    #expect(!html.contains("<!-- PROD_BASE_TAG_HERE -->"))
    #expect(baseRange.lowerBound < moduleRange.lowerBound)
}

@Test
func desktopEntryDocumentPinsFutureBundlesWithoutTheProductionPlaceholder()
    throws
{
    let source = """
        <!doctype html>
        <html>
          <head data-release="future">
            <script type="module" src="./assets/future.js"></script>
          </head>
        </html>
        """

    let prepared = try CodexDesktopWebViewEntryDocument.prepare(
        Data(source.utf8)
    )
    let html = try #require(String(data: prepared, encoding: .utf8))
    let baseRange = try #require(
        html.range(of: #"<base href="app://-/">"#)
    )
    let moduleRange = try #require(
        html.range(of: #"src="./assets/future.js""#)
    )

    #expect(baseRange.lowerBound < moduleRange.lowerBound)
}

@Test
func desktopWebViewAppResourceResolverServesModulesWithStrictMIME()
    throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let assets = root.appendingPathComponent(
        "assets",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: assets,
        withIntermediateDirectories: true
    )
    let module = assets.appendingPathComponent("entry.mjs")
    try Data("export const ready = true;".utf8).write(to: module)
    defer {
        try? fileManager.removeItem(at: root)
    }

    let requestURL = try #require(
        URL(string: "app://-/assets/entry.mjs")
    )
    let resource = try CodexDesktopWebViewAppResourceResolver.resolve(
        requestURL: requestURL,
        surfaceDirectoryURL: root
    )

    #expect(resource.fileURL == module.standardizedFileURL)
    #expect(resource.mimeType == "text/javascript")
}

@Test
func desktopWebViewAppResourceResolverRejectsEncodedTraversal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let requestURL = try #require(
        URL(string: "app://-/%2e%2e/secret.js")
    )

    #expect(
        throws: CodexDesktopWebViewHostError.invalidAppResourcePath(
            requestURL
        )
    ) {
        try CodexDesktopWebViewAppResourceResolver.resolve(
            requestURL: requestURL,
            surfaceDirectoryURL: root
        )
    }
}

@Test
func desktopWebViewEntryProbeSeparatesRequestLoadAndExecutionFailures()
    throws
{
    let notRequested = try CodexDesktopWebViewEntryDiagnosticProbe
        .snapshot(
            foundationValue: [
                "document": [
                    "readyState": "complete",
                    "href": "app://-/index.html",
                    "hasDocumentElement": true,
                    "hasBody": true,
                    "hasRoot": true,
                    "rootChildCount": 0,
                    "rootHTMLLength": 0,
                    "bridgeInstalled": true,
                    "desktopHostInstalled": true,
                ],
                "moduleScripts": [
                    [
                        "source": "/assets/entry.js",
                        "src": "app://-/assets/entry.js",
                        "loadEvent": false,
                        "errorEvent": false,
                    ]
                ],
                "resourceEntryCount": 0,
                "resourceEntries": [],
            ]
        )
    #expect(notRequested.outcome == .entryNotRequested)

    let loadFailed = try CodexDesktopWebViewEntryDiagnosticProbe.snapshot(
        foundationValue: [
            "document": [
                "readyState": "complete",
                "href": "app://-/index.html",
                "hasDocumentElement": true,
                "hasBody": true,
                "hasRoot": true,
                "rootChildCount": 0,
                "rootHTMLLength": 0,
                "bridgeInstalled": true,
                "desktopHostInstalled": true,
            ],
            "moduleScripts": [
                [
                    "source": "/assets/entry.js",
                    "src": "app://-/assets/entry.js",
                    "loadEvent": false,
                    "errorEvent": true,
                ]
            ],
            "resourceEntryCount": 1,
            "resourceEntries": [
                [
                    "name": "app://-/assets/entry.js",
                    "initiatorType": "script",
                    "startTime": 1.0,
                    "duration": 2.0,
                    "responseEnd": 3.0,
                    "transferSize": 0.0,
                    "encodedBodySize": 0.0,
                    "decodedBodySize": 0.0,
                    "responseStatus": 404,
                ]
            ],
        ]
    )
    #expect(loadFailed.outcome == .entryLoadFailed)

    let loadedNotExecuted =
        try CodexDesktopWebViewEntryDiagnosticProbe.snapshot(
            foundationValue: [
                "document": [
                    "readyState": "complete",
                    "href": "app://-/index.html",
                    "hasDocumentElement": true,
                    "hasBody": true,
                    "hasRoot": true,
                    "rootChildCount": 0,
                    "rootHTMLLength": 0,
                    "bridgeInstalled": true,
                    "desktopHostInstalled": true,
                ],
                "moduleScripts": [
                    [
                        "source": "/assets/entry.js",
                        "src": "app://-/assets/entry.js",
                        "loadEvent": true,
                        "errorEvent": false,
                    ]
                ],
                "resourceEntryCount": 1,
                "resourceEntries": [
                    [
                        "name": "app://-/assets/entry.js",
                        "initiatorType": "script",
                        "startTime": 1.0,
                        "duration": 2.0,
                        "responseEnd": 3.0,
                        "transferSize": 128.0,
                        "encodedBodySize": 96.0,
                        "decodedBodySize": 128.0,
                        "responseStatus": 200,
                    ]
                ],
            ]
        )
    #expect(loadedNotExecuted.outcome == .entryLoadedNotExecuted)
}

@Test
func desktopWebViewEntryProbeCapturesRequiredWebKitEvidence() {
    let source =
        CodexDesktopWebViewEntryDiagnosticProbe.didFinishJavaScript
    let documentStartSource =
        CodexDesktopWebViewEntryDiagnosticProbe.documentStartJavaScript

    #expect(source.contains(#"script[type="module"][src]"#))
    #expect(source.contains(#"performance.getEntriesByType("resource")"#))
    #expect(source.contains("document.readyState"))
    #expect(source.contains(#"document.getElementById("root")"#))
    #expect(
        documentStartSource.contains(
            #"window.addEventListener("unhandledrejection""#
        )
    )
    #expect(documentStartSource.contains(#"kind: "renderer-exception""#))
    #expect(documentStartSource.contains(#"status: "window-error""#))
    #expect(documentStartSource.contains(#"status: "unhandled-rejection""#))
    #expect(
        CodexDesktopWebViewEntryDiagnosticProbe.channel
            == "renderer-diagnostic"
    )
}

@Test
func desktopWebViewEntryProbePreservesRendererViewportGeometry()
    throws
{
    let payload = try CodexDesktopWebViewEntryDiagnosticProbe
        .diagnosticPayload(
            foundationValue: [
                "document": [
                    "readyState": "complete",
                    "href": "app://-/index.html",
                    "hasDocumentElement": true,
                    "hasBody": true,
                    "hasRoot": true,
                    "rootChildCount": 1,
                    "rootHTMLLength": 24,
                    "bridgeInstalled": true,
                    "desktopHostInstalled": true,
                ],
                "viewport": [
                    "windowInnerWidth": 1024,
                    "windowInnerHeight": 1366,
                    "documentElementClientWidth": 1024,
                    "documentElementClientHeight": 1366,
                ],
                "moduleScripts": [],
                "resourceEntryCount": 0,
                "resourceEntries": [],
            ]
        )
    guard case let .object(fields) = payload else {
        Issue.record("Entry diagnostic payload must be an object.")
        return
    }

    #expect(
        fields["viewport"] == .object([
            "windowInnerWidth": .integer(1024),
            "windowInnerHeight": .integer(1366),
            "documentElementClientWidth": .integer(1024),
            "documentElementClientHeight": .integer(1366),
        ])
    )

    let source = CodexDesktopWebViewEntryDiagnosticProbe.didFinishJavaScript
    #expect(source.contains("window.innerWidth"))
    #expect(source.contains("window.innerHeight"))
    #expect(source.contains("document.documentElement.clientWidth"))
    #expect(source.contains("document.documentElement.clientHeight"))
}

@Test
func focusedDiagnosticStorePersistsOnlyDebugWebKitViewportNumbers()
    throws
{
    let suiteName = "CodexDesktopWebKitViewportTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CodexDesktopFocusedDiagnosticStore(
        userDefaults: defaults,
        sessionID: "viewport-session",
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    let input: CodexJSONValue = .object([
            "kind": .string("webkit-entry-probe"),
            "document": .object([
                "href": .string("app://-/index.html?token=private"),
                "readyState": .string("complete"),
            ]),
            "viewport": .object([
                "windowInnerWidth": .integer(1366),
                "windowInnerHeight": .integer(972),
                "documentElementClientWidth": .integer(1366),
                "documentElementClientHeight": .integer(972),
                "unexpected": .string("private-token"),
            ]),
            "resourceEntries": .array([
                .object([
                    "name": .string("https://example.invalid/private.js"),
                ])
            ]),
        ])
    store.recordWebKitViewport(input)

    let encoded = try #require(
        defaults.string(
            forKey: CodexDesktopFocusedDiagnosticStore.webKitViewportKey
        )
    )
    let payload = try JSONDecoder().decode(
        CodexJSONValue.self,
        from: try #require(encoded.data(using: .utf8))
    )

    let expected: CodexJSONValue = .object([
        "windowInnerWidth": .integer(1366),
        "windowInnerHeight": .integer(972),
        "documentElementClientWidth": .integer(1366),
        "documentElementClientHeight": .integer(972),
    ])
    #expect(payload == expected)
    #expect(!encoded.contains("private"))
    #expect(!encoded.contains("example.invalid"))
    #expect(!encoded.contains("resourceEntries"))
}

@Test
func nativeGeometryDiagnosticPayloadPreservesAllLayoutLayers()
    throws
{
    let rect = CodexDesktopNativeGeometryRect(
        x: 1,
        y: 2,
        width: 1024,
        height: 1366
    )
    let insets = CodexDesktopNativeGeometryInsets(
        top: 24,
        left: 0,
        bottom: 20,
        right: 0
    )
    let node = CodexDesktopNativeGeometryNode(
        frame: rect,
        bounds: rect,
        safeAreaInsets: insets
    )
    let snapshot = CodexDesktopNativeGeometrySnapshot(
        window: node,
        windowScene: node,
        rootViewController: node,
        container: node,
        webView: node
    )

    let payload = CodexDesktopNativeGeometryDiagnostic.payload(snapshot)

    guard case let .object(fields) = payload else {
        Issue.record("Native geometry payload must be an object.")
        return
    }
    #expect(fields["kind"] == .string("native-geometry"))
    #expect(fields["window"] != nil)
    #expect(fields["windowScene"] != nil)
    #expect(fields["rootViewController"] != nil)
    #expect(fields["container"] != nil)
    #expect(fields["webView"] != nil)
}

@Test
func nativeGeometryDiagnosticStoreUsesDedicatedSanitizedKey()
    throws
{
    let suiteName = "CodexDesktopNativeGeometryTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CodexDesktopFocusedDiagnosticStore(
        userDefaults: defaults,
        sessionID: "geometry-session",
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    let nativePayload: CodexJSONValue = .object([
            "kind": .string("native-geometry"),
            "container": .object([
                "frame": .object([
                    "x": .number(0),
                    "y": .number(748),
                    "width": .number(1024),
                    "height": .number(618),
                ]),
                "bounds": .object([
                    "x": .number(0),
                    "y": .number(0),
                    "width": .number(1024),
                    "height": .number(618),
                ]),
                "safeAreaInsets": .object([
                    "top": .number(0),
                    "left": .number(0),
                    "bottom": .number(0),
                    "right": .number(0),
                ])
            ]),
            "url": .string("https://example.invalid/?token=secret"),
        ])
    store.recordNativeGeometry(nativePayload)

    let value = try #require(
        defaults.string(
            forKey: CodexDesktopFocusedDiagnosticStore
                .nativeGeometryKey
        )
    )
    #expect(value.contains("native-geometry"))
    #expect(value.contains("748"))
    #expect(!value.contains("example.invalid"))
    #expect(!value.contains("token"))
}

@Test
func focusedRendererAndHardwareDiagnosticsUseDedicatedPersistentKeys()
    throws
{
    let suiteName = "CodexDesktopFocusedDiagnosticsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CodexDesktopFocusedDiagnosticStore(
        userDefaults: defaults,
        sessionID: "shortcut-session",
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    store.recordRendererException(
        .object([
            "kind": .string("renderer-exception"),
            "status": .string("window-error"),
            "message": .string("appearance exploded"),
        ])
    )
    store.recordHardwareShortcut(
        "source=dom shortcut=settings status=forwarded"
    )

    defaults.set(
        (0 ..< 250).map { "heartbeat-\($0)" },
        forKey: "codex.desktop.runtime-diagnostics"
    )

    #expect(
        defaults.string(
            forKey: CodexDesktopFocusedDiagnosticStore
                .rendererExceptionKey
        )?.contains("appearance exploded") == true
    )

    store.recordRendererException(
        .object([
            "kind": .string("renderer-exception"),
            "status": .string("window-error"),
            "message": .string("https://api.example.test/?token=redact-me"),
            "path": .string("/settings?token=redact-me"),
            "source": .string("https://app.example.test/main.js?token=redact-me"),
        ])
    )
    let rendererRedacted = try #require(
        defaults.string(
            forKey: CodexDesktopFocusedDiagnosticStore
                .rendererExceptionKey
        )
    )
    #expect(rendererRedacted.contains("<redacted>"))
    #expect(!rendererRedacted.contains("redact-me"))
    #expect(!rendererRedacted.contains("api.example.test"))

    store.recordRendererException(
        .object([
            "kind": .string("renderer-exception"),
            "status": .string("window-error"),
            "message": .string("https://api.example.test/?token=redact-me"),
            "path": .string("/settings?token=redact-me"),
            "source": .string("https://app.example.test/main.js?token=redact-me"),
        ])
    )
    let redacted = try #require(
        defaults.string(
            forKey: CodexDesktopFocusedDiagnosticStore
                .rendererExceptionKey
        )
    )
    #expect(redacted.contains("<redacted>"))
    #expect(!redacted.contains("redact-me"))
    #expect(!redacted.contains("api.example.test"))
    let shortcutDiagnostic = try #require(
        defaults.string(
            forKey: CodexDesktopFocusedDiagnosticStore
                .hardwareShortcutKey
        )
    )
    #expect(shortcutDiagnostic.contains("sessionID=shortcut-session"))
    #expect(shortcutDiagnostic.contains("recordedAt=2023-11-14T22:13:20Z"))
    #expect(
        shortcutDiagnostic.contains(
            "source=dom shortcut=settings status=forwarded"
        )
    )
}

@Test
func statsigSummaryGateDiagnosticPersistsOnlyTheTargetGateValue() throws {
    let suiteName = "CodexDesktopStatsigSummaryGateTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let statsigPayload = #"{"feature_gates":{"4128908571":{"value":true}},"user":{"userID":"private-user"},"token":"private-token"}"#
    let store = CodexDesktopStatsigSummaryGateDiagnosticStore(
        userDefaults: defaults
    )

    store.record(
        response: .fetchSuccess(
            requestID: "statsig-bootstrap",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "statsigPayload": .string(statsigPayload)
            ])
        )
    )

    let diagnostic = try #require(
        defaults.string(
            forKey: CodexDesktopStatsigSummaryGateDiagnosticStore.key
        )
    )
    #expect(diagnostic == "gate=4128908571 present=true value=true")
    #expect(!diagnostic.contains("private-user"))
    #expect(!diagnostic.contains("private-token"))
    #expect(!diagnostic.contains("feature_gates"))
}

@Test
func statsigSummaryGateDiagnosticReadsReleasedHashedV2Gate() throws {
    let suiteName = "CodexDesktopStatsigSummaryGateV2Tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let statsigPayload = #"{"feature_gates":{"1079957873":{"v":false}}}"#
    let store = CodexDesktopStatsigSummaryGateDiagnosticStore(
        userDefaults: defaults
    )

    store.record(
        response: .fetchSuccess(
            requestID: "statsig-bootstrap-v2",
            status: 200,
            headers: [:],
            body: .object([
                "statsigPayload": .string(statsigPayload)
            ])
        )
    )

    #expect(
        defaults.string(
            forKey: CodexDesktopStatsigSummaryGateDiagnosticStore.key
        ) == "gate=4128908571 present=true value=false"
    )
}

@Test
func statsigVoiceConfigDiagnosticReadsReleasedHashedV2ConfigWithoutPayload()
    throws
{
    let suiteName = "CodexDesktopStatsigVoiceConfigV2Tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let statsigPayload = #"{"dynamic_configs":{"729731510":{"v":"voice-value"}},"values":{"voice-value":{"prompt":"private-prompt","greeting_enabled":true}},"token":"private-token"}"#
    let store = CodexDesktopStatsigVoiceConfigDiagnosticStore(
        userDefaults: defaults
    )

    store.record(
        response: .fetchSuccess(
            requestID: "statsig-bootstrap-v2",
            status: 200,
            headers: [:],
            body: .object([
                "statsigPayload": .string(statsigPayload)
            ])
        )
    )

    let diagnostic = try #require(
        defaults.string(
            forKey: CodexDesktopStatsigVoiceConfigDiagnosticStore.key
        )
    )
    #expect(
        diagnostic
            == "config=1193530394 present=true valuePresent=true fields=2"
    )
    #expect(!diagnostic.contains("private-prompt"))
    #expect(!diagnostic.contains("private-token"))
}

@Test
func focusedRendererDiagnosticStartsFreshAndRecordsCurrentSessionContext()
    throws
{
    let suiteName = "CodexDesktopFocusedDiagnosticsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
        #"{"kind":"renderer-exception","message":"stale"}"#,
        forKey: CodexDesktopFocusedDiagnosticStore.rendererExceptionKey
    )
    defaults.set(
        "source=uikit shortcut=commandMenu status=forwarded",
        forKey: CodexDesktopFocusedDiagnosticStore.hardwareShortcutKey
    )

    let store = CodexDesktopFocusedDiagnosticStore(
        userDefaults: defaults,
        sessionID: "appearance-session",
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    store.beginSession()

    #expect(
        defaults.string(
            forKey: CodexDesktopFocusedDiagnosticStore
                .rendererExceptionKey
        ) == nil
    )
    #expect(
        defaults.string(
            forKey: CodexDesktopFocusedDiagnosticStore
                .hardwareShortcutKey
        ) == nil
    )

    store.recordRendererException(
        .object([
            "kind": .string("renderer-exception"),
            "status": .string("unhandled-rejection"),
            "message": .string("unknownExport(48)"),
            "path": .string("/settings/appearance"),
        ])
    )

    let encoded = try #require(
        defaults.string(
            forKey: CodexDesktopFocusedDiagnosticStore
                .rendererExceptionKey
        )
    )
    #expect(encoded.contains(#""sessionID":"appearance-session""#))
    #expect(encoded.contains(#""recordedAt":"2023-11-14T22:13:20Z""#))
    #expect(encoded.contains(#""path":"/settings/appearance""#))
    #expect(encoded.contains(#""message":"unknownExport(48)""#))
    #expect(!encoded.contains(#""message":"stale""#))

    store.recordHardwareShortcut(
        "source=uikit shortcut=settings status=dispatching"
    )
    let hardwareDiagnostic = try #require(
        defaults.string(
            forKey: CodexDesktopFocusedDiagnosticStore
                .hardwareShortcutKey
        )
    )
    #expect(hardwareDiagnostic.contains("sessionID=appearance-session"))
    #expect(hardwareDiagnostic.contains("recordedAt=2023-11-14T22:13:20Z"))
    #expect(hardwareDiagnostic.contains("shortcut=settings"))
    #expect(!hardwareDiagnostic.contains("shortcut=commandMenu"))
}

@Test
func desktopWebViewResourceLocatorRejectsAMissingReleasedEntry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    #expect(
        throws: CodexDesktopWebViewHostError.missingSurfaceDirectory(
            root.appendingPathComponent(
                "CodexDesktopSurface",
                isDirectory: true
            ).standardizedFileURL
        )
    ) {
        try CodexDesktopWebViewResourceLocator.resolve(
            bundleResourceURL: root
        )
    }
}

@Test
func desktopWebViewRouterHandlesReleasedLifecycleAndFetchMessages() throws {
    #expect(
        try CodexDesktopWebViewMessageRouter.route(
            body: .object([
                "channel": .string("view-message"),
                "payload": .object(["type": .string("ready")]),
            ])
        ) == .rendererReady
    )
    #expect(
        try CodexDesktopWebViewMessageRouter.route(
            body: .object([
                "channel": .string("view-message"),
                "payload": .object(["type": .string("view-focused")]),
            ])
        ) == .viewFocused
    )

    let fetch = try CodexDesktopWebViewMessageRouter.route(
        body: .object([
            "channel": .string("view-message"),
            "payload": .object([
                "type": .string("fetch"),
                "requestId": .string("request-home"),
                "method": .string("POST"),
                "url": .string("vscode://codex/thread/list"),
                "headers": .object([
                    "content-type": .string("application/json")
                ]),
                "body": .string(#"{"limit":20}"#),
                "reportUploadProgress": .bool(false),
            ]),
        ])
    )

    #expect(
        fetch == .fetch(
            CodexDesktopFetchRequest(
                requestID: "request-home",
                method: "POST",
                url: "vscode://codex/thread/list",
                hostMethod: "thread/list",
                headers: ["content-type": "application/json"],
                body: #"{"limit":20}"#,
                reportUploadProgress: false
            )
        )
    )
}

@Test
func desktopWebViewRouterPreservesReleasedOpenInBrowserRequest() throws {
    #expect(
        try CodexDesktopWebViewMessageRouter.route(
            body: .object([
                "channel": .string("view-message"),
                "payload": .object([
                    "type": .string("open-in-browser"),
                    "url": .string(
                        "https://example.test/sites/project-1"
                    ),
                    "initiator": .string("sites_library"),
                    "openTarget": .string("in-app-browser"),
                    "source": .string("manual"),
                ]),
            ])
        ) == .openInBrowser(
            CodexDesktopOpenInBrowserRequest(
                url: "https://example.test/sites/project-1",
                initiator: "sites_library",
                openTarget: "in-app-browser",
                source: "manual"
            )
        )
    )
}

@Test
func desktopWebViewRouterPreservesReleasedMCPRequestMetadata() throws {
    let routed = try CodexDesktopWebViewMessageRouter.route(
        body: .object([
            "channel": .string("view-message"),
            "payload": .object([
                "type": .string("mcp-request"),
                "request": .object([
                    "id": .integer(11),
                    "method": .string("account/read"),
                    "params": .object(["refreshToken": .bool(false)]),
                ]),
                "hostId": .string("local"),
                "priority": .string("normal"),
                "source": .string("renderer"),
            ]),
        ])
    )

    #expect(
        routed == .mcpRequest(
            CodexDesktopMCPRequest(
                request: CodexDesktopMCPRequestMessage(
                    id: .integer(11),
                    method: "account/read",
                    params: .object(["refreshToken": .bool(false)]),
                    metadata: [:]
                ),
                hostID: "local",
                dispatchedAtMs: nil,
                priority: .string("normal"),
                source: .string("renderer"),
                timeoutMs: nil,
                expiresAtMs: nil,
                metadata: [:]
            )
        )
    )
}

@Test
func desktopWebViewRouterPreservesRendererLogsAndNativeChannels() throws {
    #expect(
        try CodexDesktopWebViewMessageRouter.route(
            body: .object([
                "channel": .string("view-message"),
                "payload": .object([
                    "type": .string("log-message"),
                    "level": .string("info"),
                    "message": .string("home routes mounted"),
                    "tags": .object(["surface": .string("home")]),
                ]),
            ])
        ) == .logMessage(
            CodexDesktopLogMessage(
                level: "info",
                message: "home routes mounted",
                tags: .object(["surface": .string("home")])
            )
        )
    )

    #expect(
        try CodexDesktopWebViewMessageRouter.route(
            body: .object([
                "channel": .string("show-context-menu"),
                "payload": .object(["x": .integer(14), "y": .integer(28)]),
            ])
        ) == .nativeChannel(
            name: "show-context-menu",
            payload: .object(["x": .integer(14), "y": .integer(28)])
        )
    )
}

@Test
func desktopWebViewRouterPreservesPersistedAtomAndSharedObjectMessages()
    throws
{
    #expect(
        try CodexDesktopWebViewMessageRouter.route(
            body: .object([
                "channel": .string("view-message"),
                "payload": .object([
                    "type": .string("persisted-atom-sync-request")
                ]),
            ])
        ) == .persistedAtomSyncRequest
    )
    #expect(
        try CodexDesktopWebViewMessageRouter.route(
            body: .object([
                "channel": .string("view-message"),
                "payload": .object([
                    "type": .string("persisted-atom-update"),
                    "key": .string("composer.draft"),
                    "deleted": .bool(true),
                ]),
            ])
        ) == .persistedAtomUpdate(
            CodexDesktopPersistedAtomUpdate(
                key: "composer.draft",
                value: nil,
                deleted: true
            )
        )
    )
}

@Test
func desktopWebViewRendererReadyStopsAtTheHomeDataGate() throws {
    let routed = try CodexDesktopWebViewMessageRouter.route(
        body: .object([
            "channel": .string("view-message"),
            "payload": .object(["type": .string("ready")]),
        ])
    )
    var machine = CodexDesktopSurfaceStateMachine()

    try machine.apply(.resourcesVerified)
    try machine.apply(.documentLoaded)
    if routed == .rendererReady {
        try machine.apply(.bridgeReady)
    }

    #expect(machine.state == .awaitingHomeData)
    #expect(!machine.isSurfaceReady)
}

@Test
func desktopWebViewHostResponseUsesAnObjectArgumentBinding() throws {
    let invocation = try CodexDesktopWebViewHostInvocation.make(
        message: .fetchSuccess(
            requestID: "request-home",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["data": .array([])])
        )
    )

    #expect(
        invocation.functionBody
            == "window.__codexDesktopHost.receive(message)"
    )
    #expect(invocation.argumentName == "message")
    guard case let .object(fields) = invocation.payload else {
        Issue.record("The native response must stay a bound object.")
        return
    }
    #expect(fields["type"] == .string("fetch-response"))
    #expect(fields["requestId"] == .string("request-home"))
    #expect(fields["responseType"] == .string("success"))
}

@Test
func desktopRendererLocationDiagnosticKeepsOnlyOfficialAppPath() {
    #expect(
        CodexDesktopRendererLocationDiagnostic.appPath(
            from: "app://-/settings/keyboard-shortcuts?account=secret#private"
        ) == "/settings/keyboard-shortcuts"
    )
    #expect(
        CodexDesktopRendererLocationDiagnostic.appPath(
            from: "app://-/index.html"
        ) == "/index.html"
    )
    #expect(
        CodexDesktopRendererLocationDiagnostic.appPath(
            from: "https://example.invalid/settings"
        ) == nil
    )
}

@Test
func desktopNativeShortcutsMatchReleasedElectronMessages() {
    #expect(
        CodexDesktopNativeShortcut.commandMenu.rendererMessage
            == .event(type: "command-menu", payload: .object([:]))
    )
    #expect(
        CodexDesktopNativeShortcut.commandMenuWithEmptyQuery
            .rendererMessage
            == .event(
                type: "command-menu",
                payload: .object(["query": .string("")])
            )
    )
    #expect(
        CodexDesktopNativeShortcut.searchFiles.rendererMessage
            == .event(
                type: "file-search-command-menu",
                payload: .object([:])
            )
    )
    #expect(
        CodexDesktopNativeShortcut.settings.rendererMessage
            == .event(
                type: "navigate-to-route",
                payload: .object(["path": .string("/settings")])
            )
    )
    #expect(
        CodexDesktopNativeShortcut.keyboardShortcuts.rendererMessage
            == .event(
                type: "navigate-to-route",
                payload: .object([
                    "path": .string("/settings/keyboard-shortcuts")
                ])
            )
    )
    #expect(
        CodexDesktopNativeShortcut.openBrowserTab.rendererMessage
            == .event(
                type: "open-browser-tab",
                payload: .object([
                    "source": .string("manual"),
                    "initiator": .string("app_menu"),
                ])
            )
    )
    #expect(
        CodexDesktopNativeShortcut.threadSlot(1).rendererMessage
            == .event(
                type: "run-command",
                payload: .object(["id": .string("thread1")])
            )
    )
    #expect(
        CodexDesktopNativeShortcut.threadSlot(9).rendererMessage
            == .event(
                type: "run-command",
                payload: .object(["id": .string("thread9")])
            )
    )
    #expect(
        CodexDesktopNativeShortcut.threadSlot(0).rendererMessage == nil
    )
    #expect(
        CodexDesktopNativeShortcut.threadSlot(10).rendererMessage == nil
    )
}

@Test
func desktopHardwareShortcutScriptUsesExactEncodedHostMessages() throws {
    let source = try CodexDesktopHardwareShortcutScript.make()
    #expect(source.contains("\"key\":\",\""))
    #expect(source.contains("\"path\":\"/settings\""))
    #expect(source.contains("\"path\":\"/settings/keyboard-shortcuts\""))
    #expect(source.contains("\"type\":\"file-search-command-menu\""))
    #expect(source.contains("\"id\":\"thread9\""))
    #expect(source.contains("event.stopImmediatePropagation()"))
    #expect(source.contains(#"kind: "hardware-shortcut""#))
    #expect(source.contains(#"status: "unmatched""#))
    #expect(source.contains(#"status: "host-missing""#))
    #expect(source.contains(#"status: "forwarded""#))
}

@Test
func desktopWebViewHostInstallsHardwareShortcutFallbackAtDocumentStart()
    throws
{
    let plan = try CodexDesktopWebViewUserScriptPlan.make(
        bootstrap: CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: 1_234,
            systemThemeVariant: "dark",
            initialSidebarBootstrap: .object([:]),
            sharedObjectSnapshot: [:],
            sentryInitOptions: .object([:]),
            buildFlavor: "production",
            appSessionID: "shortcut-installation-test",
            usesOwlAppShell: true
        )
    )
    let expectedSource = try CodexDesktopHardwareShortcutScript.make()

    #expect(
        plan.map(\.role)
            == [
                .initialRouteBootstrap,
                .entryDiagnostic,
                .interactiveSurface,
                .bridge,
                .routeObservation,
                .hardwareShortcut,
            ]
    )
    #expect(
        plan.first(where: { $0.role == .hardwareShortcut })?.source
            == expectedSource
    )
    #expect(
        plan.first(where: { $0.role == .hardwareShortcut })?
            .injectionPhase == .documentStart
    )
    #expect(
        plan.first(where: { $0.role == .hardwareShortcut })?
            .forMainFrameOnly == true
    )
}

@Test
func desktopWebViewHostObservesCommittedRendererRoutesAtDocumentStart()
    throws
{
    let source = CodexDesktopRendererRouteObservationScript.source
    let plan = try CodexDesktopWebViewUserScriptPlan.make(
        bootstrap: CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: 1_234,
            systemThemeVariant: "dark",
            initialSidebarBootstrap: .object([:]),
            sharedObjectSnapshot: [:],
            sentryInitOptions: .object([:]),
            buildFlavor: "production",
            appSessionID: "route-observation-test",
            usesOwlAppShell: true
        )
    )

    #expect(
        source.contains(
            CodexDesktopRendererRouteObservationScript.messageChannel
        )
    )
    #expect(source.contains("history.pushState"))
    #expect(source.contains("history.replaceState"))
    #expect(source.contains("popstate"))
    #expect(
        plan.first(where: { $0.role == .routeObservation })?.source
            == source
    )
}

@Test
func desktopWebViewHostBootstrapsValidatedInitialRouteBeforeObservation()
    throws
{
    let source = CodexDesktopInitialRouteBootstrapScript.source
    let plan = try CodexDesktopWebViewUserScriptPlan.make(
        bootstrap: CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: 1_234,
            systemThemeVariant: "dark",
            initialSidebarBootstrap: .object([:]),
            sharedObjectSnapshot: [:],
            sentryInitOptions: .object([:]),
            buildFlavor: "production",
            appSessionID: "initial-route-bootstrap-test",
            usesOwlAppShell: true
        )
    )

    #expect(source.contains("new URLSearchParams"))
    #expect(source.contains("initialRoute"))
    #expect(source.contains("history.replaceState"))
    #expect(source.contains("/avatar-overlay"))
    #expect(source.contains("/local/"))
    #expect(
        source.contains(
            "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"
                + "[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                + "[0-9a-fA-F]{12}$"
        )
    )
    #expect(
        plan.map(\.role)
            == [
                .initialRouteBootstrap,
                .entryDiagnostic,
                .interactiveSurface,
                .bridge,
                .routeObservation,
                .hardwareShortcut,
            ]
    )
    #expect(
        plan.first(where: { $0.role == .initialRouteBootstrap })?.source
            == source
    )
    #expect(
        plan.first(where: { $0.role == .initialRouteBootstrap })?
            .injectionPhase == .documentStart
    )
    #expect(
        plan.first(where: { $0.role == .initialRouteBootstrap })?
            .forMainFrameOnly == true
    )
}

@Test
func desktopInteractiveSurfaceProbeUsesVisibleSemanticControls() {
    let source = CodexDesktopInteractiveSurfaceProbe.documentStartJavaScript

    #expect(source.contains("MutationObserver"))
    #expect(source.contains("getBoundingClientRect"))
    #expect(source.contains("[contenteditable=\"true\"]"))
    #expect(source.contains("[role=\"button\"]"))
    #expect(source.contains("interactive-surface-committed"))
    #expect(!source.contains("Settings"))
    #expect(!source.contains("New thread"))
}

@Test
func desktopInteractiveSurfaceProbeRecognizesOnlyCommitPayloads() {
    #expect(
        CodexDesktopInteractiveSurfaceProbe.isCommitPayload(
            .object([
                "kind": .string("interactive-surface-committed"),
                "visibleInteractiveElementCount": .integer(3),
            ])
        )
    )
    #expect(
        !CodexDesktopInteractiveSurfaceProbe.isCommitPayload(
            .object([
                "kind": .string("interactive-surface-pending"),
                "visibleInteractiveElementCount": .integer(0),
            ])
        )
    )
}

@Test
func desktopNativeShortcutResolverIncludesReservedPunctuation() {
    #expect(
        CodexDesktopNativeShortcut.resolve(
            key: ",",
            command: true,
            shift: false,
            option: false,
            control: false
        ) == .settings
    )
    #expect(
        CodexDesktopNativeShortcut.resolve(
            key: "/",
            command: true,
            shift: false,
            option: false,
            control: false
        ) == .keyboardShortcuts
    )
    #expect(
        CodexDesktopNativeShortcut.resolve(
            key: "P",
            command: true,
            shift: true,
            option: false,
            control: false
        ) == .commandMenuWithEmptyQuery
    )
    for layoutKey in ["~", "§", "±", "ˋ"] {
        #expect(
            CodexDesktopNativeShortcut.resolve(
                key: layoutKey,
                command: false,
                shift: false,
                option: false,
                control: true
            ) == .toggleTerminal
        )
    }
    #expect(
        CodexDesktopNativeShortcut.resolve(
            key: "",
            command: false,
            shift: false,
            option: false,
            control: true,
            physicalKeyCode: 0x35
        ) == .toggleTerminal
    )
}

@Test
func desktopHardwareShortcutDispatchGateSuppressesOnlyDuplicateDelivery() {
    var gate = CodexDesktopHardwareShortcutDispatchGate(
        duplicateInterval: 0.05
    )

    let firstSettings = gate.shouldDispatch(.settings, timestamp: 10.0)
    let duplicateSettings = gate.shouldDispatch(.settings, timestamp: 10.01)
    let keyboardShortcuts = gate.shouldDispatch(
        .keyboardShortcuts,
        timestamp: 10.02
    )
    let laterSettings = gate.shouldDispatch(.settings, timestamp: 10.06)

    #expect(firstSettings)
    #expect(!duplicateSettings)
    #expect(keyboardShortcuts)
    #expect(laterSettings)
}

@Test
func desktopNativeShortcutBindingsAreCompleteAndUnique() {
    let bindings = CodexDesktopNativeShortcutBinding.released
    #expect(bindings.count == 23)
    #expect(Set(bindings.map { signature($0) }).count == bindings.count)
    #expect(bindings.map(\.shortcut).contains(.settings))
    #expect(bindings.map(\.shortcut).contains(.keyboardShortcuts))
    #expect(bindings.map(\.shortcut).contains(.searchFiles))
    #expect(bindings.last?.shortcut == .threadSlot(9))
}

private func signature(
    _ binding: CodexDesktopNativeShortcutBinding
) -> String {
    [
        binding.key,
        String(binding.command),
        String(binding.shift),
        String(binding.option),
        String(binding.control),
    ].joined(separator: ":")
}
@Test
func voiceDiagnosticAdapterInstrumentsReleasedVoiceConfigAndRegistrationGate() throws {
    let initial = Data(
        "let f=i?K9t(c,l):null;t.set(zx,f),t.set(Z9t,m);"
            .appending(
                "let{AvatarOverlayNativePage:e}=await import("
                    + "`./avatar-overlay-native-page-DJ_uSiqV.js`)"
            ).utf8
    )
    let adaptedInitial = try CodexDesktopVoiceDiagnosticResourceAdapter.adapt(
        initial,
        resourceFilename: "app-initial-BnNjcVmf.js",
        enabled: true
    )
    let initialSource = try #require(String(data: adaptedInitial, encoding: .utf8))
    #expect(initialSource.contains("voice-debug-config-r${i?1:0}"))
    #expect(initialSource.contains("-p${f!=null?1:0}"))
    #expect(
        initialSource.contains(
            "avatar-overlay-native-page-DJ_uSiqV.js?codexVoiceDiagnostic=2"
        )
    )
    #expect(initialSource.contains("voice-debug-overlay-import"))
    #expect(initialSource.contains("voice-debug-overlay-dom"))
    #expect(initialSource.contains("voice-debug-overlay-error"))
    #expect(initialSource.contains("voice-debug-overlay-rejection"))
    #expect(initialSource.contains("\n;(()=>{if(window.location.pathname"))

    let overlay = Data(
        "let R;e[45]!==Oe?(R=[Oe,j]):R=e[47],(0,Q.useEffect)(Ue,R);let We=1".utf8
    )
    let adaptedOverlay = try CodexDesktopVoiceDiagnosticResourceAdapter.adapt(
        overlay,
        resourceFilename: "avatar-overlay-native-page-DJ_uSiqV.js",
        enabled: true
    )
    let overlaySource = try #require(String(data: adaptedOverlay, encoding: .utf8))
    #expect(overlaySource.contains("voice-debug-register-c${j?1:0}"))
    #expect(overlaySource.contains("-l${b?1:0}"))
    #expect(overlaySource.contains("-s${i.realtimeVoiceRuntime!=null?1:0}"))

    #expect(
        try CodexDesktopVoiceDiagnosticResourceAdapter.adapt(
            overlay,
            resourceFilename: "avatar-overlay-native-page-DJ_uSiqV.js",
            enabled: false
        ) == overlay
    )
}

@Test
func voiceDiagnosticEntryAdapterCacheBustsTheReleasedInitialModule() throws {
    let entry = Data(
        #"<script type="module" src="/assets/app-initial-BnNjcVmf.js"></script>"#.utf8
    )

    let iPadEntry = try CodexDesktopIPadEntryResourceAdapter.adapt(entry)
    let adapted = try CodexDesktopVoiceDiagnosticEntryAdapter.adapt(
        iPadEntry,
        enabled: true
    )
    let source = try #require(String(data: adapted, encoding: .utf8))
    #expect(
        source.contains(
            "app-initial-BnNjcVmf.js?codexPadRuntime=1&codexVoiceDiagnostic=2"
        )
    )
    #expect(
        try CodexDesktopVoiceDiagnosticEntryAdapter.adapt(
            iPadEntry,
            enabled: false
        ) == iPadEntry
    )
}

@Test
func iPadEntryAdapterVersionsTheReleasedInitialModule() throws {
    let entry = Data(
        #"<script type="module" src="/assets/app-initial-BnNjcVmf.js"></script>"#.utf8
    )
    let adapted = try CodexDesktopIPadEntryResourceAdapter.adapt(entry)
    let source = try #require(String(data: adapted, encoding: .utf8))
    #expect(source.contains("app-initial-BnNjcVmf.js?codexPadRuntime=1"))
}

@Test
func desktopWebViewNavigationRequestReloadsBundledEntryDocument() throws {
    let url = try #require(URL(string: "app://-/avatar-overlay"))
    let request = CodexDesktopWebViewNavigationRequest.make(url: url)
    #expect(request.url == url)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
}

@Test
func iPadLazyModuleAdapterDoesNotBlockImportOnStylesheetLoadEvents() throws {
    let released = Data(
        #"if(r)return new Promise((e,n)=>{i.addEventListener(`load`,e),i.addEventListener(`error`,()=>n(Error(`Unable to preload CSS for ${t}`)))})"#.utf8
    )
    let adapted = try CodexDesktopIPadLazyModuleResourceAdapter.adapt(
        released,
        resourceFilename: "app-initial-BnNjcVmf.js"
    )
    let source = try #require(String(data: adapted, encoding: .utf8))
    #expect(source.contains("if(r)return"))
    #expect(!source.contains("if(r)return new Promise"))
}

@Test
func iPadMemoryRouterAdapterStartsOverlayWebViewAtItsRequestedRoute() throws {
    let released = Data(
        "function kdu(e){let t=(0,Rdu.c)(6),{children:n}=e,r;"
            .appending(
                "return t[4]===n?r=t[5]:"
                    + "(r=(0,Z9.jsx)(_Vs,{children:n}),t[4]=n,t[5]=r),r}"
            ).utf8
    )

    let adapted = try CodexDesktopIPadMemoryRouterResourceAdapter.adapt(
        released,
        resourceFilename: "app-initial-BnNjcVmf.js"
    )
    let source = try #require(String(data: adapted, encoding: .utf8))

    #expect(
        source.contains(
            "initialEntries:[window.location.pathname===`/index.html`"
        )
    )
    #expect(source.contains("window.location.search"))
    #expect(source.contains("window.location.hash"))
    #expect(source.contains("children:n"))
}

@Test
func voiceAutostartDiagnosticScriptUsesOnlyReleasedVoiceControls() {
    let source = CodexDesktopVoiceAutostartDiagnosticScript.source
    #expect(source.contains("let primaryClicked") == false)
    #expect(source.contains("let onboardingClicked") == false)
    #expect(source.contains("var primaryClicked = false"))
    #expect(source.contains("var onboardingClicked = false"))
    #expect(source.contains("Start new voice chat"))
    #expect(source.contains("开始新的语音聊天"))
    #expect(source.contains("Start voice chat"))
    #expect(source.contains("voice-debug-autostart-onboarding"))
}

@Test
func voiceWebRTCDiagnosticScriptObservesRealtimeHostNotifications() {
    let source = CodexDesktopVoiceWebRTCDiagnosticScript.source
    #expect(source.contains("host-notification"))
    #expect(source.contains("mcp-notification"))
    #expect(source.contains("thread/realtime/"))
    #expect(source.contains("message.params?.threadId"))
    #expect(source.contains("message.params?.sdp"))
}
