import Foundation

/// Application-owned downloads mechanism used by the desktop AppHost adapter.
///
/// The adapter deliberately owns no download records or filesystem behavior.
/// An iPad application integration supplies the actual manager, including its
/// platform directory picker and open/reveal operations.
public protocol CodexDesktopDownloadsAppHostManaging: Sendable {
    func acknowledge(
        _ acknowledgement:
            CodexDesktopDownloadsAppHostService.Acknowledgement
    ) async throws

    func cancel(id: String) async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult

    func chooseDownloadDirectory() async throws -> String?

    func clearHistory() async throws

    func getSnapshot() async throws
        -> CodexDesktopDownloadsAppHostService.Snapshot

    func open(id: String) async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult

    func pause(id: String) async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult

    func removeFromHistory(id: String) async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult

    func resume(id: String) async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult

    func searchHistory(
        _ request:
            CodexDesktopDownloadsAppHostService.SearchRequest
    ) async throws -> CodexDesktopDownloadsAppHostService.Snapshot

    func showDownloadsFolder() async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult

    func showInFolder(id: String) async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult
}

/// iPad application adapter for the released desktop `downloads` AppHost.
///
/// Method names, argument objects, and results mirror `Ise` in desktop release
/// 26.730.61309. Snapshot fields and action failure reasons come from the
/// released `UH` download store used by that service.
public actor CodexDesktopDownloadsAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unavailable(service: String, method: String)
        case unsupportedMethod(service: String, method: String)
    }

    public enum Acknowledgement: Equatable, Sendable {
        case all
        case ids([String])
    }

    public struct SearchRequest: Equatable, Sendable {
        public let text: String
        public let maxResults: Int64?
        public let offset: Int64?

        public init(
            text: String,
            maxResults: Int64? = nil,
            offset: Int64? = nil
        ) {
            self.text = text
            self.maxResults = maxResults
            self.offset = offset
        }
    }

    public enum DownloadStatus: String, Equatable, Sendable {
        case started
        case inProgress = "in_progress"
        case paused
        case canceled
        case complete
        case failed
    }

    public struct Download: Equatable, Sendable {
        public let canCancel: Bool
        public let canPause: Bool
        public let canResume: Bool
        public let fileExists: Bool
        public let filename: String
        public let id: String
        public let path: String
        public let receivedBytes: Int64
        public let startedAtMs: Int64
        public let status: DownloadStatus
        public let totalBytes: Int64
        public let updatedAtMs: Int64
        public let url: String

        public init(
            canCancel: Bool,
            canPause: Bool,
            canResume: Bool,
            fileExists: Bool,
            filename: String,
            id: String,
            path: String,
            receivedBytes: Int64,
            startedAtMs: Int64,
            status: DownloadStatus,
            totalBytes: Int64,
            updatedAtMs: Int64,
            url: String
        ) {
            self.canCancel = canCancel
            self.canPause = canPause
            self.canResume = canResume
            self.fileExists = fileExists
            self.filename = filename
            self.id = id
            self.path = path
            self.receivedBytes = receivedBytes
            self.startedAtMs = startedAtMs
            self.status = status
            self.totalBytes = totalBytes
            self.updatedAtMs = updatedAtMs
            self.url = url
        }

        fileprivate var value: Value {
            .object([
                "canCancel": .bool(canCancel),
                "canPause": .bool(canPause),
                "canResume": .bool(canResume),
                "fileExists": .bool(fileExists),
                "filename": .string(filename),
                "id": .string(id),
                "path": .string(path),
                "receivedBytes": .integer(receivedBytes),
                "startedAtMs": .integer(startedAtMs),
                "status": .string(status.rawValue),
                "totalBytes": .integer(totalBytes),
                "updatedAtMs": .integer(updatedAtMs),
                "url": .string(url),
            ])
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let capturedAtMs: Int64
        public let downloads: [Download]
        public let unacknowledgedIDs: [String]

        public init(
            capturedAtMs: Int64,
            downloads: [Download],
            unacknowledgedIDs: [String]
        ) {
            self.capturedAtMs = capturedAtMs
            self.downloads = downloads
            self.unacknowledgedIDs = unacknowledgedIDs
        }

        fileprivate var value: Value {
            .object([
                "capturedAtMs": .integer(capturedAtMs),
                "downloads": .array(
                    downloads.map(\.value)
                ),
                "unacknowledgedIds": .array(
                    unacknowledgedIDs.map(Value.string)
                ),
            ])
        }
    }

    public enum ActionFailureReason:
        String,
        Equatable,
        Sendable
    {
        case downloadNotPausable = "download-not-pausable"
        case downloadNotRemovable = "download-not-removable"
        case downloadNotResumable = "download-not-resumable"
        case missingDownload = "missing-download"
        case openFailed = "open-failed"
        case showInFolderFailed = "show-in-folder-failed"
    }

    public enum ActionResult: Equatable, Sendable {
        case success
        case failure(
            reason: ActionFailureReason,
            message: String? = nil
        )

        fileprivate var value: Value {
            switch self {
            case .success:
                return .object(["ok": .bool(true)])

            case let .failure(reason, message):
                var fields: [String: Value] = [
                    "ok": .bool(false),
                    "reason": .string(reason.rawValue),
                ]
                if let message {
                    fields["message"] = .string(message)
                }
                return .object(fields)
            }
        }
    }

    private let manager:
        (any CodexDesktopDownloadsAppHostManaging)?

    public init(
        manager:
            (any CodexDesktopDownloadsAppHostManaging)? = nil
    ) {
        self.manager = manager
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        guard service == "downloads" else {
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }

        switch method {
        case "acknowledge":
            let acknowledgement =
                try acknowledgement(arguments)
            try await requiredManager(method: method)
                .acknowledge(acknowledgement)
            return .undefined

        case "cancel":
            let id = try onlyID(arguments)
            return try await requiredManager(method: method)
                .cancel(id: id)
                .value

        case "chooseDownloadDirectory":
            try validateNoArguments(arguments)
            let directory = try await requiredManager(
                method: method
            ).chooseDownloadDirectory()
            return directory.map(Value.string) ?? .null

        case "clearHistory":
            try validateNoArguments(arguments)
            try await requiredManager(method: method)
                .clearHistory()
            return .undefined

        case "getSnapshot":
            try validateNoArguments(arguments)
            return try await requiredManager(method: method)
                .getSnapshot()
                .value

        case "open":
            let id = try onlyID(arguments)
            return try await requiredManager(method: method)
                .open(id: id)
                .value

        case "pause":
            let id = try onlyID(arguments)
            return try await requiredManager(method: method)
                .pause(id: id)
                .value

        case "removeFromHistory":
            let id = try onlyID(arguments)
            return try await requiredManager(method: method)
                .removeFromHistory(id: id)
                .value

        case "resume":
            let id = try onlyID(arguments)
            return try await requiredManager(method: method)
                .resume(id: id)
                .value

        case "searchHistory":
            let request = try searchRequest(arguments)
            return try await requiredManager(method: method)
                .searchHistory(request)
                .value

        case "showDownloadsFolder":
            try validateNoArguments(arguments)
            return try await requiredManager(method: method)
                .showDownloadsFolder()
                .value

        case "showInFolder":
            let id = try onlyID(arguments)
            return try await requiredManager(method: method)
                .showInFolder(id: id)
                .value

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    private func requiredManager(
        method: String
    ) throws -> any CodexDesktopDownloadsAppHostManaging {
        guard let manager else {
            throw Error.unavailable(
                service: "downloads",
                method: method
            )
        }
        return manager
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

    private func onlyID(
        _ arguments: [Value]?
    ) throws -> String {
        let argument = try onlyArgument(arguments)
        guard let fields = Self.object(argument),
              let id = Self.string(fields["id"])
        else {
            throw Error.invalidArguments
        }
        return id
    }

    private func acknowledgement(
        _ arguments: [Value]?
    ) throws -> Acknowledgement {
        let argument = try onlyArgument(arguments)
        guard let fields = Self.object(argument) else {
            throw Error.invalidArguments
        }

        if case .bool(true)? = fields["all"] {
            return .all
        }

        guard fields["all"] == nil,
              case let .array(values)? = fields["ids"]
        else {
            throw Error.invalidArguments
        }
        let ids = try values.map { value in
            guard let id = Self.string(value) else {
                throw Error.invalidArguments
            }
            return id
        }
        return .ids(ids)
    }

    private func searchRequest(
        _ arguments: [Value]?
    ) throws -> SearchRequest {
        let argument = try onlyArgument(arguments)
        guard let fields = Self.object(argument),
              let text = Self.string(fields["text"])
        else {
            throw Error.invalidArguments
        }

        let maxResults = try Self.optionalNonnegativeInteger(
            fields["maxResults"]
        )
        let offset = try Self.optionalNonnegativeInteger(
            fields["offset"]
        )
        return SearchRequest(
            text: text,
            maxResults: maxResults,
            offset: offset
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
        guard case let .string(string)? = value else {
            return nil
        }
        return string
    }

    private static func optionalNonnegativeInteger(
        _ value: Value?
    ) throws -> Int64? {
        guard let value else {
            return nil
        }
        switch value {
        case let .integer(integer) where integer >= 0:
            return integer
        case let .number(number)
            where number.isFinite
                && number >= 0
                && number.rounded(.towardZero) == number:
            guard let integer = Int64(exactly: number) else {
                throw Error.invalidArguments
            }
            return integer
        default:
            throw Error.invalidArguments
        }
    }
}
