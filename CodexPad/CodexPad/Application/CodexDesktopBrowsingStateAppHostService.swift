import Foundation

/// iPad application hooks for the released desktop browser-state services.
///
/// The desktop 26.730.61309 host obtains these values from its Chromium
/// browsing session, sidebar autocomplete coordinator, live tab registry, and
/// app-server avatar store. Those stores do not have a universal iPadOS
/// substitute, so this service validates the released RPC shapes and forwards
/// each request to an injected application provider. With no provider it
/// reports the missing mechanism rather than inventing browsing or avatar data.
public actor CodexDesktopBrowsingStateAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias Provider =
        @Sendable (Request) async throws -> Value
    public typealias CallbackInvoker =
        @Sendable (Int, [Value]) async throws -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unavailable(service: String, method: String)
        case unsupportedMethod(service: String, method: String)
    }

    public enum Request: Equatable, Sendable {
        case clearBrowsingData(Value)
        case getBrowsingDataSettings
        case getBrowsingDataSummary(timeRange: String)
        case removeBrowsingHistoryEntries(Value)
        case searchBrowsingHistory(Value)
        case startBrowserSidebarAutocomplete(
            request: Value,
            callback: Value
        )
        case stopBrowserSidebarAutocomplete(Value)
        case acceptBrowserSidebarAutocomplete(Value)
        case recordBrowserSidebarAutocompleteNavigation(Value)
        case deleteBrowserSidebarAutocompleteMatch(Value)
        case searchBrowserTabMentions(Value)
        case subscribeBrowserTabMentionInvalidations(
            callback: Value
        )
        case loadCustomAvatars
        case loadCustomAvatar(id: String)
        case previewCustomAvatarInstall(Value)
        case installCustomAvatar(Value)

        public var service: String {
            switch self {
            case .clearBrowsingData,
                 .getBrowsingDataSettings,
                 .getBrowsingDataSummary,
                 .removeBrowsingHistoryEntries,
                 .searchBrowsingHistory:
                "browsingHistory"
            case .startBrowserSidebarAutocomplete,
                 .stopBrowserSidebarAutocomplete,
                 .acceptBrowserSidebarAutocomplete,
                 .recordBrowserSidebarAutocompleteNavigation,
                 .deleteBrowserSidebarAutocompleteMatch:
                "browserSidebarAutocomplete"
            case .searchBrowserTabMentions,
                 .subscribeBrowserTabMentionInvalidations:
                "browserTabMentions"
            case .loadCustomAvatars,
                 .loadCustomAvatar,
                 .previewCustomAvatarInstall,
                 .installCustomAvatar:
                "customAvatars"
            }
        }

        public var method: String {
            switch self {
            case .clearBrowsingData:
                "clearBrowsingData"
            case .getBrowsingDataSettings:
                "getBrowsingDataSettings"
            case .getBrowsingDataSummary:
                "getBrowsingDataSummary"
            case .removeBrowsingHistoryEntries:
                "removeEntries"
            case .searchBrowsingHistory:
                "searchHistory"
            case .startBrowserSidebarAutocomplete:
                "start"
            case .stopBrowserSidebarAutocomplete:
                "stop"
            case .acceptBrowserSidebarAutocomplete:
                "accept"
            case .recordBrowserSidebarAutocompleteNavigation:
                "recordNavigation"
            case .deleteBrowserSidebarAutocompleteMatch:
                "deleteMatch"
            case .searchBrowserTabMentions:
                "search"
            case .subscribeBrowserTabMentionInvalidations:
                "subscribeInvalidations"
            case .loadCustomAvatars:
                "load"
            case .loadCustomAvatar:
                "loadAvatar"
            case .previewCustomAvatarInstall:
                "previewPetInstall"
            case .installCustomAvatar:
                "installPet"
            }
        }
    }

    private static let browsingDataTypes: Set<String> = [
        "cache",
        "cookies",
        "downloads",
        "formData",
        "history",
        "siteData",
        "siteSettings",
    ]

    private static let browsingDataTimeRanges: Set<String> = [
        "allTime",
        "lastDay",
        "lastHour",
        "lastMonth",
        "lastWeek",
    ]

    private let provider: Provider?

    public init(provider: Provider? = nil) {
        self.provider = provider
    }

    /// Builds the iPad production implementation for the released browser
    /// sidebar autocomplete contract. It uses the same embedded-page state as
    /// `browserTabs` and delivers result updates through the renderer-owned
    /// imported callback instead of returning placeholder matches.
    public init(
        pageRestoreState: CodexDesktopBrowserPageRestoreState,
        customAvatarStore: CodexDesktopCustomAvatarStore? = nil,
        callbackInvoker: @escaping CallbackInvoker
    ) {
        let autocomplete =
            CodexDesktopBrowserSidebarAutocompleteCoordinator(
                pageRestoreState: pageRestoreState,
                callbackInvoker: callbackInvoker
            )
        self.provider = { request in
            switch request.service {
            case "customAvatars":
                guard let customAvatarStore else {
                    throw Error.unavailable(
                        service: request.service,
                        method: request.method
                    )
                }
                return try await customAvatarStore.invoke(request)
            default:
                return try await autocomplete.invoke(request)
            }
        }
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        let request: Request
        switch (service, method) {
        case ("browsingHistory", "clearBrowsingData"):
            let argument = try onlyArgument(arguments)
            try Self.validateClearBrowsingData(argument)
            request = .clearBrowsingData(argument)

        case ("browsingHistory", "getBrowsingDataSettings"):
            try validateNoArguments(arguments)
            request = .getBrowsingDataSettings

        case ("browsingHistory", "getBrowsingDataSummary"):
            let argument = try onlyArgument(arguments)
            guard let timeRange = Self.string(argument),
                  Self.browsingDataTimeRanges.contains(timeRange)
            else {
                throw Error.invalidArguments
            }
            request = .getBrowsingDataSummary(
                timeRange: timeRange
            )

        case ("browsingHistory", "removeEntries"):
            let argument = try onlyArgument(arguments)
            try Self.validateHistoryRemovalEntries(argument)
            request = .removeBrowsingHistoryEntries(argument)

        case ("browsingHistory", "searchHistory"):
            let argument = try onlyArgument(arguments)
            try Self.validateHistorySearch(argument)
            request = .searchBrowsingHistory(argument)

        case ("browserSidebarAutocomplete", "start"):
            guard let arguments,
                  arguments.count == 2
            else {
                throw Error.invalidArguments
            }
            try Self.validateAutocompleteStart(arguments[0])
            try Self.validateImportedCallback(arguments[1])
            request = .startBrowserSidebarAutocomplete(
                request: arguments[0],
                callback: arguments[1]
            )

        case ("browserSidebarAutocomplete", "stop"):
            let argument = try onlyArgument(arguments)
            try Self.validateAutocompleteStop(argument)
            request = .stopBrowserSidebarAutocomplete(argument)

        case ("browserSidebarAutocomplete", "accept"):
            let argument = try onlyArgument(arguments)
            try Self.validateAutocompleteAccept(argument)
            request = .acceptBrowserSidebarAutocomplete(argument)

        case ("browserSidebarAutocomplete", "recordNavigation"):
            let argument = try onlyArgument(arguments)
            try Self.validateAutocompleteRecordNavigation(argument)
            request = .recordBrowserSidebarAutocompleteNavigation(argument)

        case ("browserSidebarAutocomplete", "deleteMatch"):
            let argument = try onlyArgument(arguments)
            try Self.validateAutocompleteDeleteMatch(argument)
            request = .deleteBrowserSidebarAutocompleteMatch(argument)

        case ("browserTabMentions", "search"):
            let argument = try onlyArgument(arguments)
            try Self.validateTabMentionSearch(argument)
            request = .searchBrowserTabMentions(argument)

        case (
            "browserTabMentions",
            "subscribeInvalidations"
        ):
            let callback = try onlyArgument(arguments)
            try Self.validateImportedCallback(callback)
            request =
                .subscribeBrowserTabMentionInvalidations(
                    callback: callback
                )

        case ("customAvatars", "load"):
            try validateNoArguments(arguments)
            request = .loadCustomAvatars

        case ("customAvatars", "loadAvatar"):
            let argument = try onlyArgument(arguments)
            guard let id = Self.string(argument) else {
                throw Error.invalidArguments
            }
            request = .loadCustomAvatar(id: id)

        case ("customAvatars", "previewPetInstall"):
            let argument = try onlyArgument(arguments)
            try Self.validatePetInstall(argument)
            request = .previewCustomAvatarInstall(argument)

        case ("customAvatars", "installPet"):
            let argument = try onlyArgument(arguments)
            try Self.validatePetInstall(argument)
            request = .installCustomAvatar(argument)

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }

        guard let provider else {
            throw Error.unavailable(
                service: request.service,
                method: request.method
            )
        }
        return try await provider(request)
    }


    private static func validatePetInstall(_ value: Value) throws {
        guard let fields = object(value),
              let name = string(fields["name"]),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let imageURL = string(fields["imageUrl"]),
              let url = URL(string: imageURL),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              host.lowercased() != "localhost"
        else {
            throw Error.invalidArguments
        }
        if let description = fields["description"],
           description != .null,
           string(description) == nil
        {
            throw Error.invalidArguments
        }
        if let version = fields["spriteVersionNumber"] {
            guard let number = nonnegativeInteger(version),
                  number == 1 || number == 2
            else {
                throw Error.invalidArguments
            }
        }
    }

    private func onlyArgument(
        _ arguments: [Value]?
    ) throws -> Value {
        guard let arguments,
              arguments.count == 1
        else {
            throw Error.invalidArguments
        }
        return arguments[0]
    }

    private func validateNoArguments(
        _ arguments: [Value]?
    ) throws {
        guard arguments?.isEmpty ?? true else {
            throw Error.invalidArguments
        }
    }

    private static func validateClearBrowsingData(
        _ value: Value
    ) throws {
        guard let fields = object(value),
              case let .array(dataTypes)? = fields["dataTypes"],
              let timeRange = string(fields["timeRange"]),
              browsingDataTimeRanges.contains(timeRange),
              dataTypes.allSatisfy({ value in
                  guard let dataType = string(value) else {
                      return false
                  }
                  return browsingDataTypes.contains(dataType)
              })
        else {
            throw Error.invalidArguments
        }
    }

    private static func validateHistoryRemovalEntries(
        _ value: Value
    ) throws {
        guard case let .array(entries) = value,
              entries.allSatisfy({ value in
                  guard let fields = object(value),
                        nonemptyString(fields["url"]) != nil,
                        let visitTime = number(
                            fields["visitTime"]
                        )
                  else {
                      return false
                  }
                  return visitTime >= 0
              })
        else {
            throw Error.invalidArguments
        }
    }

    private static func validateHistorySearch(
        _ value: Value
    ) throws {
        guard let fields = object(value),
              string(fields["text"]) != nil,
              let startTime = number(fields["startTime"]),
              startTime >= 0
        else {
            throw Error.invalidArguments
        }

        if let endTime = fields["endTime"] {
            guard let value = number(endTime),
                  value >= 0
            else {
                throw Error.invalidArguments
            }
        }
        if let maxResults = fields["maxResults"] {
            guard nonnegativeInteger(maxResults) != nil else {
                throw Error.invalidArguments
            }
        }
        if let offset = fields["offset"] {
            guard nonnegativeInteger(offset) != nil else {
                throw Error.invalidArguments
            }
        }
    }

    private static func validateAutocompleteStart(
        _ value: Value
    ) throws {
        guard let fields = object(value),
              hasAutocompleteIdentity(fields),
              let input = object(fields["input"]),
              nonnegativeInteger(input["cursorPosition"]) != nil,
              case .bool? = input["preventInlineAutocomplete"],
              string(input["text"]) != nil
        else {
            throw Error.invalidArguments
        }
    }

    private static func validateAutocompleteStop(
        _ value: Value
    ) throws {
        guard let fields = object(value),
              hasAutocompleteIdentity(fields),
              nonemptyString(fields["reason"]) != nil
        else {
            throw Error.invalidArguments
        }
    }

    private static func validateAutocompleteAccept(
        _ value: Value
    ) throws {
        guard let fields = object(value),
              hasAutocompleteIdentity(fields),
              nonemptyString(fields["acceptToken"]) != nil
        else {
            throw Error.invalidArguments
        }
    }

    private static func validateAutocompleteRecordNavigation(
        _ value: Value
    ) throws {
        guard let fields = object(value),
              hasAutocompleteIdentity(fields),
              let destinationURL = nonemptyString(fields["destinationURL"]),
              URL(string: destinationURL) != nil
        else {
            throw Error.invalidArguments
        }
    }

    private static func validateAutocompleteDeleteMatch(
        _ value: Value
    ) throws {
        guard let fields = object(value),
              hasAutocompleteIdentity(fields),
              nonemptyString(fields["deleteToken"]) != nil
        else {
            throw Error.invalidArguments
        }
    }

    private static func hasAutocompleteIdentity(
        _ fields: [String: Value]
    ) -> Bool {
        nonemptyString(fields["browserTabId"]) != nil
            && nonemptyString(fields["conversationId"]) != nil
            && nonemptyString(fields["editingSessionId"]) != nil
            && nonemptyString(fields["requestId"]) != nil
    }

    private static func validateTabMentionSearch(
        _ value: Value
    ) throws {
        guard let fields = object(value),
              nonemptyString(fields["conversationId"]) != nil,
              string(fields["query"]) != nil
        else {
            throw Error.invalidArguments
        }
    }

    private static func validateImportedCallback(
        _ value: Value
    ) throws {
        guard case .import = value else {
            throw Error.invalidArguments
        }
    }

    private static func object(
        _ value: Value?
    ) -> [String: Value]? {
        guard case let .object(fields)? = value else {
            return nil
        }
        return fields
    }

    private static func string(_ value: Value?) -> String? {
        guard case let .string(string)? = value else {
            return nil
        }
        return string
    }

    private static func nonemptyString(
        _ value: Value?
    ) -> String? {
        guard let value = string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func number(_ value: Value?) -> Double? {
        switch value {
        case let .integer(value):
            return Double(value)
        case let .number(value) where value.isFinite:
            return value
        default:
            return nil
        }
    }

    private static func nonnegativeInteger(
        _ value: Value?
    ) -> Int64? {
        switch value {
        case let .integer(value) where value >= 0:
            return value
        case let .number(value)
            where value.isFinite
                && value >= 0
                && value.rounded(.towardZero) == value:
            return Int64(exactly: value)
        default:
            return nil
        }
    }
}

private actor CodexDesktopBrowserSidebarAutocompleteCoordinator {
    typealias Value = CodexDesktopAppHostRPC.Value
    typealias Request = CodexDesktopBrowsingStateAppHostService.Request
    typealias CallbackInvoker =
        CodexDesktopBrowsingStateAppHostService.CallbackInvoker

    private struct Identity: Hashable, Sendable {
        let browserTabID: String
        let conversationID: String
        let editingSessionID: String
        let requestID: String
    }

    private struct ActiveRequest: Sendable {
        let identity: Identity
        let callbackID: Int
        var matches: [[String: Value]]
    }

    private struct RecentNavigation: Equatable, Sendable {
        let conversationID: String
        let destinationURL: String
    }

    private let pageRestoreState: CodexDesktopBrowserPageRestoreState
    private let callbackInvoker: CallbackInvoker
    private var activeRequest: ActiveRequest?
    private var deletedTokens = Set<String>()
    private var recentNavigations: [RecentNavigation] = []

    init(
        pageRestoreState: CodexDesktopBrowserPageRestoreState,
        callbackInvoker: @escaping CallbackInvoker
    ) {
        self.pageRestoreState = pageRestoreState
        self.callbackInvoker = callbackInvoker
    }

    func invoke(_ request: Request) async throws -> Value {
        switch request {
        case let .startBrowserSidebarAutocomplete(value, callback):
            try await start(value, callback: callback)
        case let .stopBrowserSidebarAutocomplete(value):
            stop(value)
        case let .acceptBrowserSidebarAutocomplete(value):
            accept(value)
        case let .recordBrowserSidebarAutocompleteNavigation(value):
            recordNavigation(value)
        case let .deleteBrowserSidebarAutocompleteMatch(value):
            try await deleteMatch(value)
        default:
            throw CodexDesktopBrowsingStateAppHostService.Error
                .unavailable(
                    service: request.service,
                    method: request.method
                )
        }
        return .undefined
    }

    private func start(
        _ value: Value,
        callback: Value
    ) async throws {
        guard let fields = Self.object(value),
              let identity = Self.identity(fields),
              let input = Self.object(fields["input"]),
              let text = Self.string(input["text"]),
              let cursorPosition = Self.integer(
                  input["cursorPosition"]
              ),
              case let .bool(preventInlineAutocomplete)? =
                  input["preventInlineAutocomplete"],
              case let .import(callbackID) = callback
        else {
            throw CodexDesktopBrowsingStateAppHostService.Error
                .invalidArguments
        }

        let query = Self.query(
            text: text,
            utf16CursorPosition: cursorPosition
        )
        var matches = await pageMatches(
            conversationID: identity.conversationID,
            query: query,
            preventInlineAutocomplete: preventInlineAutocomplete
        )
        if let direct = Self.directURLMatch(query: query) {
            matches.insert(direct, at: 0)
        }
        matches.append(
            contentsOf: recentNavigationMatches(
                conversationID: identity.conversationID,
                query: query,
                existingDestinations: Set(
                    matches.compactMap {
                        Self.string($0["destinationURL"])
                    }
                )
            )
        )
        matches = Array(matches.prefix(128))

        activeRequest = ActiveRequest(
            identity: identity,
            callbackID: callbackID,
            matches: matches
        )
        try await sendCurrentResult()
    }

    private func stop(_ value: Value) {
        guard let identity = Self.identity(Self.object(value)),
              activeRequest?.identity == identity
        else {
            return
        }
        activeRequest = nil
    }

    private func accept(_ value: Value) {
        guard let identity = Self.identity(Self.object(value)),
              activeRequest?.identity == identity
        else {
            return
        }
        activeRequest = nil
    }

    private func recordNavigation(_ value: Value) {
        guard let fields = Self.object(value),
              let identity = Self.identity(fields),
              activeRequest?.identity == identity,
              let destinationURL = Self.string(
                  fields["destinationURL"]
              ),
              activeRequest?.matches.contains(where: { match in
                  Self.string(match["destinationURL"])
                      == destinationURL
                      && match["acceptToken"] == nil
              }) == true
        else {
            return
        }

        let navigation = RecentNavigation(
            conversationID: identity.conversationID,
            destinationURL: destinationURL
        )
        recentNavigations.removeAll { $0 == navigation }
        recentNavigations.insert(navigation, at: 0)
        if recentNavigations.count > 64 {
            recentNavigations.removeLast(
                recentNavigations.count - 64
            )
        }
    }

    private func deleteMatch(_ value: Value) async throws {
        guard let fields = Self.object(value),
              let identity = Self.identity(fields),
              var active = activeRequest,
              active.identity == identity,
              let deleteToken = Self.string(fields["deleteToken"]),
              active.matches.contains(where: {
                  Self.string($0["deleteToken"]) == deleteToken
              })
        else {
            return
        }

        deletedTokens.insert(deleteToken)
        active.matches.removeAll {
            Self.string($0["deleteToken"]) == deleteToken
        }
        activeRequest = active
        try await sendCurrentResult()
    }

    private func sendCurrentResult() async throws {
        guard let activeRequest else { return }
        let result: Value = .object([
            "defaultMatch": .null,
            "done": .bool(true),
            "matches": .array(
                activeRequest.matches.map(Value.object)
            ),
        ])
        let update: Value = .object([
            "browserTabId": .string(
                activeRequest.identity.browserTabID
            ),
            "conversationId": .string(
                activeRequest.identity.conversationID
            ),
            "editingSessionId": .string(
                activeRequest.identity.editingSessionID
            ),
            "requestId": .string(
                activeRequest.identity.requestID
            ),
            "result": result,
        ])
        try await callbackInvoker(
            activeRequest.callbackID,
            [update]
        )
    }

    private func pageMatches(
        conversationID: String,
        query: String,
        preventInlineAutocomplete: Bool
    ) async -> [[String: Value]] {
        guard !query.isEmpty else { return [] }
        let candidates = await pageRestoreState.searchPageMentions(
            conversationID: conversationID,
            query: query
        )
        return candidates.compactMap { candidate in
            guard let fields = Self.object(candidate),
                  let snapshot = Self.object(fields["snapshot"]),
                  let destinationURL = Self.string(snapshot["url"]),
                  !destinationURL.isEmpty
            else {
                return nil
            }
            let title = Self.string(snapshot["title"])
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? destinationURL
            let tabID = Self.string(fields["tabId"]) ?? ""
            let token = Self.token(
                components: [
                    conversationID,
                    tabID,
                    destinationURL,
                ]
            )
            guard !deletedTokens.contains(token) else {
                return nil
            }
            return Self.match(
                contents: title,
                description: destinationURL,
                destinationURL: destinationURL,
                faviconDataURL: fields["faviconUrl"],
                fillIntoEdit: destinationURL,
                inlineAutocompletion:
                    preventInlineAutocomplete
                    ? ""
                    : Self.inlineSuffix(
                        query: query,
                        destinationURL: destinationURL
                    ),
                type: "history",
                acceptToken: token,
                deleteToken: token,
                deletable: true
            )
        }
    }

    private func recentNavigationMatches(
        conversationID: String,
        query: String,
        existingDestinations: Set<String>
    ) -> [[String: Value]] {
        guard !query.isEmpty else { return [] }
        return recentNavigations.compactMap { navigation in
            guard navigation.conversationID == conversationID,
                  !existingDestinations.contains(
                      navigation.destinationURL
                  ),
                  navigation.destinationURL
                    .localizedCaseInsensitiveContains(query)
            else {
                return nil
            }
            let token = Self.token(
                components: [
                    conversationID,
                    "recent-navigation",
                    navigation.destinationURL,
                ]
            )
            guard !deletedTokens.contains(token) else {
                return nil
            }
            return Self.match(
                contents: navigation.destinationURL,
                description: navigation.destinationURL,
                destinationURL: navigation.destinationURL,
                faviconDataURL: nil,
                fillIntoEdit: navigation.destinationURL,
                inlineAutocompletion: "",
                type: "history",
                acceptToken: token,
                deleteToken: token,
                deletable: true
            )
        }
    }

    private static func directURLMatch(
        query: String
    ) -> [String: Value]? {
        guard let url = URL(string: query),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            return nil
        }
        return match(
            contents: query,
            description: query,
            destinationURL: query,
            faviconDataURL: nil,
            fillIntoEdit: query,
            inlineAutocompletion: "",
            type: "url",
            acceptToken: nil,
            deleteToken: nil,
            deletable: false
        )
    }

    private static func match(
        contents: String,
        description: String,
        destinationURL: String,
        faviconDataURL: Value?,
        fillIntoEdit: String,
        inlineAutocompletion: String,
        type: String,
        acceptToken: String?,
        deleteToken: String?,
        deletable: Bool
    ) -> [String: Value] {
        var fields: [String: Value] = [
            "contents": .string(contents),
            "contentsClass": .array([]),
            "deletable": .bool(deletable),
            "description": .string(description),
            "descriptionClass": .array([]),
            "destinationURL": .string(destinationURL),
            "faviconDataURL": faviconDataURL ?? .null,
            "fillIntoEdit": .string(fillIntoEdit),
            "inlineAutocompletion": .string(
                inlineAutocompletion
            ),
            "isSearch": .bool(false),
            "type": .string(type),
        ]
        if let acceptToken {
            fields["acceptToken"] = .string(acceptToken)
        }
        if let deleteToken {
            fields["deleteToken"] = .string(deleteToken)
        }
        return fields
    }

    private static func query(
        text: String,
        utf16CursorPosition: Int64
    ) -> String {
        let utf16Count = text.utf16.count
        let cursor = min(
            max(Int(utf16CursorPosition), 0),
            utf16Count
        )
        return (text as NSString)
            .substring(to: cursor)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inlineSuffix(
        query: String,
        destinationURL: String
    ) -> String {
        guard destinationURL.lowercased().hasPrefix(
            query.lowercased()
        ) else {
            return ""
        }
        return String(destinationURL.dropFirst(query.count))
    }

    private static func token(components: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in components.joined(separator: "\u{0}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "ipad-page-" + String(hash, radix: 16)
    }

    private static func identity(
        _ fields: [String: Value]?
    ) -> Identity? {
        guard let fields,
              let browserTabID = string(fields["browserTabId"]),
              let conversationID = string(fields["conversationId"]),
              let editingSessionID = string(
                  fields["editingSessionId"]
              ),
              let requestID = string(fields["requestId"])
        else {
            return nil
        }
        return Identity(
            browserTabID: browserTabID,
            conversationID: conversationID,
            editingSessionID: editingSessionID,
            requestID: requestID
        )
    }

    private static func object(
        _ value: Value?
    ) -> [String: Value]? {
        guard case let .object(fields)? = value else {
            return nil
        }
        return fields
    }

    private static func string(_ value: Value?) -> String? {
        guard case let .string(value)? = value else {
            return nil
        }
        return value
    }

    private static func integer(_ value: Value?) -> Int64? {
        guard case let .integer(value)? = value else {
            return nil
        }
        return value
    }
}
