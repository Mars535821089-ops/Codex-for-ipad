import Foundation

public struct CodexReasoningEffort:
    RawRepresentable,
    CaseIterable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "A reasoning effort must be a non-empty string."
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let none = Self(rawValue: "none")!
    public static let minimal = Self(rawValue: "minimal")!
    public static let low = Self(rawValue: "low")!
    public static let medium = Self(rawValue: "medium")!
    public static let high = Self(rawValue: "high")!
    public static let xhigh = Self(rawValue: "xhigh")!
    public static let max = Self(rawValue: "max")!
    public static let ultra = Self(rawValue: "ultra")!

    public static let allCases: [Self] = [
        .none,
        .minimal,
        .low,
        .medium,
        .high,
        .xhigh,
        .max,
        .ultra,
    ]

    public var displayName: String {
        switch rawValue {
        case Self.none.rawValue: "None"
        case Self.minimal.rawValue: "Minimal"
        case Self.low.rawValue: "Light"
        case Self.medium.rawValue: "Medium"
        case Self.high.rawValue: "High"
        case Self.xhigh.rawValue: "Extra High"
        case Self.max.rawValue: "Max"
        case Self.ultra.rawValue: "Ultra"
        default: rawValue
        }
    }
}

public enum CodexModelInputModality:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case text
    case image
    case audio
}

public struct CodexModelReasoningEffortOption:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let reasoningEffort: CodexReasoningEffort
    public let description: String

    public init(
        reasoningEffort: CodexReasoningEffort,
        description: String
    ) {
        self.reasoningEffort = reasoningEffort
        self.description = description
    }
}

public struct CodexModelAvailabilityNUX:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct CodexModelServiceTier:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let id: String
    public let name: String
    public let description: String

    public init(id: String, name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct CodexModelUpgradeInfo:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let model: String
    public let upgradeCopy: String?
    public let modelLink: String?
    public let migrationMarkdown: String?

    public init(
        model: String,
        upgradeCopy: String? = nil,
        modelLink: String? = nil,
        migrationMarkdown: String? = nil
    ) {
        self.model = model
        self.upgradeCopy = upgradeCopy
        self.modelLink = modelLink
        self.migrationMarkdown = migrationMarkdown
    }
}

public struct CodexModelConfiguration:
    Codable,
    Equatable,
    Sendable,
    Identifiable
{
    public let id: String
    public let model: String
    public let upgrade: String?
    public let upgradeInfo: CodexModelUpgradeInfo?
    public let availabilityNux: CodexModelAvailabilityNUX?
    public let displayName: String
    public let description: String
    public let hidden: Bool
    public let reasoningEffortOptions:
        [CodexModelReasoningEffortOption]
    public let defaultReasoningEffort: CodexReasoningEffort
    public let inputModalities: [CodexModelInputModality]
    public let supportsPersonality: Bool
    public let additionalSpeedTiers: [String]
    public let serviceTiers: [CodexModelServiceTier]
    public let defaultServiceTier: String?
    public let isDefault: Bool

    public var supportedReasoningEfforts: [CodexReasoningEffort] {
        reasoningEffortOptions.map(\.reasoningEffort)
    }

    public init(
        id: String,
        model: String,
        upgrade: String? = nil,
        upgradeInfo: CodexModelUpgradeInfo? = nil,
        availabilityNux: CodexModelAvailabilityNUX? = nil,
        displayName: String,
        description: String,
        hidden: Bool,
        reasoningEffortOptions: [CodexModelReasoningEffortOption],
        defaultReasoningEffort: CodexReasoningEffort,
        inputModalities: [CodexModelInputModality] = [.text, .image],
        supportsPersonality: Bool = false,
        additionalSpeedTiers: [String] = [],
        serviceTiers: [CodexModelServiceTier] = [],
        defaultServiceTier: String? = nil,
        isDefault: Bool
    ) {
        self.id = id
        self.model = model
        self.upgrade = upgrade
        self.upgradeInfo = upgradeInfo
        self.availabilityNux = availabilityNux
        self.displayName = displayName
        self.description = description
        self.hidden = hidden
        self.reasoningEffortOptions = reasoningEffortOptions
        self.defaultReasoningEffort = defaultReasoningEffort
        self.inputModalities = inputModalities
        self.supportsPersonality = supportsPersonality
        self.additionalSpeedTiers = additionalSpeedTiers
        self.serviceTiers = serviceTiers
        self.defaultServiceTier = defaultServiceTier
        self.isDefault = isDefault
    }

    /// Compatibility initializer for the generated build snapshot. Runtime
    /// model selection uses the complete app-server catalog instead.
    public init(
        id: String,
        displayName: String,
        description: String,
        defaultReasoningEffort: CodexReasoningEffort,
        supportedReasoningEfforts: [CodexReasoningEffort]
    ) {
        self.init(
            id: id,
            model: id,
            displayName: displayName,
            description: description,
            hidden: false,
            reasoningEffortOptions: supportedReasoningEfforts.map {
                .init(
                    reasoningEffort: $0,
                    description: $0.displayName
                )
            },
            defaultReasoningEffort: defaultReasoningEffort,
            isDefault: false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case upgrade
        case upgradeInfo
        case availabilityNux
        case displayName
        case description
        case hidden
        case reasoningEffortOptions = "supportedReasoningEfforts"
        case defaultReasoningEffort
        case inputModalities
        case supportsPersonality
        case additionalSpeedTiers
        case serviceTiers
        case defaultServiceTier
        case isDefault
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        model = try container.decode(String.self, forKey: .model)
        upgrade = try container.decodeIfPresent(String.self, forKey: .upgrade)
        upgradeInfo = try container.decodeIfPresent(
            CodexModelUpgradeInfo.self,
            forKey: .upgradeInfo
        )
        availabilityNux = try container.decodeIfPresent(
            CodexModelAvailabilityNUX.self,
            forKey: .availabilityNux
        )
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decode(String.self, forKey: .description)
        hidden = try container.decode(Bool.self, forKey: .hidden)
        reasoningEffortOptions = try container.decode(
            [CodexModelReasoningEffortOption].self,
            forKey: .reasoningEffortOptions
        )
        defaultReasoningEffort = try container.decode(
            CodexReasoningEffort.self,
            forKey: .defaultReasoningEffort
        )
        inputModalities = try container.decodeIfPresent(
            [CodexModelInputModality].self,
            forKey: .inputModalities
        ) ?? [.text, .image]
        supportsPersonality = try container.decodeIfPresent(
            Bool.self,
            forKey: .supportsPersonality
        ) ?? false
        additionalSpeedTiers = try container.decodeIfPresent(
            [String].self,
            forKey: .additionalSpeedTiers
        ) ?? []
        serviceTiers = try container.decodeIfPresent(
            [CodexModelServiceTier].self,
            forKey: .serviceTiers
        ) ?? []
        defaultServiceTier = try container.decodeIfPresent(
            String.self,
            forKey: .defaultServiceTier
        )
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
    }
}

public enum CodexModelCatalog {
    public static let defaultModel = current[0]

    public static func model(id: String) -> CodexModelConfiguration? {
        current.first { $0.id == id }
    }

    public static func reasoningEffort(
        rawValue: String,
        forModelID modelID: String
    ) -> CodexReasoningEffort {
        let model = model(id: modelID) ?? defaultModel
        guard let requested = CodexReasoningEffort(rawValue: rawValue),
              model.supportedReasoningEfforts.contains(requested)
        else {
            return model.defaultReasoningEffort
        }
        return requested
    }
}
