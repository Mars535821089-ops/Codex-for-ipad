#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexWorkspaceAccessError: Error, Equatable, Sendable {
    case invalidBookmark
    case accessDenied
    case invalidRelativePath
    case fileTooLarge
    case notText
}

public struct CodexWorkspaceFile: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let isDirectory: Bool
}

public struct CodexWorkspaceAccess: Sendable {
    public static let maximumReadableBytes = 2 * 1_024 * 1_024

    public init() {}

    public func bookmark(for url: URL) throws -> String {
        let granted = url.startAccessingSecurityScopedResource()
        defer {
            if granted {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return data.base64EncodedString()
    }

    public func resolve(_ bookmark: String) throws -> URL {
        guard let data = Data(base64Encoded: bookmark) else {
            throw CodexWorkspaceAccessError.invalidBookmark
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else {
            throw CodexWorkspaceAccessError.invalidBookmark
        }
        return url
    }

    public func listFiles(
        bookmark: String,
        limit: Int = 2_000
    ) throws -> [CodexWorkspaceFile] {
        let root = try resolve(bookmark)
        return try withAccess(to: root) {
            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            ) else {
                throw CodexWorkspaceAccessError.accessDenied
            }
            var files: [CodexWorkspaceFile] = []
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isDirectory == true || values.isRegularFile == true
                else {
                    continue
                }
                files.append(
                    CodexWorkspaceFile(
                        relativePath: try Self.relativePath(
                            for: url,
                            inside: root
                        ),
                        isDirectory: values.isDirectory == true
                    )
                )
                if files.count >= limit {
                    break
                }
            }
            return files.sorted {
                if $0.isDirectory != $1.isDirectory {
                    return $0.isDirectory && !$1.isDirectory
                }
                return $0.relativePath.localizedStandardCompare(
                    $1.relativePath
                ) == .orderedAscending
            }
        }
    }

    public func readText(
        bookmark: String,
        relativePath: String
    ) throws -> String {
        let root = try resolve(bookmark)
        let file = try Self.secureURL(
            relativePath: relativePath,
            inside: root
        )
        return try withAccess(to: root) {
            let values = try file.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true else {
                throw CodexWorkspaceAccessError.invalidRelativePath
            }
            guard (values.fileSize ?? 0) <= Self.maximumReadableBytes else {
                throw CodexWorkspaceAccessError.fileTooLarge
            }
            let data = try Data(contentsOf: file)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CodexWorkspaceAccessError.notText
            }
            return text
        }
    }

    public func writeText(
        bookmark: String,
        relativePath: String,
        text: String
    ) throws {
        guard text.utf8.count <= Self.maximumReadableBytes else {
            throw CodexWorkspaceAccessError.fileTooLarge
        }
        let root = try resolve(bookmark)
        let file = try Self.secureURL(
            relativePath: relativePath,
            inside: root
        )
        try withAccess(to: root) {
            let parent = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: file.path) {
                let values = try file.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true
                else {
                    throw CodexWorkspaceAccessError.invalidRelativePath
                }
            }
            guard let data = text.data(using: .utf8) else {
                throw CodexWorkspaceAccessError.notText
            }
            try data.write(to: file, options: .atomic)
        }
    }

    public static func secureURL(
        relativePath: String,
        inside root: URL
    ) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw CodexWorkspaceAccessError.invalidRelativePath
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot
            .appending(path: relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw CodexWorkspaceAccessError.invalidRelativePath
        }
        return candidate
    }

    private static func relativePath(
        for url: URL,
        inside root: URL
    ) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw CodexWorkspaceAccessError.invalidRelativePath
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func withAccess<Value>(
        to root: URL,
        operation: () throws -> Value
    ) throws -> Value {
        let granted = root.startAccessingSecurityScopedResource()
        defer {
            if granted {
                root.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }
}

public enum CodexDesktopDefaultWorkspaceCreator {
    private static let releasedDefaultName = "New project"
    private static let forbiddenScalars: Set<Unicode.Scalar> = Set(
        "<>:\"/\\|?*".unicodeScalars
    )
    private static let windowsReservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5",
        "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5",
        "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    public static func create(
        named requestedName: String,
        initializeGitRepository: Bool,
        documentsDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let baseName = sanitizedName(requestedName)
        let chatGPTDirectory = documentsDirectory.appendingPathComponent(
            "ChatGPT",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: chatGPTDirectory,
            withIntermediateDirectories: true
        )
        var candidate = chatGPTDirectory.appendingPathComponent(
            baseName,
            isDirectory: true
        )
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = chatGPTDirectory.appendingPathComponent(
                "\(baseName) \(suffix)",
                isDirectory: true
            )
            suffix += 1
        }

        try fileManager.createDirectory(
            at: candidate,
            withIntermediateDirectories: true
        )
        do {
            if initializeGitRepository {
                try writeGitRepositoryLayout(
                    at: candidate,
                    fileManager: fileManager
                )
            }
            return candidate
        } catch {
            try? fileManager.removeItem(at: candidate)
            throw error
        }
    }

    private static func sanitizedName(_ requestedName: String) -> String {
        let replaced = String(
            requestedName.unicodeScalars.map { scalar in
                if isControl(scalar) || forbiddenScalars.contains(scalar) {
                    return "_"
                }
                return String(scalar)
            }.joined()
        )
        let trimmed = replaced
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let name = trimmed.isEmpty ? releasedDefaultName : trimmed
        return windowsSafeName(name)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        (0x00 ... 0x1F).contains(scalar.value)
            || (0x7F ... 0x9F).contains(scalar.value)
    }

    private static func windowsSafeName(_ name: String) -> String {
        let stem = name.split(separator: ".", maxSplits: 1).first
            .map(String.init)?
            .uppercased() ?? name.uppercased()
        return windowsReservedNames.contains(stem) ? name + "_" : name
    }

    private static func writeGitRepositoryLayout(
        at workspace: URL,
        fileManager: FileManager
    ) throws {
        let git = workspace.appendingPathComponent(
            ".git",
            isDirectory: true
        )
        for relativePath in [
            "branches",
            "hooks",
            "info",
            "objects/info",
            "objects/pack",
            "refs/heads",
            "refs/tags",
        ] {
            try fileManager.createDirectory(
                at: git.appendingPathComponent(
                    relativePath,
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
        }
        try Data("ref: refs/heads/main\n".utf8).write(
            to: git.appendingPathComponent("HEAD"),
            options: .atomic
        )
        try Data(
            """
            [core]
            \trepositoryformatversion = 0
            \tfilemode = true
            \tbare = false
            \tlogallrefupdates = true

            """.utf8
        ).write(
            to: git.appendingPathComponent("config"),
            options: .atomic
        )
        try Data(
            "Unnamed repository; edit this file 'description' to name it.\n"
                .utf8
        ).write(
            to: git.appendingPathComponent("description"),
            options: .atomic
        )
        try Data(
            """
            # git ls-files --others --exclude-from=.git/info/exclude
            # Lines that start with '#' are comments.

            """.utf8
        ).write(
            to: git.appendingPathComponent("info/exclude"),
            options: .atomic
        )
    }
}

public enum CodexPadUITestWorkspaceBootstrap {
    private static let environmentKey =
        "CODEXPAD_UI_TEST_GIT_WORKSPACE"
    private static let workspaceName = "Parity Git Workspace"

    @discardableResult
    public static func prepare(
        environment: [String: String],
        documentsDirectory: URL,
        existingWorkspaces: [Workspace] = [],
        fileManager: FileManager = .default,
        persistWorkspace: (Workspace) throws -> Void
    ) throws -> URL? {
        guard environment[environmentKey] == "1" else {
            return nil
        }
        let root = documentsDirectory.appendingPathComponent(
            workspaceName,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        do {
            let gitRoot = try CodexDesktopDefaultWorkspaceCreator.create(
                named: workspaceName,
                initializeGitRepository: true,
                documentsDirectory: documentsDirectory,
                fileManager: fileManager
            )
            if gitRoot != root {
                try fileManager.removeItem(at: root)
                try fileManager.moveItem(at: gitRoot, to: root)
            }
            try Data(
                "# Codex for ipad parity workspace\n".utf8
            ).write(
                to: root.appendingPathComponent("README.md"),
                options: .atomic
            )
            let bookmark = try CodexWorkspaceAccess().bookmark(for: root)
            let matchingWorkspaces = existingWorkspaces.filter {
                $0.displayName == workspaceName
            }
            if matchingWorkspaces.isEmpty {
                try persistWorkspace(
                    Workspace(
                        id: UUID(),
                        displayName: workspaceName,
                        rootBookmarkID: bookmark
                    )
                )
            } else {
                for workspace in matchingWorkspaces {
                    try persistWorkspace(
                        Workspace(
                            id: workspace.id,
                            displayName: workspaceName,
                            rootBookmarkID: bookmark
                        )
                    )
                }
            }
            return root
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }
}

public enum CodexDesktopWorkspaceOnboardingEffect:
    Equatable,
    Sendable
{
    case ignored
    case handled
    case presentPicker(allowsMultipleSelection: Bool)
}

/// Reproduces the released Electron main-process boundary used by
/// `select-workspace-page-*`. Folder access is staged when the picker closes
/// and is only committed after the renderer sends its selected roots.
@MainActor
public final class CodexDesktopWorkspaceOnboardingCoordinator {
    public typealias WorkspaceSnapshot = () -> [Workspace]
    public typealias WorkspacePersistence =
        (UUID, String, String) throws -> Void
    public typealias BookmarkCreation = (URL) throws -> String
    public typealias BookmarkResolution = (String) throws -> URL
    public typealias DefaultWorkspaceCreation =
        (String, Bool) throws -> URL
    public typealias WorkspaceSelection = (UUID?) -> Void
    public typealias MessageSender =
        (CodexDesktopHostMessage) async -> Void

    private let workspaces: WorkspaceSnapshot
    private let persistWorkspace: WorkspacePersistence
    private let bookmark: BookmarkCreation
    private let resolveBookmark: BookmarkResolution
    private let createDefaultWorkspace: DefaultWorkspaceCreation
    private let selectWorkspace: WorkspaceSelection
    private let send: MessageSender
    private var stagedBookmarksByPath: [String: String] = [:]
    private var pendingOnboardingPicker:
        (
            defaultProjectName: String,
            initializeGitRepository: Bool
        )?

    public init(
        workspaces: @escaping WorkspaceSnapshot,
        persistWorkspace: @escaping WorkspacePersistence,
        bookmark: @escaping BookmarkCreation,
        resolveBookmark: @escaping BookmarkResolution,
        createDefaultWorkspace:
            @escaping DefaultWorkspaceCreation,
        selectWorkspace:
            @escaping WorkspaceSelection = { _ in },
        send: @escaping MessageSender
    ) {
        self.workspaces = workspaces
        self.persistWorkspace = persistWorkspace
        self.bookmark = bookmark
        self.resolveBookmark = resolveBookmark
        self.createDefaultWorkspace = createDefaultWorkspace
        self.selectWorkspace = selectWorkspace
        self.send = send
    }

    public func handleViewEvent(
        type: String,
        payload: CodexJSONValue
    ) async -> CodexDesktopWorkspaceOnboardingEffect {
        guard case let .object(fields) = payload else {
            return .ignored
        }
        switch type {
        case "electron-add-new-workspace-root-option":
            guard case let .string(root)? = fields["root"],
                  !root.isEmpty
            else {
                return .ignored
            }
            await addAndSelectRoot(
                URL(
                    fileURLWithPath: root,
                    isDirectory: true
                )
            )
            return .handled

        case "electron-create-new-workspace-root-option":
            guard case let .bool(initializeGitRepository)? =
                fields["initializeGitRepository"]
            else {
                return .ignored
            }
            let projectName: String
            switch fields["projectName"] {
            case let .string(value)? where !value.isEmpty:
                projectName = value
            case nil:
                projectName = "My project"
            default:
                return .ignored
            }
            if let root = try? createDefaultWorkspace(
                projectName,
                initializeGitRepository
            ) {
                await addAndSelectRoot(
                    root,
                    preferredName: projectName
                )
            }
            return .handled

        case "electron-pick-workspace-root-option":
            guard case let .bool(allowsMultiple)? =
                fields["allowMultiple"]
            else {
                return .ignored
            }
            pendingOnboardingPicker = nil
            return .presentPicker(
                allowsMultipleSelection: allowsMultiple
            )

        case
            "electron-onboarding-pick-workspace-or-create-default":
            guard case let .string(defaultProjectName)? =
                fields["defaultProjectName"],
                !defaultProjectName.isEmpty,
                case let .bool(initializeGitRepository)? =
                    fields["initializeGitRepository"]
            else {
                return .ignored
            }
            pendingOnboardingPicker = (
                defaultProjectName,
                initializeGitRepository
            )
            return .presentPicker(
                allowsMultipleSelection: false
            )

        case "electron-update-workspace-root-options":
            guard case let .array(values)? = fields["roots"] else {
                return .ignored
            }
            let roots = values.compactMap { value -> String? in
                guard case let .string(root) = value,
                      !root.isEmpty
                else {
                    return nil
                }
                return root
            }
            guard roots.count == values.count else {
                return .ignored
            }
            commit(roots: roots)
            await sendWorkspaceStateChanged()
            return .handled

        case "electron-onboarding-skip-workspace":
            let projectName: String
            switch fields["projectName"] {
            case let .string(value)? where !value.isEmpty:
                projectName = value
            case nil:
                projectName = "My project"
            default:
                return .ignored
            }
            guard case let .bool(initializeGitRepository)? =
                fields["initializeGitRepository"]
            else {
                return .ignored
            }
            await createAndSelectDefaultWorkspace(
                projectName: projectName,
                initializeGitRepository: initializeGitRepository
            )
            return .handled

        case "electron-rename-workspace-root-option":
            guard case let .string(root)? = fields["root"],
                  case let .string(label)? = fields["label"],
                  let workspace = workspace(forRoot: root),
                  let bookmark = workspace.rootBookmarkID
            else {
                return .ignored
            }
            let trimmedLabel = label.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmedLabel.isEmpty else {
                return .handled
            }
            try? persistWorkspace(
                workspace.id,
                trimmedLabel,
                bookmark
            )
            await sendGlobalStateChanged(keys: [
                "local-projects"
            ])
            await send(
                .event(
                    type: "workspace-root-options-updated",
                    payload: .object([:])
                )
            )
            return .handled

        case "electron-set-active-workspace-root":
            guard case let .string(root)? = fields["root"],
                  !root.isEmpty
            else {
                return .ignored
            }
            if let existing = workspace(forRoot: root) {
                selectWorkspace(existing.id)
                await sendWorkspaceSelectionChanged(
                    includeProjectCollections: false
                )
            } else {
                await addAndSelectRoot(
                    URL(
                        fileURLWithPath: root,
                        isDirectory: true
                    )
                )
            }
            return .handled

        case "electron-clear-active-workspace-root":
            selectWorkspace(nil)
            await sendWorkspaceSelectionChanged(
                includeProjectCollections: false
            )
            return .handled

        default:
            return .ignored
        }
    }

    public func completePicker(urls: [URL]) async {
        if let pendingOnboardingPicker {
            self.pendingOnboardingPicker = nil
            await completeOnboardingPicker(
                urls: urls,
                defaultProjectName:
                    pendingOnboardingPicker.defaultProjectName,
                initializeGitRepository:
                    pendingOnboardingPicker.initializeGitRepository
            )
            return
        }
        for url in urls {
            let canonical = url.standardizedFileURL
            guard let bookmark = try? bookmark(canonical) else {
                continue
            }
            stagedBookmarksByPath[canonical.path] = bookmark
            await send(
                .event(
                    type: "workspace-root-option-picked",
                    payload: .object([
                        "root": .string(canonical.path)
                    ])
                )
            )
        }
    }

    private func completeOnboardingPicker(
        urls: [URL],
        defaultProjectName: String,
        initializeGitRepository: Bool
    ) async {
        var source = "picked"
        var selectedRoot: URL?
        do {
            let root: URL
            if let picked = urls.first {
                root = picked.standardizedFileURL
            } else {
                source = "created_default"
                root = try createDefaultWorkspace(
                    defaultProjectName,
                    initializeGitRepository
                ).standardizedFileURL
            }
            selectedRoot = root

            let workspaceID: UUID
            if let existing = workspace(forRoot: root.path) {
                workspaceID = existing.id
            } else {
                let createdBookmark = try bookmark(root)
                let fallbackName = root.lastPathComponent.isEmpty
                    ? defaultProjectName
                    : root.lastPathComponent
                let id = UUID()
                try persistWorkspace(
                    id,
                    source == "created_default"
                        ? defaultProjectName
                        : fallbackName,
                    createdBookmark
                )
                workspaceID = id
            }
            selectWorkspace(workspaceID)
            await sendOnboardingWorkspaceStateChanged()
            await send(
                .event(
                    type:
                        "electron-onboarding-pick-workspace-or-create-default-result",
                    payload: .object([
                        "success": .bool(true),
                        "source": .string(source),
                        "root": .string(root.path),
                    ])
                )
            )
            await sendNavigateToWorkspace()
        } catch {
            var fields: [String: CodexJSONValue] = [
                "success": .bool(false),
                "source": .string(source),
                "error": .string(String(describing: error)),
            ]
            if let selectedRoot {
                fields["root"] = .string(selectedRoot.path)
            }
            await send(
                .event(
                    type:
                        "electron-onboarding-pick-workspace-or-create-default-result",
                    payload: .object(fields)
                )
            )
        }
    }

    private func commit(roots: [String]) {
        var existingPaths = Set(
            workspaces().compactMap { workspace -> String? in
                guard let bookmark = workspace.rootBookmarkID,
                      let url = try? resolveBookmark(bookmark)
                else {
                    return nil
                }
                return url.standardizedFileURL.path
            }
        )
        var processedPaths: Set<String> = []

        for rawRoot in roots {
            let root = URL(
                fileURLWithPath: rawRoot,
                isDirectory: true
            ).standardizedFileURL.path
            guard processedPaths.insert(root).inserted else {
                continue
            }
            if existingPaths.contains(root) {
                stagedBookmarksByPath.removeValue(forKey: root)
                continue
            }
            guard let bookmark = stagedBookmarksByPath[root] else {
                continue
            }
            let name = URL(
                fileURLWithPath: root,
                isDirectory: true
            ).lastPathComponent
            do {
                try persistWorkspace(
                    UUID(),
                    name.isEmpty ? "Project" : name,
                    bookmark
                )
                existingPaths.insert(root)
                stagedBookmarksByPath.removeValue(forKey: root)
            } catch {
                continue
            }
        }
    }

    private func createAndSelectDefaultWorkspace(
        projectName: String,
        initializeGitRepository: Bool
    ) async {
        do {
            let root = try createDefaultWorkspace(
                projectName,
                initializeGitRepository
            ).standardizedFileURL
            let createdBookmark = try bookmark(root)
            let workspaceID = UUID()
            try persistWorkspace(
                workspaceID,
                projectName,
                createdBookmark
            )
            selectWorkspace(workspaceID)
            await send(
                .event(
                    type:
                        "electron-onboarding-skip-workspace-result",
                    payload: .object([
                        "success": .bool(true),
                        "root": .string(root.path),
                    ])
                )
            )
            await sendWorkspaceStateChanged()
        } catch {
            await send(
                .event(
                    type:
                        "electron-onboarding-skip-workspace-result",
                    payload: .object([
                        "success": .bool(false),
                        "error": .string(
                            String(describing: error)
                        ),
                    ])
                )
            )
        }
    }

    private func workspace(forRoot root: String) -> Workspace? {
        let canonicalRoot = URL(
            fileURLWithPath: root,
            isDirectory: true
        ).standardizedFileURL.path
        return workspaces().first { workspace in
            guard let bookmark = workspace.rootBookmarkID,
                  let resolved = try? resolveBookmark(bookmark)
            else {
                return false
            }
            return resolved.standardizedFileURL.path == canonicalRoot
        }
    }

    private func addAndSelectRoot(
        _ url: URL,
        preferredName: String? = nil
    ) async {
        let root = url.standardizedFileURL
        let existing = workspace(forRoot: root.path)
        let workspaceID: UUID
        if let existing {
            workspaceID = existing.id
        } else {
            guard let createdBookmark = try? bookmark(root) else {
                await send(
                    .event(
                        type: "workspace-root-option-add-canceled",
                        payload: .object([:])
                    )
                )
                return
            }
            let id = UUID()
            let fallbackName = root.lastPathComponent.isEmpty
                ? "Project"
                : root.lastPathComponent
            do {
                try persistWorkspace(
                    id,
                    preferredName ?? fallbackName,
                    createdBookmark
                )
            } catch {
                await send(
                    .event(
                        type: "workspace-root-option-add-canceled",
                        payload: .object([:])
                    )
                )
                return
            }
            workspaceID = id
        }
        selectWorkspace(workspaceID)
        await sendWorkspaceSelectionChanged(
            includeProjectCollections: true
        )
        await send(
            .event(
                type: "workspace-root-options-updated",
                payload: .object([:])
            )
        )
        await send(
            .event(
                type: "workspace-root-option-added",
                payload: .object([
                    "projectId": existing == nil
                        ? .string(workspaceID.uuidString.lowercased())
                        : .null,
                    "root": .string(root.path),
                ])
            )
        )
    }

    private func sendWorkspaceSelectionChanged(
        includeProjectCollections: Bool
    ) async {
        var keys = ["selected-project"]
        if includeProjectCollections {
            keys.insert("project-order", at: 0)
            keys.insert("local-projects", at: 0)
        }
        await sendGlobalStateChanged(keys: keys)
        await send(
            .event(
                type: "active-workspace-roots-updated",
                payload: .object([:])
            )
        )
    }

    private func sendGlobalStateChanged(keys: [String]) async {
        await send(
            .event(
                type: "global-state-updated",
                payload: .object([
                    "keys": .array(
                        keys.map(CodexJSONValue.string)
                    )
                ])
            )
        )
    }

    private func sendWorkspaceStateChanged() async {
        await send(
            .event(
                type: "active-workspace-roots-updated",
                payload: .object([:])
            )
        )
        await send(
            .event(
                type: "global-state-updated",
                payload: .object([
                    "keys": .array([
                        .string("local-projects"),
                        .string("project-order"),
                        .string("selected-project"),
                    ])
                ])
            )
        )
        await send(
            .event(
                type: "workspace-root-options-updated",
                payload: .object([:])
            )
        )
    }

    private func sendOnboardingWorkspaceStateChanged() async {
        await send(
            .event(
                type: "workspace-root-options-updated",
                payload: .object([:])
            )
        )
        await sendGlobalStateChanged(keys: [
            "local-projects",
            "project-order",
            "selected-project",
        ])
        await send(
            .event(
                type: "active-workspace-roots-updated",
                payload: .object([:])
            )
        )
    }

    private func sendNavigateToWorkspace() async {
        await send(
            .event(
                type: "navigate-to-route",
                payload: .object([
                    "path": .string("/"),
                    "state": .object([
                        "focusComposerNonce": .integer(
                            Int64(
                                Date().timeIntervalSince1970
                                    * 1_000
                            )
                        )
                    ]),
                ])
            )
        )
    }
}
