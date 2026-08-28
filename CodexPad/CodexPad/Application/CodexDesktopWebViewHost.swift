#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexDesktopWebViewInjectionPhase:
    String,
    Equatable,
    Sendable
{
    case documentStart
}

public struct CodexDesktopWebViewContract:
    Equatable,
    Sendable
{
    // The released desktop registers a privileged `app` scheme and opens
    // `app://-/index.html`. Serving the recovered module graph from that
    // stable origin avoids the file-origin module behavior seen in WebKit.
    public static let official = CodexDesktopWebViewContract(
        surfaceDirectoryName: "CodexDesktopSurface",
        entryFilename: "index.html",
        applicationScheme: "app",
        applicationHost: "-",
        messageHandlerName: "codexDesktopBridge",
        viewMessageChannel: "view-message",
        injectionPhase: .documentStart,
        injectForMainFrameOnly: true,
        hostReceiveFunctionBody:
            "window.__codexDesktopHost.receive(message)",
        hostReceiveArgumentName: "message"
    )

    public let surfaceDirectoryName: String
    public let entryFilename: String
    public let applicationScheme: String
    public let applicationHost: String
    public let messageHandlerName: String
    public let viewMessageChannel: String
    public let injectionPhase: CodexDesktopWebViewInjectionPhase
    public let injectForMainFrameOnly: Bool
    public let hostReceiveFunctionBody: String
    public let hostReceiveArgumentName: String

    public init(
        surfaceDirectoryName: String,
        entryFilename: String,
        applicationScheme: String,
        applicationHost: String,
        messageHandlerName: String,
        viewMessageChannel: String,
        injectionPhase: CodexDesktopWebViewInjectionPhase,
        injectForMainFrameOnly: Bool,
        hostReceiveFunctionBody: String,
        hostReceiveArgumentName: String
    ) {
        self.surfaceDirectoryName = surfaceDirectoryName
        self.entryFilename = entryFilename
        self.applicationScheme = applicationScheme
        self.applicationHost = applicationHost
        self.messageHandlerName = messageHandlerName
        self.viewMessageChannel = viewMessageChannel
        self.injectionPhase = injectionPhase
        self.injectForMainFrameOnly = injectForMainFrameOnly
        self.hostReceiveFunctionBody = hostReceiveFunctionBody
        self.hostReceiveArgumentName = hostReceiveArgumentName
    }
}

public struct CodexDesktopWebViewLoadPlan:
    Equatable,
    Sendable
{
    public let entryURL: URL
    public let readAccessURL: URL
    public let requestURL: URL

    fileprivate init(
        entryURL: URL,
        readAccessURL: URL,
        requestURL: URL
    ) {
        self.entryURL = entryURL
        self.readAccessURL = readAccessURL
        self.requestURL = requestURL
    }
}

public enum CodexDesktopWebViewHostError:
    Error,
    Equatable,
    Sendable
{
    case missingBundleResourceURL
    case missingSurfaceDirectory(URL)
    case missingEntryFile(URL)
    case invalidScriptMessageEnvelope
    case invalidScriptMessageChannel
    case invalidScriptMessagePayload
    case invalidHostPayload
    case invalidApplicationOrigin
    case invalidAppResourceURL(URL)
    case invalidAppResourcePath(URL)
    case missingAppResource(URL)
    case invalidEntryDocumentEncoding
    case missingEntryDocumentHead
    case invalidEntryDiagnosticPayload
}

public struct CodexDesktopWebViewAppResource:
    Equatable,
    Sendable
{
    public let fileURL: URL
    public let mimeType: String

    public init(fileURL: URL, mimeType: String) {
        self.fileURL = fileURL
        self.mimeType = mimeType
    }
}

public enum CodexDesktopWebViewEntryDocument {
    private static let productionBasePlaceholder =
        "<!-- PROD_BASE_TAG_HERE -->"

    public static func prepare(
        _ data: Data,
        contract: CodexDesktopWebViewContract = .official
    ) throws -> Data {
        guard var html = String(data: data, encoding: .utf8) else {
            throw CodexDesktopWebViewHostError.invalidEntryDocumentEncoding
        }

        var components = URLComponents()
        components.scheme = contract.applicationScheme
        components.host = contract.applicationHost
        components.path = "/"
        guard let rootURL = components.url else {
            throw CodexDesktopWebViewHostError.invalidApplicationOrigin
        }
        let baseTag = #"<base href="\#(rootURL.absoluteString)">"#

        if html.contains(productionBasePlaceholder) {
            html = html.replacingOccurrences(
                of: productionBasePlaceholder,
                with: baseTag
            )
        } else if html.range(
            of: "<base ",
            options: [.caseInsensitive]
        ) == nil {
            guard let headEnd = html.range(
                of: #"<head\b[^>]*>"#,
                options: [.regularExpression, .caseInsensitive]
            ) else {
                throw CodexDesktopWebViewHostError.missingEntryDocumentHead
            }
            html.insert(contentsOf: "\n    " + baseTag, at: headEnd.upperBound)
        }

        guard let prepared = html.data(using: .utf8) else {
            throw CodexDesktopWebViewHostError.invalidEntryDocumentEncoding
        }
        return prepared
    }
}

/// Keeps the released renderer intact while adapting the one desktop-only
/// authentication choice that cannot complete on iPadOS. The renderer already
/// ships its full device-code UI and account/login protocol; only the primary
/// ChatGPT button is redirected to that existing handler as the JavaScript
/// resource is served to WKWebView.
public enum CodexDesktopIPadLoginResourceAdapter {
    private static let loginRoutePrefix = "login-route-"
    private static let releasedPrimaryBinding =
        "handleChatGptSignIn:P"
    private static let deviceCodeBinding =
        "handleChatGptDeviceCodeSignIn:I"
    private static let streamlinedEntry =
        "(t=(0,$t.jsx)(qt,{})"
    private static let releasedDeviceCodeEntry =
        "(t=(0,$t.jsx)(rt,{})"

    public static func adapt(
        _ data: Data,
        resourceFilename: String
    ) throws -> Data {
        guard resourceFilename.hasPrefix(loginRoutePrefix),
              resourceFilename.hasSuffix(".js"),
              var source = String(data: data, encoding: .utf8),
              source.contains(deviceCodeBinding),
              source.contains(releasedPrimaryBinding),
              source.contains(streamlinedEntry),
              source.contains(releasedDeviceCodeEntry)
        else {
            return data
        }

        source = source.replacingOccurrences(
            of: streamlinedEntry,
            with: releasedDeviceCodeEntry
        )
        source = source.replacingOccurrences(
            of: releasedPrimaryBinding,
            with: "handleChatGptSignIn:I"
        )
        guard let adapted = source.data(using: .utf8) else {
            throw CodexDesktopWebViewHostError
                .invalidEntryDocumentEncoding
        }
        return adapted
    }
}

public enum CodexDesktopWebViewAppResourceResolver {
    public static func entryRequestURL(
        contract: CodexDesktopWebViewContract = .official,
        initialRoute: String? = nil
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = contract.applicationScheme
        components.host = contract.applicationHost
        components.path = "/" + contract.entryFilename
        if let initialRoute, !initialRoute.isEmpty {
            components.queryItems = [
                URLQueryItem(
                    name: "initialRoute",
                    value: initialRoute
                )
            ]
        }
        guard let url = components.url else {
            throw CodexDesktopWebViewHostError.invalidApplicationOrigin
        }
        return url
    }

    public static func resolve(
        requestURL: URL,
        surfaceDirectoryURL: URL,
        contract: CodexDesktopWebViewContract = .official,
        fileManager: FileManager = .default
    ) throws -> CodexDesktopWebViewAppResource {
        guard requestURL.scheme == contract.applicationScheme,
              requestURL.host == contract.applicationHost,
              let components = URLComponents(
                  url: requestURL,
                  resolvingAgainstBaseURL: false
              )
        else {
            throw CodexDesktopWebViewHostError.invalidAppResourceURL(
                requestURL
            )
        }

        let encodedPath = components.percentEncodedPath
        guard encodedPath.hasPrefix("/"),
              let decodedPath = encodedPath.removingPercentEncoding
        else {
            throw CodexDesktopWebViewHostError.invalidAppResourcePath(
                requestURL
            )
        }
        let relativePath = String(decodedPath.dropFirst())
        let pathComponents = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !relativePath.isEmpty,
              !relativePath.contains("\\"),
              !relativePath.contains("\0"),
              pathComponents.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              })
        else {
            throw CodexDesktopWebViewHostError.invalidAppResourcePath(
                requestURL
            )
        }

        let root = surfaceDirectoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = root
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix =
            root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw CodexDesktopWebViewHostError.invalidAppResourcePath(
                requestURL
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue
        else {
            throw CodexDesktopWebViewHostError.missingAppResource(
                requestURL
            )
        }

        return CodexDesktopWebViewAppResource(
            fileURL: candidate,
            mimeType: mimeType(forPathExtension: candidate.pathExtension)
        )
    }

    private static func mimeType(
        forPathExtension pathExtension: String
    ) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm":
            return "text/html"
        case "js", "mjs", "cjs":
            return "text/javascript"
        case "css":
            return "text/css"
        case "json", "map":
            return "application/json"
        case "wasm":
            return "application/wasm"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "avif":
            return "image/avif"
        case "ico":
            return "image/x-icon"
        case "woff":
            return "font/woff"
        case "woff2":
            return "font/woff2"
        case "ttf":
            return "font/ttf"
        case "otf":
            return "font/otf"
        case "txt":
            return "text/plain"
        default:
            return "application/octet-stream"
        }
    }
}

public enum CodexDesktopWebViewResourceLocator {
    public static func resolve(
        bundleResourceURL: URL?,
        contract: CodexDesktopWebViewContract = .official,
        initialRoute: String? = nil,
        fileManager: FileManager = .default
    ) throws -> CodexDesktopWebViewLoadPlan {
        guard let bundleResourceURL else {
            throw CodexDesktopWebViewHostError.missingBundleResourceURL
        }
        let surfaceDirectory = bundleResourceURL.appendingPathComponent(
            contract.surfaceDirectoryName,
            isDirectory: true
        ).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: surfaceDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue
        else {
            throw CodexDesktopWebViewHostError.missingSurfaceDirectory(
                surfaceDirectory
            )
        }

        let entryURL = surfaceDirectory.appendingPathComponent(
            contract.entryFilename,
            isDirectory: false
        ).standardizedFileURL
        isDirectory = false
        guard fileManager.fileExists(
            atPath: entryURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue
        else {
            throw CodexDesktopWebViewHostError.missingEntryFile(entryURL)
        }

        return CodexDesktopWebViewLoadPlan(
            entryURL: entryURL,
            readAccessURL: surfaceDirectory,
            requestURL:
                try CodexDesktopWebViewAppResourceResolver
                    .entryRequestURL(
                        contract: contract,
                        initialRoute: initialRoute
                    )
        )
    }

    public static func resolve(
        bundle: Bundle,
        contract: CodexDesktopWebViewContract = .official,
        initialRoute: String? = nil,
        fileManager: FileManager = .default
    ) throws -> CodexDesktopWebViewLoadPlan {
        try resolve(
            bundleResourceURL: bundle.resourceURL,
            contract: contract,
            initialRoute: initialRoute,
            fileManager: fileManager
        )
    }
}

/// Persists the released renderer's last committed local-thread route.
///
/// The entry document is a bootstrap URL rather than a product route, so its
/// `/index.html` pathname must not erase a thread selected in the previous
/// process. Every other non-local product route intentionally clears the
/// restoration anchor.
public final class CodexDesktopLastActiveLocalThreadStore {
    private static let threadIDKey =
        "codex.desktop.last-active-local-thread-id"
    public static let diagnosticKey =
        "codex.desktop.last-active-anchor-diagnostic"

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public var threadID: String? {
        guard let value = userDefaults.string(
            forKey: Self.threadIDKey
        ), !value.isEmpty
        else {
            return nil
        }
        return value
    }

    public func recordRendererPath(_ path: String) {
        if path == "/index.html" {
            recordDiagnostic(
                source: "renderer-route",
                pathKind: "bootstrap"
            )
            return
        }
        guard let threadID = Self.localThreadID(from: path) else {
            clear(
                source: "renderer-route",
                pathKind: Self.pathKind(path)
            )
            return
        }
        record(
            threadID: threadID,
            source: "renderer-route"
        )
    }

    public func recordDurableThreadID(
        _ threadID: String,
        source: String = "conversation-commit"
    ) {
        guard !threadID.isEmpty else {
            return
        }
        record(
            threadID: threadID,
            source: source
        )
    }

    public func restoredInitialRoute(
        threadExists: (String) -> Bool
    ) -> String? {
        guard let threadID else {
            return nil
        }
        guard threadExists(threadID) else {
            clear(
                source: "restore",
                pathKind: "missing-thread"
            )
            return nil
        }
        return "/local/" + threadID
    }

    private func record(
        threadID: String,
        source: String
    ) {
        userDefaults.set(threadID, forKey: Self.threadIDKey)
        recordDiagnostic(
            source: source,
            pathKind: "local"
        )
    }

    private func clear(
        source: String,
        pathKind: String
    ) {
        userDefaults.removeObject(forKey: Self.threadIDKey)
        recordDiagnostic(
            source: source,
            pathKind: pathKind
        )
    }

    private func recordDiagnostic(
        source: String,
        pathKind: String
    ) {
        let anchorState = threadID == nil ? "missing" : "present"
        userDefaults.set(
            "source=\(source) path=\(pathKind) anchor=\(anchorState)",
            forKey: Self.diagnosticKey
        )
    }

    private static func pathKind(_ path: String) -> String {
        if path == "/" || path.isEmpty {
            return "home"
        }
        return "nonlocal"
    }

    private static func localThreadID(from path: String) -> String? {
        let prefix = "/local/"
        guard path.hasPrefix(prefix) else {
            return nil
        }
        let threadID = String(path.dropFirst(prefix.count))
        guard !threadID.isEmpty,
              !threadID.contains("/"),
              threadID.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ) == threadID
        else {
            return nil
        }
        return threadID
    }
}

@MainActor
public final class CodexDesktopConversationLifecycleAnchor {
    private let store: CodexDesktopLastActiveLocalThreadStore

    public init(store: CodexDesktopLastActiveLocalThreadStore) {
        self.store = store
    }

    public func threadStarted(_ threadID: CodexStoredThreadID) {
        store.recordDurableThreadID(
            threadID.rawValue,
            source: "thread-start"
        )
    }

    public func turnStarted(_ threadID: CodexStoredThreadID) {
        store.recordDurableThreadID(
            threadID.rawValue,
            source: "turn-start"
        )
    }
}

public enum CodexDesktopWebViewEntryOutcome:
    String,
    Codable,
    Equatable,
    Sendable
{
    case entryNotRequested = "entry-not-requested"
    case entryLoadFailed = "entry-load-failed"
    case entryLoadedNotExecuted = "entry-loaded-not-executed"
    case entryExecuted = "entry-executed"
    case probeFailed = "probe-failed"
}

/// Reports the first renderer mutation that exposes a visible semantic
/// control. The released splash contains no interactive controls, while the
/// desktop home, login, settings, and conversation surfaces all do. This
/// avoids coupling readiness to localized copy or minified CSS class names.
public enum CodexDesktopInteractiveSurfaceProbe {
    public static let channel = "renderer-surface"

    public static let documentStartJavaScript = #"""
    (() => {
      "use strict";
      const selector = [
        "button",
        "input",
        "textarea",
        "select",
        "a[href]",
        '[contenteditable="true"]',
        '[role="button"]',
        '[role="link"]',
        '[role="textbox"]',
        '[role="menuitem"]',
        '[role="tab"]',
      ].join(",");
      let committed = false;
      let observer = null;
      const isVisible = (element) => {
        if (!(element instanceof HTMLElement)) return false;
        if (element.hidden || element.getAttribute("aria-hidden") === "true") {
          return false;
        }
        const style = window.getComputedStyle(element);
        if (style.display === "none" || style.visibility === "hidden") {
          return false;
        }
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const inspect = () => {
        if (committed) return;
        const root = document.getElementById("root");
        if (!root) return;
        const visibleInteractiveElementCount = Array.from(
          root.querySelectorAll(selector)
        ).filter(isVisible).length;
        if (visibleInteractiveElementCount === 0) return;
        committed = true;
        observer?.disconnect();
        const handler =
          window.webkit?.messageHandlers?.codexDesktopBridge;
        if (!handler || typeof handler.postMessage !== "function") return;
        try {
          const reply = handler.postMessage({
            channel: "\#(channel)",
            payload: {
              kind: "interactive-surface-committed",
              visibleInteractiveElementCount,
              path: String(window.location.pathname || ""),
            },
          });
          if (reply && typeof reply.catch === "function") {
            void reply.catch(() => {});
          }
        } catch {}
      };
      const start = () => {
        inspect();
        if (committed || !document.documentElement) return;
        observer = new MutationObserver(inspect);
        observer.observe(document.documentElement, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: [
            "aria-hidden",
            "class",
            "contenteditable",
            "disabled",
            "hidden",
            "href",
            "role",
            "style",
          ],
        });
      };
      if (document.documentElement) {
        start();
      } else {
        document.addEventListener("DOMContentLoaded", start, {once: true});
      }
      window.addEventListener("load", inspect, {once: true});
    })();
    """#

    public static func isCommitPayload(
        _ payload: CodexJSONValue
    ) -> Bool {
        guard case let .object(fields) = payload,
              case .string("interactive-surface-committed")? =
                fields["kind"],
              case let .integer(count)? =
                fields["visibleInteractiveElementCount"]
        else {
            return false
        }
        return count > 0
    }
}

public struct CodexDesktopWebViewEntryDocumentState:
    Codable,
    Equatable,
    Sendable
{
    public let readyState: String
    public let href: String
    public let hasDocumentElement: Bool
    public let hasBody: Bool
    public let hasRoot: Bool
    public let rootChildCount: Int?
    public let rootHTMLLength: Int?
    public let bridgeInstalled: Bool
    public let desktopHostInstalled: Bool
}

/// Captures the renderer's CSS viewport independently from the native view
/// hierarchy.  The whole value is optional so older diagnostic payloads and
/// pages that do not expose a complete viewport remain decodable.
public struct CodexDesktopWebViewViewportState:
    Codable,
    Equatable,
    Sendable
{
    public let windowInnerWidth: Int?
    public let windowInnerHeight: Int?
    public let documentElementClientWidth: Int?
    public let documentElementClientHeight: Int?
}

public struct CodexDesktopNativeGeometryRect:
    Codable,
    Equatable,
    Sendable
{
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct CodexDesktopNativeGeometryInsets:
    Codable,
    Equatable,
    Sendable
{
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double

    public init(
        top: Double,
        left: Double,
        bottom: Double,
        right: Double
    ) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

public struct CodexDesktopNativeGeometryNode:
    Codable,
    Equatable,
    Sendable
{
    public let frame: CodexDesktopNativeGeometryRect
    public let bounds: CodexDesktopNativeGeometryRect
    public let safeAreaInsets: CodexDesktopNativeGeometryInsets?

    public init(
        frame: CodexDesktopNativeGeometryRect,
        bounds: CodexDesktopNativeGeometryRect,
        safeAreaInsets: CodexDesktopNativeGeometryInsets?
    ) {
        self.frame = frame
        self.bounds = bounds
        self.safeAreaInsets = safeAreaInsets
    }
}

public struct CodexDesktopNativeGeometrySnapshot:
    Codable,
    Equatable,
    Sendable
{
    public let window: CodexDesktopNativeGeometryNode?
    public let windowScene: CodexDesktopNativeGeometryNode?
    public let rootViewController: CodexDesktopNativeGeometryNode?
    public let container: CodexDesktopNativeGeometryNode
    public let webView: CodexDesktopNativeGeometryNode

    public init(
        window: CodexDesktopNativeGeometryNode?,
        windowScene: CodexDesktopNativeGeometryNode?,
        rootViewController: CodexDesktopNativeGeometryNode?,
        container: CodexDesktopNativeGeometryNode,
        webView: CodexDesktopNativeGeometryNode
    ) {
        self.window = window
        self.windowScene = windowScene
        self.rootViewController = rootViewController
        self.container = container
        self.webView = webView
    }
}

public enum CodexDesktopNativeGeometryDiagnostic {
    public static let kind = "native-geometry"
    public static let key =
        "codex.desktop.last-native-geometry-diagnostic"

    public static func payload(
        _ snapshot: CodexDesktopNativeGeometrySnapshot
    ) -> CodexJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        guard let data = try? encoder.encode(snapshot),
              let decoded = try? JSONDecoder().decode(
                  CodexJSONValue.self,
                  from: data
              ),
              case let .object(fields) = decoded
        else {
            return .object(["kind": .string("invalid")])
        }
        var result = fields
        result["kind"] = .string(kind)
        return .object(result)
    }

    public static func sanitizedPayload(
        _ payload: CodexJSONValue
    ) -> CodexJSONValue {
        guard case let .object(fields) = payload else {
            return .object(["kind": .string("invalid")])
        }
        var sanitized: [String: CodexJSONValue] = [
            "kind": .string(kind)
        ]
        for layer in [
            "window",
            "windowScene",
            "rootViewController",
            "container",
            "webView",
        ] {
            guard let value = fields[layer],
                  Self.isGeometryNode(value)
            else {
                continue
            }
            sanitized[layer] = value
        }
        return .object(sanitized)
    }

    private static func isGeometryNode(
        _ value: CodexJSONValue
    ) -> Bool {
        guard case let .object(fields) = value,
              isRect(fields["frame"]),
              isRect(fields["bounds"])
        else {
            return false
        }
        guard let insets = fields["safeAreaInsets"] else {
            return true
        }
        guard case .null = insets else {
            return isInsets(insets)
        }
        return true
    }

    private static func isRect(
        _ value: CodexJSONValue?
    ) -> Bool {
        guard case let .object(fields)? = value else {
            return false
        }
        return ["x", "y", "width", "height"].allSatisfy {
            key in
            isNumber(fields[key])
        }
    }

    private static func isInsets(
        _ value: CodexJSONValue
    ) -> Bool {
        guard case let .object(fields) = value else {
            return false
        }
        return ["top", "left", "bottom", "right"].allSatisfy {
            key in
            isNumber(fields[key])
        }
    }

    private static func isNumber(
        _ value: CodexJSONValue?
    ) -> Bool {
        guard let value else { return false }
        switch value {
        case .integer, .number:
            return true
        default:
            return false
        }
    }
}

public struct CodexDesktopWebViewModuleScriptState:
    Codable,
    Equatable,
    Sendable
{
    public let source: String
    public let src: String
    public let loadEvent: Bool
    public let errorEvent: Bool
}

public struct CodexDesktopWebViewResourceTimingState:
    Codable,
    Equatable,
    Sendable
{
    public let name: String
    public let initiatorType: String
    public let startTime: Double
    public let duration: Double
    public let responseEnd: Double
    public let transferSize: Double
    public let encodedBodySize: Double
    public let decodedBodySize: Double
    public let responseStatus: Int?
}

public struct CodexDesktopWebViewEntryDiagnosticSnapshot:
    Codable,
    Equatable,
    Sendable
{
    public let document: CodexDesktopWebViewEntryDocumentState
    public let viewport: CodexDesktopWebViewViewportState?
    public let moduleScripts: [CodexDesktopWebViewModuleScriptState]
    public let resourceEntryCount: Int
    public let resourceEntries:
        [CodexDesktopWebViewResourceTimingState]

    public var outcome: CodexDesktopWebViewEntryOutcome {
        let evidence = moduleEvidence
        guard !moduleScripts.isEmpty,
              evidence.requestedCount == moduleScripts.count
        else {
            return .entryNotRequested
        }
        guard evidence.failedCount == 0,
              evidence.loadedCount == moduleScripts.count
        else {
            return .entryLoadFailed
        }
        guard (document.rootChildCount ?? 0) > 0
            || (document.rootHTMLLength ?? 0) > 0
        else {
            return .entryLoadedNotExecuted
        }
        return .entryExecuted
    }

    fileprivate func diagnosticPayload() throws -> CodexJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(self)
        let decoded = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: encoded
        )
        guard case var .object(fields) = decoded else {
            throw CodexDesktopWebViewHostError
                .invalidEntryDiagnosticPayload
        }
        let evidence = moduleEvidence
        fields["kind"] = .string("webkit-entry-probe")
        fields["outcome"] = .string(outcome.rawValue)
        fields["moduleScriptCount"] = .integer(
            Int64(moduleScripts.count)
        )
        fields["requestedModuleScriptCount"] = .integer(
            Int64(evidence.requestedCount)
        )
        fields["loadedModuleScriptCount"] = .integer(
            Int64(evidence.loadedCount)
        )
        fields["failedModuleScriptCount"] = .integer(
            Int64(evidence.failedCount)
        )
        return .object(fields)
    }

    private var moduleEvidence:
        (
            requestedCount: Int,
            loadedCount: Int,
            failedCount: Int
        )
    {
        var requestedCount = 0
        var loadedCount = 0
        var failedCount = 0

        for script in moduleScripts {
            let matchingEntries = resourceEntries.filter {
                $0.name == script.src
            }
            let requested =
                script.loadEvent
                || script.errorEvent
                || !matchingEntries.isEmpty
            let failed =
                script.errorEvent
                || matchingEntries.contains {
                    guard let status = $0.responseStatus else {
                        return false
                    }
                    return status >= 400
                }
            let loaded =
                script.loadEvent
                || matchingEntries.contains {
                    if let status = $0.responseStatus,
                       (200 ..< 400).contains(status)
                    {
                        return true
                    }
                    return $0.transferSize > 0
                        || $0.encodedBodySize > 0
                        || $0.decodedBodySize > 0
                }

            requestedCount += requested ? 1 : 0
            loadedCount += loaded ? 1 : 0
            failedCount += failed ? 1 : 0
        }
        return (requestedCount, loadedCount, failedCount)
    }
}

public enum CodexDesktopWebViewEntryDiagnosticProbe {
    public static let channel = "renderer-diagnostic"

    public static let documentStartJavaScript = #"""
    (() => {
      "use strict";
      const records = Object.create(null);
      const diagnosticHandler = () =>
        window.webkit?.messageHandlers?.codexDesktopBridge;
      const text = (value, limit = 2000) =>
        String(value ?? "").slice(0, limit);
      const postDiagnostic = (payload) => {
        const handler = diagnosticHandler();
        if (!handler || typeof handler.postMessage !== "function") {
          return;
        }
        try {
          const reply = handler.postMessage({
            channel: "\#(channel)",
            payload,
          });
          if (reply && typeof reply.catch === "function") {
            void reply.catch(() => {});
          }
        } catch {}
      };
      const moduleRecord = (target) => {
        if (!(target instanceof HTMLScriptElement)) {
          return null;
        }
        const type = (target.getAttribute("type") ?? "")
          .trim()
          .toLowerCase();
        if (type !== "module" || target.src.length === 0) {
          return null;
        }
        const src = target.src;
        records[src] ??= {loadEvent: false, errorEvent: false};
        return records[src];
      };
      window.addEventListener(
        "load",
        (event) => {
          const record = moduleRecord(event.target);
          if (record !== null) {
            record.loadEvent = true;
          }
        },
        true
      );
      window.addEventListener(
        "error",
        (event) => {
          const record = moduleRecord(event.target);
          if (record !== null) {
            record.errorEvent = true;
          }
          if (typeof event.message === "string" && event.message.length > 0) {
            postDiagnostic({
              kind: "renderer-exception",
              status: "window-error",
              message: text(event.message),
              source: text(event.filename, 1000),
              line: Number.isFinite(event.lineno) ? event.lineno : 0,
              column: Number.isFinite(event.colno) ? event.colno : 0,
              path: text(window.location.pathname, 1000),
            });
          }
        },
        true
      );
      window.addEventListener("unhandledrejection", (event) => {
        const reason = event.reason;
        postDiagnostic({
          kind: "renderer-exception",
          status: "unhandled-rejection",
          message: text(reason?.message ?? reason),
          name: text(reason?.name, 200),
          path: text(window.location.pathname, 1000),
        });
      });
      Object.defineProperty(window, "__codexWebKitEntryProbe", {
        configurable: false,
        enumerable: false,
        value: {records},
        writable: false,
      });
    })();
    """#

    public static let didFinishJavaScript = #"""
    (() => {
      "use strict";
      const tracker =
        window.__codexWebKitEntryProbe?.records ?? Object.create(null);
      const moduleScripts = Array.from(
        document.querySelectorAll('script[type="module"][src]')
      ).map((script) => {
        const evidence = tracker[script.src] ?? {};
        return {
          source: script.getAttribute("src") ?? "",
          src: script.src,
          loadEvent: evidence.loadEvent === true,
          errorEvent: evidence.errorEvent === true,
        };
      });
      const moduleSources = new Set(
        moduleScripts.map((script) => script.src)
      );
      const allResourceEntries =
        performance.getEntriesByType("resource");
      const resourceEntries = allResourceEntries
        .filter(
          (entry) =>
            entry.initiatorType === "script" ||
            moduleSources.has(entry.name)
        )
        .slice(0, 64)
        .map((entry) => ({
          name: entry.name,
          initiatorType: entry.initiatorType,
          startTime: Number.isFinite(entry.startTime)
            ? entry.startTime
            : 0,
          duration: Number.isFinite(entry.duration)
            ? entry.duration
            : 0,
          responseEnd: Number.isFinite(entry.responseEnd)
            ? entry.responseEnd
            : 0,
          transferSize: Number.isFinite(entry.transferSize)
            ? entry.transferSize
            : 0,
          encodedBodySize: Number.isFinite(entry.encodedBodySize)
            ? entry.encodedBodySize
            : 0,
          decodedBodySize: Number.isFinite(entry.decodedBodySize)
            ? entry.decodedBodySize
            : 0,
          responseStatus:
            typeof entry.responseStatus === "number"
              ? entry.responseStatus
              : null,
        }));
      const root = document.getElementById("root");
      const finiteInteger = (value) =>
        Number.isFinite(value) ? Math.round(value) : null;
      return {
        document: {
          readyState: document.readyState,
          href: window.location.href,
          hasDocumentElement: document.documentElement !== null,
          hasBody: document.body !== null,
          hasRoot: root !== null,
          rootChildCount: root?.childElementCount ?? null,
          rootHTMLLength: root?.innerHTML.length ?? null,
          bridgeInstalled: window.electronBridge !== undefined,
          desktopHostInstalled:
            window.__codexDesktopHost !== undefined,
        },
        viewport: {
          windowInnerWidth: finiteInteger(window.innerWidth),
          windowInnerHeight: finiteInteger(window.innerHeight),
          documentElementClientWidth: finiteInteger(
            document.documentElement
              ? document.documentElement.clientWidth
              : null
          ),
          documentElementClientHeight: finiteInteger(
            document.documentElement
              ? document.documentElement.clientHeight
              : null
          ),
        },
        moduleScripts,
        resourceEntryCount: allResourceEntries.length,
        resourceEntries,
      };
    })();
    """#

    public static func snapshot(
        foundationValue: Any
    ) throws -> CodexDesktopWebViewEntryDiagnosticSnapshot {
        guard JSONSerialization.isValidJSONObject(foundationValue) else {
            throw CodexDesktopWebViewHostError
                .invalidEntryDiagnosticPayload
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: foundationValue
            )
            return try JSONDecoder().decode(
                CodexDesktopWebViewEntryDiagnosticSnapshot.self,
                from: data
            )
        } catch {
            throw CodexDesktopWebViewHostError
                .invalidEntryDiagnosticPayload
        }
    }

    public static func diagnosticPayload(
        foundationValue: Any
    ) throws -> CodexJSONValue {
        try snapshot(
            foundationValue: foundationValue
        ).diagnosticPayload()
    }

    public static func failurePayload(
        _ error: Error
    ) -> CodexJSONValue {
        .object([
            "kind": .string("webkit-entry-probe"),
            "outcome": .string(
                CodexDesktopWebViewEntryOutcome.probeFailed.rawValue
            ),
            "message": .string(String(describing: error)),
        ])
    }
}

/// Keeps failure evidence for the two interactive paths currently under
/// physical-device acceptance. These keys intentionally sit outside the
/// bounded heartbeat-heavy runtime log so the last actionable failure is not
/// evicted before device preferences are collected.
public final class CodexDesktopFocusedDiagnosticStore {
    public static let rendererExceptionKey =
        "codex.desktop.last-renderer-exception-diagnostic"
    public static let hardwareShortcutKey =
        "codex.desktop.last-hardware-shortcut-diagnostic"
    public static let nativeGeometryKey =
        CodexDesktopNativeGeometryDiagnostic.key
    /// Debug-only, four-number snapshot used to compare the renderer CSS
    /// viewport with the separately recorded UIKit geometry on a real iPad.
    /// It deliberately has no URL, DOM, session, or timing metadata.
    public static let webKitViewportKey =
        "codex.desktop.debug-last-webkit-viewport-diagnostic"

    private static let webKitViewportFieldNames = [
        "windowInnerWidth",
        "windowInnerHeight",
        "documentElementClientWidth",
        "documentElementClientHeight",
    ]

    private let userDefaults: UserDefaults
    private let sessionID: String
    private let now: () -> Date

    public init(
        userDefaults: UserDefaults = .standard,
        sessionID: String = UUID().uuidString,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.sessionID = sessionID
        self.now = now
    }

    public func beginSession() {
        userDefaults.removeObject(forKey: Self.rendererExceptionKey)
        userDefaults.removeObject(forKey: Self.hardwareShortcutKey)
        userDefaults.removeObject(forKey: Self.nativeGeometryKey)
        userDefaults.removeObject(forKey: Self.webKitViewportKey)
    }

    /// Persists only the CSS viewport's four integer dimensions, and only in
    /// Debug builds used for physical-device diagnosis. Production builds do
    /// not retain the renderer diagnostic at all.
    public func recordWebKitViewport(
        _ payload: CodexJSONValue
    ) {
        #if DEBUG
            guard let sanitized = Self.sanitizedWebKitViewportPayload(
                payload
            ) else {
                userDefaults.removeObject(forKey: Self.webKitViewportKey)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
            guard let data = try? encoder.encode(sanitized),
                  let encoded = String(data: data, encoding: .utf8)
            else {
                userDefaults.removeObject(forKey: Self.webKitViewportKey)
                return
            }
            userDefaults.set(
                String(encoded.prefix(256)),
                forKey: Self.webKitViewportKey
            )
        #endif
    }

    public func recordNativeGeometry(
        _ payload: CodexJSONValue
    ) {
        let sanitized =
            CodexDesktopNativeGeometryDiagnostic.sanitizedPayload(payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        guard let data = try? encoder.encode(sanitized),
              let encoded = String(data: data, encoding: .utf8)
        else {
            userDefaults.set(
                #"{"kind":"invalid"}"#,
                forKey: Self.nativeGeometryKey
            )
            return
        }
        userDefaults.set(
            String(encoded.prefix(8_000)),
            forKey: Self.nativeGeometryKey
        )
    }

    public static func sanitizedRendererDiagnosticPayload(
        _ payload: CodexJSONValue
    ) -> CodexJSONValue {
        guard case let .object(fields) = payload else {
            return .object(["kind": .string("invalid")])
        }
        var sanitized: [String: CodexJSONValue] = [:]
        for key in ["kind", "status", "name", "shortcut"] {
            if case let .string(value)? = fields[key],
               safeToken(value)
            {
                sanitized[key] = .string(value)
            }
        }
        if case let .string(message)? = fields["message"] {
            sanitized["message"] = .string(
                safeDiagnosticText(message) ? message : "<redacted>"
            )
        }
        if case let .string(path)? = fields["path"] {
            sanitized["path"] = .string(
                safeRendererPath(path) ? path : "<redacted>"
            )
        }
        if fields["source"] != nil {
            sanitized["source"] = .string("present")
        }
        for key in ["line", "column"] {
            if case let .integer(value)? = fields[key] {
                sanitized[key] = .integer(value)
            }
        }
        return .object(sanitized)
    }

    private static func sanitizedWebKitViewportPayload(
        _ payload: CodexJSONValue
    ) -> CodexJSONValue? {
        guard case let .object(fields) = payload,
              case let .object(viewport)? = fields["viewport"]
        else {
            return nil
        }
        var sanitized: [String: CodexJSONValue] = [:]
        for name in webKitViewportFieldNames {
            guard let integer = diagnosticViewportInteger(viewport[name])
            else {
                return nil
            }
            sanitized[name] = .integer(integer)
        }
        return .object(sanitized)
    }

    private static func diagnosticViewportInteger(
        _ value: CodexJSONValue?
    ) -> Int64? {
        let integer: Int64
        switch value {
        case let .integer(value):
            integer = value
        case let .number(value):
            guard value.isFinite,
                  value.rounded() == value,
                  value >= Double(Int64.min),
                  value <= Double(Int64.max)
            else {
                return nil
            }
            integer = Int64(value)
        default:
            return nil
        }
        // This is a CSS viewport dimension, not unbounded app data.
        guard (0 ... 16_384).contains(integer) else {
            return nil
        }
        return integer
    }

    public func recordRendererException(
        _ payload: CodexJSONValue
    ) {
        var fields: [String: CodexJSONValue]
        if case let .object(sanitized) =
            Self.sanitizedRendererDiagnosticPayload(payload)
        {
            fields = sanitized
        } else {
            fields = ["kind": .string("invalid")]
        }
        fields["sessionID"] = .string(sessionID)
        fields["recordedAt"] = .string(
            ISO8601DateFormatter().string(from: now())
        )
        let recordedPayload = CodexJSONValue.object(fields)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let value: String
        if let data = try? encoder.encode(recordedPayload),
           let encoded = String(data: data, encoding: .utf8)
        {
            value = String(encoded.prefix(8_000))
        } else {
            value = #"{"kind":"invalid"}"#
        }
        userDefaults.set(value, forKey: Self.rendererExceptionKey)
    }

    private static func safeToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 120
            && value.unicodeScalars.allSatisfy {
                let scalar = $0.value
                return (scalar >= 48 && scalar <= 57)
                    || (scalar >= 65 && scalar <= 90)
                    || (scalar >= 97 && scalar <= 122)
                    || scalar == 95
                    || scalar == 45
            }
    }

    private static func safeDiagnosticText(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 2_000 else {
            return false
        }
        let lowered = value.lowercased()
        let sensitiveMarkers = [
            "http://", "https://", "bearer ", "authorization",
            "access_token", "refresh_token", "api_key", "apikey",
            "token=", "password=", "secret=",
        ]
        return !sensitiveMarkers.contains(where: lowered.contains)
    }

    private static func safeRendererPath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && value.utf8.count <= 1_000
            && !value.contains("?")
            && !value.contains("#")
            && !value.contains("\n")
            && !value.contains("\r")
    }

    public func recordHardwareShortcut(_ diagnostic: String) {
        let context =
            "sessionID=\(sessionID) "
            + "recordedAt=\(ISO8601DateFormatter().string(from: now())) "
            + diagnostic
        userDefaults.set(
            String(context.prefix(4_000)),
            forKey: Self.hardwareShortcutKey
        )
    }
}

/// Persists only the released thread-summary gate result from the Statsig
/// bootstrap. The full response can contain account identifiers and tokens,
/// so none of the source payload is retained.
public final class CodexDesktopStatsigSummaryGateDiagnosticStore {
    public static let key =
        "codex.desktop.last-statsig-summary-gate-diagnostic"
    public static let gateID = "4128908571"
    private static let hashedGateID = "1079957873"

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func record(response: CodexDesktopHostMessage) {
        guard case let .fetchSuccess(_, status, _, body) = response,
              (200 ..< 300).contains(status),
              case let .object(responseFields) = body,
              case let .string(payload)? = responseFields["statsigPayload"],
              let payloadData = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                  CodexJSONValue.self,
                  from: payloadData
              ),
              case let .object(payloadFields) = decoded,
              case let .object(gates)? = payloadFields["feature_gates"]
        else {
            persist(present: false, value: nil)
            return
        }

        guard let gate = gates[Self.gateID]
            ?? gates[Self.hashedGateID]
        else {
            persist(present: false, value: nil)
            return
        }

        let value: Bool?
        switch gate {
        case let .bool(gateValue):
            value = gateValue
        case let .object(fields):
            if case let .bool(gateValue)? = fields["value"]
                ?? fields["v"]
            {
                value = gateValue
            } else {
                value = nil
            }
        default:
            value = nil
        }
        persist(present: true, value: value)
    }

    private func persist(present: Bool, value: Bool?) {
        userDefaults.set(
            "gate=\(Self.gateID) present=\(present) value="
                + (value.map(String.init) ?? "unknown"),
            forKey: Self.key
        )
    }
}

/// Observes the renderer-owned history stack without inventing navigation
/// state on the native side. The actual committed pathname is sent through
/// the same reply-capable WebKit bridge used by the released preload.
/// Converts the native bootstrap query into the renderer-owned SPA pathname
/// before the released renderer or route observer reads `window.location`.
public enum CodexDesktopInitialRouteBootstrapScript {
    public static let source = #"""
    (() => {
      "use strict";
      const candidate = new URLSearchParams(window.location.search).get(
        "initialRoute"
      );
      if (candidate === null) {
        return;
      }

      const localPrefix = "/local/";
      const threadID = candidate.startsWith(localPrefix)
        ? candidate.slice(localPrefix.length)
        : "";
      const uuidPattern =
        /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
      const isPermittedRoute =
        candidate === "/avatar-overlay" ||
        (candidate === localPrefix + threadID && uuidPattern.test(threadID));
      if (!isPermittedRoute) {
        return;
      }

      history.replaceState(history.state, "", candidate);
    })();
    """#
}

public enum CodexDesktopRendererRouteObservationScript {
    public static let messageChannel = "renderer-route-observation"

    public static let source = #"""
    (() => {
      "use strict";
      const notifyNative = () => {
        const handler =
          window.webkit?.messageHandlers?.codexDesktopBridge;
        if (!handler || typeof handler.postMessage !== "function") {
          return;
        }
        try {
          const reply = handler.postMessage({
            channel: "\#(messageChannel)",
            payload: {path: window.location.pathname},
          });
          if (reply && typeof reply.catch === "function") {
            void reply.catch(() => {});
          }
        } catch {}
      };

      const pushState = history.pushState;
      if (typeof pushState === "function") {
        history.pushState = function (...args) {
          const result = Reflect.apply(pushState, this, args);
          notifyNative();
          return result;
        };
      }

      const replaceState = history.replaceState;
      if (typeof replaceState === "function") {
        history.replaceState = function (...args) {
          const result = Reflect.apply(replaceState, this, args);
          notifyNative();
          return result;
        };
      }

      window.addEventListener("popstate", notifyNative);
      notifyNative();
    })();
    """#
}

public enum CodexDesktopWebViewInboundEvent:
    Equatable,
    Sendable
{
    case rendererReady
    case viewFocused
    case logMessage(CodexDesktopLogMessage)
    case fetch(CodexDesktopFetchRequest)
    case fetchStream(CodexDesktopFetchStreamRequest)
    case cancelFetchStream(requestID: String)
    case openInBrowser(CodexDesktopOpenInBrowserRequest)
    case mcpRequest(CodexDesktopMCPRequest)
    case mcpResponse(
        hostID: String,
        response: CodexDesktopMCPClientResponse
    )
    case persistedAtomSyncRequest
    case persistedAtomUpdate(CodexDesktopPersistedAtomUpdate)
    case sharedObjectSubscribe(key: String)
    case sharedObjectUnsubscribe(key: String)
    case sharedObjectSet(key: String, value: CodexJSONValue?)
    case viewEvent(type: String, payload: CodexJSONValue)
    case nativeChannel(name: String, payload: CodexJSONValue)
}

public enum CodexDesktopWebViewMessageRouter {
    public static func route(
        body: CodexJSONValue,
        contract: CodexDesktopWebViewContract = .official
    ) throws -> CodexDesktopWebViewInboundEvent {
        guard case let .object(envelope) = body else {
            throw CodexDesktopWebViewHostError.invalidScriptMessageEnvelope
        }
        guard case let .string(channel)? = envelope["channel"],
              !channel.isEmpty
        else {
            throw CodexDesktopWebViewHostError.invalidScriptMessageChannel
        }
        guard let payload = envelope["payload"] else {
            throw CodexDesktopWebViewHostError.invalidScriptMessagePayload
        }

        guard channel == contract.viewMessageChannel else {
            return .nativeChannel(name: channel, payload: payload)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let message = try CodexDesktopBridgeCodec.decodeViewPayload(
            encoder.encode(payload)
        )
        switch message {
        case .ready:
            return .rendererReady
        case .viewFocused:
            return .viewFocused
        case let .logMessage(log):
            return .logMessage(log)
        case let .fetch(request):
            return .fetch(request)
        case let .fetchStream(request):
            return .fetchStream(request)
        case let .cancelFetchStream(requestID):
            return .cancelFetchStream(requestID: requestID)
        case let .openInBrowser(request):
            return .openInBrowser(request)
        case let .mcpRequest(request):
            return .mcpRequest(request)
        case let .mcpResponse(hostID, response):
            return .mcpResponse(
                hostID: hostID,
                response: response
            )
        case .persistedAtomSyncRequest:
            return .persistedAtomSyncRequest
        case let .persistedAtomUpdate(update):
            return .persistedAtomUpdate(update)
        case let .sharedObjectSubscribe(key):
            return .sharedObjectSubscribe(key: key)
        case let .sharedObjectUnsubscribe(key):
            return .sharedObjectUnsubscribe(key: key)
        case let .sharedObjectSet(key, value):
            return .sharedObjectSet(key: key, value: value)
        case let .viewEvent(type, payload):
            return .viewEvent(type: type, payload: payload)
        }
    }

    public static func route(
        foundationBody: Any,
        contract: CodexDesktopWebViewContract = .official
    ) throws -> CodexDesktopWebViewInboundEvent {
        guard JSONSerialization.isValidJSONObject(foundationBody) else {
            throw CodexDesktopWebViewHostError.invalidScriptMessageEnvelope
        }
        let data = try JSONSerialization.data(
            withJSONObject: foundationBody
        )
        let body = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: data
        )
        return try route(body: body, contract: contract)
    }
}

/// Mirrors the released Electron main-process round trip for renderer-owned
/// command surfaces. The sidebar emits `chat-search-command-menu`; the native
/// host sends the same event back, which opens the existing released React
/// menu instead of substituting an iPad-only screen.
public enum CodexDesktopCommandMenuHostRouter {
    public static func response(
        to type: String,
        payload: CodexJSONValue
    ) -> CodexDesktopHostMessage? {
        guard type == "chat-search-command-menu" else {
            return nil
        }
        return .event(type: type, payload: payload)
    }
}

/// Renderer state retained by Electron's WindowManager and consulted by
/// native shortcut routing. Keeping the complete released payload prevents
/// hardware-keyboard behavior from drifting when focus moves between the
/// composer, terminal, and browser panels.
public struct CodexDesktopAppShellShortcutState: Equatable, Sendable {
    public let bottomPanelBrowserCanZoom: Bool
    public let bottomPanelBrowserConversationID: String?
    public let bottomPanelBrowserTabID: String?
    public let canAcceptAppshotShortcut: Bool
    public let canRedoAppAction: Bool
    public let canUndoAppAction: Bool
    public let bottomPanelCanCloseActiveTab: Bool
    public let focusArea: String
    public let focusedEditable: String?
    public let imagePreviewOpen: Bool
    public let isNewChatRoute: Bool
    public let terminalFocused: Bool
    public let threadNavigationShortcutLocked: Bool
    public let rightPanelBrowserCanZoom: Bool
    public let rightPanelBrowserConversationID: String?
    public let rightPanelBrowserTabID: String?
    public let rightPanelCanCloseActiveTab: Bool

    public init?(payload: CodexJSONValue) {
        guard case let .object(fields) = payload,
              case let .bool(bottomPanelBrowserCanZoom)? =
                  fields["bottomPanelBrowserCanZoom"],
              let bottomPanelBrowserConversationID = Self.nullableString(
                  fields["bottomPanelBrowserConversationId"]
              ),
              let bottomPanelBrowserTabID = Self.nullableString(
                  fields["bottomPanelBrowserTabId"]
              ),
              case let .bool(canAcceptAppshotShortcut)? =
                  fields["canAcceptAppshotShortcut"],
              case let .bool(canRedoAppAction)? =
                  fields["canRedoAppAction"],
              case let .bool(canUndoAppAction)? =
                  fields["canUndoAppAction"],
              case let .bool(bottomPanelCanCloseActiveTab)? =
                  fields["bottomPanelCanCloseActiveTab"],
              case let .string(focusArea)? = fields["focusArea"],
              let focusedEditable = Self.nullableString(
                  fields["focusedEditable"]
              ),
              case let .bool(imagePreviewOpen)? =
                  fields["imagePreviewOpen"],
              case let .bool(isNewChatRoute)? = fields["isNewChatRoute"],
              case let .bool(terminalFocused)? = fields["terminalFocused"],
              case let .bool(threadNavigationShortcutLocked)? =
                  fields["threadNavigationShortcutLocked"],
              case let .bool(rightPanelBrowserCanZoom)? =
                  fields["rightPanelBrowserCanZoom"],
              let rightPanelBrowserConversationID = Self.nullableString(
                  fields["rightPanelBrowserConversationId"]
              ),
              let rightPanelBrowserTabID = Self.nullableString(
                  fields["rightPanelBrowserTabId"]
              ),
              case let .bool(rightPanelCanCloseActiveTab)? =
                  fields["rightPanelCanCloseActiveTab"]
        else {
            return nil
        }

        self.bottomPanelBrowserCanZoom = bottomPanelBrowserCanZoom
        self.bottomPanelBrowserConversationID =
            bottomPanelBrowserConversationID.value
        self.bottomPanelBrowserTabID = bottomPanelBrowserTabID.value
        self.canAcceptAppshotShortcut = canAcceptAppshotShortcut
        self.canRedoAppAction = canRedoAppAction
        self.canUndoAppAction = canUndoAppAction
        self.bottomPanelCanCloseActiveTab = bottomPanelCanCloseActiveTab
        self.focusArea = focusArea
        self.focusedEditable = focusedEditable.value
        self.imagePreviewOpen = imagePreviewOpen
        self.isNewChatRoute = isNewChatRoute
        self.terminalFocused = terminalFocused
        self.threadNavigationShortcutLocked =
            threadNavigationShortcutLocked
        self.rightPanelBrowserCanZoom = rightPanelBrowserCanZoom
        self.rightPanelBrowserConversationID =
            rightPanelBrowserConversationID.value
        self.rightPanelBrowserTabID = rightPanelBrowserTabID.value
        self.rightPanelCanCloseActiveTab = rightPanelCanCloseActiveTab
    }

    private struct NullableString {
        let value: String?
    }

    private static func nullableString(
        _ value: CodexJSONValue?
    ) -> NullableString? {
        switch value {
        case .null?: NullableString(value: nil)
        case let .string(value)?: NullableString(value: value)
        default: nil
        }
    }
}

/// Native menu accelerators extracted from desktop Codex 26.803.41515.
///
/// Electron owns these keystrokes and forwards the messages below to the
/// renderer. iPad hardware keyboards bypass Electron, so the SwiftUI host
/// must reproduce that native boundary exactly rather than inventing a
/// second command implementation.
public enum CodexDesktopNativeShortcut: Equatable, Sendable {
    case newTask
    case commandMenu
    case commandMenuWithEmptyQuery
    case searchFiles
    case settings
    case keyboardShortcuts
    case toggleSidebar
    case toggleBottomPanel
    case toggleTerminal
    case openBrowserTab
    case openReviewTab
    case openSideChat
    case navigateBack
    case navigateForward
    case threadSlot(Int)

    public static func resolve(
        key rawKey: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool,
        physicalKeyCode: UInt16? = nil
    ) -> Self? {
        // iPad hardware keyboards expose the key immediately left of `1`
        // differently depending on the active layout.  With Control held,
        // the physical backtick key can arrive as `~`, `§`, or `±`
        // instead of a literal backtick.  Electron's accelerator is still
        // Control+`, so normalize those layout spellings at this boundary.
        let loweredKey = rawKey.lowercased()
        let isPhysicalGraveKey = physicalKeyCode == 0x35
        let key = control && (isPhysicalGraveKey
            || ["~", "§", "±", "ˋ"].contains(loweredKey))
            ? "`"
            : loweredKey
        return switch (key, command, shift, option, control) {
        case ("n", true, false, false, false): .newTask
        case ("k", true, false, false, false): .commandMenu
        case ("p", true, true, false, false):
            .commandMenuWithEmptyQuery
        case ("p", true, false, false, false): .searchFiles
        case (",", true, false, false, false): .settings
        case ("/", true, false, false, false): .keyboardShortcuts
        case ("b", true, false, false, false): .toggleSidebar
        case ("j", true, false, false, false): .toggleBottomPanel
        case ("`", false, false, false, true): .toggleTerminal
        case ("t", true, false, false, false): .openBrowserTab
        case ("g", false, true, false, true): .openReviewTab
        case ("s", true, false, true, false): .openSideChat
        case ("[", true, false, false, false): .navigateBack
        case ("]", true, false, false, false): .navigateForward
        case let (slot, true, false, false, false)
            where Int(slot).map({ (1 ... 9).contains($0) }) == true:
            .threadSlot(Int(slot)!)
        default: nil
        }
    }

    public var rendererMessage: CodexDesktopHostMessage? {
        switch self {
        case .newTask:
            return runCommand("newTask")
        case .commandMenu:
            return .event(type: "command-menu", payload: .object([:]))
        case .commandMenuWithEmptyQuery:
            return .event(
                type: "command-menu",
                payload: .object(["query": .string("")])
            )
        case .searchFiles:
            return .event(
                type: "file-search-command-menu",
                payload: .object([:])
            )
        case .settings:
            return navigate("/settings")
        case .keyboardShortcuts:
            return navigate("/settings/keyboard-shortcuts")
        case .toggleSidebar:
            return .event(type: "toggle-sidebar", payload: .object([:]))
        case .toggleBottomPanel:
            return .event(
                type: "toggle-bottom-panel",
                payload: .object([:])
            )
        case .toggleTerminal:
            return .event(type: "toggle-terminal", payload: .object([:]))
        case .openBrowserTab:
            return .event(
                type: "open-browser-tab",
                payload: .object([
                    "source": .string("manual"),
                    "initiator": .string("app_menu"),
                ])
            )
        case .openReviewTab:
            return runCommand("openReviewTab")
        case .openSideChat:
            return runCommand("openSideChat")
        case .navigateBack:
            return .event(type: "navigate-back", payload: .object([:]))
        case .navigateForward:
            return .event(type: "navigate-forward", payload: .object([:]))
        case let .threadSlot(slot):
            guard (1 ... 9).contains(slot) else {
                return nil
            }
            return runCommand("thread\(slot)")
        }
    }

    private func runCommand(
        _ id: String
    ) -> CodexDesktopHostMessage {
        .event(
            type: "run-command",
            payload: .object(["id": .string(id)])
        )
    }

    private func navigate(
        _ path: String
    ) -> CodexDesktopHostMessage {
        .event(
            type: "navigate-to-route",
            payload: .object(["path": .string(path)])
        )
    }
}

/// Prevents one physical keyboard press from being replayed twice when both
/// UIKit's key-command path and the lower-level press responder observe it.
public struct CodexDesktopHardwareShortcutDispatchGate: Sendable {
    public let duplicateInterval: TimeInterval
    private var lastDispatch:
        (shortcut: CodexDesktopNativeShortcut, timestamp: TimeInterval)?

    public init(duplicateInterval: TimeInterval = 0.05) {
        self.duplicateInterval = duplicateInterval
    }

    public mutating func shouldDispatch(
        _ shortcut: CodexDesktopNativeShortcut,
        timestamp: TimeInterval
    ) -> Bool {
        defer { lastDispatch = (shortcut, timestamp) }
        guard let lastDispatch,
              lastDispatch.shortcut == shortcut
        else {
            return true
        }
        let elapsed = timestamp - lastDispatch.timestamp
        return elapsed < 0 || elapsed > duplicateInterval
    }
}

/// The released desktop accelerator table shared by both WebKit's DOM bridge
/// and UIKit's priority responder-chain commands. Keeping one table prevents
/// an iPad-only accelerator from drifting away from the Electron contract.
public struct CodexDesktopNativeShortcutBinding: Equatable, Sendable {
    public let title: String
    public let key: String
    public let command: Bool
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let shortcut: CodexDesktopNativeShortcut

    public static let released: [Self] = {
        var bindings: [Self] = [
            binding("New Chat", "n", command: true, shortcut: .newTask),
            binding("Command Menu", "k", command: true, shortcut: .commandMenu),
            binding(
                "Command Menu",
                "p",
                command: true,
                shift: true,
                shortcut: .commandMenuWithEmptyQuery
            ),
            binding("Search Files", "p", command: true, shortcut: .searchFiles),
            binding("Settings", ",", command: true, shortcut: .settings),
            binding(
                "Keyboard Shortcuts",
                "/",
                command: true,
                shortcut: .keyboardShortcuts
            ),
            binding("Toggle Sidebar", "b", command: true, shortcut: .toggleSidebar),
            binding(
                "Toggle Bottom Panel",
                "j",
                command: true,
                shortcut: .toggleBottomPanel
            ),
            binding("Open Terminal", "`", control: true, shortcut: .toggleTerminal),
            binding("Open Browser Tab", "t", command: true, shortcut: .openBrowserTab),
            binding(
                "Open Review Tab",
                "g",
                shift: true,
                control: true,
                shortcut: .openReviewTab
            ),
            binding(
                "Open Side Chat",
                "s",
                command: true,
                option: true,
                shortcut: .openSideChat
            ),
            binding("Back", "[", command: true, shortcut: .navigateBack),
            binding("Forward", "]", command: true, shortcut: .navigateForward),
        ]
        bindings.append(
            contentsOf: (1 ... 9).map {
                binding(
                    "Open Chat \($0)",
                    String($0),
                    command: true,
                    shortcut: .threadSlot($0)
                )
            }
        )
        return bindings
    }()

    private static func binding(
        _ title: String,
        _ key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shortcut: CodexDesktopNativeShortcut
    ) -> Self {
        Self(
            title: title,
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control,
            shortcut: shortcut
        )
    }
}

public enum CodexDesktopHardwareShortcutScript {
    public static func make() throws -> String {
        let bindings = CodexDesktopNativeShortcutBinding.released.map(binding)
        let data = try JSONSerialization.data(
            withJSONObject: bindings,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw CodexDesktopWebViewHostError.invalidHostPayload
        }
        return """
        (() => {
          const bindings = \(json);
          const postDiagnostic = payload => {
            const handler =
              window.webkit?.messageHandlers?.codexDesktopBridge;
            if (!handler || typeof handler.postMessage !== "function") {
              return;
            }
            try {
              const reply = handler.postMessage({
                channel: "\(CodexDesktopWebViewEntryDiagnosticProbe.channel)",
                payload: {
                  kind: "hardware-shortcut",
                  ...payload,
                },
              });
              if (reply && typeof reply.catch === "function") {
                void reply.catch(() => {});
              }
            } catch {}
          };
          document.addEventListener("keydown", event => {
            const key = String(event.key || "").toLowerCase();
            const binding = bindings.find(candidate =>
              candidate.key === key &&
              candidate.command === event.metaKey &&
              candidate.shift === event.shiftKey &&
              candidate.option === event.altKey &&
              candidate.control === event.ctrlKey
            );
            if (!binding) {
              if (event.metaKey || event.ctrlKey) {
                postDiagnostic({
                  status: "unmatched",
                  key,
                  command: event.metaKey,
                  shift: event.shiftKey,
                  option: event.altKey,
                  control: event.ctrlKey,
                });
              }
              return;
            }
            const host = window.__codexDesktopHost;
            if (!host || typeof host.receive !== "function") {
              postDiagnostic({status: "host-missing", key});
              return;
            }
            event.preventDefault();
            event.stopImmediatePropagation();
            host.receive(binding.message);
            postDiagnostic({status: "forwarded", key});
          }, true);
        })();
        """
    }

    private static func binding(
        _ binding: CodexDesktopNativeShortcutBinding
    ) -> [String: Any] {
        guard let message = binding.shortcut.rendererMessage,
              let object = try? JSONSerialization.jsonObject(
                  with: CodexDesktopBridgeCodec.encodeHostPayload(message)
              )
        else {
            preconditionFailure("Invalid desktop shortcut message")
        }
        return [
            "key": binding.key,
            "command": binding.command,
            "shift": binding.shift,
            "option": binding.option,
            "control": binding.control,
            "message": object,
        ]
    }
}

public enum CodexDesktopWebViewUserScriptRole:
    String,
    Equatable,
    Sendable
{
    case initialRouteBootstrap
    case entryDiagnostic
    case interactiveSurface
    case bridge
    case routeObservation
    case hardwareShortcut
}

public struct CodexDesktopWebViewUserScriptDescriptor:
    Equatable,
    Sendable
{
    public let role: CodexDesktopWebViewUserScriptRole
    public let source: String
    public let injectionPhase: CodexDesktopWebViewInjectionPhase
    public let forMainFrameOnly: Bool
}

public enum CodexDesktopWebViewUserScriptPlan {
    public static func make(
        bootstrap: CodexDesktopBridgeBootstrap,
        contract: CodexDesktopWebViewContract = .official
    ) throws -> [CodexDesktopWebViewUserScriptDescriptor] {
        [
            CodexDesktopWebViewUserScriptDescriptor(
                role: .initialRouteBootstrap,
                source: CodexDesktopInitialRouteBootstrapScript.source,
                injectionPhase: contract.injectionPhase,
                forMainFrameOnly: contract.injectForMainFrameOnly
            ),
            CodexDesktopWebViewUserScriptDescriptor(
                role: .entryDiagnostic,
                source:
                    CodexDesktopWebViewEntryDiagnosticProbe
                        .documentStartJavaScript,
                injectionPhase: contract.injectionPhase,
                forMainFrameOnly: contract.injectForMainFrameOnly
            ),
            CodexDesktopWebViewUserScriptDescriptor(
                role: .interactiveSurface,
                source:
                    CodexDesktopInteractiveSurfaceProbe
                        .documentStartJavaScript,
                injectionPhase: contract.injectionPhase,
                forMainFrameOnly: contract.injectForMainFrameOnly
            ),
            CodexDesktopWebViewUserScriptDescriptor(
                role: .bridge,
                source: try CodexDesktopBridgeScript.make(
                    bootstrap: bootstrap
                ),
                injectionPhase: contract.injectionPhase,
                forMainFrameOnly: contract.injectForMainFrameOnly
            ),
            CodexDesktopWebViewUserScriptDescriptor(
                role: .routeObservation,
                source: CodexDesktopRendererRouteObservationScript.source,
                injectionPhase: contract.injectionPhase,
                forMainFrameOnly: contract.injectForMainFrameOnly
            ),
            CodexDesktopWebViewUserScriptDescriptor(
                role: .hardwareShortcut,
                source: try CodexDesktopHardwareShortcutScript.make(),
                injectionPhase: contract.injectionPhase,
                forMainFrameOnly: contract.injectForMainFrameOnly
            ),
        ]
    }
}

public struct CodexDesktopWebViewHostInvocation:
    Equatable,
    Sendable
{
    public let functionBody: String
    public let argumentName: String
    public let payload: CodexJSONValue

    public static func make(
        message: CodexDesktopHostMessage,
        contract: CodexDesktopWebViewContract = .official
    ) throws -> CodexDesktopWebViewHostInvocation {
        let data = try CodexDesktopBridgeCodec.encodeHostPayload(message)
        let payload = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: data
        )
        guard case .object = payload else {
            throw CodexDesktopWebViewHostError.invalidHostPayload
        }
        return CodexDesktopWebViewHostInvocation(
            functionBody: contract.hostReceiveFunctionBody,
            argumentName: contract.hostReceiveArgumentName,
            payload: payload
        )
    }

    fileprivate func foundationPayload() throws -> Any {
        let data = try JSONEncoder().encode(payload)
        return try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
    }
}

/// Reduces a renderer location to the released app origin and path only.
/// Query and fragment values may contain account or workspace data, so runtime
/// diagnostics must never persist the full WebView URL.
public enum CodexDesktopRendererLocationDiagnostic {
    public static func appPath(
        from absoluteString: String,
        contract: CodexDesktopWebViewContract = .official
    ) -> String? {
        guard let components = URLComponents(string: absoluteString),
              components.scheme == contract.applicationScheme,
              components.host == contract.applicationHost
        else {
            return nil
        }
        return components.path.isEmpty ? "/" : components.path
    }
}

#if os(iOS) && canImport(WebKit)
    import UIKit
    import WebKit

    /// Owns the iPad hardware-keyboard boundary that Electron owns on macOS.
    ///
    /// Registering these commands on the WebView's responder chain is
    /// intentional: SwiftUI scene commands lose reserved combinations such as
    /// Command-comma to iPadOS before the released renderer can receive them.
    /// Priority commands keep those accelerators application-local while the
    /// currently focused DOM control remains the text-input responder.
    @MainActor
    private final class CodexDesktopHardwareShortcutWebView: WKWebView {
        var onHardwareShortcut:
            ((CodexDesktopNativeShortcut) -> Void)?
        var avatarOverlayInputRegions:
            [CodexDesktopAvatarOverlayInputRegion]?

        override func point(
            inside point: CGPoint,
            with event: UIEvent?
        ) -> Bool {
            guard super.point(inside: point, with: event) else {
                return false
            }
            guard let avatarOverlayInputRegions else {
                return true
            }
            return avatarOverlayInputRegions.contains { region in
                region.contains(
                    x: Double(point.x),
                    y: Double(point.y)
                )
            }
        }

        override var keyCommands: [UIKeyCommand]? {
            Self.shortcutCommands + (super.keyCommands ?? [])
        }

        override func pressesBegan(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            let handled = dispatchHardwareShortcut(from: presses)
            if !handled {
                super.pressesBegan(presses, with: event)
            }
        }

        @objc
        private func performDesktopShortcut(
            _ command: UIKeyCommand
        ) {
            guard let input = command.input else {
                return
            }
            let flags = command.modifierFlags
            guard let shortcut = CodexDesktopNativeShortcut.resolve(
                key: input,
                command: flags.contains(.command),
                shift: flags.contains(.shift),
                option: flags.contains(.alternate),
                control: flags.contains(.control)
            ) else {
                return
            }
            onHardwareShortcut?(shortcut)
        }

        private func dispatchHardwareShortcut(
            from presses: Set<UIPress>
        ) -> Bool {
            for press in presses {
                guard let key = press.key else { continue }
                let flags = key.modifierFlags
                let input = key.charactersIgnoringModifiers
                let shortcut = CodexDesktopNativeShortcut.resolve(
                    key: input,
                    command: flags.contains(.command),
                    shift: flags.contains(.shift),
                    option: flags.contains(.alternate),
                    control: flags.contains(.control),
                    physicalKeyCode: UInt16(key.keyCode.rawValue)
                )
                UserDefaults.standard.set(
                    "path=webview-presses-began input=\(input) flags=\(flags.rawValue) handled=\(shortcut != nil)",
                    forKey: CodexDesktopFocusedDiagnosticStore.hardwareShortcutKey
                )
                guard let shortcut else { continue }
                onHardwareShortcut?(shortcut)
                return true
            }
            return false
        }

        private static let shortcutCommands: [UIKeyCommand] = {
            CodexDesktopNativeShortcutBinding.released.map { binding in
                var modifiers: UIKeyModifierFlags = []
                if binding.command { modifiers.insert(.command) }
                if binding.shift { modifiers.insert(.shift) }
                if binding.option { modifiers.insert(.alternate) }
                if binding.control { modifiers.insert(.control) }
                let command = UIKeyCommand(
                    title: binding.title,
                    action: #selector(performDesktopShortcut(_:)),
                    input: binding.key,
                    modifierFlags: modifiers
                )
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }()

    }

    private final class CodexDesktopWebViewAppSchemeHandler:
        NSObject,
        WKURLSchemeHandler
    {
        private let contract: CodexDesktopWebViewContract
        private let lock = NSLock()
        private var surfaceDirectoryURL: URL?

        init(contract: CodexDesktopWebViewContract) {
            self.contract = contract
        }

        func configure(surfaceDirectoryURL: URL) {
            lock.lock()
            self.surfaceDirectoryURL = surfaceDirectoryURL
            lock.unlock()
        }

        func webView(
            _: WKWebView,
            start urlSchemeTask: WKURLSchemeTask
        ) {
            let request = urlSchemeTask.request
            guard request.httpMethod == nil
                || request.httpMethod?.uppercased() == "GET"
            else {
                urlSchemeTask.didFailWithError(
                    NSError(
                        domain: "CodexDesktopWebViewAppScheme",
                        code: 405,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Only GET is supported for app resources."
                        ]
                    )
                )
                return
            }

            lock.lock()
            let root = surfaceDirectoryURL
            lock.unlock()

            guard let root else {
                urlSchemeTask.didFailWithError(
                    NSError(
                        domain: "CodexDesktopWebViewAppScheme",
                        code: 503,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The Codex surface is not configured."
                        ]
                    )
                )
                return
            }

            do {
                guard let requestURL = request.url else {
                    throw CodexDesktopWebViewHostError
                        .invalidApplicationOrigin
                }
                let resource =
                    try CodexDesktopWebViewAppResourceResolver.resolve(
                        requestURL: requestURL,
                        surfaceDirectoryURL: root,
                        contract: contract
                    )
                var data = try Data(contentsOf: resource.fileURL)
                if requestURL.path == "/" + contract.entryFilename {
                    data = try CodexDesktopWebViewEntryDocument.prepare(
                        data,
                        contract: contract
                    )
                } else if resource.mimeType == "text/javascript" {
                    data = try CodexDesktopIPadLoginResourceAdapter.adapt(
                        data,
                        resourceFilename:
                            resource.fileURL.lastPathComponent
                    )
                }
                let response = URLResponse(
                    url: requestURL,
                    mimeType: resource.mimeType,
                    expectedContentLength: data.count,
                    textEncodingName:
                        Self.textEncodingName(for: resource.mimeType)
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                urlSchemeTask.didFailWithError(error)
            }
        }

        func webView(
            _: WKWebView,
            stop _: WKURLSchemeTask
        ) {}

        private static func textEncodingName(
            for mimeType: String
        ) -> String? {
            switch mimeType {
            case "text/html",
                 "text/javascript",
                 "text/css",
                 "application/json",
                 "text/plain":
                return "utf-8"
            default:
                return nil
            }
        }
    }

    @MainActor
public final class CodexDesktopWebViewHost:
    NSObject,
    WKNavigationDelegate
{
        /// Stable native accessibility state for the released surface.
        ///
        /// The renderer exposes its DOM controls before the native startup
        /// gate has finished. Giving the hosting WebView a stateful
        /// identifier lets UI automation wait for the same `ready`
        /// checkpoint that the controller uses, instead of racing the
        /// renderer's splash screen.
        private enum AccessibilityIdentifier {
            static let loading = "CodexDesktopSurfaceLoading"
            static let ready = "CodexDesktopSurfaceReady"
            static let failed = "CodexDesktopSurfaceFailed"
        }

        public typealias EventHandler =
            @MainActor (CodexDesktopWebViewInboundEvent) -> Void
        public typealias StateHandler =
            @MainActor (CodexDesktopSurfaceState) -> Void
        public typealias NativeChannelHandler =
            @MainActor (
                String,
                CodexJSONValue
            ) async throws -> CodexJSONValue?

        public let webView: WKWebView
        public let contract: CodexDesktopWebViewContract
        public private(set) var stateMachine:
            CodexDesktopSurfaceStateMachine
        public var onEvent: EventHandler
        public var onStateChange: StateHandler
        public var onNativeChannel: NativeChannelHandler?
        public var onHardwareShortcut:
            (@MainActor (CodexDesktopNativeShortcut) -> Void)?

        public func setAvatarOverlayInputShape(
            _ regions: [CodexDesktopAvatarOverlayInputRegion]
        ) {
            guard let webView = webView as?
                CodexDesktopHardwareShortcutWebView
            else {
                return
            }
            webView.avatarOverlayInputRegions = regions
        }

        private let userContentController: WKUserContentController
        private let scriptHandler: CodexDesktopWebViewScriptHandler
        private let appSchemeHandler:
            CodexDesktopWebViewAppSchemeHandler
        private var pendingRendererReady = false

        public init(
            bootstrap: CodexDesktopBridgeBootstrap,
            contract: CodexDesktopWebViewContract = .official,
            onEvent: @escaping EventHandler = { _ in },
            onStateChange: @escaping StateHandler = { _ in }
        ) throws {
            let userScriptPlan = try CodexDesktopWebViewUserScriptPlan.make(
                bootstrap: bootstrap,
                contract: contract
            )
            let contentController = WKUserContentController()
            let scriptHandler = CodexDesktopWebViewScriptHandler()
            let appSchemeHandler =
                CodexDesktopWebViewAppSchemeHandler(contract: contract)
            for descriptor in userScriptPlan {
                let injectionTime: WKUserScriptInjectionTime =
                    switch descriptor.injectionPhase {
                    case .documentStart:
                        .atDocumentStart
                    }
                contentController.addUserScript(
                    WKUserScript(
                        source: descriptor.source,
                        injectionTime: injectionTime,
                        forMainFrameOnly: descriptor.forMainFrameOnly,
                        in: .page
                    )
                )
            }
            contentController.addScriptMessageHandler(
                scriptHandler,
                contentWorld: .page,
                name: contract.messageHandlerName
            )

            let configuration = WKWebViewConfiguration()
            configuration.userContentController = contentController
            configuration.setURLSchemeHandler(
                appSchemeHandler,
                forURLScheme: contract.applicationScheme
            )

            let webView = CodexDesktopHardwareShortcutWebView(
                frame: .zero,
                configuration: configuration
            )
            self.webView = webView
            self.webView.accessibilityIdentifier =
                AccessibilityIdentifier.loading
            self.webView.scrollView.delaysContentTouches = false
            self.contract = contract
            self.stateMachine = CodexDesktopSurfaceStateMachine()
            self.onEvent = onEvent
            self.onStateChange = onStateChange
            self.userContentController = contentController
            self.scriptHandler = scriptHandler
            self.appSchemeHandler = appSchemeHandler
            super.init()

            scriptHandler.owner = self
            webView.navigationDelegate = self
            webView.onHardwareShortcut = { [weak self] shortcut in
                self?.onHardwareShortcut?(shortcut)
            }
        }

        public var state: CodexDesktopSurfaceState {
            stateMachine.state
        }

        public func loadVerifiedSurface(
            _ plan: CodexDesktopWebViewLoadPlan
        ) throws {
            guard FileManager.default.fileExists(
                atPath: plan.entryURL.path
            ) else {
                let error = CodexDesktopWebViewHostError.missingEntryFile(
                    plan.entryURL
                )
                try apply(.resourcesFailed(String(describing: error)))
                throw error
            }

            guard plan.requestURL.scheme == contract.applicationScheme,
                  plan.requestURL.host == contract.applicationHost
            else {
                let error =
                    CodexDesktopWebViewHostError.invalidAppResourceURL(
                        plan.requestURL
                    )
                try apply(.resourcesFailed(String(describing: error)))
                throw error
            }
            try apply(.resourcesVerified)
            appSchemeHandler.configure(
                surfaceDirectoryURL: plan.readAccessURL
            )
            webView.load(URLRequest(url: plan.requestURL))
        }

        public func resourceVerificationFailed(
            _ reason: String
        ) throws {
            try apply(.resourcesFailed(reason))
        }

        public func markHomeDataLoaded() throws {
            try apply(.homeDataLoaded)
        }

        public func markBridgeReady() throws {
            switch stateMachine.state {
            case .loadingDocument:
                pendingRendererReady = true
            case .awaitingBridgeReady:
                try apply(.bridgeReady)
            case .awaitingHomeData, .ready:
                break
            case .verifyingResources, .failed:
                throw CodexDesktopSurfaceTransitionError
                    .invalidTransition(
                        from: stateMachine.state,
                        event: .bridgeReady
                    )
            }
        }

        public func retry() throws {
            pendingRendererReady = false
            try apply(.retry)
        }

        public func send(
            _ message: CodexDesktopHostMessage
        ) async throws {
            let invocation = try CodexDesktopWebViewHostInvocation.make(
                message: message,
                contract: contract
            )
            let payload = try invocation.foundationPayload()
            _ = try await webView.callAsyncJavaScript(
                invocation.functionBody,
                arguments: [invocation.argumentName: payload],
                in: nil,
                contentWorld: .page
            )
        }

        public func currentRendererPath() async throws -> String? {
            let value = try await webView.callAsyncJavaScript(
                "return String(window.location.href || '');",
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            guard let absoluteString = value as? String else {
                return nil
            }
            return CodexDesktopRendererLocationDiagnostic.appPath(
                from: absoluteString,
                contract: contract
            )
        }

        public func visibleTextOccurrenceCount(
            _ text: String
        ) async throws -> Int {
            let result = try await webView.callAsyncJavaScript(
                """
                const value = String(text || "");
                if (!value) return 0;
                return String(document.body?.innerText || "")
                    .split(value).length - 1;
                """,
                arguments: ["text": text],
                in: nil,
                contentWorld: .page
            )
            return result as? Int ?? 0
        }

        public func webView(
            _: WKWebView,
            didFinish _: WKNavigation?
        ) {
            collectEntryDiagnostics()
            do {
                try apply(.documentLoaded)
                if pendingRendererReady {
                    pendingRendererReady = false
                    try apply(.bridgeReady)
                }
            } catch {
                failRenderer(error)
            }
        }

        private func collectEntryDiagnostics() {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                do {
                    let result = try await webView.evaluateJavaScript(
                        CodexDesktopWebViewEntryDiagnosticProbe
                            .didFinishJavaScript
                    )
                    guard let result else {
                        throw CodexDesktopWebViewHostError
                            .invalidEntryDiagnosticPayload
                    }
                    let payload =
                        try CodexDesktopWebViewEntryDiagnosticProbe
                            .diagnosticPayload(
                                foundationValue: result
                            )
                    await dispatchRendererDiagnostic(payload)
                } catch {
                    await dispatchRendererDiagnostic(
                        CodexDesktopWebViewEntryDiagnosticProbe
                            .failurePayload(error)
                    )
                }
            }
        }

        private func dispatchRendererDiagnostic(
            _ payload: CodexJSONValue
        ) async {
            let channel = CodexDesktopWebViewEntryDiagnosticProbe.channel
            onEvent(
                .nativeChannel(
                    name: channel,
                    payload: payload
                )
            )
            guard let onNativeChannel else {
                return
            }
            do {
                _ = try await onNativeChannel(channel, payload)
            } catch {
                onEvent(
                    .nativeChannel(
                        name: channel,
                        payload:
                            CodexDesktopWebViewEntryDiagnosticProbe
                                .failurePayload(error)
                    )
                )
            }
        }

        public func webView(
            _: WKWebView,
            didFail _: WKNavigation?,
            withError error: Error
        ) {
            failRenderer(error)
        }

        public func webView(
            _: WKWebView,
            didFailProvisionalNavigation _: WKNavigation?,
            withError error: Error
        ) {
            failRenderer(error)
        }

        public func webViewWebContentProcessDidTerminate(
            _: WKWebView
        ) {
            do {
                try apply(.webContentProcessTerminated)
            } catch {
                failRenderer(error)
            }
        }

        fileprivate func receiveScriptMessage(
            body: Any
        ) async -> (Any?, String?) {
            do {
                let event = try CodexDesktopWebViewMessageRouter.route(
                    foundationBody: body,
                    contract: contract
                )
                onEvent(event)

                switch event {
                case .rendererReady:
                    receiveRendererReady()
                    return (nil, nil)
                case .viewFocused,
                     .logMessage,
                     .openInBrowser,
                     .persistedAtomSyncRequest,
                     .persistedAtomUpdate,
                     .sharedObjectSubscribe,
                     .sharedObjectUnsubscribe,
                     .sharedObjectSet,
                     .viewEvent,
                     .fetch,
                     .fetchStream,
                     .cancelFetchStream,
                     .mcpRequest,
                     .mcpResponse:
                    return (nil, nil)
                case let .nativeChannel(name, payload):
                    guard let onNativeChannel else {
                        return (
                            nil,
                            "Native bridge channel is not connected: \(name)"
                        )
                    }
                    let result = try await onNativeChannel(name, payload)
                    if let result {
                        let data = try JSONEncoder().encode(result)
                        let object = try JSONSerialization.jsonObject(
                            with: data,
                            options: [.fragmentsAllowed]
                        )
                        return (object, nil)
                    } else {
                        return (nil, nil)
                    }
                }
            } catch {
                return (nil, String(describing: error))
            }
        }

        private func receiveRendererReady() {
            do {
                try markBridgeReady()
            } catch {
                // A released renderer message is ignored until navigation
                // has entered the verified document lifecycle.
            }
        }

        private func apply(
            _ event: CodexDesktopSurfaceEvent
        ) throws {
            try stateMachine.apply(event)
            switch stateMachine.state {
            case .ready:
                webView.accessibilityIdentifier =
                    AccessibilityIdentifier.ready
            case .failed:
                webView.accessibilityIdentifier =
                    AccessibilityIdentifier.failed
            default:
                webView.accessibilityIdentifier =
                    AccessibilityIdentifier.loading
            }
            onStateChange(stateMachine.state)
        }

        private func failRenderer(_ error: Error) {
            do {
                try apply(.rendererFailed(String(describing: error)))
            } catch {
                // The first explicit failure remains the surfaced state.
            }
        }
    }

    @MainActor
    private final class CodexDesktopWebViewScriptHandler:
        NSObject,
        WKScriptMessageHandlerWithReply
    {
        weak var owner: CodexDesktopWebViewHost?

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) async -> (Any?, String?) {
            guard let owner else {
                return (nil, "Codex desktop host was released")
            }
            return await owner.receiveScriptMessage(body: message.body)
        }
    }
#endif
