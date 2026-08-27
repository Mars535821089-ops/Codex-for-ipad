import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain

private final class RuntimeAdapterContextProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CodexRemoteControlWebSocketRuntimeContext?

    func record(_ context: CodexRemoteControlWebSocketRuntimeContext) {
        lock.withLock {
            value = context
        }
    }

    func snapshot() -> CodexRemoteControlWebSocketRuntimeContext? {
        lock.withLock { value }
    }
}

private actor RuntimeAdapterSession:
    CodexRemoteControlVirtualSession
{
    private var closed = false

    func receive(_ message: CodexJSONValue) async -> CodexJSONValue? {
        guard case let .object(fields) = message,
              let id = fields["id"]
        else {
            return nil
        }
        return .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": .object(["runtime": .bool(true)]),
        ])
    }

    func close() async {
        closed = true
    }

    func isClosed() -> Bool {
        closed
    }
}

private actor RuntimeAdapterTransportProbe:
    CodexRemoteControlWebSocketRunning
{
    private let inbound: CodexRemoteControlInboundHandler
    private let status: CodexRemoteControlWebSocketStatusHandler
    private var sent: [
        (
            event: CodexRemoteControlServerEvent,
            clientID: String,
            streamID: String
        )
    ] = []
    private var disconnectCount = 0

    init(
        inbound: @escaping CodexRemoteControlInboundHandler,
        status: @escaping CodexRemoteControlWebSocketStatusHandler
    ) {
        self.inbound = inbound
        self.status = status
    }

    func run() async throws {
        await status(.connecting)
        await status(.connected)
        try await inbound(
            .init(
                event: .clientMessage(
                    .object([
                        "jsonrpc": .string("2.0"),
                        "id": .integer(41),
                        "method": .string("initialize"),
                        "params": .object([:]),
                    ])
                ),
                clientID: "client-runtime",
                streamID: "stream-runtime",
                seqID: 1,
                cursor: "cursor-1"
            )
        )
    }

    func send(
        event: CodexRemoteControlServerEvent,
        clientID: String,
        streamID: String
    ) async throws {
        sent.append((event, clientID, streamID))
    }

    func disconnect() async throws {
        disconnectCount += 1
    }

    func snapshot() -> (
        sent: [
            (
                event: CodexRemoteControlServerEvent,
                clientID: String,
                streamID: String
            )
        ],
        disconnectCount: Int
    ) {
        (sent, disconnectCount)
    }
}

@Test
func runtimeAdapterMapsLifecycleAndRoutesVirtualSessionOnExactStream()
    async throws
{
    let session = RuntimeAdapterSession()
    let router = CodexRemoteControlVirtualSessionRouter { _ in
        session
    }
    let contextProbe = RuntimeAdapterContextProbe()
    let transportSlot = LockIsolated<
        RuntimeAdapterTransportProbe?
    >(nil)
    let adapter = CodexRemoteControlWebSocketLifecycleAdapter(
        router: router,
        makeTransport: { context, inbound, status in
            contextProbe.record(context)
            let transport = RuntimeAdapterTransportProbe(
                inbound: inbound,
                status: status
            )
            transportSlot.withValue { $0 = transport }
            return transport
        }
    )

    let stream = try await adapter.connect(
        target: "https://chatgpt.com/backend-api/",
        installationID: "install-runtime",
        accountID: "account-runtime",
        serverID: "server-runtime",
        environmentID: "environment-runtime",
        serverName: "Codex for ipad",
        token: "token-runtime"
    )
    var statuses: [CodexRemoteControlConnectionStatus] = []
    for try await status in stream {
        statuses.append(status)
    }

    #expect(statuses == [.connecting, .connected])
    #expect(
        contextProbe.snapshot()
            == .init(
                validatedHTTPBaseURL: URL(
                    string: "https://chatgpt.com/backend-api/"
                )!,
                enrollment: .init(
                    serverID: "server-runtime",
                    environmentID: "environment-runtime",
                    remoteControlToken: "token-runtime",
                    expiresAt: .max,
                    accountID: "account-runtime"
                ),
                serverName: "Codex for ipad",
                installationID: "install-runtime"
            )
    )
    let transport = try #require(transportSlot.value)
    let snapshot = await transport.snapshot()
    #expect(snapshot.sent.count == 1)
    #expect(snapshot.sent[0].clientID == "client-runtime")
    #expect(snapshot.sent[0].streamID == "stream-runtime")
    #expect(
        snapshot.sent[0].event
            == .serverMessage(
                .object([
                    "jsonrpc": .string("2.0"),
                    "id": .integer(41),
                    "result": .object(["runtime": .bool(true)]),
                ])
            )
    )
    #expect(await router.activeSessionCount == 1)

    await adapter.disconnect()
    #expect(await transport.snapshot().disconnectCount == 1)
    #expect(await router.activeSessionCount == 1)
    await router.shutdown()
    #expect(await session.isClosed())
}

private final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.withLock {
            body(&storage)
        }
    }
}
