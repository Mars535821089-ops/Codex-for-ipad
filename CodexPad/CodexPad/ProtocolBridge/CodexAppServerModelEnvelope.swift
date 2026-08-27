#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

/// The exact optionality used by the stable `model/list` app-server method.
///
/// The app server distinguishes a missing field from an explicit JSON `null`,
/// so these values intentionally use `CodexWireOptional` rather than Swift
/// optionals.
public struct CodexModelListParams: Equatable, Sendable {
    public var cursor: CodexWireOptional<String>
    public var limit: CodexWireOptional<UInt32>
    public var includeHidden: CodexWireOptional<Bool>

    public init(
        cursor: CodexWireOptional<String> = .omitted,
        limit: CodexWireOptional<UInt32> = .omitted,
        includeHidden: CodexWireOptional<Bool> = .omitted
    ) {
        self.cursor = cursor
        self.limit = limit
        self.includeHidden = includeHidden
    }
}

public struct CodexModelListResponse:
    Codable,
    Equatable,
    Sendable
{
    public let data: [CodexModelConfiguration]
    public let nextCursor: String?

    public init(
        data: [CodexModelConfiguration],
        nextCursor: String? = nil
    ) {
        self.data = data
        self.nextCursor = nextCursor
    }
}

public struct CodexModelProviderCapabilities:
    Codable,
    Equatable,
    Sendable
{
    public let namespaceTools: Bool
    public let imageGeneration: Bool
    public let webSearch: Bool

    public init(
        namespaceTools: Bool,
        imageGeneration: Bool,
        webSearch: Bool
    ) {
        self.namespaceTools = namespaceTools
        self.imageGeneration = imageGeneration
        self.webSearch = webSearch
    }
}

/// Process-local configuration for the embedded model manager. The access
/// token is encoded only for the direct FFI submit and is neither persisted in
/// the session database nor retained in Swift view state.
public struct CodexModelCatalogRuntimeConfiguration: Sendable {
    public let providerID: String
    public let accountIdentity: String?
    public let accessToken: String?
    public let accountID: String?
    public let baseURL: String?
    public let chatGPTAuth: Bool
    public let cacheDirectory: String?
    public let capabilities: CodexModelProviderCapabilities?

    public init(
        providerID: String,
        accountIdentity: String?,
        accessToken: String?,
        accountID: String?,
        baseURL: String?,
        chatGPTAuth: Bool,
        cacheDirectory: String?,
        capabilities: CodexModelProviderCapabilities?
    ) {
        self.providerID = providerID
        self.accountIdentity = accountIdentity
        self.accessToken = accessToken
        self.accountID = accountID
        self.baseURL = baseURL
        self.chatGPTAuth = chatGPTAuth
        self.cacheDirectory = cacheDirectory
        self.capabilities = capabilities
    }
}

public enum CodexModelCatalogCommand: Sendable {
    case configure(CodexModelCatalogRuntimeConfiguration)
    case clear

    public func encodedData() throws -> Data {
        switch self {
        case let .configure(configuration):
            return try encodeModelRequest(
                ConfigureModelCatalogCommandWire(configuration)
            )
        case .clear:
            return try encodeModelRequest(ClearModelCatalogCommandWire())
        }
    }
}

public enum CodexAppServerModelRequest: Equatable, Sendable {
    case list(
        id: CodexAppServerRequestID,
        params: CodexModelListParams
    )
    case providerCapabilitiesRead(id: CodexAppServerRequestID)

    public var id: CodexAppServerRequestID {
        switch self {
        case let .list(id, _), let .providerCapabilitiesRead(id):
            id
        }
    }

    public func encodedData() throws -> Data {
        switch self {
        case let .list(id, params):
            return try encodeModelRequest(
                ModelRequestEnvelope(
                    id: id,
                    method: "model/list",
                    params: ModelListParamsWire(params)
                )
            )
        case let .providerCapabilitiesRead(id):
            return try encodeModelRequest(
                ModelRequestEnvelope(
                    id: id,
                    method: "modelProvider/capabilities/read",
                    params: EmptyModelParams()
                )
            )
        }
    }
}

private struct ModelRequestEnvelope<Params: Encodable>: Encodable {
    let id: CodexAppServerRequestID
    let method: String
    let params: Params
}

private struct ModelListParamsWire: Encodable {
    let params: CodexModelListParams

    init(_ params: CodexModelListParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case cursor
        case limit
        case includeHidden
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeModelWireOptional(
            params.cursor,
            forKey: .cursor,
            into: &container
        )
        try encodeModelWireOptional(
            params.limit,
            forKey: .limit,
            into: &container
        )
        try encodeModelWireOptional(
            params.includeHidden,
            forKey: .includeHidden,
            into: &container
        )
    }
}

private struct EmptyModelParams: Encodable {}

private struct ConfigureModelCatalogCommandWire: Encodable {
    let configuration: CodexModelCatalogRuntimeConfiguration

    init(_ configuration: CodexModelCatalogRuntimeConfiguration) {
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case providerID = "providerId"
        case accountIdentity
        case accessToken
        case accountID = "accountId"
        case baseURL = "baseUrl"
        case chatGPTAuth = "chatgptAuth"
        case cacheDirectory
        case capabilities
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("model.catalog.configure", forKey: .kind)
        try container.encode(configuration.providerID, forKey: .providerID)
        try encodeNullable(
            configuration.accountIdentity,
            forKey: .accountIdentity,
            into: &container
        )
        try encodeNullable(
            configuration.accessToken,
            forKey: .accessToken,
            into: &container
        )
        try encodeNullable(
            configuration.accountID,
            forKey: .accountID,
            into: &container
        )
        try encodeNullable(
            configuration.baseURL,
            forKey: .baseURL,
            into: &container
        )
        try container.encode(configuration.chatGPTAuth, forKey: .chatGPTAuth)
        try encodeNullable(
            configuration.cacheDirectory,
            forKey: .cacheDirectory,
            into: &container
        )
        try encodeNullable(
            configuration.capabilities,
            forKey: .capabilities,
            into: &container
        )
    }
}

private struct ClearModelCatalogCommandWire: Encodable {
    let kind = "model.catalog.clear"
}

private func encodeNullable<Value, Key>(
    _ value: Value?,
    forKey key: Key,
    into container: inout KeyedEncodingContainer<Key>
) throws where Value: Encodable, Key: CodingKey {
    if let value {
        try container.encode(value, forKey: key)
    } else {
        try container.encodeNil(forKey: key)
    }
}

private func encodeModelWireOptional<Value, Key>(
    _ field: CodexWireOptional<Value>,
    forKey key: Key,
    into container: inout KeyedEncodingContainer<Key>
) throws where
    Value: Encodable & Equatable & Sendable,
    Key: CodingKey
{
    switch field {
    case .omitted:
        break
    case .null:
        try container.encodeNil(forKey: key)
    case let .value(value):
        try container.encode(value, forKey: key)
    }
}

private func encodeModelRequest(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
