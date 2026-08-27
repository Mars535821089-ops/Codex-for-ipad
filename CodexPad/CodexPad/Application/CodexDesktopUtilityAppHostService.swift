import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// iPadOS implementations for released AppHost utilities that are platform
/// state rather than renderer UI.
public actor CodexDesktopUtilityAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias ClipboardWriter =
        @Sendable (String) async -> Void
    public typealias BrowserProfileList =
        @Sendable () async throws -> [Value]
    public typealias BrowserProfileImporter =
        @Sendable (Value) async throws -> Value
    public typealias ScheduledTaskList =
        @Sendable (Value) async throws -> Value
    public typealias PerformanceOperation =
        @Sendable (String, Value) async throws -> Value

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unsupportedMethod(service: String, method: String)
    }

    private struct PermissionState: Codable {
        var iabHistoryApprovalMode = "alwaysAsk"
        var webMcpEnabled = false
        var origins: [String: [String]] = [:]

        private enum CodingKeys: String, CodingKey {
            case iabHistoryApprovalMode
            case webMcpEnabled = "webmcp_enabled"
            case origins
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            iabHistoryApprovalMode = try container.decodeIfPresent(
                String.self,
                forKey: .iabHistoryApprovalMode
            ) ?? "alwaysAsk"
            webMcpEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .webMcpEnabled
            ) ?? false
            origins = try container.decodeIfPresent(
                [String: [String]].self,
                forKey: .origins
            ) ?? [:]
        }
    }

    private let stateURL: URL
    private let clipboardWriter: ClipboardWriter
    private let listBrowserProfiles: BrowserProfileList
    private let importBrowserProfile: BrowserProfileImporter
    private let listPluginScheduledTasks: ScheduledTaskList
    private let performanceOperation: PerformanceOperation
    private var permissionState: PermissionState

    public init(
        codexHome: URL,
        clipboardWriter: ClipboardWriter? = nil,
        listBrowserProfiles: BrowserProfileList? = nil,
        importBrowserProfile: BrowserProfileImporter? = nil,
        listPluginScheduledTasks: ScheduledTaskList? = nil,
        performanceOperation: PerformanceOperation? = nil
    ) {
        stateURL = codexHome.appendingPathComponent(
            "browser-use-permissions.json"
        )
        self.clipboardWriter =
            clipboardWriter ?? Self.writeClipboard
        self.listBrowserProfiles = listBrowserProfiles ?? { [] }
        self.importBrowserProfile =
            importBrowserProfile ?? { _ in
                throw Error.invalidArguments
            }
        self.listPluginScheduledTasks =
            listPluginScheduledTasks ?? { _ in
                .object(["groups": .array([])])
            }
        self.performanceOperation =
            performanceOperation ?? { _, _ in .undefined }
        permissionState = (
            try? Data(contentsOf: stateURL)
        ).flatMap {
            try? JSONDecoder().decode(
                PermissionState.self,
                from: $0
            )
        } ?? PermissionState()
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch (service, method) {
        case ("clipboard", "writeText"):
            guard let text = Self.string(arguments?.first) else {
                throw Error.invalidArguments
            }
            await clipboardWriter(text)
            return .undefined

        case (
            "browserUsePermissions",
            "updateIabHistoryApprovalMode"
        ):
            guard let mode = Self.string(arguments?.first),
                  ["alwaysAsk", "neverAsk", "disabled"].contains(mode)
            else {
                throw Error.invalidArguments
            }
            permissionState.iabHistoryApprovalMode = mode
            try persistPermissionState()
            return permissionSnapshot()

        case ("browserUsePermissions", "updateWebMcpEnabled"):
            guard arguments?.count == 1,
                  case let .bool(enabled)? = arguments?.first
            else {
                throw Error.invalidArguments
            }
            permissionState.webMcpEnabled = enabled
            try persistPermissionState()
            return permissionSnapshot()

        case ("browserUsePermissions", "updateOriginRules"):
            guard case let .array(rules)? = arguments?.first else {
                throw Error.invalidArguments
            }
            for rule in rules {
                try applyOriginRule(rule)
            }
            try persistPermissionState()
            return permissionSnapshot()

        case (
            "browserProfileImport",
            "listImportableBrowserProfiles"
        ):
            return .array(try await listBrowserProfiles())

        case ("browserProfileImport", "importBrowserProfile"):
            guard let request = arguments?.first,
                  case .object = request
            else {
                throw Error.invalidArguments
            }
            return try await importBrowserProfile(request)

        case ("pluginScheduledTasks", "list"):
            guard let request = arguments?.first,
                  case .object = request
            else {
                throw Error.invalidArguments
            }
            return try await listPluginScheduledTasks(request)

        case (
            "performanceTelemetry",
            "startSpanCpuSampling"
        ),
        (
            "performanceTelemetry",
            "cancelSpanCpuSampling"
        ),
        (
            "performanceTelemetry",
            "finishSpanCpuSampling"
        ):
            guard let value = arguments?.first else {
                throw Error.invalidArguments
            }
            return try await performanceOperation(method, value)

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    private func applyOriginRule(_ value: Value) throws {
        guard case let .object(fields) = value,
              let action = Self.string(fields["action"]),
              let kind = Self.string(fields["kind"]),
              let resource = Self.string(fields["resource"]),
              let rawOrigin = Self.string(fields["origin"]),
              ["add", "remove"].contains(action),
              ["allowed", "denied"].contains(kind),
              let origin = Self.normalizedOrigin(rawOrigin)
        else {
            throw Error.invalidArguments
        }
        let prefix: String
        switch resource {
        case "navigation", "browser", "origin":
            prefix = ""
        case "download":
            prefix = "download."
        case "upload":
            prefix = "upload."
        case "fullCdp", "full_cdp":
            prefix = "fullCdp."
        default:
            throw Error.invalidArguments
        }
        let key = prefix + kind
        let opposite = prefix
            + (kind == "allowed" ? "denied" : "allowed")
        var values = permissionState.origins[key] ?? []
        var oppositeValues = permissionState.origins[opposite] ?? []
        if action == "add" {
            if !values.contains(origin) {
                values.append(origin)
            }
            oppositeValues.removeAll { $0 == origin }
        } else {
            values.removeAll { $0 == origin }
        }
        permissionState.origins[key] = values
        permissionState.origins[opposite] = oppositeValues
    }

    private func permissionSnapshot() -> Value {
        func values(_ key: String) -> Value {
            .array(
                (permissionState.origins[key] ?? []).map(
                    Value.string
                )
            )
        }
        return .object([
            "fullCdpAccessEnabled": .bool(false),
            "webMcpEnabled": .bool(permissionState.webMcpEnabled),
            "approvalMode": .string("alwaysAsk"),
            "chromeHistoryApprovalMode": .string("alwaysAsk"),
            "iabHistoryApprovalMode": .string(
                permissionState.iabHistoryApprovalMode
            ),
            "downloadApprovalMode": .string("alwaysAsk"),
            "uploadApprovalMode": .string("alwaysAsk"),
            "allowedOrigins": values("allowed"),
            "deniedOrigins": values("denied"),
            "allowedDownloadOrigins": values("download.allowed"),
            "deniedDownloadOrigins": values("download.denied"),
            "allowedUploadOrigins": values("upload.allowed"),
            "deniedUploadOrigins": values("upload.denied"),
            "allowedFullCdpOrigins": values("fullCdp.allowed"),
            "deniedFullCdpOrigins": values("fullCdp.denied"),
        ])
    }

    private func persistPermissionState() throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(permissionState).write(
            to: stateURL,
            options: .atomic
        )
    }

    private static func normalizedOrigin(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#,
            options: .regularExpression
        ) == nil ? "https://\(trimmed)" : trimmed
        guard let components = URLComponents(string: candidate),
              ["http", "https"].contains(components.scheme),
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }
        var origin = "\(components.scheme!)://\(host)"
        if let port = components.port {
            origin += ":\(port)"
        }
        return origin
    }

    private static func string(_ value: Value?) -> String? {
        guard case let .string(string)? = value else {
            return nil
        }
        return string
    }

    private static func writeClipboard(_ text: String) async {
        #if canImport(UIKit)
        await MainActor.run {
            UIPasteboard.general.string = text
        }
        #else
        _ = text
        #endif
    }
}
