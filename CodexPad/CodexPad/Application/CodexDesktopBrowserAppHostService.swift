import Foundation

/// Owns the iPad equivalent of the desktop browser-sidebar window state.
///
/// iPadOS has one primary application window for this surface, so storage
/// ownership is local to that window. The state still preserves the released
/// renderer-session, host-generation, storage-ownership, live-page, and
/// durable-snapshot contracts instead of returning a fixed restore result.
public actor CodexDesktopBrowserPageRestoreState {
    public typealias Value = CodexDesktopAppHostRPC.Value

    public struct PageIdentity: Hashable, Sendable {
        public let browserStorageID: String
        public let browserTabID: String
        public let conversationID: String

        public init(
            browserStorageID: String,
            browserTabID: String,
            conversationID: String
        ) {
            self.browserStorageID = browserStorageID
            self.browserTabID = browserTabID
            self.conversationID = conversationID
        }
    }

    public enum RestoreMode: String, Sendable {
        case none
        case required
    }

    private struct RouteIdentity: Hashable, Sendable {
        let browserTabID: String
        let conversationID: String
    }

    private struct LivePage: Sendable {
        let identity: PageIdentity
        var hostGeneration: Int64?
        var snapshot: Value
    }

    private var rendererInstanceID: String?
    private var durableSnapshots: [PageIdentity: Value] = [:]
    private var livePages: [RouteIdentity: LivePage] = [:]

    public init() {}

    public func recordDurableSnapshot(
        _ snapshot: Value,
        browserStorageID: String,
        browserTabID: String,
        conversationID: String
    ) {
        let identity = PageIdentity(
            browserStorageID: browserStorageID,
            browserTabID: browserTabID,
            conversationID: conversationID
        )
        durableSnapshots[identity] = snapshot

        let route = RouteIdentity(
            browserTabID: browserTabID,
            conversationID: conversationID
        )
        if var livePage = livePages[route],
           livePage.identity == identity
        {
            livePage.snapshot = snapshot
            livePages[route] = livePage
        }
    }

    public func registerWebviewHostSession(
        rendererInstanceID: String
    ) -> Bool {
        if self.rendererInstanceID == rendererInstanceID {
            return true
        }
        self.rendererInstanceID = rendererInstanceID
        for route in livePages.keys {
            livePages[route]?.hostGeneration = nil
        }
        return true
    }

    public func registerWebviewHost(
        browserTabID: String,
        conversationID: String,
        hostGeneration: Int64,
        browserStorageID: String,
        restoreMode: RestoreMode,
        rendererInstanceID: String
    ) -> Bool {
        guard self.rendererInstanceID == rendererInstanceID else {
            return false
        }

        let route = RouteIdentity(
            browserTabID: browserTabID,
            conversationID: conversationID
        )
        let identity = PageIdentity(
            browserStorageID: browserStorageID,
            browserTabID: browserTabID,
            conversationID: conversationID
        )

        if let existing = livePages[route] {
            guard existing.identity == identity,
                  existing.hostGeneration.map({ $0 <= hostGeneration })
                    ?? true
            else {
                return false
            }
        }
        guard !livePages.contains(where: { otherRoute, page in
            otherRoute != route
                && page.identity.browserStorageID == browserStorageID
        }) else {
            return false
        }

        let snapshot: Value
        if let existing = livePages[route] {
            snapshot = existing.snapshot
        } else if let durableSnapshot = durableSnapshots[identity] {
            snapshot = durableSnapshot
        } else if restoreMode == .required {
            return false
        } else {
            snapshot = Self.emptyPageSnapshot
        }

        livePages[route] = LivePage(
            identity: identity,
            hostGeneration: hostGeneration,
            snapshot: snapshot
        )
        return true
    }

    public func restoreResults(
        for pages: [PageIdentity]
    ) -> [Value] {
        pages.map { identity in
            let liveOwners = livePages.values.filter {
                $0.identity.browserStorageID
                    == identity.browserStorageID
            }
            if let livePage = liveOwners.first(where: {
                $0.identity.browserTabID == identity.browserTabID
                    && $0.identity.conversationID
                        == identity.conversationID
            }) {
                return .object([
                    "browserStorageId": .string(
                        livePage.identity.browserStorageID
                    ),
                    "snapshot": livePage.snapshot,
                    "status": .string("already-live"),
                ])
            }
            guard liveOwners.isEmpty,
                  let snapshot = durableSnapshots[identity]
            else {
                return .object(["status": .string("missing")])
            }
            return .object([
                "snapshot": snapshot,
                "status": .string("snapshot-ready"),
            ])
        }
    }

    /// Searches the embedded iPad browser pages that are known to this
    /// renderer session.  The desktop implementation combines this source
    /// with Chrome extension tabs; on iPad this is the native equivalent.
    public func searchPageMentions(
        conversationID: String,
        query: String,
        limit: Int = 128
    ) -> [Value] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty, limit > 0 else { return [] }

        var pagesByIdentity: [PageIdentity: Value] = durableSnapshots
        for page in livePages.values {
            pagesByIdentity[page.identity] = page.snapshot
        }

        return pagesByIdentity
            .filter { identity, snapshot in
                guard identity.conversationID == conversationID else {
                    return false
                }
                let title = Self.stringValue(snapshot, key: "title") ?? ""
                let url = Self.stringValue(snapshot, key: "url") ?? ""
                return title.localizedCaseInsensitiveContains(normalizedQuery)
                    || url.localizedCaseInsensitiveContains(normalizedQuery)
            }
            .sorted {
                ($0.key.browserTabID, $0.key.browserStorageID)
                    < ($1.key.browserTabID, $1.key.browserStorageID)
            }
            .prefix(limit)
            .map { identity, snapshot in
                .object([
                    "browserId": .string("ipad-in-app-browser"),
                    "browserFamily": .string("in-app"),
                    "faviconUrl": Self.value(snapshot, key: "faviconUrl") ?? .null,
                    "pluginId": .string("browser"),
                    "tabId": .string(identity.browserTabID),
                    "snapshot": .object([
                        "title": Self.value(snapshot, key: "title") ?? .string(""),
                        "url": Self.value(snapshot, key: "url") ?? .string(""),
                    ]),
                    "source": .string("in-app"),
                ])
            }
    }

    public func deleteConversation(_ conversationID: String) {
        durableSnapshots = durableSnapshots.filter {
            $0.key.conversationID != conversationID
        }
        livePages = livePages.filter {
            $0.key.conversationID != conversationID
        }
    }

    private static let emptyPageSnapshot: Value = .object([
        "activeWebMcpToolCalls": .array([]),
        "annotationFlow": .string("batch"),
        "annotationModeEntrySource": .null,
        "canGoBack": .bool(false),
        "canGoForward": .bool(false),
        "commentModeDisabledReason": .null,
        "comments": .array([]),
        "faviconUrl": .null,
        "interactionMode": .string("browse"),
        "isAudible": .bool(false),
        "isAudioMuted": .bool(false),
        "isCapturingUserMedia": .bool(false),
        "isLoading": .bool(false),
        "isSuspended": .bool(false),
        "isWaitingForResponse": .bool(false),
        "lastWebMcpToolCall": .null,
        "securityState": .null,
        "tabType": .string("new-tab-page"),
        "title": .string("New tab"),
        "url": .string(""),
        "webMcpToolsAvailability": .string("unavailable"),
        "zoomPercent": .integer(100),
    ])

    private static func value(_ snapshot: Value, key: String) -> Value? {
        guard case let .object(fields) = snapshot else { return nil }
        return fields[key]
    }

    private static func stringValue(_ snapshot: Value, key: String) -> String? {
        guard case let .string(value)? = value(snapshot, key: key) else {
            return nil
        }
        return value
    }
}

/// iPad-native browser integration for the released desktop AppHost contract.
///
/// Electron webviews and Chrome native messaging do not exist on iPadOS, so
/// requests are forwarded to the application layer where the embedded browser,
/// UIApplication URL routing, and embedded plugin runtime perform the matching
/// platform operation.
public actor CodexDesktopBrowserAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias InstalledBrowserFamilies =
        @Sendable () async -> [String]
    public typealias EventHandler =
        @Sendable (String, String, [Value]?) async -> Void
    public typealias WebMcpInspectorDataProvider =
        @Sendable (_ conversationID: String, _ browserTabID: String)
            async throws -> Value
    /// Returns the extension actions exposed by the current iPad web view.
    /// The default implementation reports an empty action set, which is the
    /// truthful iPad equivalent when no browser extension host is installed.
    public typealias ExtensionActionsProvider =
        @Sendable (_ conversationID: String, _ browserTabID: String)
            async throws -> Value

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unsupportedMethod(service: String, method: String)
    }

    private let installedBrowserFamiliesHandler:
        InstalledBrowserFamilies
    private let eventHandler: EventHandler
    private let webMcpInspectorDataProvider: WebMcpInspectorDataProvider
    private let extensionActionsProvider: ExtensionActionsProvider
    private let pageRestoreState: CodexDesktopBrowserPageRestoreState
    public private(set) var preparedConversationIDs: Set<String> = []

    public init(
        installedBrowserFamilies:
            InstalledBrowserFamilies? = nil,
        pageRestoreState:
            CodexDesktopBrowserPageRestoreState = .init(),
        webMcpInspectorDataProvider:
            WebMcpInspectorDataProvider? = nil,
        extensionActionsProvider: ExtensionActionsProvider? = nil,
        eventHandler: EventHandler? = nil
    ) {
        installedBrowserFamiliesHandler =
            installedBrowserFamilies ?? { [] }
        self.pageRestoreState = pageRestoreState
        self.webMcpInspectorDataProvider =
            webMcpInspectorDataProvider ?? { _, _ in .null }
        self.extensionActionsProvider =
            extensionActionsProvider ?? { _, _ in
                .object([
                    "status": .string("unsupported"),
                    "actions": .array([]),
                ])
            }
        self.eventHandler = eventHandler ?? { _, _, _ in }
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch (service, method) {
        case ("browserTabs", "search"):
            let fields = try argumentObject(arguments)
            guard let conversationID = Self.nonemptyString(fields["conversationId"]),
                  let query = Self.string(fields["query"])
            else {
                throw Error.invalidArguments
            }
            return .object([
                "candidates": .array(
                    await pageRestoreState.searchPageMentions(
                        conversationID: conversationID,
                        query: query
                    )
                )
            ])

        case ("browserTabs", "getChromeTabLiveness"):
            let fields = try argumentObject(arguments)
            guard Self.nonemptyString(fields["extensionInstanceId"])
                    != nil,
                  case .array? = fields["tabIds"]
            else {
                throw Error.invalidArguments
            }
            return .object(["status": .string("unavailable")])

        case ("browserTabs", "focusChromeTab"),
             ("browserTabs", "subscribeInvalidations"):
            _ = try argumentObject(arguments)
            await eventHandler(service, method, arguments)
            return .undefined

        case ("inAppBrowserIncompleteNavigation", "subscribe"):
            guard arguments?.count == 1,
                  case .import? = arguments?.first
            else {
                throw Error.invalidArguments
            }
            await eventHandler(service, method, arguments)
            return .undefined

        case ("inAppBrowserIncompleteNavigation", "unsubscribe"):
            guard arguments == nil || arguments?.isEmpty == true else {
                throw Error.invalidArguments
            }
            await eventHandler(service, method, arguments)
            return .undefined

        case ("browserSidebar", "getPageRestoreResults"):
            let fields = try argumentObject(arguments)
            guard case let .array(pages)? = fields["pages"] else {
                throw Error.invalidArguments
            }
            let identities = try pages.map(Self.pageIdentity)
            return .array(
                await pageRestoreState.restoreResults(for: identities)
            )

        case ("browserSidebar", "getExtensionActions"):
            let fields = try argumentObject(arguments)
            guard let browserTabID = Self.nonemptyString(
                fields["browserTabId"]
            ),
                  let conversationID = Self.nonemptyString(
                    fields["conversationId"]
                  )
            else {
                throw Error.invalidArguments
            }
            let result = try await extensionActionsProvider(
                conversationID,
                browserTabID
            )
            guard Self.isValidExtensionActionsResult(result) else {
                throw Error.invalidArguments
            }
            return result

        case ("browserSidebar", "getWebMcpInspectorData"):
            guard arguments?.count == 1 else {
                throw Error.invalidArguments
            }
            let fields = try argumentObject(arguments)
            guard let browserTabID = Self.nonemptyString(
                fields["browserTabId"]
            ),
                  let conversationID = Self.nonemptyString(
                    fields["conversationId"]
                  )
            else {
                throw Error.invalidArguments
            }
            let result = try await webMcpInspectorDataProvider(
                conversationID,
                browserTabID
            )
            try Self.validateWebMcpInspectorData(result)
            return result

        case (
            "browserSidebar",
            "prepareLocalWorkSessionRoute"
        ):
            let fields = try argumentObject(arguments)
            guard let conversationID = Self.string(
                fields["browserConversationId"]
            ) else {
                throw Error.invalidArguments
            }
            preparedConversationIDs.insert(conversationID)
            await eventHandler(service, method, arguments)
            return .undefined

        case (
            "browserSidebar",
            "cancelPendingLocalWorkSessionRoute"
        ):
            let fields = try argumentObject(arguments)
            guard let conversationID = Self.string(
                fields["browserConversationId"]
            ) else {
                throw Error.invalidArguments
            }
            preparedConversationIDs.remove(conversationID)
            await eventHandler(service, method, arguments)
            return .undefined

        case ("browserSidebar", "deleteConversation"):
            let fields = try argumentObject(arguments)
            guard let conversationID =
                Self.string(fields["browserConversationId"])
                    ?? Self.string(fields["conversationId"])
            else {
                throw Error.invalidArguments
            }
            preparedConversationIDs.remove(conversationID)
            await pageRestoreState.deleteConversation(conversationID)
            await eventHandler(service, method, arguments)
            return .undefined

        case ("browserSidebar", "triggerExtensionAction"):
            _ = try argumentObject(arguments)
            await eventHandler(service, method, arguments)
            // The released desktop contract uses false when an extension
            // action is unavailable for the current page.
            return .bool(false)

        case ("browserSidebar", "setAudioMuted"):
            let fields = try argumentObject(arguments)
            guard Self.nonemptyString(fields["browserTabId"]) != nil,
                  Self.nonemptyString(fields["conversationId"]) != nil,
                  case .bool? = fields["muted"]
            else {
                throw Error.invalidArguments
            }
            await eventHandler(service, method, arguments)
            return .undefined

        case ("browserSidebar", "registerWebviewHostSession"):
            let fields = try argumentObject(arguments)
            guard let rendererInstanceID = Self.nonemptyString(
                fields["rendererInstanceId"]
            ) else {
                throw Error.invalidArguments
            }
            return .bool(
                await pageRestoreState.registerWebviewHostSession(
                    rendererInstanceID: rendererInstanceID
                )
            )

        case ("browserSidebar", "registerWebviewHost"):
            let fields = try argumentObject(arguments)
            guard let browserTabID = Self.nonemptyString(
                fields["browserTabId"]
            ),
                  let conversationID = Self.nonemptyString(
                    fields["conversationId"]
                  ),
                  case let .integer(hostGeneration)? =
                    fields["hostGeneration"],
                  case let .object(pagePersistence)? =
                    fields["pagePersistence"],
                  let browserStorageID = Self.nonemptyString(
                    pagePersistence["browserStorageId"]
                  ),
                  let restoreValue = Self.nonemptyString(
                    pagePersistence["restore"]
                  ),
                  let restoreMode =
                    CodexDesktopBrowserPageRestoreState.RestoreMode(
                        rawValue: restoreValue
                    ),
                  let rendererInstanceID = Self.nonemptyString(
                    fields["rendererInstanceId"]
                  )
            else {
                throw Error.invalidArguments
            }
            return .bool(
                await pageRestoreState.registerWebviewHost(
                    browserTabID: browserTabID,
                    conversationID: conversationID,
                    hostGeneration: hostGeneration,
                    browserStorageID: browserStorageID,
                    restoreMode: restoreMode,
                    rendererInstanceID: rendererInstanceID
                )
            )

        case ("browserSidebar", "focusCommentOverlay"),
             ("browserSidebar", "openSiteInfo"),
             (
                 "browserSidebar",
                 "setFloatingComposerRevealTracking"
             ):
            _ = try argumentObject(arguments)
            await eventHandler(service, method, arguments)
            return .undefined

        case ("chromeNativeHost", "install"):
            let fields = try argumentObject(arguments)
            guard Self.nonemptyString(fields["hostId"]) != nil,
                  Self.nonemptyString(fields["pluginName"]) != nil,
                  fields["marketplacePath"] == .null
                    || Self.string(fields["marketplacePath"]) != nil
            else {
                throw Error.invalidArguments
            }
            await eventHandler(service, method, arguments)
            return .undefined

        case ("chromeNativeHost", "uninstall"):
            let fields = try argumentObject(arguments)
            guard Self.nonemptyString(fields["hostId"]) != nil,
                  Self.nonemptyString(fields["marketplaceName"]) != nil,
                  Self.nonemptyString(fields["pluginName"]) != nil
            else {
                throw Error.invalidArguments
            }
            await eventHandler(service, method, arguments)
            return .undefined

        case (
            "chromiumBrowser",
            "getInstalledBrowserFamilies"
        ):
            let values = await installedBrowserFamiliesHandler()
            var seen: Set<String> = []
            return .array(
                values.compactMap { value in
                    let normalized = value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !normalized.isEmpty,
                          seen.insert(normalized).inserted
                    else {
                        return nil
                    }
                    return .string(normalized)
                }
            )

        case ("chromiumBrowser", "openUrl"):
            let fields = try argumentObject(arguments)
            guard Self.nonemptyString(fields["browserFamily"]) != nil,
                  let rawURL = Self.nonemptyString(fields["url"]),
                  URL(string: rawURL) != nil
            else {
                throw Error.invalidArguments
            }
            await eventHandler(service, method, arguments)
            return .undefined

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    private static func validateWebMcpInspectorData(
        _ value: Value
    ) throws {
        if value == .null { return }
        guard case let .object(fields) = value,
              case .array? = fields["recentToolCalls"],
              case .array? = fields["tools"]
        else {
            throw Error.invalidArguments
        }
    }

    private func argumentObject(
        _ arguments: [Value]?
    ) throws -> [String: Value] {
        guard case let .object(fields)? = arguments?.first else {
            throw Error.invalidArguments
        }
        return fields
    }

    private static func string(_ value: Value?) -> String? {
        guard case let .string(string)? = value else {
            return nil
        }
        return string
    }

    private static func nonemptyString(_ value: Value?) -> String? {
        guard let value = string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func isValidExtensionActionsResult(_ value: Value) -> Bool {
        if value == .null { return true }
        guard case let .object(fields) = value,
              case let .string(status)? = fields["status"],
              !status.isEmpty,
              case .array? = fields["actions"]
        else { return false }
        return true
    }

    private static func pageIdentity(
        _ value: Value
    ) throws -> CodexDesktopBrowserPageRestoreState.PageIdentity {
        guard case let .object(fields) = value,
              let browserStorageID = nonemptyString(
                fields["browserStorageId"]
              ),
              let browserTabID = nonemptyString(fields["browserTabId"]),
              let conversationID = nonemptyString(
                fields["conversationId"]
              )
        else {
            throw Error.invalidArguments
        }
        return CodexDesktopBrowserPageRestoreState.PageIdentity(
            browserStorageID: browserStorageID,
            browserTabID: browserTabID,
            conversationID: conversationID
        )
    }
}
