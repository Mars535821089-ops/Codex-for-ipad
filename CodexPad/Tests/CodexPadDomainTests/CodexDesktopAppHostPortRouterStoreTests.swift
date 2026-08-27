import Foundation
import Testing

@testable import CodexPadApplication

private final class PortRouterFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func increment(_ portID: String) {
        lock.lock()
        counts[portID, default: 0] += 1
        lock.unlock()
    }

    func count(for portID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[portID, default: 0]
    }
}

private let portRouterAppInfo =
    CodexDesktopInitialAppHostRouter.AppInfo(
        version: "26.730.61309",
        buildNumber: "6223",
        buildFlavor: "prod",
        osName: "iPadOS",
        systemVersion: "18.0",
        appName: "Codex for ipad",
        appBrand: "codex"
    )

@Test
func desktopAppHostPortRouterStoreIsolatesPortsAndReplacesReloadedPort() {
    let counter = PortRouterFactoryCounter()
    let store = CodexDesktopAppHostPortRouterStore { portID in
        counter.increment(portID)
        return CodexDesktopInitialAppHostRouter(
            appInfo: portRouterAppInfo,
            workspaceRoot: "/workspace/\(portID)"
        )
    }

    let firstA = store.router(for: "app-host-1")
    let secondA = store.router(for: "app-host-1")
    let firstB = store.router(for: "app-host-2")

    #expect(firstA === secondA)
    #expect(firstA !== firstB)
    #expect(firstA.workspaceRoot == "/workspace/app-host-1")
    #expect(firstB.workspaceRoot == "/workspace/app-host-2")
    #expect(counter.count(for: "app-host-1") == 1)
    #expect(counter.count(for: "app-host-2") == 1)

    store.reset(portID: "app-host-1")
    let reloadedA = store.router(for: "app-host-1")

    #expect(reloadedA !== firstA)
    #expect(counter.count(for: "app-host-1") == 2)
    #expect(store.portIDs == ["app-host-1", "app-host-2"])
}

@Test
func desktopAppHostPortRouterStoreRoutesInvocationThroughOriginatingPort() async
    throws
{
    let store = CodexDesktopAppHostPortRouterStore { portID in
        CodexDesktopInitialAppHostRouter(
            appInfo: .init(
                version: portID,
                buildNumber: "6223",
                buildFlavor: "prod",
                osName: "iPadOS",
                systemVersion: "18.0",
                appName: "Codex for ipad",
                appBrand: "codex"
            ),
            workspaceRoot: "/workspace/\(portID)"
        )
    }
    let targetID = try #require(
        CodexDesktopInitialAppHostRouter.serviceNames
            .firstIndex(of: "appInfo")
    )

    let value = try await store.response(
        to: CodexDesktopAppHostInvocationContext(
            portID: "app-host-7",
            pipeline: CodexDesktopAppHostRPC.Pipeline(
                targetID: -(targetID + 1),
                path: [.key("get")],
                arguments: []
            )
        )
    )

    guard case let .object(fields) = value else {
        Issue.record("Expected appInfo object")
        return
    }
    #expect(fields["version"] == .string("app-host-7"))
}
