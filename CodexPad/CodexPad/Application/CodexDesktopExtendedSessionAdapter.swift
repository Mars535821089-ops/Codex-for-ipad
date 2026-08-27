#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

/// Maps the renderer's opaque extended-session request boundary onto native
/// iPad session state.
///
/// Release evidence establishes the method names and opaque params/result
/// transport only. The fields interpreted below are local iPad semantics for
/// the native stores; they are not presented as an official generated field
/// contract.
@MainActor
public final class CodexDesktopExtendedSessionAdapter {
    public enum Error: Swift.Error, Equatable, Sendable {
        case malformedParams(CodexDesktopExtendedSessionMethod)
        case capabilityUnavailable(
            CodexDesktopExtendedSessionMethod
        )
    }

    private let threadStarter:
        any CodexDesktopThreadSessionStarting
    private let runner: CodexDesktopTurnSessionRunner?
    private let feedbackUploader:
        (any CodexDesktopFeedbackUploading)?
    private let sandboxStore:
        CodexDesktopInteractiveSessionSandboxStore

    public init(
        threadStarter:
            any CodexDesktopThreadSessionStarting,
        runner: CodexDesktopTurnSessionRunner? = nil,
        feedbackUploader:
            (any CodexDesktopFeedbackUploading)? = nil,
        sandboxStore:
            CodexDesktopInteractiveSessionSandboxStore
    ) {
        self.threadStarter = threadStarter
        self.runner = runner
        self.feedbackUploader = feedbackUploader
        self.sandboxStore = sandboxStore
    }

    public func handle(
        _ request: CodexDesktopExtendedSessionRequest
    ) async throws -> CodexJSONValue {
        switch request.method {
        case .threadStartAeon:
            return try startAeon(request)
        case .threadStop:
            return try stopThread(request)
        case .interactiveLiveSessionsList:
            return try liveSessions(request)
        case .interactiveSessionUpload:
            return try await uploadSession(request)
        case .interactiveSessionSandboxList:
            return try await listSandbox(request)
        case .interactiveSessionSandboxRead:
            return try await readSandbox(request)
        }
    }

    private func startAeon(
        _ request: CodexDesktopExtendedSessionRequest
    ) throws -> CodexJSONValue {
        var params: CodexThreadStartParams
        do {
            params =
                try CodexDesktopInitialMCPRouter
                    .decodeThreadStartParams(
                        .object(request.params)
                    )
        } catch {
            throw Error.malformedParams(request.method)
        }

        if case .omitted = params.sessionStartSource {
            params.sessionStartSource = .value("aeon")
        }
        if case .omitted = params.threadSource {
            params.threadSource = .value("aeon")
        }

        let result = try threadStarter.startThread(
            id: request.id,
            params: params
        )
        return try CodexDesktopInitialMCPRouter
            .encodedThreadResult(result)
    }

    private func stopThread(
        _ request: CodexDesktopExtendedSessionRequest
    ) throws -> CodexJSONValue {
        let threadID = try Self.requiredNonBlankString(
            request.params["threadId"],
            method: request.method
        )
        guard let runner else {
            throw Error.capabilityUnavailable(request.method)
        }
        runner.interruptDesktopTurns(
            threadID: CodexStoredThreadID(threadID)
        )
        return .object([:])
    }

    private func liveSessions(
        _ request: CodexDesktopExtendedSessionRequest
    ) throws -> CodexJSONValue {
        guard let runner else {
            throw Error.capabilityUnavailable(request.method)
        }
        let data = runner.activeTurnSnapshots()
            .sorted {
                if $0.threadID.rawValue == $1.threadID.rawValue {
                    return $0.turnID < $1.turnID
                }
                return $0.threadID.rawValue
                    < $1.threadID.rawValue
            }
            .map { snapshot in
                CodexJSONValue.object([
                    "threadId":
                        .string(snapshot.threadID.rawValue),
                    "turnId": .string(snapshot.turnID),
                    "status": .string("active"),
                ])
            }
        return .object(["data": .array(data)])
    }

    private func uploadSession(
        _ request: CodexDesktopExtendedSessionRequest
    ) async throws -> CodexJSONValue {
        let sessionID = try Self.requiredNonBlankString(
            request.params["sessionId"],
            method: request.method
        )
        let classification =
            try Self.nullableString(
                request.params["classification"],
                method: request.method
            ) ?? "interactive_session"
        guard !classification.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw Error.malformedParams(request.method)
        }
        let reason = try Self.nullableString(
            request.params["reason"],
            method: request.method
        )
        let threadID = try Self.nullableString(
            request.params["threadId"],
            method: request.method
        )
        if let threadID,
           threadID.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty
        {
            throw Error.malformedParams(request.method)
        }
        let includeLogs = try Self.optionalBool(
            request.params["includeLogs"],
            default: false,
            method: request.method
        )
        var tags = try Self.nullableStringMap(
            request.params["tags"],
            method: request.method
        )
        tags["session_id"] = sessionID

        guard let feedbackUploader else {
            throw Error.capabilityUnavailable(request.method)
        }
        let attachments: [URL]
        do {
            attachments = try await sandboxStore.attachmentURLs(
                sessionID: sessionID
            )
        } catch let error as
            CodexDesktopInteractiveSessionSandboxStore.Error
        {
            throw Self.mappedSandboxError(
                error,
                method: request.method
            )
        }
        let trackingThreadID =
            try await feedbackUploader.uploadFeedback(
                CodexFeedbackUploadParameters(
                    classification: classification,
                    reason: reason,
                    threadID: threadID,
                    includeLogs: includeLogs,
                    extraLogFiles: attachments,
                    tags: tags
                )
            )
        return .object([
            "threadId": .string(trackingThreadID),
            "sessionId": .string(sessionID),
        ])
    }

    private func listSandbox(
        _ request: CodexDesktopExtendedSessionRequest
    ) async throws -> CodexJSONValue {
        let sessionID = try Self.requiredNonBlankString(
            request.params["sessionId"],
            method: request.method
        )
        let relativePath = try Self.nullableString(
            request.params["path"],
            method: request.method
        )
        do {
            return try await sandboxStore.list(
                sessionID: sessionID,
                relativePath: relativePath
            )
        } catch let error as
            CodexDesktopInteractiveSessionSandboxStore.Error
        {
            throw Self.mappedSandboxError(
                error,
                method: request.method
            )
        }
    }

    private func readSandbox(
        _ request: CodexDesktopExtendedSessionRequest
    ) async throws -> CodexJSONValue {
        let sessionID = try Self.requiredNonBlankString(
            request.params["sessionId"],
            method: request.method
        )
        let relativePath = try Self.requiredString(
            request.params["path"],
            method: request.method
        )
        do {
            return try await sandboxStore.read(
                sessionID: sessionID,
                relativePath: relativePath
            )
        } catch let error as
            CodexDesktopInteractiveSessionSandboxStore.Error
        {
            throw Self.mappedSandboxError(
                error,
                method: request.method
            )
        }
    }

    private static func requiredNonBlankString(
        _ value: CodexJSONValue?,
        method: CodexDesktopExtendedSessionMethod
    ) throws -> String {
        let string = try requiredString(
            value,
            method: method
        )
        guard !string.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw Error.malformedParams(method)
        }
        return string
    }

    private static func requiredString(
        _ value: CodexJSONValue?,
        method: CodexDesktopExtendedSessionMethod
    ) throws -> String {
        guard case let .string(string)? = value else {
            throw Error.malformedParams(method)
        }
        return string
    }

    private static func nullableString(
        _ value: CodexJSONValue?,
        method: CodexDesktopExtendedSessionMethod
    ) throws -> String? {
        guard let value else {
            return nil
        }
        switch value {
        case .null:
            return nil
        case let .string(string):
            return string
        default:
            throw Error.malformedParams(method)
        }
    }

    private static func optionalBool(
        _ value: CodexJSONValue?,
        default defaultValue: Bool,
        method: CodexDesktopExtendedSessionMethod
    ) throws -> Bool {
        guard let value else {
            return defaultValue
        }
        guard case let .bool(boolean) = value else {
            throw Error.malformedParams(method)
        }
        return boolean
    }

    private static func nullableStringMap(
        _ value: CodexJSONValue?,
        method: CodexDesktopExtendedSessionMethod
    ) throws -> [String: String] {
        guard let value else {
            return [:]
        }
        switch value {
        case .null:
            return [:]
        case let .object(values):
            var strings: [String: String] = [:]
            for (key, value) in values {
                guard case let .string(string) = value else {
                    throw Error.malformedParams(method)
                }
                strings[key] = string
            }
            return strings
        default:
            throw Error.malformedParams(method)
        }
    }

    private static func mappedSandboxError(
        _ error:
            CodexDesktopInteractiveSessionSandboxStore.Error,
        method: CodexDesktopExtendedSessionMethod
    ) -> any Swift.Error {
        switch error {
        case .invalidSessionID,
             .invalidPath,
             .pathNotFound,
             .notDirectory,
             .notFile:
            Error.malformedParams(method)
        case .readLimitExceeded:
            error
        }
    }
}
