import Foundation

public enum CodexMCPPythonPackageSnapshotManifestError:
    Error,
    Equatable,
    Sendable
{
    case invalidEncoding
    case unsupportedSchema
    case runtimeMismatch
    case invalidSourceIdentity
    case invalidDigest
    case invalidTree
    case invalidPackage
    case duplicatePackage(String)
    case duplicateSpecifier(String)
}

public struct CodexMCPPythonPackageSnapshotManifest:
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
        public var abi: String
        public var sourceTag: String
        public var sourceCommit: String
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
        public var consoleScript: String
    }

    public var schemaVersion: Int
    public var runtime: Runtime
    public var requirementsLockSha256: String
    public var tree: Tree
    public var packages: [Package]

    public init(validating data: Data) throws {
        struct Payload: Decodable {
            var schemaVersion: Int
            var runtime: Runtime
            var requirementsLockSha256: String
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
            throw CodexMCPPythonPackageSnapshotManifestError
                .invalidEncoding
        }

        guard payload.schemaVersion == 1 else {
            throw CodexMCPPythonPackageSnapshotManifestError
                .unsupportedSchema
        }
        guard payload.runtime.name == "CPython",
              payload.runtime.version == "3.13.14",
              payload.runtime.abi == "cp313"
        else {
            throw CodexMCPPythonPackageSnapshotManifestError
                .runtimeMismatch
        }
        guard payload.runtime.sourceTag == "3.13-b14",
              Self.isHexDigest(
                  payload.runtime.sourceCommit,
                  length: 40
              )
        else {
            throw CodexMCPPythonPackageSnapshotManifestError
                .invalidSourceIdentity
        }
        guard Self.isHexDigest(
                  payload.requirementsLockSha256,
                  length: 64
              ),
              Self.isHexDigest(payload.tree.sha256, length: 64)
        else {
            throw CodexMCPPythonPackageSnapshotManifestError
                .invalidDigest
        }
        guard payload.tree.fileCount > 0,
              payload.tree.totalBytes > 0,
              !payload.packages.isEmpty
        else {
            throw CodexMCPPythonPackageSnapshotManifestError
                .invalidTree
        }

        var packageNames = Set<String>()
        var specifiers = Set<String>()
        for package in payload.packages {
            guard Self.isPackageName(package.name),
                  Self.isVersion(package.version),
                  Self.isEntrypoint(package.entrypoint),
                  Self.isConsoleScript(package.consoleScript)
            else {
                throw CodexMCPPythonPackageSnapshotManifestError
                    .invalidPackage
            }

            let canonicalName = Self.canonicalPackageName(
                package.name
            )
            guard packageNames.insert(canonicalName).inserted
            else {
                throw CodexMCPPythonPackageSnapshotManifestError
                    .duplicatePackage(package.name)
            }

            for specifier in Self.specifiers(for: package) {
                guard specifiers.insert(specifier).inserted else {
                    throw CodexMCPPythonPackageSnapshotManifestError
                        .duplicateSpecifier(specifier)
                }
            }
        }

        schemaVersion = payload.schemaVersion
        runtime = payload.runtime
        requirementsLockSha256 =
            payload.requirementsLockSha256
        tree = payload.tree
        packages = payload.packages
    }

    public var uvxRegistryEntries: [String: String] {
        var entries: [String: String] = [:]
        for package in packages {
            for specifier in Self.specifiers(for: package) {
                entries[specifier] = package.entrypoint
            }
        }
        return entries
    }

    private static func specifiers(
        for package: Package
    ) -> [String] {
        let name = canonicalPackageName(package.name)
        var values = [
            name,
            "\(name)@\(package.version)",
            "\(name)@latest",
        ]
        if package.consoleScript != name {
            values.append(package.consoleScript)
            values.append(
                "\(package.consoleScript)@\(package.version)"
            )
            values.append("\(package.consoleScript)@latest")
        }
        return values
    }

    private static func canonicalPackageName(
        _ value: String
    ) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private static func isPackageName(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              )
        else {
            return false
        }
        return value.allSatisfy {
            $0.isLetter || $0.isNumber
                || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    private static func isVersion(_ value: String) -> Bool {
        !value.isEmpty
            && value.allSatisfy {
                $0.isLetter || $0.isNumber
                    || $0 == "." || $0 == "-"
                    || $0 == "+" || $0 == "_"
            }
    }

    private static func isEntrypoint(
        _ value: String
    ) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.split(separator: "/").contains(".."),
              !value.contains("\\"),
              value == value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              )
        else {
            return false
        }
        if value.hasPrefix("PythonPackages/") {
            return value.hasSuffix(".py")
        }
        let entrypointComponents = value.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard entrypointComponents.count == 1
                || entrypointComponents.count == 2,
              entrypointComponents.allSatisfy({ !$0.isEmpty })
        else {
            return false
        }
        return entrypointComponents.allSatisfy { component in
            component.split(
                separator: ".",
                omittingEmptySubsequences: false
            ).allSatisfy {
            !$0.isEmpty
                && ($0.first?.isLetter == true
                    || $0.first == "_")
                && $0.allSatisfy {
                    $0.isLetter || $0.isNumber || $0 == "_"
                }
            }
        }
    }

    private static func isConsoleScript(
        _ value: String
    ) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-")
        else {
            return false
        }
        return value.allSatisfy {
            $0.isLetter || $0.isNumber
                || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    private static func isHexDigest(
        _ value: String,
        length: Int
    ) -> Bool {
        value.count == length && value.allSatisfy {
            $0.isHexDigit
        }
    }
}
