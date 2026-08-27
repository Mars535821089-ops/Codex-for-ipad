import Foundation
import Testing

@testable import CodexPadDomain

private func remoteControlJSONObject<T: Encodable>(
    _ value: T
) throws -> Any {
    try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(value),
        options: [.fragmentsAllowed]
    )
}

@Test
func remoteControlBooleanDefaultsMatchOfficialSerdeWireRules() throws {
    let decoder = JSONDecoder()

    #expect(
        try decoder.decode(
            CodexRemoteControlEnableParams.self,
            from: Data("{}".utf8)
        ) == .init(ephemeral: false)
    )
    #expect(
        try decoder.decode(
            CodexRemoteControlDisableParams.self,
            from: Data("{}".utf8)
        ) == .init(ephemeral: false)
    )
    #expect(
        try decoder.decode(
            CodexRemoteControlPairingStartParams.self,
            from: Data("{}".utf8)
        ) == .init(manualCode: false)
    )
    #expect(
        try remoteControlJSONObject(
            CodexRemoteControlEnableParams()
        ) as? NSDictionary == [:]
    )
    #expect(
        try remoteControlJSONObject(
            CodexRemoteControlDisableParams(ephemeral: true)
        ) as? NSDictionary == ["ephemeral": true]
    )
    #expect(
        try remoteControlJSONObject(
            CodexRemoteControlPairingStartParams(manualCode: true)
        ) as? NSDictionary == ["manualCode": true]
    )
    #expect(throws: DecodingError.self) {
        try decoder.decode(
            CodexRemoteControlEnableParams.self,
            from: Data(#"{"ephemeral":null}"#.utf8)
        )
    }
}

@Test
func remoteControlNullableOptionalsCanonicalizeToExplicitNull() throws {
    let decoder = JSONDecoder()
    let pairing = try decoder.decode(
        CodexRemoteControlPairingStatusParams.self,
        from: Data("{}".utf8)
    )
    #expect(pairing.pairingCode == nil)
    #expect(pairing.manualPairingCode == nil)
    #expect(
        try remoteControlJSONObject(pairing) as? NSDictionary
            == [
                "pairingCode": NSNull(),
                "manualPairingCode": NSNull(),
            ]
    )

    let list = try decoder.decode(
        CodexRemoteControlClientsListParams.self,
        from: Data(#"{"environmentId":"env-123"}"#.utf8)
    )
    #expect(list.cursor == nil)
    #expect(list.limit == nil)
    #expect(list.order == nil)
    #expect(
        try remoteControlJSONObject(list) as? NSDictionary
            == [
                "environmentId": "env-123",
                "cursor": NSNull(),
                "limit": NSNull(),
                "order": NSNull(),
            ]
    )

    let nullList = try decoder.decode(
        CodexRemoteControlClientsListParams.self,
        from: Data(
            #"""
            {
              "environmentId":"env-123",
              "cursor":null,
              "limit":null,
              "order":null
            }
            """#.utf8
        )
    )
    #expect(nullList == list)
}

@Test
func remoteControlStatusPayloadsUseExactCamelCaseAndNullableIdentity()
    throws
{
    let payload = CodexRemoteControlStatusChangedNotification(
        status: .connecting,
        serverName: "Mars-iPad",
        installationId: "installation-123",
        environmentId: nil
    )
    #expect(
        try remoteControlJSONObject(payload) as? NSDictionary
            == [
                "status": "connecting",
                "serverName": "Mars-iPad",
                "installationId": "installation-123",
                "environmentId": NSNull(),
            ]
    )
    let decoded = try JSONDecoder().decode(
        CodexRemoteControlStatusReadResponse.self,
        from: Data(
            #"""
            {
              "status":"connected",
              "serverName":"Mars-iPad",
              "installationId":"installation-123"
            }
            """#.utf8
        )
    )
    #expect(decoded.environmentId == nil)
    #expect(
        try remoteControlJSONObject(decoded) as? NSDictionary
            == [
                "status": "connected",
                "serverName": "Mars-iPad",
                "installationId": "installation-123",
                "environmentId": NSNull(),
            ]
    )
}

@Test
func remoteControlPairingAndClientTimestampsRemainInt64Safe() throws {
    let largeTimestamp = Int64.max - 7
    let pairing = CodexRemoteControlPairingStartResponse(
        pairingCode: "pairing-code",
        manualPairingCode: nil,
        environmentId: "env-123",
        expiresAt: largeTimestamp
    )
    let pairingRoundTrip = try JSONDecoder().decode(
        CodexRemoteControlPairingStartResponse.self,
        from: JSONEncoder().encode(pairing)
    )
    #expect(pairingRoundTrip.expiresAt == largeTimestamp)
    #expect(
        try remoteControlJSONObject(pairing) as? NSDictionary
            == [
                "pairingCode": "pairing-code",
                "manualPairingCode": NSNull(),
                "environmentId": "env-123",
                "expiresAt": NSNumber(value: largeTimestamp),
            ]
    )

    let client = CodexRemoteControlClient(
        clientId: "client-123",
        displayName: nil,
        deviceType: nil,
        platform: nil,
        osVersion: nil,
        deviceModel: nil,
        appVersion: nil,
        lastSeenAt: largeTimestamp
    )
    let clientRoundTrip = try JSONDecoder().decode(
        CodexRemoteControlClient.self,
        from: JSONEncoder().encode(client)
    )
    #expect(clientRoundTrip.lastSeenAt == largeTimestamp)
    let object = try #require(
        remoteControlJSONObject(client) as? NSDictionary
    )
    #expect(object["clientId"] as? String == "client-123")
    #expect(object["displayName"] is NSNull)
    #expect(object["deviceType"] is NSNull)
    #expect(object["platform"] is NSNull)
    #expect(object["osVersion"] is NSNull)
    #expect(object["deviceModel"] is NSNull)
    #expect(object["appVersion"] is NSNull)
    #expect(object["lastSeenAt"] as? NSNumber == NSNumber(value: largeTimestamp))
}

@Test
func remoteControlListRevokeAndEnumWireShapesAreExact() throws {
    let params = CodexRemoteControlClientsListParams(
        environmentId: "env-123",
        cursor: "cursor-123",
        limit: 100,
        order: .desc
    )
    #expect(
        try remoteControlJSONObject(params) as? NSDictionary
            == [
                "environmentId": "env-123",
                "cursor": "cursor-123",
                "limit": 100,
                "order": "desc",
            ]
    )
    #expect(
        try remoteControlJSONObject(
            CodexRemoteControlClientsListResponse(
                data: [],
                nextCursor: nil
            )
        ) as? NSDictionary
            == [
                "data": [],
                "nextCursor": NSNull(),
            ]
    )
    #expect(
        try remoteControlJSONObject(
            CodexRemoteControlClientsRevokeParams(
                environmentId: "env-123",
                clientId: "client-123"
            )
        ) as? NSDictionary
            == [
                "environmentId": "env-123",
                "clientId": "client-123",
            ]
    )
    #expect(
        try remoteControlJSONObject(
            CodexRemoteControlClientsRevokeResponse()
        ) as? NSDictionary == [:]
    )
}
