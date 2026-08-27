#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public enum CodexDesktopMemoryResetError:
    Error,
    Equatable,
    Sendable
{
    case symlinkedRoot(String)
}

/// Mirrors the desktop memory reset filesystem contract. Memory roots remain
/// present after reset, but every generated artifact below them is removed.
public final class CodexDesktopMemoryResetService:
    CodexDesktopMemoryResetting,
    @unchecked Sendable
{
    private let codexHome: URL
    private let fileManager: FileManager

    public init(
        codexHome: URL,
        fileManager: FileManager = .default
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.fileManager = fileManager
    }

    public func resetMemory() throws {
        for directoryName in [
            "memories",
            "memories_extensions",
        ] {
            try clearRoot(
                codexHome.appendingPathComponent(
                    directoryName,
                    isDirectory: true
                )
            )
        }
    }

    private func clearRoot(_ root: URL) throws {
        if fileManager.fileExists(atPath: root.path) {
            let attributes = try fileManager.attributesOfItem(
                atPath: root.path
            )
            if attributes[.type] as? FileAttributeType
                == .typeSymbolicLink
            {
                throw CodexDesktopMemoryResetError.symlinkedRoot(
                    root.path
                )
            }
        }

        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for child in children {
            try fileManager.removeItem(at: child)
        }
    }
}
