import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// iPad implementation of the desktop conversational-onboarding file exports.
/// The desktop writes notes/charts into a renderer-selected parent directory;
/// iPad restricts that directory to explicitly supplied workspace roots.
public actor CodexDesktopConversationalOnboardingAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case invalidPath
        case unsupportedMethod(String)
        case writeFailed
    }

    private let allowedRoots: [URL]
    private let fileManager: FileManager

    public init(
        allowedWorkspaceRoots: [URL],
        fileManager: FileManager = .default
    ) {
        self.allowedRoots = allowedWorkspaceRoots.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        self.fileManager = fileManager
    }

    public func invoke(
        method: String,
        arguments: [Value]?
    ) throws -> Value {
        guard let arguments, arguments.count == 1,
              case let .object(fields) = arguments[0]
        else { throw Error.invalidArguments }
        switch method {
        case "createDesktopNote":
            guard let content = string(fields["content"]),
                  let fileStem = string(fields["fileStem"]),
                  let parentPath = string(fields["parentPath"])
            else { throw Error.invalidArguments }
            let parent = try resolveParent(parentPath)
            let stem = try safeStem(fileStem)
            var index = 0
            while true {
                let suffix = index == 0 ? "" : " (\(index))"
                let file = parent.appendingPathComponent(
                    "\(stem)\(suffix).txt"
                )
                do {
                    try writeExclusive(Data(content.utf8), to: file)
                    return .object(["path": .string(file.path)])
                } catch FileWriteError.exists {
                    index += 1
                } catch {
                    throw Error.writeFailed
                }
            }
        case "createSampleChart":
            guard let bytes = fields["bytes"],
                  let fileStem = string(fields["fileStem"]),
                  let parentPath = string(fields["parentPath"])
            else { throw Error.invalidArguments }
            let parent = try resolveParent(parentPath)
            let stem = try safeStem(fileStem)
            let data = try byteData(bytes)
            let file = parent.appendingPathComponent("\(stem).png")
            do {
                try data.write(to: file, options: .atomic)
            } catch {
                throw Error.writeFailed
            }
            return .object(["path": .string(file.path)])
        default:
            throw Error.unsupportedMethod(method)
        }
    }

    private enum FileWriteError: Swift.Error { case exists }

    private func writeExclusive(_ data: Data, to url: URL) throws {
        #if canImport(Darwin)
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EEXIST { throw FileWriteError.exists }
            throw Error.writeFailed
        }
        defer { close(descriptor) }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                guard count > 0 else { throw Error.writeFailed }
                written += count
            }
        }
        #else
        if fileManager.fileExists(atPath: url.path) {
            throw FileWriteError.exists
        }
        try data.write(to: url)
        #endif
    }

    private func resolveParent(_ raw: String) throws -> URL {
        guard !raw.isEmpty else { throw Error.invalidPath }
        let candidate: URL
        if raw.hasPrefix("/") {
            candidate = URL(fileURLWithPath: raw)
        } else if let root = allowedRoots.first {
            candidate = root.appendingPathComponent(raw)
        } else {
            throw Error.invalidPath
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: resolved.path),
              isAllowed(resolved)
        else { throw Error.invalidPath }
        return resolved
    }

    private func isAllowed(_ url: URL) -> Bool {
        allowedRoots.contains { root in
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            return url.path == root.path || url.path.hasPrefix(rootPath)
        }
    }

    private func safeStem(_ value: String) throws -> String {
        let stem = URL(fileURLWithPath: value).lastPathComponent
        guard !stem.isEmpty, stem != ".", stem != "..", stem == value,
              !stem.contains("/")
        else { throw Error.invalidPath }
        return stem
    }

    private func byteData(_ value: Value) throws -> Data {
        guard case let .array(values) = value else { throw Error.invalidArguments }
        var data = Data(capacity: values.count)
        for value in values {
            guard case let .integer(byte) = value, (0 ... 255).contains(byte)
            else { throw Error.invalidArguments }
            data.append(UInt8(byte))
        }
        return data
    }

    private func string(_ value: Value?) -> String? {
        guard case let .string(value)? = value else { return nil }
        return value
    }
}
