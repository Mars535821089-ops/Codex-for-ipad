#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public enum CodexExperimentalFeatureStage:
    String,
    Equatable,
    Sendable
{
    case beta
    case underDevelopment
    case stable
    case deprecated
    case removed
}

public struct CodexExperimentalFeatureSpec:
    Equatable,
    Sendable
{
    public let name: String
    public let stage: CodexExperimentalFeatureStage
    public let displayName: String?
    public let description: String?
    public let announcement: String?
    public let defaultEnabled: Bool

    public init(
        name: String,
        stage: CodexExperimentalFeatureStage,
        displayName: String?,
        description: String?,
        announcement: String?,
        defaultEnabled: Bool
    ) {
        self.name = name
        self.stage = stage
        self.displayName = displayName
        self.description = description
        self.announcement = announcement
        self.defaultEnabled = defaultEnabled
    }
}

public struct CodexExperimentalFeature:
    Equatable,
    Sendable
{
    public let name: String
    public let stage: CodexExperimentalFeatureStage
    public let displayName: String?
    public let description: String?
    public let announcement: String?
    public let enabled: Bool
    public let defaultEnabled: Bool
}

public struct CodexExperimentalFeaturePage:
    Equatable,
    Sendable
{
    public let data: [CodexExperimentalFeature]
    public let nextCursor: String?
}

public struct CodexPermissionProfileSummary:
    Equatable,
    Sendable
{
    public let id: String
    public let description: String?
    public let allowed: Bool
}

public struct CodexPermissionProfilePage:
    Equatable,
    Sendable
{
    public let data: [CodexPermissionProfileSummary]
    public let nextCursor: String?
}

public struct CodexCollaborationModeMask:
    Equatable,
    Sendable
{
    public let name: String
    public let mode: String?
    public let model: String?
    public let reasoningEffort: String?

    public init(
        name: String,
        mode: String?,
        model: String?,
        reasoningEffort: String?
    ) {
        self.name = name
        self.mode = mode
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public enum CodexSettingsCatalogError:
    Error,
    Equatable,
    Sendable
{
    case invalidCursor(String)
    case cursorExceedsTotal(cursor: Int, total: Int, catalog: String)

    public var message: String {
        switch self {
        case let .invalidCursor(cursor):
            "invalid cursor: \(cursor)"
        case let .cursorExceedsTotal(cursor, total, catalog):
            "cursor \(cursor) exceeds total \(catalog) \(total)"
        }
    }
}

/// Mirrors the released app-server feature and permission-profile catalogs.
///
/// The feature registry is generated from the exact Rust source shipped with
/// the reversed desktop release. Runtime enablement is stored under the same
/// `[features]` config keys used by desktop Codex.
@MainActor
public final class CodexExperimentalSettingsService {
    public static let supportedEnablement: Set<String> = [
        "auth_elicitation",
        "mcp_2026_07_28",
        "memories",
        "mentions_v2",
        "remote_control",
        "remote_plugin",
        "tool_suggest",
    ]

    private static let builtInPermissionProfileIDs = [
        ":read-only",
        ":workspace",
        ":danger-full-access",
    ]

    private let configStore: CodexDesktopConfigStore
    private let catalog: [CodexExperimentalFeatureSpec]
    private let allowedPermissionProfiles: Set<String>?

    public init(
        configStore: CodexDesktopConfigStore,
        catalog: [CodexExperimentalFeatureSpec] =
            CodexExperimentalFeatureSpec.releasedCatalog,
        allowedPermissionProfiles: Set<String>? = nil
    ) {
        self.configStore = configStore
        self.catalog = catalog
        self.allowedPermissionProfiles = allowedPermissionProfiles
    }

    public var releasedFeatureCount: Int { catalog.count }

    public func listCollaborationModes()
        -> [CodexCollaborationModeMask]
    {
        [
            CodexCollaborationModeMask(
                name: "Plan",
                mode: "plan",
                model: nil,
                reasoningEffort: "medium"
            ),
            CodexCollaborationModeMask(
                name: "Default",
                mode: "default",
                model: nil,
                reasoningEffort: nil
            ),
        ]
    }

    public func listExperimentalFeatures(
        cursor: String?,
        limit: Int?
    ) throws -> CodexExperimentalFeaturePage {
        let overrides = featureOverrides()
        let values = catalog.map { spec in
            CodexExperimentalFeature(
                name: spec.name,
                stage: spec.stage,
                displayName: spec.displayName,
                description: spec.description,
                announcement: spec.announcement,
                enabled: overrides[spec.name] ?? spec.defaultEnabled,
                defaultEnabled: spec.defaultEnabled
            )
        }
        let page = try paginate(
            values,
            cursor: cursor,
            limit: limit,
            catalogName: "feature flags"
        )
        return CodexExperimentalFeaturePage(
            data: page.data,
            nextCursor: page.nextCursor
        )
    }

    public func setExperimentalFeatureEnablement(
        _ enablement: [String: Bool]
    ) {
        let edits = enablement
            .filter { Self.supportedEnablement.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map {
                (
                    keyPath: "features.\($0.key)",
                    value: CodexJSONValue.bool($0.value),
                    mergeStrategy: "replace"
                )
            }
        guard !edits.isEmpty else { return }
        _ = configStore.batchWrite(edits: edits)
    }

    public func listPermissionProfiles(
        cursor: String?,
        limit: Int?,
        cwd _: String?
    ) throws -> CodexPermissionProfilePage {
        let declared = declaredPermissionProfiles()
        var values = Self.builtInPermissionProfileIDs.map { id in
            CodexPermissionProfileSummary(
                id: id,
                description: nil,
                allowed: isAllowedPermissionProfile(id)
            )
        }
        values.append(
            contentsOf: declared.keys.sorted().map { id in
                let profile = declared[id] ?? [:]
                let description: String?
                if case let .string(value)? = profile["description"] {
                    description = value
                } else {
                    description = nil
                }
                return CodexPermissionProfileSummary(
                    id: id,
                    description: description,
                    allowed: isAllowedPermissionProfile(id)
                        && resolvesPermissionProfile(
                            id,
                            declared: declared,
                            visited: []
                        )
                )
            }
        )
        let page = try paginate(
            values,
            cursor: cursor,
            limit: limit,
            catalogName: "permission profiles"
        )
        return CodexPermissionProfilePage(
            data: page.data,
            nextCursor: page.nextCursor
        )
    }

    private func featureOverrides() -> [String: Bool] {
        guard case let .object(features)? =
            configStore.snapshot["features"]
        else {
            return [:]
        }
        return features.reduce(into: [:]) { result, entry in
            guard case let .bool(value) = entry.value else { return }
            result[entry.key] = value
        }
    }

    private func declaredPermissionProfiles()
        -> [String: [String: CodexJSONValue]]
    {
        guard case let .object(permissions)? =
            configStore.snapshot["permissions"]
        else {
            return [:]
        }
        return permissions.reduce(into: [:]) { result, entry in
            guard !entry.key.hasPrefix(":"),
                  case let .object(profile) = entry.value
            else {
                return
            }
            result[entry.key] = profile
        }
    }

    private func isAllowedPermissionProfile(_ id: String) -> Bool {
        allowedPermissionProfiles?.contains(id) ?? true
    }

    private func resolvesPermissionProfile(
        _ id: String,
        declared: [String: [String: CodexJSONValue]],
        visited: Set<String>
    ) -> Bool {
        guard !visited.contains(id),
              let profile = declared[id]
        else {
            return false
        }
        guard case let .string(parent)? = profile["extends"] else {
            return true
        }
        if parent == ":read-only" || parent == ":workspace" {
            return true
        }
        guard !parent.hasPrefix(":") else { return false }
        var nextVisited = visited
        nextVisited.insert(id)
        return resolvesPermissionProfile(
            parent,
            declared: declared,
            visited: nextVisited
        )
    }

    private func paginate<Value>(
        _ values: [Value],
        cursor: String?,
        limit: Int?,
        catalogName: String
    ) throws -> (data: [Value], nextCursor: String?) {
        let total = values.count
        let start: Int
        if let cursor {
            guard let decoded = Int(cursor), decoded >= 0 else {
                throw CodexSettingsCatalogError.invalidCursor(cursor)
            }
            start = decoded
        } else {
            start = 0
        }
        guard start <= total else {
            throw CodexSettingsCatalogError.cursorExceedsTotal(
                cursor: start,
                total: total,
                catalog: catalogName
            )
        }
        guard total > 0 else { return ([], nil) }
        let effectiveLimit = max(1, limit ?? total)
        let end = min(total, start + effectiveLimit)
        return (
            Array(values[start ..< end]),
            end < total ? String(end) : nil
        )
    }
}
