import CodexPadDomain
import Foundation
import Testing
@testable import CodexPadProtocolBridge

@Test
func modelListRequestPreservesOmittedNullAndValueParams() throws {
    let omitted = CodexAppServerModelRequest.list(
        id: .string("models-omitted"),
        params: .init()
    )
    let null = CodexAppServerModelRequest.list(
        id: .integer(7),
        params: .init(
            cursor: .null,
            limit: .null,
            includeHidden: .null
        )
    )
    let values = CodexAppServerModelRequest.list(
        id: .string("models-values"),
        params: .init(
            cursor: .value("opaque-cursor"),
            limit: .value(25),
            includeHidden: .value(true)
        )
    )

    #expect(
        try omitted.encodedData()
            == Data(
                #"{"id":"models-omitted","method":"model/list","params":{}}"#.utf8
            )
    )
    #expect(
        try null.encodedData()
            == Data(
                #"{"id":7,"method":"model/list","params":{"cursor":null,"includeHidden":null,"limit":null}}"#.utf8
            )
    )
    #expect(
        try values.encodedData()
            == Data(
                #"{"id":"models-values","method":"model/list","params":{"cursor":"opaque-cursor","includeHidden":true,"limit":25}}"#.utf8
            )
    )
}

@Test
func modelProviderCapabilitiesRequestUsesTheStableEmptyParamsShape() throws {
    let request = CodexAppServerModelRequest.providerCapabilitiesRead(
        id: .integer(8)
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":8,"method":"modelProvider/capabilities/read","params":{}}"#.utf8
            )
    )
}

@Test
func modelCatalogRuntimeCommandsEncodeEveryEphemeralConfigurationField() throws {
    let configured = CodexModelCatalogCommand.configure(
        .init(
            providerID: "openai",
            accountIdentity: "account-cache-partition",
            accessToken: "in-memory-token",
            accountID: "chatgpt-account",
            baseURL: "https://example.test/codex",
            chatGPTAuth: true,
            cacheDirectory: "/private/var/mobile/Library/Caches/models",
            capabilities: .init(
                namespaceTools: true,
                imageGeneration: false,
                webSearch: true
            )
        )
    )
    let anonymous = CodexModelCatalogCommand.configure(
        .init(
            providerID: "bedrock",
            accountIdentity: nil,
            accessToken: nil,
            accountID: nil,
            baseURL: nil,
            chatGPTAuth: false,
            cacheDirectory: nil,
            capabilities: nil
        )
    )
    #expect(
        try configured.encodedData()
            == Data(
                #"{"accessToken":"in-memory-token","accountId":"chatgpt-account","accountIdentity":"account-cache-partition","baseUrl":"https://example.test/codex","cacheDirectory":"/private/var/mobile/Library/Caches/models","capabilities":{"imageGeneration":false,"namespaceTools":true,"webSearch":true},"chatgptAuth":true,"kind":"model.catalog.configure","providerId":"openai"}"#.utf8
            )
    )
    #expect(
        try anonymous.encodedData()
            == Data(
                #"{"accessToken":null,"accountId":null,"accountIdentity":null,"baseUrl":null,"cacheDirectory":null,"capabilities":null,"chatgptAuth":false,"kind":"model.catalog.configure","providerId":"bedrock"}"#.utf8
            )
    )
    #expect(
        try CodexModelCatalogCommand.clear.encodedData()
            == Data(#"{"kind":"model.catalog.clear"}"#.utf8)
    )
}

@Test
func modelListResponseDecodesEveryStableFieldLosslessly() throws {
    let data = Data(
        #"""
        {
          "id":"models-1",
          "result":{
            "data":[{
              "id":"picker-id",
              "model":"provider-model-id",
              "upgrade":"next-model",
              "upgradeInfo":{
                "model":"next-model",
                "upgradeCopy":"Move up",
                "modelLink":"https://example.invalid/model",
                "migrationMarkdown":"## Migration"
              },
              "availabilityNux":{"message":"Now available"},
              "displayName":"Provider Model",
              "description":"Provider supplied description",
              "hidden":false,
              "supportedReasoningEfforts":[
                {"reasoningEffort":"max","description":"Maximum"},
                {"reasoningEffort":"focused","description":"Provider focused mode"}
              ],
              "defaultReasoningEffort":"focused",
              "inputModalities":["text","image","audio"],
              "supportsPersonality":true,
              "additionalSpeedTiers":["fast"],
              "serviceTiers":[{
                "id":"priority",
                "name":"Priority",
                "description":"Fast queue"
              }],
              "defaultServiceTier":"priority",
              "isDefault":true
            }],
            "nextCursor":"opaque-next"
          }
        }
        """#.utf8
    )

    let response = try JSONDecoder().decode(
        CodexAppServerResponse<CodexModelListResponse>.self,
        from: data
    )
    let model = try #require(response.result.data.first)

    #expect(response.id == .string("models-1"))
    #expect(response.result.nextCursor == "opaque-next")
    #expect(model.id == "picker-id")
    #expect(model.model == "provider-model-id")
    #expect(model.upgrade == "next-model")
    #expect(model.upgradeInfo?.upgradeCopy == "Move up")
    #expect(model.upgradeInfo?.modelLink == "https://example.invalid/model")
    #expect(model.upgradeInfo?.migrationMarkdown == "## Migration")
    #expect(model.availabilityNux?.message == "Now available")
    #expect(model.displayName == "Provider Model")
    #expect(model.description == "Provider supplied description")
    #expect(model.hidden == false)
    #expect(
        model.reasoningEffortOptions == [
            .init(reasoningEffort: .max, description: "Maximum"),
            .init(
                reasoningEffort: CodexReasoningEffort(rawValue: "focused")!,
                description: "Provider focused mode"
            ),
        ]
    )
    #expect(model.defaultReasoningEffort.rawValue == "focused")
    #expect(model.inputModalities == [.text, .image, .audio])
    #expect(model.supportsPersonality)
    #expect(model.additionalSpeedTiers == ["fast"])
    #expect(
        model.serviceTiers == [
            .init(
                id: "priority",
                name: "Priority",
                description: "Fast queue"
            ),
        ]
    )
    #expect(model.defaultServiceTier == "priority")
    #expect(model.isDefault)
}

@Test
func modelListResponseAppliesOnlyOfficialCompatibilityDefaults() throws {
    let data = Data(
        #"""
        {
          "id":9,
          "result":{
            "data":[{
              "id":"minimal",
              "model":"minimal-provider-model",
              "displayName":"Minimal",
              "description":"Required fields only",
              "hidden":false,
              "supportedReasoningEfforts":[{
                "reasoningEffort":"low",
                "description":"Low"
              }],
              "defaultReasoningEffort":"low",
              "isDefault":false
            }]
          }
        }
        """#.utf8
    )

    let response = try JSONDecoder().decode(
        CodexAppServerResponse<CodexModelListResponse>.self,
        from: data
    )
    let model = try #require(response.result.data.first)

    #expect(response.result.nextCursor == nil)
    #expect(model.upgrade == nil)
    #expect(model.upgradeInfo == nil)
    #expect(model.availabilityNux == nil)
    #expect(model.inputModalities == [.text, .image])
    #expect(model.supportsPersonality == false)
    #expect(model.additionalSpeedTiers.isEmpty)
    #expect(model.serviceTiers.isEmpty)
    #expect(model.defaultServiceTier == nil)
}

@Test
func modelProviderCapabilitiesAndErrorsDecodeWithBothRequestIDKinds() throws {
    let capabilities = try JSONDecoder().decode(
        CodexAppServerResponse<CodexModelProviderCapabilities>.self,
        from: Data(
            #"{"id":10,"result":{"namespaceTools":true,"imageGeneration":false,"webSearch":true}}"#.utf8
        )
    )
    let error = try JSONDecoder().decode(
        CodexAppServerReply<CodexModelListResponse>.self,
        from: Data(
            #"{"id":"models-error","error":{"code":-32600,"message":"invalid cursor: bad","data":null}}"#.utf8
        )
    )

    #expect(capabilities.id == .integer(10))
    #expect(
        capabilities.result
            == .init(
                namespaceTools: true,
                imageGeneration: false,
                webSearch: true
            )
    )
    #expect(
        error == .failure(
            .init(
                id: .string("models-error"),
                error: .init(
                    code: -32600,
                    message: "invalid cursor: bad",
                    data: nil
                )
            )
        )
    )
}

@Test
func modelWireRejectsAnEmptyReasoningEffort() {
    let data = Data(
        #"""
        {
          "id":11,
          "result":{
            "data":[{
              "id":"bad",
              "model":"bad",
              "displayName":"Bad",
              "description":"Bad effort",
              "hidden":false,
              "supportedReasoningEfforts":[{
                "reasoningEffort":"",
                "description":"Invalid"
              }],
              "defaultReasoningEffort":"",
              "isDefault":true
            }]
          }
        }
        """#.utf8
    )

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(
            CodexAppServerResponse<CodexModelListResponse>.self,
            from: data
        )
    }
}

@MainActor
@Test
func modelCatalogClientAbstractionCarriesTheExactTypedRequest() throws {
    let client: any CodexModelCatalogClient = RecordingModelCatalogClient()
    let request = CodexAppServerModelRequest.providerCapabilitiesRead(
        id: .string("capabilities-typed")
    )

    #expect(
        try client.request(request)
            == Data(
                #"{"id":"capabilities-typed","method":"modelProvider/capabilities/read","params":{}}"#.utf8
            )
    )
}

@MainActor
private final class RecordingModelCatalogClient: CodexModelCatalogClient {
    func request(_ request: CodexAppServerModelRequest) throws -> Data {
        try request.encodedData()
    }
}
