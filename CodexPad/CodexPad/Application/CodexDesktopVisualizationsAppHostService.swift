import Foundation

/// iPad-native implementation of the released visualization AppHost.
///
/// It preserves the desktop filename, size, root-containment, and symlink
/// checks while delegating image capture to the platform surface.
public actor CodexDesktopVisualizationsAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias LocalHostPredicate =
        @Sendable (String) async -> Bool
    public typealias ThreadRootProvider =
        @Sendable (String) -> URL
    public typealias EventHandler =
        @Sendable (String, [Value]?) async -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case invalidReadRequest
        case unsupportedMethod(String)
    }

    private static let maximumHTMLBytes = 10 * 1_024 * 1_024
    private let codexHome: URL
    private let temporaryDirectory: URL
    private let isLocalHost: LocalHostPredicate
    private let threadRootProvider: ThreadRootProvider
    private let eventHandler: EventHandler

    public init(
        codexHome: URL,
        temporaryDirectory: URL =
            FileManager.default.temporaryDirectory,
        isLocalHost: LocalHostPredicate? = nil,
        threadRoot: ThreadRootProvider? = nil,
        eventHandler: EventHandler? = nil
    ) {
        self.codexHome = codexHome
        self.temporaryDirectory = temporaryDirectory
        self.isLocalHost = isLocalHost ?? { $0 == "local" }
        threadRootProvider = threadRoot ?? { threadID in
            codexHome
                .appendingPathComponent(
                    "visualizations",
                    isDirectory: true
                )
                .appendingPathComponent(
                    threadID,
                    isDirectory: true
                )
        }
        self.eventHandler = eventHandler ?? { _, _ in }
    }

    public func invoke(
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch method {
        case "getTemporaryRoots":
            guard let hostID = nonemptyString(arguments?.first) else {
                throw Error.invalidArguments
            }
            guard await isLocalHost(hostID) else {
                return .array([])
            }
            let raw = temporaryDirectory.path
            let resolved = temporaryDirectory
                .resolvingSymlinksInPath().path
            var roots = [raw]
            if resolved != raw {
                roots.append(resolved)
            }
            return .array(roots.map(Value.string))

        case "read":
            return try read(arguments)

        case "copyImage":
            guard case .object? = arguments?.first else {
                throw Error.invalidArguments
            }
            await eventHandler(method, arguments)
            return .undefined

        default:
            throw Error.unsupportedMethod(method)
        }
    }

    private func read(_ arguments: [Value]?) throws -> Value {
        guard case let .object(fields)? = arguments?.first,
              nonemptyString(fields["hostId"]) != nil,
              let rawPath = nonemptyString(fields["path"]),
              let threadID = nonemptyString(fields["threadId"])
        else {
            throw Error.invalidReadRequest
        }
        let threadRoot = threadRootProvider(threadID)
            .standardizedFileURL
        let fileName = URL(fileURLWithPath: rawPath)
            .lastPathComponent
        guard validHTMLFileName(fileName) else {
            throw Error.invalidReadRequest
        }

        let candidate: URL
        let allowedRoots: [URL]
        if rawPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: rawPath)
                .standardizedFileURL
            allowedRoots = absoluteAllowedRoots(
                fields: fields,
                threadRoot: threadRoot
            )
        } else {
            guard rawPath == fileName else {
                throw Error.invalidReadRequest
            }
            candidate = threadRoot.appendingPathComponent(fileName)
                .standardizedFileURL
            allowedRoots = [threadRoot]
        }

        guard let containingRoot = allowedRoots.first(where: {
            contains(candidate, in: $0.standardizedFileURL)
        }),
        noSymbolicLinks(from: containingRoot, through: candidate),
        let data = try? Data(contentsOf: candidate)
        else {
            throw Error.invalidReadRequest
        }
        guard data.count <= Self.maximumHTMLBytes else {
            return .null
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            throw Error.invalidReadRequest
        }
        return .object(["contents": .string(contents)])
    }

    private func absoluteAllowedRoots(
        fields: [String: Value],
        threadRoot: URL
    ) -> [URL] {
        var roots = [threadRoot]
        if case let .object(policy)? = fields["sandboxPolicy"],
           case let .array(writableRoots)? = policy["writableRoots"]
        {
            roots += writableRoots.compactMap { value in
                guard let path = nonemptyString(value),
                      path.hasPrefix("/")
                else {
                    return nil
                }
                return URL(fileURLWithPath: path)
            }
            if policy["excludeTmpdirEnvVar"] == .bool(false) {
                roots.append(temporaryDirectory)
                roots.append(
                    temporaryDirectory.resolvingSymlinksInPath()
                )
            }
        }
        return roots
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/")
            ? root.path
            : root.path + "/"
        return candidate.path == root.path
            || candidate.path.hasPrefix(rootPath)
    }

    private func noSymbolicLinks(
        from root: URL,
        through candidate: URL
    ) -> Bool {
        guard contains(candidate, in: root) else {
            return false
        }
        var current = candidate
        while true {
            guard let values = try? current.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ),
            values.isSymbolicLink != true
            else {
                return false
            }
            if current.path == root.path {
                return true
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                return false
            }
            current = parent
        }
    }

    private func validHTMLFileName(_ name: String) -> Bool {
        name.range(
            of: #"^[a-z0-9]+(?:-[a-z0-9]+)*\.html$"#,
            options: .regularExpression
        ) != nil
    }

    private func nonemptyString(_ value: Value?) -> String? {
        guard case let .string(raw)? = value else {
            return nil
        }
        let value = raw.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? nil : value
    }
}
