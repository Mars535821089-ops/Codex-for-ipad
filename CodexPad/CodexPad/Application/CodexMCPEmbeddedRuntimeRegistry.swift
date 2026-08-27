import Foundation

public enum CodexMCPNodePackageSnapshotManifestError:
    Error,
    Equatable,
    Sendable
{
    case invalidEncoding
    case unsupportedSchema
    case runtimeMismatch
    case invalidDigest
    case invalidTree
    case invalidPackage
    case duplicatePackage(String)
}

public struct CodexMCPNodePackageSnapshotManifest:
    Equatable,
    Sendable
{
    public struct Runtime:
        Codable,
        Equatable,
        Sendable
    {
        public var name: String
        public var version: String
    }

    public struct Tree:
        Codable,
        Equatable,
        Sendable
    {
        public var sha256: String
        public var fileCount: Int
        public var totalBytes: Int
    }

    public struct Package:
        Codable,
        Equatable,
        Sendable
    {
        public var name: String
        public var version: String
        public var entrypoint: String
    }

    public var schemaVersion: Int
    public var runtime: Runtime
    public var packageLockSha256: String
    public var tree: Tree
    public var packages: [Package]

    public init(validating data: Data) throws {
        struct Payload: Decodable {
            var schemaVersion: Int
            var runtime: Runtime
            var packageLockSha256: String
            var tree: Tree
            var packages: [Package]
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(
                Payload.self,
                from: data
            )
        } catch {
            throw CodexMCPNodePackageSnapshotManifestError
                .invalidEncoding
        }
        guard payload.schemaVersion == 1 else {
            throw CodexMCPNodePackageSnapshotManifestError
                .unsupportedSchema
        }
        guard payload.runtime
            == Runtime(
                name: "NodeMobile",
                version: "18.20.4"
            )
        else {
            throw CodexMCPNodePackageSnapshotManifestError
                .runtimeMismatch
        }
        guard Self.isSHA256(payload.packageLockSha256),
              Self.isSHA256(payload.tree.sha256)
        else {
            throw CodexMCPNodePackageSnapshotManifestError
                .invalidDigest
        }
        guard payload.tree.fileCount > 0,
              payload.tree.totalBytes > 0,
              !payload.packages.isEmpty
        else {
            throw CodexMCPNodePackageSnapshotManifestError
                .invalidTree
        }
        var packageNames = Set<String>()
        for package in payload.packages {
            guard !package.name.isEmpty,
                  !package.version.isEmpty,
                  package.entrypoint.hasPrefix(
                      "MCPPackages/node_modules/"
                  ),
                  !package.entrypoint.hasPrefix("/"),
                  !package.entrypoint.split(
                      separator: "/"
                  ).contains("..")
            else {
                throw CodexMCPNodePackageSnapshotManifestError
                    .invalidPackage
            }
            guard packageNames.insert(package.name).inserted
            else {
                throw CodexMCPNodePackageSnapshotManifestError
                    .duplicatePackage(package.name)
            }
        }
        schemaVersion = payload.schemaVersion
        runtime = payload.runtime
        packageLockSha256 = payload.packageLockSha256
        tree = payload.tree
        packages = payload.packages
    }

    public var npxRegistryEntries: [String: String] {
        var entries: [String: String] = [:]
        for package in packages {
            entries[package.name] = package.entrypoint
            entries["\(package.name)@\(package.version)"] =
                package.entrypoint
            entries["\(package.name)@latest"] = package.entrypoint
        }
        return entries
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            $0.isHexDigit
        }
    }
}

public enum CodexMCPEmbeddedRuntime:
    String,
    Equatable,
    Sendable
{
    case node
    case python
}

public enum CodexMCPEmbeddedRuntimeRoute:
    Equatable,
    Sendable
{
    case iosSystem(command: String, arguments: [String])
    case node(arguments: [String])
    case vendoredNodePackage(
        package: String,
        entrypoint: String,
        arguments: [String]
    )
    case python(arguments: [String])
    case vendoredPythonPackage(
        package: String,
        entrypoint: String,
        consoleScript: String?,
        arguments: [String]
    )
}

public enum CodexMCPEmbeddedRuntimeUnavailableReason:
    Equatable,
    Sendable
{
    case unsupportedCommand
    case runtimeMissing(CodexMCPEmbeddedRuntime)
    case packageSpecifierMissing
    case invalidPackageInvocation(String)
    case packageSnapshotMissing(String)
}

public struct CodexMCPEmbeddedRuntimeUnavailability:
    Equatable,
    Sendable
{
    public var command: String
    public var reason:
        CodexMCPEmbeddedRuntimeUnavailableReason

    public init(
        command: String,
        reason: CodexMCPEmbeddedRuntimeUnavailableReason
    ) {
        self.command = command
        self.reason = reason
    }
}

public enum CodexMCPEmbeddedRuntimeResolution:
    Equatable,
    Sendable
{
    case available(CodexMCPEmbeddedRuntimeRoute)
    case unavailable(CodexMCPEmbeddedRuntimeUnavailability)
}

public struct CodexMCPEmbeddedRuntimeRegistry:
    Sendable
{
    public static let iosSystemCommands: Set<String> = [
        "alias",
        "cat",
        "cd",
        "chflags",
        "chmod",
        "cksum",
        "compress",
        "cp",
        "date",
        "diff",
        "du",
        "echo",
        "ed",
        "egrep",
        "env",
        "export",
        "fgrep",
        "find",
        "grep",
        "gunzip",
        "gzip",
        "head",
        "link",
        "ln",
        "ls",
        "md5",
        "mkdir",
        "mv",
        "open",
        "openurl",
        "pbcopy",
        "pbpaste",
        "printenv",
        "pwd",
        "readlink",
        "rm",
        "rmdir",
        "say",
        "sed",
        "setenv",
        "sh",
        "sort",
        "stat",
        "sum",
        "tail",
        "tee",
        "touch",
        "tr",
        "unalias",
        "uname",
        "uncompress",
        "uniq",
        "unlink",
        "unsetenv",
        "uptime",
        "wc",
        "whoami",
        "xargs",
    ]

    private let nodeAvailable: Bool
    private let pythonAvailable: Bool
    private let npxPackages: [String: String]
    private let uvxPackages: [String: String]

    private struct PythonPackageInvocation {
        var packageSpecifier: String
        var consoleScript: String?
        var arguments: [String]
    }

    private enum PythonPackageInvocationError: Error {
        case packageSpecifierMissing
        case invalid(String)

        var diagnostic: String {
            switch self {
            case .packageSpecifierMissing:
                "package specifier is missing"
            case let .invalid(message):
                message
            }
        }
    }

    public init(
        nodeAvailable: Bool = false,
        pythonAvailable: Bool = false,
        npxPackages: [String: String] = [:],
        uvxPackages: [String: String] = [:]
    ) {
        self.nodeAvailable = nodeAvailable
        self.pythonAvailable = pythonAvailable
        self.npxPackages = npxPackages
        self.uvxPackages = uvxPackages
    }

    public func resolve(
        command: String,
        arguments: [String]
    ) -> CodexMCPEmbeddedRuntimeResolution {
        let executable = URL(
            fileURLWithPath: command
        ).lastPathComponent
        if Self.iosSystemCommands.contains(executable) {
            return .available(
                .iosSystem(
                    command: executable,
                    arguments: arguments
                )
            )
        }
        switch executable {
        case "node":
            return interpreterResolution(
                command: executable,
                runtime: .node,
                available: nodeAvailable,
                route: .node(arguments: arguments)
            )
        case "python", "python3":
            return interpreterResolution(
                command: executable,
                runtime: .python,
                available: pythonAvailable,
                route: .python(arguments: arguments)
            )
        case "npx":
            return packageResolution(
                command: executable,
                arguments: arguments,
                runtime: .node,
                runtimeAvailable: nodeAvailable,
                packages: npxPackages,
                route: {
                    .vendoredNodePackage(
                        package: $0,
                        entrypoint: $1,
                        arguments: $2
                    )
                }
            )
        case "uv", "uvx":
            return pythonPackageResolution(
                command: executable,
                arguments: arguments,
                runtimeAvailable: pythonAvailable
            )
        default:
            return unavailable(
                executable,
                reason: .unsupportedCommand
            )
        }
    }

    private func interpreterResolution(
        command: String,
        runtime: CodexMCPEmbeddedRuntime,
        available: Bool,
        route: CodexMCPEmbeddedRuntimeRoute
    ) -> CodexMCPEmbeddedRuntimeResolution {
        guard available else {
            return unavailable(
                command,
                reason: .runtimeMissing(runtime)
            )
        }
        return .available(route)
    }

    private func packageResolution(
        command: String,
        arguments: [String],
        runtime: CodexMCPEmbeddedRuntime,
        runtimeAvailable: Bool,
        packages: [String: String],
        route: (
            String,
            String,
            [String]
        ) -> CodexMCPEmbeddedRuntimeRoute
    ) -> CodexMCPEmbeddedRuntimeResolution {
        guard runtimeAvailable else {
            return unavailable(
                command,
                reason: .runtimeMissing(runtime)
            )
        }
        guard let packageIndex = packageSpecifierIndex(
            in: arguments
        ) else {
            return unavailable(
                command,
                reason: .packageSpecifierMissing
            )
        }
        let packageSpecifier = arguments[packageIndex]
        guard let entrypoint = packages[packageSpecifier] else {
            return unavailable(
                command,
                reason: .packageSnapshotMissing(packageSpecifier)
            )
        }
        let package = packageName(
            from: packageSpecifier
        )
        return .available(
            route(
                package,
                entrypoint,
                Array(arguments.dropFirst(packageIndex + 1))
            )
        )
    }

    private func pythonPackageResolution(
        command: String,
        arguments: [String],
        runtimeAvailable: Bool
    ) -> CodexMCPEmbeddedRuntimeResolution {
        guard runtimeAvailable else {
            return unavailable(
                command,
                reason: .runtimeMissing(.python)
            )
        }

        let invocation: PythonPackageInvocation
        do {
            invocation = try pythonPackageInvocation(
                command: command,
                arguments: arguments
            )
        } catch PythonPackageInvocationError
            .packageSpecifierMissing
        {
            return unavailable(
                command,
                reason: .packageSpecifierMissing
            )
        } catch let error as PythonPackageInvocationError {
            return unavailable(
                command,
                reason: .invalidPackageInvocation(
                    error.diagnostic
                )
            )
        } catch {
            return unavailable(
                command,
                reason: .invalidPackageInvocation(
                    String(describing: error)
                )
            )
        }

        guard let entrypoint =
            uvxPackages[invocation.packageSpecifier]
        else {
            return unavailable(
                command,
                reason: .packageSnapshotMissing(
                    invocation.packageSpecifier
                )
            )
        }
        return .available(
            .vendoredPythonPackage(
                package: packageName(
                    from: invocation.packageSpecifier
                ),
                entrypoint: entrypoint,
                consoleScript: invocation.consoleScript,
                arguments: invocation.arguments
            )
        )
    }

    private func pythonPackageInvocation(
        command: String,
        arguments: [String]
    ) throws -> PythonPackageInvocation {
        let toolArguments: [String]
        if command == "uv" {
            toolArguments = try uvToolRunArguments(
                arguments
            )
        } else {
            toolArguments = arguments
        }
        return try uvxInvocation(arguments: toolArguments)
    }

    private func uvToolRunArguments(
        _ arguments: [String]
    ) throws -> [String] {
        var index = 0
        while index < arguments.count,
              arguments[index] != "tool"
        {
            guard arguments[index].hasPrefix("-") else {
                throw PythonPackageInvocationError.invalid(
                    "expected `uv tool run`, found subcommand "
                    + arguments[index]
                )
            }
            index = try Self.indexAfterOption(
                arguments,
                at: index,
                longValueOptions: Self.uvGlobalValueOptions,
                longFlagOptions: Self.uvGlobalFlagOptions,
                shortValueOptions: [],
                shortFlagOptions: Self.uvGlobalShortFlagOptions,
                context: "uv"
            )
        }
        guard index < arguments.count,
              arguments[index] == "tool"
        else {
            throw PythonPackageInvocationError.invalid(
                "expected `uv tool run`"
            )
        }

        index += 1
        while index < arguments.count,
              arguments[index] != "run"
        {
            guard arguments[index].hasPrefix("-") else {
                throw PythonPackageInvocationError.invalid(
                    "expected `run` after `uv tool`"
                )
            }
            index = try Self.indexAfterOption(
                arguments,
                at: index,
                longValueOptions: Self.uvGlobalValueOptions,
                longFlagOptions: Self.uvGlobalFlagOptions,
                shortValueOptions: [],
                shortFlagOptions: Self.uvGlobalShortFlagOptions,
                context: "uv tool"
            )
        }
        guard index < arguments.count,
              arguments[index] == "run"
        else {
            throw PythonPackageInvocationError.invalid(
                "expected `run` after `uv tool`"
            )
        }
        return Array(arguments.dropFirst(index + 1))
    }

    private func uvxInvocation(
        arguments: [String]
    ) throws -> PythonPackageInvocation {
        var index = 0
        var fromSpecifier: String?

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                break
            }
            guard argument.hasPrefix("-") else {
                break
            }

            if argument == "--from" {
                guard index + 1 < arguments.count,
                      Self.isOptionValue(arguments[index + 1])
                else {
                    throw PythonPackageInvocationError.invalid(
                        "option requires a value: --from"
                    )
                }
                fromSpecifier = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("--from=") {
                let value = String(
                    argument.dropFirst("--from=".count)
                )
                guard Self.isOptionValue(value) else {
                    throw PythonPackageInvocationError.invalid(
                        "option requires a value: --from"
                    )
                }
                fromSpecifier = value
                index += 1
                continue
            }

            index = try Self.indexAfterOption(
                arguments,
                at: index,
                longValueOptions: Self.uvxValueOptions,
                longFlagOptions: Self.uvxFlagOptions,
                shortValueOptions: Self.uvxShortValueOptions,
                shortFlagOptions: Self.uvxShortFlagOptions,
                context: "uvx"
            )
        }

        guard index < arguments.count else {
            if fromSpecifier != nil {
                throw PythonPackageInvocationError.invalid(
                    "command is missing after --from"
                )
            }
            throw PythonPackageInvocationError
                .packageSpecifierMissing
        }

        let commandSpecifier = arguments[index]
        guard !commandSpecifier.isEmpty,
              !commandSpecifier.utf8.contains(0)
        else {
            throw PythonPackageInvocationError.invalid(
                "command specifier is invalid"
            )
        }
        return PythonPackageInvocation(
            packageSpecifier:
                fromSpecifier ?? commandSpecifier,
            consoleScript:
                fromSpecifier == nil
                ? nil
                : commandSpecifier,
            arguments:
                Array(arguments.dropFirst(index + 1))
        )
    }

    private static func indexAfterOption(
        _ arguments: [String],
        at index: Int,
        longValueOptions: Set<String>,
        longFlagOptions: Set<String>,
        shortValueOptions: Set<String>,
        shortFlagOptions: Set<String>,
        context: String
    ) throws -> Int {
        let argument = arguments[index]
        if argument.hasPrefix("--") {
            if let separator = argument.firstIndex(of: "=") {
                let name = String(argument[..<separator])
                let value = String(
                    argument[argument.index(after: separator)...]
                )
                guard longValueOptions.contains(name),
                      isOptionValue(value)
                else {
                    throw PythonPackageInvocationError.invalid(
                        "unsupported \(context) option: \(argument)"
                    )
                }
                return index + 1
            }
            if longFlagOptions.contains(argument) {
                return index + 1
            }
            if longValueOptions.contains(argument) {
                guard index + 1 < arguments.count,
                      isOptionValue(arguments[index + 1])
                else {
                    throw PythonPackageInvocationError.invalid(
                        "option requires a value: \(argument)"
                    )
                }
                return index + 2
            }
            throw PythonPackageInvocationError.invalid(
                "unsupported \(context) option: \(argument)"
            )
        }

        if shortFlagOptions.contains(argument)
            || isQuietVerboseCluster(argument)
        {
            return index + 1
        }
        if shortValueOptions.contains(argument) {
            guard index + 1 < arguments.count,
                  isOptionValue(arguments[index + 1])
            else {
                throw PythonPackageInvocationError.invalid(
                    "option requires a value: \(argument)"
                )
            }
            return index + 2
        }
        if argument.count > 2 {
            let option = String(argument.prefix(2))
            if shortValueOptions.contains(option) {
                let value = String(argument.dropFirst(2))
                guard isOptionValue(value) else {
                    throw PythonPackageInvocationError.invalid(
                        "option requires a value: \(option)"
                    )
                }
                return index + 1
            }
        }
        throw PythonPackageInvocationError.invalid(
            "unsupported \(context) option: \(argument)"
        )
    }

    private static func isOptionValue(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("-")
            && !value.utf8.contains(0)
    }

    private static func isQuietVerboseCluster(
        _ value: String
    ) -> Bool {
        value.count > 1
            && value.first == "-"
            && value.dropFirst().allSatisfy {
                $0 == "q" || $0 == "v"
            }
    }

    private static let uvGlobalValueOptions: Set<String> = [
        "--allow-insecure-host",
        "--color",
        "--config-file",
        "--directory",
        "--project",
    ]

    private static let uvGlobalFlagOptions: Set<String> = [
        "--help",
        "--native-tls",
        "--no-config",
        "--no-progress",
        "--offline",
        "--quiet",
        "--system-certs",
        "--verbose",
        "--version",
    ]

    private static let uvGlobalShortFlagOptions: Set<String> = [
        "-V",
        "-h",
        "-q",
        "-v",
    ]

    private static let uvxValueOptions: Set<String> = [
        "--allow-insecure-host",
        "--build-constraints",
        "--cache-dir",
        "--color",
        "--config-file",
        "--config-setting",
        "--config-settings-package",
        "--constraints",
        "--default-index",
        "--directory",
        "--env-file",
        "--exclude-newer",
        "--exclude-newer-package",
        "--extra-index-url",
        "--find-links",
        "--fork-strategy",
        "--index",
        "--index-strategy",
        "--index-url",
        "--keyring-provider",
        "--link-mode",
        "--no-binary-package",
        "--no-build-isolation-package",
        "--no-build-package",
        "--no-sources-package",
        "--overrides",
        "--prerelease",
        "--project",
        "--python",
        "--python-platform",
        "--refresh-package",
        "--reinstall-package",
        "--resolution",
        "--torch-backend",
        "--upgrade-group",
        "--upgrade-package",
        "--with",
        "--with-editable",
        "--with-requirements",
    ]

    private static let uvxFlagOptions: Set<String> = [
        "--compile-bytecode",
        "--help",
        "--isolated",
        "--lfs",
        "--managed-python",
        "--native-tls",
        "--no-binary",
        "--no-build",
        "--no-build-isolation",
        "--no-cache",
        "--no-config",
        "--no-env-file",
        "--no-index",
        "--no-managed-python",
        "--no-progress",
        "--no-python-downloads",
        "--no-sources",
        "--offline",
        "--quiet",
        "--refresh",
        "--reinstall",
        "--system-certs",
        "--upgrade",
        "--verbose",
        "--version",
    ]

    private static let uvxShortValueOptions: Set<String> = [
        "-C",
        "-P",
        "-b",
        "-c",
        "-f",
        "-i",
        "-p",
        "-w",
    ]

    private static let uvxShortFlagOptions: Set<String> = [
        "-U",
        "-V",
        "-h",
        "-n",
        "-q",
        "-v",
    ]

    private func packageSpecifierIndex(
        in arguments: [String]
    ) -> Int? {
        arguments.firstIndex {
            !$0.hasPrefix("-")
        }
    }

    private func packageName(
        from specifier: String
    ) -> String {
        guard let versionSeparator = specifier.lastIndex(of: "@")
        else {
            return specifier
        }
        if specifier.hasPrefix("@") {
            guard let scopeSeparator = specifier.firstIndex(of: "/"),
                  versionSeparator > scopeSeparator
            else {
                return specifier
            }
        } else if versionSeparator == specifier.startIndex {
            return specifier
        }
        return String(specifier[..<versionSeparator])
    }

    private func unavailable(
        _ command: String,
        reason: CodexMCPEmbeddedRuntimeUnavailableReason
    ) -> CodexMCPEmbeddedRuntimeResolution {
        .unavailable(
            .init(command: command, reason: reason)
        )
    }
}
