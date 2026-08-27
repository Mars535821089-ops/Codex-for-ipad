#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

/// Builds the renderer bootstrap returned by Electron's
/// `getInitialSidebarBootstrap` IPC method.
///
/// iPad has no Electron main process, so returning `null` leaves the Owl
/// renderer without its initial catalog/global-state snapshot.  Keep this
/// payload deliberately conservative: it only mirrors state already owned by
/// the native session/persistence stores and never invents an account or a
/// thread.
public enum CodexDesktopInitialSidebarBootstrap {
    public static let globalStateKeys: [String] = [
        "desktop-first-seen-at-ms",
        "local-projects",
        "selected-project",
        "project-appearances",
        "pinned-thread-ids",
        "pinned-project-ids",
        "sidebar-project-thread-orders",
        "sidebar-thread-metadata",
        "thread-project-assignments",
        "thread-workspace-root-hints",
        "projectless-thread-ids",
        "remote-projects",
        "project-order",
        "connection-group-order",
        "remote-cwds-by-host-and-workspace",
        "added-remote-control-env-ids",
        "remote-connection-auto-connect-by-host-id",
    ]

    public static func make(
        state: CodexSessionState,
        persistedAtoms: [String: CodexJSONValue],
        selectedProject: CodexJSONValue?,
        pinnedThreadIDs: [String],
        threadProjectAssignments: CodexJSONValue,
        localProjects: [String: CodexJSONValue] = [:],
        projectOrder: [String] = []
    ) -> CodexJSONValue {
        let workspaces = state.workspaces
        // Electron's local-project manager returns paths, not project objects.
        // Owl immediately treats each root as a string (including calling
        // `.trim()` while normalising it), so never send the native workspace
        // bookkeeping object here.
        var roots = workspaces.reduce(into: [String]()) { roots, workspace in
            guard let root = workspace.rootBookmarkID, !roots.contains(root) else {
                return
            }
            roots.append(root)
        }
        var labels: [String: String] = Dictionary(
            workspaces.compactMap { workspace in
                guard let root = workspace.rootBookmarkID else { return nil }
                let label = workspace.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                return (root, label)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // A restored local project can outlive the transient workspace array.
        // The released renderer uses these persisted roots to enable its file
        // search command, so carry them into the initial bootstrap as well.
        for value in localProjects.values {
            guard case let .object(fields) = value,
                  case let .array(rootValues)? = fields["rootPaths"]
            else {
                continue
            }
            let projectName: String?
            if case let .string(name)? = fields["name"] {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                projectName = trimmed.isEmpty ? nil : trimmed
            } else {
                projectName = nil
            }
            for rootValue in rootValues {
                guard case let .string(root) = rootValue,
                      !root.isEmpty,
                      !roots.contains(root)
                else {
                    continue
                }
                roots.append(root)
                if let projectName {
                    labels[root] = projectName
                }
            }
        }
        let workspaceRootOptions = CodexJSONValue.object([
            "roots": .array(roots.map(CodexJSONValue.string)),
            "labels": .object(labels.mapValues(CodexJSONValue.string)),
        ])

        var values = persistedAtoms
        values["selected-project"] = selectedProject ?? .null
        values["pinned-thread-ids"] = .array(
            pinnedThreadIDs.map(CodexJSONValue.string)
        )
        values["thread-project-assignments"] = threadProjectAssignments
        values["local-projects"] = .object(localProjects)
        values["project-order"] = .array(projectOrder.map(CodexJSONValue.string))

        let entries = state.threads
            .filter { !state.archivedThreadIDs.contains($0.id) }
            .map { thread in
                let workspace = workspaces.first { $0.id == thread.workspaceID }
                return CodexJSONValue.object([
                    // `getInitialSidebarBootstrap` is consumed directly by
                    // the renderer's catalog store. Unlike the persisted
                    // SQLite row, this bridge payload is already camelCase.
                    "hostId": .string("local"),
                    "threadId": .string(thread.id.uuidString.lowercased()),
                    "displayTitle": .string(thread.title),
                    "sourceCreatedAt": .integer(0),
                    "sourceUpdatedAt": .integer(0),
                    "sourceRecencyAt": .integer(0),
                    "cwd": .string(workspace?.rootBookmarkID ?? ""),
                    "sourceKind": .string("appServer"),
                    "sourceDetail": .null,
                    "threadSource": .null,
                    "modelProvider": .string(""),
                    "gitBranch": .null,
                ])
            }

        let globalStateEntries: [CodexJSONValue] = globalStateKeys.map { key in
            .object(["key": .string(key), "value": values[key] ?? .null])
        }

        return .object([
            "catalogEntries": .array(entries),
            "catalogHostIds": .array([.string("local")]),
            "globalStateEntries": .array(globalStateEntries),
            "workspaceRootOptions": workspaceRootOptions,
            "projectlessWorkspaceRoot": .object([
                "workspaceRoot": .string(""),
            ]),
        ])
    }
}
