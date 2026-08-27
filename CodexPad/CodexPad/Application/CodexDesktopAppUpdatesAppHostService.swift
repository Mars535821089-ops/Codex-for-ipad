import Foundation

/// Released desktop `appUpdates` AppHost surface retained only for renderer
/// protocol compatibility. Product-side automatic updates are intentionally
/// removed: iPadOS never downloads, stages, installs, or persists an update
/// request. Manual release scripts remain the only supported upgrade path.
public actor CodexDesktopAppUpdatesAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value

    public struct QueryParameters: Equatable, Sendable, Codable {
        public let beta: Bool
        public let planType: String?

        public init(beta: Bool, planType: String?) {
            self.beta = beta
            self.planType = planType
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unavailable(method: String)
        case unsupportedMethod(String)
    }

    public init() {}

    public func invoke(
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch method {
        case "setSparkleQueryParams":
            _ = try Self.queryParameters(arguments)
            throw Error.unavailable(method: method)

        case "checkForUpdates":
            try Self.requireNoArguments(arguments)
            throw Error.unavailable(method: method)

        case "installUpdate":
            try Self.requireNoArguments(arguments)
            throw Error.unavailable(method: method)

        default:
            throw Error.unsupportedMethod(method)
        }
    }

    private static func queryParameters(
        _ arguments: [Value]?
    ) throws -> QueryParameters {
        guard let arguments,
              arguments.count == 1,
              case let .object(fields) = arguments[0],
              case let .bool(beta)? = fields["beta"]
        else {
            throw Error.invalidArguments
        }

        let planType: String?
        switch fields["planType"] {
        case nil, .null?, .undefined?:
            planType = nil
        case let .string(value)?:
            planType = value
        default:
            throw Error.invalidArguments
        }

        return QueryParameters(beta: beta, planType: planType)
    }

    private static func requireNoArguments(
        _ arguments: [Value]?
    ) throws {
        guard arguments?.isEmpty != false else {
            throw Error.invalidArguments
        }
    }
}
