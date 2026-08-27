#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public struct CodexUsageCenterModel: Equatable, Sendable {
    public enum BreakdownDimension: Sendable {
        case model
        case reasoningEffort
        case speed
    }

    public struct BreakdownRow: Equatable, Sendable, Identifiable {
        public let label: String
        public let micros: Int64
        public var id: String { label }

        public init(label: String, micros: Int64) {
            self.label = label
            self.micros = micros
        }
    }

    public let threadID: String
    public let creditsMicros: Int64
    public let usdMicros: Int64?
    private let modelBreakdown: [BreakdownRow]
    private let reasoningEffortBreakdown: [BreakdownRow]
    private let speedBreakdown: [BreakdownRow]

    public init?(payload: CodexJSONValue) {
        guard case let .object(root) = payload,
              case let .object(thread)? = root["threadUsage"],
              case let .string(threadID)? = thread["threadId"],
              case let .integer(creditsMicros)? = thread["estimatedUsageCreditsMicros"]
        else { return nil }

        self.threadID = threadID
        self.creditsMicros = creditsMicros
        if case let .integer(value)? = thread["estimatedUsageUsdMicros"] {
            self.usdMicros = value
        } else {
            self.usdMicros = nil
        }

        var model: [String: Int64] = [:]
        var reasoning: [String: Int64] = [:]
        var speed: [String: Int64] = [:]
        if case let .array(groups)? = thread["groups"] {
            for group in groups {
                guard case let .object(group) = group,
                      case let .integer(micros)? = group["estimatedUsageCreditsMicros"]
                else { continue }
                if case let .string(value)? = group["model"] { model[value, default: 0] += micros }
                if case let .string(value)? = group["reasoningEffort"] { reasoning[value, default: 0] += micros }
                if case let .string(value)? = group["speed"] { speed[value, default: 0] += micros }
            }
        }
        self.modelBreakdown = Self.rows(model)
        self.reasoningEffortBreakdown = Self.rows(reasoning)
        self.speedBreakdown = Self.rows(speed)
    }

    public func breakdown(for dimension: BreakdownDimension) -> [BreakdownRow] {
        switch dimension {
        case .model: return modelBreakdown
        case .reasoningEffort: return reasoningEffortBreakdown
        case .speed: return speedBreakdown
        }
    }

    public var hasBreakdown: Bool {
        !modelBreakdown.isEmpty || !reasoningEffortBreakdown.isEmpty || !speedBreakdown.isEmpty
    }

    private static func rows(_ values: [String: Int64]) -> [BreakdownRow] {
        values.map { BreakdownRow(label: $0.key, micros: $0.value) }
            .sorted { lhs, rhs in
                lhs.micros == rhs.micros ? lhs.label < rhs.label : lhs.micros > rhs.micros
            }
    }
}
