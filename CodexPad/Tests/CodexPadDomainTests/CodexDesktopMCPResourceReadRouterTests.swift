import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class MCPResourceReadProbe:
    CodexDesktopMCPResourceReading
{
    private(set) var received:
        (
            threadID: CodexStoredThreadID?,
            server: String,
            uri: String
        )?
    var error: CodexMCPResourceError?

    func readMCPResource(
        threadID: CodexStoredThreadID?,
        server: String,
        uri: String
    ) async throws -> [CodexMCPResourceContent] {
        received = (threadID, server, uri)
        if let error {
            throw error
        }
        return [
            .text(
                uri: uri,
                mimeType: "text/plain",
                text: "fixture body",
                meta: .object(["revision": .integer(7)])
            ),
        ]
    }
}

@MainActor
private final class MCPResourceThreadReadProbe:
    CodexDesktopThreadSessionListing,
    CodexDesktopThreadSessionReading
{
    private(set) var readParams: CodexThreadReadParams?

    func listThreads(
        id _: CodexAppServerRequestID,
        params _: CodexThreadListParams
    ) throws -> CodexThreadPage {
        .init(data: [], nextCursor: nil, backwardsCursor: nil)
    }

    func readThread(
        id _: CodexAppServerRequestID,
        params: CodexThreadReadParams
    ) throws -> CodexThreadReadResult {
        readParams = params
        return .init(
            thread: CodexStoredThread(
                id: params.threadID,
                sessionID: "resource-session",
                preview: "resource",
                ephemeral: false,
                modelProvider: "openai",
                createdAt: 1,
                updatedAt: 1,
                recencyAt: 1,
                status: .idle,
                path: "/tmp/resource.jsonl",
                cwd: "/workspace",
                cliVersion: "1",
                source: .named("appServer"),
                name: "Resource",
                turns: []
            )
        )
    }
}

@Test
@MainActor
func mcpResourceReadMatchesOfficialWireContractAndValidatesThread()
    async
{
    let resourceReader = MCPResourceReadProbe()
    let threadReader = MCPResourceThreadReadProbe()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: mcpResourceRequest(
                params: .object([
                    "threadId": .string("thread-resource"),
                    "server": .string("calendar"),
                    "uri": .string("calendar://today"),
                ])
            ),
            state: mcpResourceState(),
            allowedFileSystemRoots: [],
            threadLister: threadReader,
            mcpResourceReader: resourceReader
        )

    #expect(threadReader.readParams?.threadID == .init("thread-resource"))
    #expect(threadReader.readParams?.includeTurns == false)
    #expect(resourceReader.received?.threadID == .init("thread-resource"))
    #expect(resourceReader.received?.server == "calendar")
    #expect(resourceReader.received?.uri == "calendar://today")
    #expect(
        mcpResourceResult(response)
            == [
                "contents": .array([
                    .object([
                        "uri": .string("calendar://today"),
                        "mimeType": .string("text/plain"),
                        "text": .string("fixture body"),
                        "_meta": .object([
                            "revision": .integer(7),
                        ]),
                    ]),
                ]),
            ]
    )
}

@Test(arguments: [
    nil,
    CodexJSONValue.null,
    .object([:]),
    .object([
        "server": .string("calendar"),
        "uri": .string(""),
    ]),
    .object([
        "server": .string("calendar"),
        "uri": .string("calendar://today"),
        "threadId": .integer(1),
    ]),
    .object([
        "server": .string("calendar"),
        "uri": .string("calendar://today"),
        "extra": .bool(true),
    ]),
])
@MainActor
func mcpResourceReadRejectsNonOfficialParameterShapes(
    params: CodexJSONValue?
) async {
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: mcpResourceRequest(params: params),
            state: mcpResourceState(),
            allowedFileSystemRoots: [],
            mcpResourceReader: MCPResourceReadProbe()
        )
    #expect(mcpResourceError(response)?["code"] == .integer(-32602))
}

@Test(arguments: [
    (
        CodexMCPResourceError.unknownServer("missing"),
        "MCP server not found"
    ),
    (
        CodexMCPResourceError.unknownResource(
            server: "calendar",
            uri: "calendar://missing"
        ),
        "MCP resource not found"
    ),
])
@MainActor
func mcpResourceReadMapsLookupFailuresToInvalidRequest(
    fixture: (CodexMCPResourceError, String)
) async {
    let reader = MCPResourceReadProbe()
    reader.error = fixture.0
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: mcpResourceRequest(
                params: .object([
                    "server": .string("calendar"),
                    "uri": .string("calendar://today"),
                ])
            ),
            state: mcpResourceState(),
            allowedFileSystemRoots: [],
            mcpResourceReader: reader
        )
    #expect(mcpResourceError(response)?["code"] == .integer(-32600))
    #expect(
        mcpResourceError(response)?["message"]
            == .string(fixture.1)
    )
}

private func mcpResourceRequest(
    params: CodexJSONValue?
) -> CodexDesktopMCPRequest {
    .init(
        request: .init(
            id: .string("resource-read-1"),
            method: "mcpServer/resource/read",
            params: params,
            metadata: [:]
        ),
        hostID: "desktop-host-resource",
        dispatchedAtMs: nil,
        priority: nil,
        source: nil,
        timeoutMs: nil,
        expiresAtMs: nil,
        metadata: [:]
    )
}

private func mcpResourceState() -> CodexDesktopInitialMCPState {
    .init(
        account: .init(
            account: nil,
            authMethod: nil,
            requiresOpenAIAuth: true
        ),
        config: .init(config: [:], origins: [:], layers: []),
        remoteControl: .init(
            status: .disabled,
            serverName: "Codex for ipad",
            installationID: "installation",
            environmentID: nil
        )
    )
}

private func mcpResourceResult(
    _ response: CodexDesktopHostMessage
) -> [String: CodexJSONValue]? {
    guard case let .mcpResponse(_, .object(envelope), _) =
        response,
        case let .object(result)? = envelope["result"]
    else {
        return nil
    }
    return result
}

private func mcpResourceError(
    _ response: CodexDesktopHostMessage
) -> [String: CodexJSONValue]? {
    guard case let .mcpResponse(_, .object(envelope), _) =
        response,
        case let .object(error)? = envelope["error"]
    else {
        return nil
    }
    return error
}
