import Foundation

public typealias CodexDesktopSummaryDiagnosticSink =
    @Sendable (_ key: String, _ value: String) async -> Void

/// AppHost services whose desktop implementation delegates to app-server
/// state or a short isolated model request.
public actor CodexDesktopIntelligenceAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value

    public struct TitleRequest: Equatable, Sendable {
        public let hostID: String
        public let prompt: String
        public let cwd: String
        public let readOnlyAppToolAllowlist: [String]
        public let threadStartKind: String?
        public let serviceName: String?

        public init(
            hostID: String,
            prompt: String,
            cwd: String,
            readOnlyAppToolAllowlist: [String],
            threadStartKind: String?,
            serviceName: String?
        ) {
            self.hostID = hostID
            self.prompt = prompt
            self.cwd = cwd
            self.readOnlyAppToolAllowlist = readOnlyAppToolAllowlist
            self.threadStartKind = threadStartKind
            self.serviceName = serviceName
        }
    }

    public struct DescriptionRequest: Equatable, Sendable {
        public let hostID: String
        public let threadID: String
        public let title: String?
        public let cwd: String
        public let serviceName: String?

        public init(
            hostID: String,
            threadID: String,
            title: String?,
            cwd: String,
            serviceName: String?
        ) {
            self.hostID = hostID
            self.threadID = threadID
            self.title = title
            self.cwd = cwd
            self.serviceName = serviceName
        }
    }

    public struct ReconsiderTitleRequest: Equatable, Sendable {
        public let hostID: String
        public let threadID: String
        public let currentTitle: String
        public let cwd: String
        public let serviceName: String?

        public init(
            hostID: String,
            threadID: String,
            currentTitle: String,
            cwd: String,
            serviceName: String?
        ) {
            self.hostID = hostID
            self.threadID = threadID
            self.currentTitle = currentTitle
            self.cwd = cwd
            self.serviceName = serviceName
        }
    }

    public struct SummaryRequest: Equatable, Sendable {
        public let hostID: String
        public let threadID: String
        public let title: String?
        public let previousUserMessage: String?
        public let previousAssistantMessage: String?
        public let latestMessage: String
        public let phase: String
        public let cwd: String
        public let includeCompactSummary: Bool
        public let serviceName: String?

        public init(
            hostID: String,
            threadID: String,
            title: String?,
            previousUserMessage: String?,
            previousAssistantMessage: String?,
            latestMessage: String,
            phase: String,
            cwd: String,
            includeCompactSummary: Bool,
            serviceName: String?
        ) {
            self.hostID = hostID
            self.threadID = threadID
            self.title = title
            self.previousUserMessage = previousUserMessage
            self.previousAssistantMessage = previousAssistantMessage
            self.latestMessage = latestMessage
            self.phase = phase
            self.cwd = cwd
            self.includeCompactSummary = includeCompactSummary
            self.serviceName = serviceName
        }
    }

    public struct GeneratedTitle: Equatable, Sendable {
        public let title: String
        public let description: String?

        public init(title: String, description: String?) {
            self.title = title
            self.description = description
        }
    }

    public struct GeneratedSummary: Equatable, Sendable {
        public let summary: String
        public let compactSummary: String?

        public init(summary: String, compactSummary: String?) {
            self.summary = summary
            self.compactSummary = compactSummary
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unsupportedMethod(service: String, method: String)
    }

    public typealias AccessibleAppQuery =
        @Sendable () async throws -> Bool
    public typealias GenerationStatusesProvider =
        @Sendable () async throws -> Value
    public typealias WorkTaskSuggestionsProvider =
        @Sendable (String) async throws -> Value
    public typealias WorkTaskSuggestionSelectionHandler =
        @Sendable (String, String) async throws -> Value
    public typealias TitleGenerator =
        @Sendable (TitleRequest) async throws -> GeneratedTitle?
    public typealias DescriptionGenerator =
        @Sendable (DescriptionRequest) async throws -> String?
    public typealias ReconsiderTitleGenerator =
        @Sendable (ReconsiderTitleRequest) async throws -> GeneratedTitle?
    public typealias SummaryGenerator =
        @Sendable (SummaryRequest) async throws -> GeneratedSummary?

    private let hasAccessibleAndEnabledApp: AccessibleAppQuery
    private let getGenerationStatuses: GenerationStatusesProvider
    private let getWorkTaskSuggestions: WorkTaskSuggestionsProvider
    private let markWorkTaskSuggestionSelected: WorkTaskSuggestionSelectionHandler
    private let generateTitle: TitleGenerator
    private let generateDescription: DescriptionGenerator
    private let reconsiderTitle: ReconsiderTitleGenerator
    private let generateSummary: SummaryGenerator
    private let summaryDiagnostic: CodexDesktopSummaryDiagnosticSink

    public init(
        hasAccessibleAndEnabledApp: AccessibleAppQuery? = nil,
        getGenerationStatuses: GenerationStatusesProvider? = nil,
        getWorkTaskSuggestions: WorkTaskSuggestionsProvider? = nil,
        markWorkTaskSuggestionSelected: WorkTaskSuggestionSelectionHandler? = nil,
        generateTitle: TitleGenerator? = nil,
        generateDescription: DescriptionGenerator? = nil,
        reconsiderTitle: ReconsiderTitleGenerator? = nil,
        generateSummary: SummaryGenerator? = nil,
        summaryDiagnostic: CodexDesktopSummaryDiagnosticSink? = nil
    ) {
        self.hasAccessibleAndEnabledApp =
            hasAccessibleAndEnabledApp ?? { false }
        self.getGenerationStatuses = getGenerationStatuses ?? {
            .object([:])
        }
        self.getWorkTaskSuggestions = getWorkTaskSuggestions ?? { _ in
            .array([])
        }
        self.markWorkTaskSuggestionSelected =
            markWorkTaskSuggestionSelected ?? { _, _ in .undefined }
        self.generateTitle = generateTitle ?? { _ in nil }
        self.generateDescription =
            generateDescription ?? { _ in nil }
        self.reconsiderTitle = reconsiderTitle ?? { _ in nil }
        self.generateSummary = generateSummary ?? { _ in nil }
        self.summaryDiagnostic = summaryDiagnostic ?? { key, value in
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch (service, method) {
        case (
            "ambientSuggestions",
            "hasAccessibleAndEnabledApp"
        ):
            let fields = try argumentObject(arguments)
            guard Self.string(fields["hostId"]) != nil else {
                throw Error.invalidArguments
            }
            return .bool(try await hasAccessibleAndEnabledApp())

        case ("ambientSuggestions", "getGenerationStatuses"):
            guard arguments == nil || arguments?.isEmpty == true else {
                throw Error.invalidArguments
            }
            return try await getGenerationStatuses()

        case ("ambientSuggestions", "getChatGptWorkTaskSuggestions"):
            let fields = try argumentObject(arguments)
            guard let hostID = Self.string(fields["hostId"]),
                  !hostID.isEmpty, arguments?.count == 1
            else {
                throw Error.invalidArguments
            }
            return try await getWorkTaskSuggestions(hostID)

        case (
            "ambientSuggestions",
            "markChatGptWorkTaskSuggestionSelected"
        ):
            let fields = try argumentObject(arguments)
            guard let hostID = Self.string(fields["hostId"]),
                  !hostID.isEmpty,
                  let suggestionID = Self.string(fields["suggestionId"]),
                  !suggestionID.isEmpty,
                  arguments?.count == 1
            else {
                throw Error.invalidArguments
            }
            return try await markWorkTaskSuggestionSelected(
                hostID,
                suggestionID
            )

        case (
            "threadMetadataGeneration",
            "generateTitle"
        ):
            let fields = try argumentObject(arguments)
            guard let hostID = Self.string(fields["hostId"]),
                  let rawPrompt = Self.string(fields["prompt"]),
                  let cwd = Self.string(fields["cwd"])
            else {
                throw Error.invalidArguments
            }
            let prompt = rawPrompt.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !prompt.isEmpty else {
                return .null
            }
            let request = TitleRequest(
                hostID: hostID,
                prompt: String(prompt.prefix(2_000)),
                cwd: cwd,
                readOnlyAppToolAllowlist: Self.strings(
                    fields["readOnlyAppToolAllowlist"]
                ),
                threadStartKind: Self.string(
                    fields["threadStartKind"]
                ),
                serviceName: Self.string(fields["serviceName"])
            )
            guard let generated = try await generateTitle(request),
                  let title = Self.normalizedTitle(generated.title)
            else {
                return .null
            }
            return .object([
                "title": .string(title),
                "description": Self.normalizedDescription(
                    generated.description
                ).map(Value.string) ?? .null,
            ])

        case (
            "threadMetadataGeneration",
            "reconsiderTitle"
        ):
            let fields = try argumentObject(arguments)
            guard let hostID = Self.string(fields["hostId"]),
                  let threadID = Self.string(fields["threadId"]),
                  let currentTitle = Self.string(fields["currentTitle"]),
                  let cwd = Self.string(fields["cwd"])
            else {
                throw Error.invalidArguments
            }
            let normalizedCurrentTitle = currentTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedCurrentTitle.isEmpty else {
                return .null
            }
            guard let generated = try await reconsiderTitle(
                ReconsiderTitleRequest(
                    hostID: hostID,
                    threadID: threadID,
                    currentTitle: normalizedCurrentTitle,
                    cwd: cwd,
                    serviceName: Self.string(fields["serviceName"])
                )
            ), let title = Self.normalizedTitle(generated.title)
            else {
                return .null
            }
            return .object([
                "title": .string(title),
                "description": Self.normalizedDescription(
                    generated.description
                ).map(Value.string) ?? .null,
            ])

        case (
            "threadMetadataGeneration",
            "generateDescription"
        ):
            let fields = try argumentObject(arguments)
            guard let hostID = Self.string(fields["hostId"]),
                  let threadID = Self.string(fields["threadId"]),
                  let cwd = Self.string(fields["cwd"])
            else {
                throw Error.invalidArguments
            }
            let generated = try await generateDescription(
                DescriptionRequest(
                    hostID: hostID,
                    threadID: threadID,
                    title: Self.string(fields["title"]),
                    cwd: cwd,
                    serviceName: Self.string(fields["serviceName"])
                )
            )
            return Self.normalizedDescription(generated)
                .map(Value.string) ?? .null

        case (
            "threadMetadataGeneration",
            "generateSummary"
        ):
            let fields = try argumentObject(arguments)
            guard let hostID = Self.string(fields["hostId"]),
                  let threadID = Self.string(fields["threadId"]),
                  let rawLatestMessage = Self.string(
                    fields["latestMessage"]
                  ),
                  let phase = Self.string(fields["phase"]),
                  let cwd = Self.string(fields["cwd"])
            else {
                throw Error.invalidArguments
            }
            let latestMessage = rawLatestMessage.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !latestMessage.isEmpty else {
                return .null
            }
            let includeCompactSummary = Self.bool(
                fields["includeCompactSummary"]
            ) ?? false
            let request = SummaryRequest(
                    hostID: hostID,
                    threadID: threadID,
                    title: Self.string(fields["title"]),
                    previousUserMessage: Self.string(
                        fields["previousUserMessage"]
                    ),
                    previousAssistantMessage: Self.string(
                        fields["previousAssistantMessage"]
                    ),
                    latestMessage: String(latestMessage.prefix(2_000)),
                    phase: phase,
                    cwd: cwd,
                    includeCompactSummary: includeCompactSummary,
                    serviceName: Self.string(fields["serviceName"])
                )
            let diagnosticPrefix =
                "called=true phase=\(phase) "
                + "latestBytes=\(latestMessage.utf8.count)"
            let diagnosticKey =
                "codex.desktop.last-summary-generation-diagnostic"
            await summaryDiagnostic(
                diagnosticKey,
                diagnosticPrefix + " result=pending"
            )
            let generated: GeneratedSummary?
            do {
                generated = try await generateSummary(request)
            } catch {
                await summaryDiagnostic(
                    diagnosticKey,
                    diagnosticPrefix + " result=failed error="
                        + Self.summaryFailureLabel(error)
                )
                throw error
            }
            guard let generated,
                  let summary = Self.normalizedSummary(
                    generated.summary,
                    limit: 280
                  )
            else {
                await summaryDiagnostic(
                    diagnosticKey,
                    diagnosticPrefix + " result=missing"
                )
                return .null
            }
            guard includeCompactSummary,
                  let compactSummary = Self.normalizedSummary(
                    generated.compactSummary,
                    limit: 60
                  )
            else {
                await summaryDiagnostic(
                    diagnosticKey,
                    diagnosticPrefix
                        + " result=present summaryLength=\(summary.count) "
                        + "compactLength=0"
                )
                return .string(summary)
            }
            await summaryDiagnostic(
                diagnosticKey,
                diagnosticPrefix
                    + " result=present summaryLength=\(summary.count) "
                    + "compactLength=\(compactSummary.count)"
            )
            return .object([
                "summary": .string(summary),
                "compactSummary": .string(compactSummary),
            ])

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    private func argumentObject(
        _ arguments: [Value]?
    ) throws -> [String: Value] {
        guard case .object(let fields)? = arguments?.first else {
            throw Error.invalidArguments
        }
        return fields
    }

    private static func string(_ value: Value?) -> String? {
        guard case .string(let string)? = value else {
            return nil
        }
        return string
    }

    private static func summaryFailureLabel(
        _ error: Swift.Error
    ) -> String {
        guard let error = error as?
            CodexDesktopThreadMetadataGenerator.Error
        else {
            let typeName = String(describing: type(of: error))
                .filter {
                    $0.isLetter || $0.isNumber || $0 == "." || $0 == "_"
                }
            guard !typeName.isEmpty else {
                return "other"
            }
            return "other." + String(typeName.prefix(80))
        }
        switch error {
        case .providerUnavailable:
            return "providerUnavailable"
        case .providerRequestMismatch:
            return "providerRequestMismatch"
        case .toolCallNotAllowed:
            return "toolCallNotAllowed"
        case .missingCompletion:
            return "missingCompletion"
        case .incompleteResponse:
            return "incompleteResponse"
        case .emptyResponse:
            return "emptyResponse"
        case .invalidJSONResponse:
            return "invalidJSONResponse"
        case .missingStructuredField:
            return "missingStructuredField"
        case .invalidStructuredResponse:
            return "invalidStructuredResponse"
        }
    }

    private static func strings(_ value: Value?) -> [String] {
        guard case .array(let values)? = value else {
            return []
        }
        return values.compactMap(string)
    }

    private static func bool(_ value: Value?) -> Bool? {
        guard case .bool(let value)? = value else {
            return nil
        }
        return value
    }

    private static func normalizedTitle(
        _ rawValue: String
    ) -> String? {
        var title = rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: {
                !$0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            })
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        title = title.replacingOccurrences(
            of: #"^title[:\s]+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        title = title.trimmingCharacters(
            in: CharacterSet(
                charactersIn: "`\"'“”‘’"
            )
        )
        title = title.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(
            of: #"[.?!]+$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return nil
        }
        if title.count > 36 {
            return String(title.prefix(35))
                .trimmingCharacters(in: .whitespaces) + "…"
        }
        return title
    }

    private static func normalizedDescription(
        _ rawValue: String?
    ) -> String? {
        guard let rawValue else {
            return nil
        }
        let value = rawValue.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(value.prefix(100))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? nil : limited
    }

    private static func normalizedSummary(
        _ rawValue: String?,
        limit: Int
    ) -> String? {
        guard let rawValue else {
            return nil
        }
        let value = rawValue.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(value.prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? nil : limited
    }
}
