import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@testable import CodexPadApplication

private let desktopAppHostServices:
    [String: CodexDesktopAppHostRPC.Value] =
[
    "appActions": .rpcObject([:]),
    "appUpdates": .rpcObject([:]),
    "clientCoordination": .rpcObject([:]),
    "downloads": .rpcObject([:]),
]

@MainActor
@Test
func desktopAppHostSessionStoreCreatesAndResetsOneRPCPerLogicalPort()
    throws
{
    let store = try CodexDesktopAppHostSessionStore(
        services: desktopAppHostServices
    )

    #expect(
        try store.handleNativeChannel(
            name: "app-host-connected",
            payload: .object(["portID": .string("app-host-1")])
        ) == .handled(
            CodexDesktopAppHostHandledChannel(
                reply: nil,
                deferredFrames: []
            )
        )
    )
    #expect(store.portIDs == ["app-host-1"])

    _ = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(
                #"["push",["pipeline",0,["services"]]]"#
            ),
        ])
    )
    #expect(
        store.snapshot(for: "app-host-1")?
            .nextPipelineExportID == 2
    )

    _ = try store.handleNativeChannel(
        name: "app-host-connected",
        payload: .object(["portID": .string("app-host-1")])
    )
    #expect(store.portIDs == ["app-host-1"])
    #expect(
        store.snapshot(for: "app-host-1")?
            .nextPipelineExportID == 1
    )
}

@MainActor
@Test
func desktopAppHostSessionStoreReconnectTerminatesAnOldAwaitedImport()
    async throws
{
    var emitted: [CodexDesktopAppHostOutboundFrame] = []
    let store = try CodexDesktopAppHostSessionStore(
        services: desktopAppHostServices,
        deferredFrameHandler: { emitted.append($0) }
    )
    let connectedPayload: CodexJSONValue = .object([
        "portID": .string("app-host-1")
    ])
    _ = try store.handleNativeChannel(
        name: "app-host-connected",
        payload: connectedPayload
    )
    var outcome: Result<
        CodexDesktopAppHostRPC.Value,
        Swift.Error
    >?
    let call = Task { @MainActor in
        do {
            outcome = .success(
                try await store.callImport(
                    onPortID: "app-host-1",
                    callbackID: 41,
                    arguments: [.string("file-1")]
                )
            )
        } catch {
            outcome = .failure(error)
        }
    }
    while emitted.count < 2 {
        await Task.yield()
    }

    _ = try store.handleNativeChannel(
        name: "app-host-connected",
        payload: connectedPayload
    )
    for _ in 0..<100 where outcome == nil {
        await Task.yield()
    }

    let failure: Swift.Error?
    if case let .failure(error)? = outcome {
        failure = error
    } else {
        failure = nil
    }
    #expect(
        failure as? CodexDesktopAppHostRPC.Error
            == .sessionAborted
    )
    #expect(
        store.snapshot(for: "app-host-1")?
            .nextPipelineExportID == 1
    )
    _ = await call.result
}

@MainActor
@Test
func desktopAppHostSessionStoreReportsEveryConnectedSessionAfterReset()
    throws
{
    var connectedPorts: [String] = []
    var observedNextPipelineIDs: [Int?] = []
    var store: CodexDesktopAppHostSessionStore!
    store = try CodexDesktopAppHostSessionStore(
        services: desktopAppHostServices,
        portConnectedHandler: { portID in
            connectedPorts.append(portID)
            observedNextPipelineIDs.append(
                store.snapshot(for: portID)?
                    .nextPipelineExportID
            )
        }
    )

    let connectedPayload: CodexJSONValue = .object([
        "portID": .string("app-host-1")
    ])
    _ = try store.handleNativeChannel(
        name: "app-host-connected",
        payload: connectedPayload
    )
    _ = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(
                #"["push",["pipeline",0,["services"]]]"#
            ),
        ])
    )
    #expect(
        store.snapshot(for: "app-host-1")?
            .nextPipelineExportID == 2
    )

    _ = try store.handleNativeChannel(
        name: "app-host-connected",
        payload: connectedPayload
    )

    #expect(connectedPorts == ["app-host-1", "app-host-1"])
    #expect(observedNextPipelineIDs == [1, 1])
}

@MainActor
@Test
func desktopAppHostSessionStoreReturnsTheFirstFrameAsTheWKReply()
    throws
{
    let store = try CodexDesktopAppHostSessionStore(
        services: [
            "appActions": .rpcObject([:])
        ]
    )
    _ = try store.handleNativeChannel(
        name: "app-host-connected",
        payload: .object(["portID": .string("app-host-1")])
    )

    let push = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(
                #"["push",["pipeline",0,["services"]]]"#
            ),
        ])
    )
    let pull = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(#"["pull",1]"#),
        ])
    )

    #expect(
        push == .handled(
            CodexDesktopAppHostHandledChannel(
                reply: nil,
                deferredFrames: []
            )
        )
    )
    #expect(
        pull == .handled(
            CodexDesktopAppHostHandledChannel(
                reply: .string(
                    #"["resolve",1,{"appActions":["export",-1]}]"#
                ),
                deferredFrames: []
            )
        )
    )
}

@MainActor
@Test
func desktopAppHostSessionStoreMarksOnlyTheServicesResolveAsReady()
    throws
{
    var resolvedPorts: [String] = []
    let store = try CodexDesktopAppHostSessionStore(
        services: [
            "appInfo": .rpcObject([:])
        ],
        servicesResolvedHandler: {
            resolvedPorts.append($0)
        }
    )
    let connectedPayload: CodexJSONValue = .object([
        "portID": .string("app-host-1")
    ])
    _ = try store.handleNativeChannel(
        name: "app-host-connected",
        payload: connectedPayload
    )

    #expect(!store.hasResolvedServices)
    #expect(resolvedPorts.isEmpty)

    _ = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(
                #"["push",["pipeline",0,["services"]]]"#
            ),
        ])
    )

    #expect(!store.hasResolvedServices)
    #expect(resolvedPorts.isEmpty)

    let pull = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(#"["pull",1]"#),
        ])
    )

    #expect(
        pull.wkReply
            == .string(
                #"["resolve",1,{"appInfo":["export",-1]}]"#
            )
    )
    #expect(store.hasResolvedServices)
    #expect(
        store.servicesResolvedPortIDs
            == Set(["app-host-1"])
    )
    #expect(resolvedPorts == ["app-host-1"])

    _ = try store.handleNativeChannel(
        name: "app-host-connected",
        payload: connectedPayload
    )
    #expect(!store.hasResolvedServices)
    #expect(resolvedPorts == ["app-host-1"])
}

@MainActor
@Test
func desktopAppHostSessionStoreAcceptsOfficialLiteralRootValuesAndClosesHandshake()
    throws
{
    var resolvedPorts: [String] = []
    let store = try CodexDesktopAppHostSessionStore(
        services: [
            "appInfo": .rpcObject([:]),
            "notificationPermissionsSupported": .bool(true),
        ],
        servicesResolvedHandler: {
            resolvedPorts.append($0)
        }
    )

    _ = try store.handleNativeChannel(
        name: "app-host-connected",
        payload: .object(["portID": .string("app-host-1")])
    )
    let push = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(
                #"["push",["pipeline",0,["services"]]]"#
            ),
        ])
    )
    let pull = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(#"["pull",1]"#),
        ])
    )

    #expect(push.wkReply == nil)
    #expect(
        pull.wkReply
            == .string(
                #"["resolve",1,{"appInfo":["export",-1],"notificationPermissionsSupported":true}]"#
            )
    )
    #expect(store.hasResolvedServices)
    #expect(resolvedPorts == ["app-host-1"])
}

@MainActor
@Test
func desktopAppHostSessionStoreInjectsTheNativeInvocationHandler()
    throws
{
    var captured: CodexDesktopAppHostRPC.Pipeline?
    let store = try CodexDesktopAppHostSessionStore(
        services: [
            "appActions": .rpcObject([:])
        ],
        invocationHandler: { pipeline in
            captured = pipeline
            return .string("opened")
        }
    )
    _ = try store.handleNativeChannel(
        name: "app-host-connected",
        payload: .object(["portID": .string("app-host-1")])
    )
    _ = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(
                #"["push",["pipeline",0,["services"]]]"#
            ),
        ])
    )
    _ = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(#"["pull",1]"#),
        ])
    )
    _ = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(
                #"["push",["pipeline",-1,["open"],["project-1"]]]"#
            ),
        ])
    )
    let response = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(#"["pull",2]"#),
        ])
    )

    #expect(
        captured
            == CodexDesktopAppHostRPC.Pipeline(
                targetID: -1,
                path: [.key("open")],
                arguments: [.string("project-1")]
            )
    )
    #expect(
        response.wkReply
            == .string(#"["resolve",2,"opened"]"#)
    )
}

@MainActor
@Test
func desktopAppHostSessionStoreInjectsAnAsyncInvocationHandler()
    async throws
{
    let store = try CodexDesktopAppHostSessionStore(
        services: [
            "workspaceFiles": .rpcObject([:])
        ],
        asyncInvocationHandler: { pipeline in
            await Task.yield()
            #expect(pipeline.path == [.key("read")])
            return .string("async-contents")
        }
    )
    _ = try await store.handleNativeChannelAsync(
        name: "app-host-connected",
        payload: .object(["portID": .string("app-host-1")])
    )
    _ = try await store.handleNativeChannelAsync(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(
                #"["push",["pipeline",0,["services"]]]"#
            ),
        ])
    )
    _ = try await store.handleNativeChannelAsync(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(#"["pull",1]"#),
        ])
    )
    _ = try await store.handleNativeChannelAsync(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(
                #"["push",["pipeline",-1,["read"],[{"path":"/workspace/a.txt"}]]]"#
            ),
        ])
    )
    let response = try await store.handleNativeChannelAsync(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-1"),
            "frame": .string(#"["pull",2]"#),
        ])
    )

    #expect(
        response.wkReply
            == .string(#"["resolve",2,"async-contents"]"#)
    )
}

@MainActor
@Test
func desktopAppHostSessionStorePartitionsRemainingFramesForAsyncDelivery()
    throws
{
    var emitted: [CodexDesktopAppHostOutboundFrame] = []
    let store = try CodexDesktopAppHostSessionStore(
        services: desktopAppHostServices,
        deferredFrameHandler: { emitted.append($0) }
    )

    let response = store.routeResponseFrames(
        [
            #"["resolve",1,true]"#,
            #"["resolve",2,false]"#,
            #"["reject",3,["error","Error","failed"]]"#,
        ],
        portID: "app-host-7"
    )

    let deferred = [
        CodexDesktopAppHostOutboundFrame(
            portID: "app-host-7",
            frame: #"["resolve",2,false]"#
        ),
        CodexDesktopAppHostOutboundFrame(
            portID: "app-host-7",
            frame: #"["reject",3,["error","Error","failed"]]"#
        ),
    ]
    #expect(
        response
            == CodexDesktopAppHostHandledChannel(
                reply: .string(#"["resolve",1,true]"#),
                deferredFrames: deferred
            )
    )
    #expect(emitted == deferred)
    #expect(
        deferred[0].hostMessage
            == .event(
                type: "app-host-message",
                payload: .object([
                    "portID": .string("app-host-7"),
                    "frame": .string(#"["resolve",2,false]"#),
                ])
            )
    )
}

@MainActor
@Test
func desktopAppHostSessionStoreValidatesOfficialChannelPayloads()
    throws
{
    let store = try CodexDesktopAppHostSessionStore(
        services: desktopAppHostServices
    )

    #expect(
        throws:
            CodexDesktopAppHostSessionStore.Error
                .invalidPayload(channel: "app-host-connected")
    ) {
        try store.handleNativeChannel(
            name: "app-host-connected",
            payload: .object([:])
        )
    }
    #expect(
        throws:
            CodexDesktopAppHostSessionStore.Error
                .invalidPayload(channel: "app-host-message")
    ) {
        try store.handleNativeChannel(
            name: "app-host-message",
            payload: .object([
                "portID": .string("app-host-1"),
                "frame": .integer(1),
            ])
        )
    }
    #expect(
        throws:
            CodexDesktopAppHostSessionStore.Error
                .unknownPortID("app-host-missing")
    ) {
        try store.handleNativeChannel(
            name: "app-host-message",
            payload: .object([
                "portID": .string("app-host-missing"),
                "frame": .string(#"["pull",1]"#),
            ])
        )
    }
}

@MainActor
@Test
func desktopAppHostSessionStoreLeavesOtherNativeChannelsUnhandled()
    throws
{
    let store = try CodexDesktopAppHostSessionStore(
        services: desktopAppHostServices
    )

    #expect(
        try store.handleNativeChannel(
            name: "show-context-menu",
            payload: .object(["portID": .string("ignored")])
        ) == .notHandled
    )
    #expect(store.portIDs.isEmpty)
}

@MainActor
@Test
func desktopAppHostSessionStoreRequiresEveryServiceToBeAnRPCTarget() {
    #expect(
        throws:
            CodexDesktopAppHostSessionStore.Error
                .invalidServiceTarget("appActions")
    ) {
        try CodexDesktopAppHostSessionStore(
            services: [
                "appActions": .object([:])
            ]
        )
    }
}

@MainActor
@Test
func desktopAppHostSessionStoreProvidesTheLogicalPortToSyncInvocations()
    throws
{
    var contexts: [CodexDesktopAppHostInvocationContext] = []
    let store = try CodexDesktopAppHostSessionStore(
        services: [
            "appActions": .rpcObject([:])
        ],
        portScopedInvocationHandler: { context in
            contexts.append(context)
            return .string(context.portID)
        }
    )

    for portID in ["app-host-1", "app-host-2"] {
        _ = try store.handleNativeChannel(
            name: "app-host-connected",
            payload: .object(["portID": .string(portID)])
        )
        _ = try store.handleNativeChannel(
            name: "app-host-message",
            payload: .object([
                "portID": .string(portID),
                "frame": .string(
                    #"["push",["pipeline",0,["services"]]]"#
                ),
            ])
        )
        _ = try store.handleNativeChannel(
            name: "app-host-message",
            payload: .object([
                "portID": .string(portID),
                "frame": .string(#"["pull",1]"#),
            ])
        )
        _ = try store.handleNativeChannel(
            name: "app-host-message",
            payload: .object([
                "portID": .string(portID),
                "frame": .string(
                    #"["push",["pipeline",-1,["open"],["project-1"]]]"#
                ),
            ])
        )
        let response = try store.handleNativeChannel(
            name: "app-host-message",
            payload: .object([
                "portID": .string(portID),
                "frame": .string(#"["pull",2]"#),
            ])
        )
        #expect(
            response.wkReply
                == .string(#"["resolve",2,"\#(portID)"]"#)
        )
    }

    #expect(contexts.map(\.portID) == ["app-host-1", "app-host-2"])
    #expect(
        contexts.map(\.pipeline.path)
            == [[.key("open")], [.key("open")]]
    )
}

@MainActor
@Test
func desktopAppHostSessionStoreProvidesTheLogicalPortToAsyncInvocations()
    async throws
{
    let store = try CodexDesktopAppHostSessionStore(
        services: [
            "workspaceFiles": .rpcObject([:])
        ],
        portScopedAsyncInvocationHandler: { context in
            await Task.yield()
            #expect(context.portID == "app-host-8")
            #expect(context.pipeline.path == [.key("read")])
            return .string("async-contents")
        }
    )
    _ = try await store.handleNativeChannelAsync(
        name: "app-host-connected",
        payload: .object(["portID": .string("app-host-8")])
    )
    _ = try await store.handleNativeChannelAsync(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-8"),
            "frame": .string(
                #"["push",["pipeline",0,["services"]]]"#
            ),
        ])
    )
    _ = try await store.handleNativeChannelAsync(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-8"),
            "frame": .string(#"["pull",1]"#),
        ])
    )
    _ = try await store.handleNativeChannelAsync(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-8"),
            "frame": .string(
                #"["push",["pipeline",-1,["read"],["README.md"]]]"#
            ),
        ])
    )
    let response = try await store.handleNativeChannelAsync(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-8"),
            "frame": .string(#"["pull",2]"#),
        ])
    )

    #expect(
        response.wkReply
            == .string(#"["resolve",2,"async-contents"]"#)
    )
}

@MainActor
@Test
func desktopAppHostSessionStoreSendsImportCallsToTheOwningLogicalPort()
    throws
{
    var emitted: [CodexDesktopAppHostOutboundFrame] = []
    let store = try CodexDesktopAppHostSessionStore(
        services: desktopAppHostServices,
        deferredFrameHandler: { emitted.append($0) }
    )
    for portID in ["app-host-3", "app-host-4"] {
        _ = try store.handleNativeChannel(
            name: "app-host-connected",
            payload: .object(["portID": .string(portID)])
        )
    }

    let firstCallback = CodexDesktopAppHostCallbackIdentity(
        portID: "app-host-3",
        callbackID: 41
    )
    let secondCallback = CodexDesktopAppHostCallbackIdentity(
        portID: "app-host-4",
        callbackID: 41
    )
    #expect(firstCallback != secondCallback)

    let firstFrame = try store.sendImportCall(
        to: firstCallback,
        arguments: [
            .object(["type": .string("changed")])
        ]
    )
    let secondFrame = try store.sendImportCall(
        to: secondCallback,
        arguments: [
            .string("ready")
        ]
    )

    #expect(
        firstFrame
            == CodexDesktopAppHostOutboundFrame(
                portID: "app-host-3",
                frame:
                    #"["push",["pipeline",41,[],[{"type":"changed"}]]]"#
            )
    )
    #expect(
        secondFrame
            == CodexDesktopAppHostOutboundFrame(
                portID: "app-host-4",
                frame: #"["push",["pipeline",41,[],["ready"]]]"#
            )
    )
    #expect(emitted == [firstFrame, secondFrame])
}

@MainActor
@Test
func desktopAppHostSessionStoreAwaitsRendererImportResolution()
    async throws
{
    var emitted: [CodexDesktopAppHostOutboundFrame] = []
    let store = try CodexDesktopAppHostSessionStore(
        services: desktopAppHostServices,
        deferredFrameHandler: { emitted.append($0) }
    )
    _ = try store.handleNativeChannel(
        name: "app-host-connected",
        payload: .object(["portID": .string("app-host-5")])
    )

    _ = try store.sendImportCall(
        to: CodexDesktopAppHostCallbackIdentity(
            portID: "app-host-5",
            callbackID: 40
        ),
        arguments: [.string("one-way")]
    )
    let result = Task { @MainActor in
        try await store.callImport(
            onPortID: "app-host-5",
            callbackID: 41,
            arguments: [.string("file-1")]
        )
    }
    while emitted.count < 3 {
        await Task.yield()
    }

    #expect(
        emitted
            == [
                CodexDesktopAppHostOutboundFrame(
                    portID: "app-host-5",
                    frame:
                        #"["push",["pipeline",40,[],["one-way"]]]"#
                ),
                CodexDesktopAppHostOutboundFrame(
                    portID: "app-host-5",
                    frame:
                        #"["push",["pipeline",41,[],["file-1"]]]"#
                ),
                CodexDesktopAppHostOutboundFrame(
                    portID: "app-host-5",
                    frame: #"["pull",2]"#
                ),
            ]
    )

    let response = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-5"),
            "frame": .string(
                #"["resolve",2,{"url":"https://example.invalid/file-1"}]"#
            ),
        ])
    )

    #expect(response.wkReply == .string(#"["release",2,1]"#))
    #expect(
        try await result.value
            == .object([
                "url": .string(
                    "https://example.invalid/file-1"
                )
            ])
    )
}

@MainActor
@Test
func desktopAppHostSessionStoreSurfacesRendererImportRejection()
    async throws
{
    var emitted: [CodexDesktopAppHostOutboundFrame] = []
    let store = try CodexDesktopAppHostSessionStore(
        services: desktopAppHostServices,
        deferredFrameHandler: { emitted.append($0) }
    )
    _ = try store.handleNativeChannel(
        name: "app-host-connected",
        payload: .object(["portID": .string("app-host-6")])
    )

    let result = Task { @MainActor in
        try await store.callImport(
            onPortID: "app-host-6",
            callbackID: 51,
            arguments: [.string("file-2")]
        )
    }
    while emitted.count < 2 {
        await Task.yield()
    }
    #expect(
        emitted.map(\.frame)
            == [
                #"["push",["pipeline",51,[],["file-2"]]]"#,
                #"["pull",1]"#,
            ]
    )

    let response = try store.handleNativeChannel(
        name: "app-host-message",
        payload: .object([
            "portID": .string("app-host-6"),
            "frame": .string(
                #"["reject",1,["error","Error","denied"]]"#
            ),
        ])
    )

    #expect(response.wkReply == .string(#"["release",1,1]"#))
    await #expect(
        throws:
            CodexDesktopAppHostRPC.ImportRejection(
                value: .error(
                    name: "Error",
                    message: "denied",
                    stack: nil
                )
            )
    ) {
        _ = try await result.value
    }
}
