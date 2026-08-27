import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopAppHostRPCDecodesAndEncodesOfficialStringFrames() throws {
    let servicesPipeline =
        CodexDesktopAppHostRPC.Pipeline(
            targetID: 0,
            path: [.key("services")],
            arguments: nil
        )
    let push = #"["push",["pipeline",0,["services"]]]"#
    let pull = #"["pull",1]"#
    let release = #"["release",-1,1]"#

    #expect(
        try CodexDesktopAppHostRPC.decode(push)
            == .push(servicesPipeline)
    )
    #expect(
        try CodexDesktopAppHostRPC.encode(.push(servicesPipeline))
            == push
    )
    #expect(
        try CodexDesktopAppHostRPC.decode(pull)
            == .pull(1)
    )
    #expect(
        try CodexDesktopAppHostRPC.encode(.release(id: -1, count: 1))
            == release
    )
}

@Test
func desktopAppHostRPCImportsRendererExportArguments() throws {
    let frame = try CodexDesktopAppHostRPC.decode(
        #"["push",["pipeline",-62,["subscribe"],[["export",-1]]]]"#
    )

    #expect(
        frame == .push(
            .init(
                targetID: -62,
                path: [.key("subscribe")],
                arguments: [.import(-1)]
            )
        )
    )
}

@Test
func desktopAppHostRPCClosesTheInitialServicesPipelineAndPull() throws {
    var sentFrames: [String] = []
    // Construct the dictionary in the opposite order from the official wire
    // contract. Export IDs must follow the canonical service order rather than
    // Swift Dictionary's process-randomized iteration order.
    var services: [String: CodexDesktopAppHostRPC.Value] = [:]
    services["downloads"] = .rpcObject([:])
    services["appActions"] = .rpcObject([:])
    let rpc = CodexDesktopAppHostRPC(
        services: services,
        send: { sentFrames.append($0) }
    )

    let pushResponses = try rpc.receive(
        #"["push",["pipeline",0,["services"]]]"#
    )
    let pullResponses = try rpc.receive(#"["pull",1]"#)

    #expect(pushResponses.isEmpty)
    #expect(
        pullResponses
            == [
                #"["resolve",1,{"appActions":["export",-1],"downloads":["export",-2]}]"#
            ]
    )
    #expect(sentFrames == pullResponses)
    #expect(
        rpc.snapshot
            == CodexDesktopAppHostRPC.Snapshot(
                importIDs: [0],
                exportIDs: [-2, -1, 0, 1],
                pendingPullIDs: [],
                nextPipelineExportID: 2,
                nextRPCExportID: -3
            )
    )
}

@Test
func desktopAppHostRPCMaintainsPipelineAndRPCExportIDsAcrossRelease() throws {
    let rpc = CodexDesktopAppHostRPC(
        services: [
            "appActions": .rpcObject([
                "menu": .rpcObject([
                    "isEnabled": .bool(true)
                ])
            ])
        ]
    )

    _ = try rpc.receive(
        #"["push",["pipeline",0,["services"]]]"#
    )
    _ = try rpc.receive(#"["pull",1]"#)
    _ = try rpc.receive(#"["release",1,1]"#)

    _ = try rpc.receive(
        #"["push",["pipeline",-1,["menu"]]]"#
    )
    let servicePull = try rpc.receive(#"["pull",2]"#)

    #expect(
        servicePull
            == [#"["resolve",2,["export",-2]]"#]
    )
    #expect(
        rpc.snapshot.exportIDs == [-2, -1, 0, 2]
    )
    #expect(rpc.snapshot.nextPipelineExportID == 3)
    #expect(rpc.snapshot.nextRPCExportID == -3)
}

@Test
func desktopAppHostRPCIgnoresADuplicateLateRelease() throws {
    let rpc = CodexDesktopAppHostRPC()

    _ = try rpc.receive(
        #"["push",["pipeline",0,["services"]]]"#
    )
    _ = try rpc.receive(#"["pull",1]"#)
    _ = try rpc.receive(#"["release",1,1]"#)

    #expect(
        try rpc.receive(#"["release",1,1]"#).isEmpty
    )
}

@Test
func desktopAppHostRPCDispatchesMethodPipelinesToTheNativeHandler() throws {
    var captured: CodexDesktopAppHostRPC.Pipeline?
    let rpc = CodexDesktopAppHostRPC(
        services: ["appActions": .rpcObject([:])],
        invocationHandler: { pipeline in
            captured = pipeline
            return .bool(true)
        }
    )

    _ = try rpc.receive(
        #"["push",["pipeline",0,["services"]]]"#
    )
    _ = try rpc.receive(#"["pull",1]"#)
    _ = try rpc.receive(
        #"["push",["pipeline",-1,["open"],["project-1"]]]"#
    )
    let response = try rpc.receive(#"["pull",2]"#)

    #expect(
        captured
            == CodexDesktopAppHostRPC.Pipeline(
                targetID: -1,
                path: [.key("open")],
                arguments: [.string("project-1")]
            )
    )
    #expect(response == [#"["resolve",2,true]"#])
}

@MainActor
@Test
func desktopAppHostRPCResolvesAnAsyncNativeInvocation() async throws {
    let rpc = CodexDesktopAppHostRPC(
        services: ["workspaceFiles": .rpcObject([:])],
        asyncInvocationHandler: { pipeline in
            await Task.yield()
            #expect(
                pipeline.path == [.key("read")]
            )
            return .string("contents")
        }
    )

    _ = try await rpc.receiveAsync(
        #"["push",["pipeline",0,["services"]]]"#
    )
    _ = try await rpc.receiveAsync(#"["pull",1]"#)
    _ = try await rpc.receiveAsync(
        #"["push",["pipeline",-1,["read"],[{"path":"/workspace/a.txt"}]]]"#
    )
    let response = try await rpc.receiveAsync(#"["pull",2]"#)

    #expect(response == [#"["resolve",2,"contents"]"#])
}

@MainActor
@Test
func desktopAppHostRPCWaitResolvesAnAsyncInvocationResult() async throws {
    var nativeTargets: [Int] = []
    let rpc = CodexDesktopAppHostRPC(
        services: ["github": .rpcObject([:])],
        asyncInvocationHandler: { pipeline in
            nativeTargets.append(pipeline.targetID)
            guard pipeline.targetID < 0 else {
                throw CodexDesktopInitialAppHostRouter.Error
                    .unknownServiceTarget(pipeline.targetID)
            }
            return .object([
                "isInstalled": .bool(false),
                "isAuthenticated": .bool(false)
            ])
        }
    )

    _ = try await rpc.receiveAsync(
        #"["push",["pipeline",0,["services"]]]"#
    )
    _ = try await rpc.receiveAsync(#"["pull",1]"#)
    _ = try await rpc.receiveAsync(
        #"["push",["pipeline",-1,["request"],["gh-cli-status",{"hostId":"local"},"git_direct_call"]]]"#
    )
    _ = try await rpc.receiveAsync(
        #"["push",["pipeline",2,["wait"],[]]]"#
    )
    let response = try await rpc.receiveAsync(#"["pull",3]"#)

    #expect(nativeTargets == [-1])
    #expect(
        response
            == [
                #"["resolve",3,{"isAuthenticated":false,"isInstalled":false}]"#
            ]
    )
}

@MainActor
@Test
func desktopAppHostRPCStillReadsAWaitPropertyFromAnAsyncResult() async throws {
    let rpc = CodexDesktopAppHostRPC(
        services: ["github": .rpcObject([:])],
        asyncInvocationHandler: { _ in
            .object(["wait": .string("business-value")])
        }
    )

    _ = try await rpc.receiveAsync(
        #"["push",["pipeline",0,["services"]]]"#
    )
    _ = try await rpc.receiveAsync(#"["pull",1]"#)
    _ = try await rpc.receiveAsync(
        #"["push",["pipeline",-1,["request"],[]]]"#
    )
    _ = try await rpc.receiveAsync(
        #"["push",["pipeline",2,["wait"]]]"#
    )
    let response = try await rpc.receiveAsync(#"["pull",3]"#)

    #expect(response == [#"["resolve",3,"business-value"]"#])
}

@MainActor
@Test
func desktopAppHostRPCQueuesPipelineWhileItsAsyncTargetIsPending()
    async throws
{
    var unblockInvocation: CheckedContinuation<Void, Never>?
    let rpc = CodexDesktopAppHostRPC(
        services: ["github": .rpcObject([:])],
        asyncInvocationHandler: { _ in
            await withCheckedContinuation { continuation in
                unblockInvocation = continuation
            }
            return .rpcObject([
                "wait": .rpcObject([:])
            ])
        }
    )

    _ = try await rpc.receiveAsync(
        #"["push",["pipeline",0,["services"]]]"#
    )
    _ = try await rpc.receiveAsync(#"["pull",1]"#)

    let request = Task { @MainActor in
        try await rpc.receiveAsync(
            #"["push",["pipeline",-1,["request"],["gh-cli-status"]]]"#
        )
    }
    while unblockInvocation == nil {
        await Task.yield()
    }
    let wait = Task { @MainActor in
        try await rpc.receiveAsync(
            #"["push",["pipeline",2,["wait"],[]]]"#
        )
    }
    await Task.yield()

    unblockInvocation?.resume()
    _ = try await request.value
    _ = try await wait.value
    let response = try await rpc.receiveAsync(#"["pull",3]"#)

    #expect(response == [#"["resolve",3,["export",-2]]"#])
}

@MainActor
@Test
func desktopAppHostRPCQueuesPullWhileAsyncInvocationIsPending()
    async throws
{
    var unblockInvocation: CheckedContinuation<Void, Never>?
    let rpc = CodexDesktopAppHostRPC(
        services: ["notifications": .rpcObject([:])],
        asyncInvocationHandler: { _ in
            await withCheckedContinuation { continuation in
                unblockInvocation = continuation
            }
            return .array([])
        }
    )

    _ = try await rpc.receiveAsync(
        #"["push",["pipeline",0,["services"]]]"#
    )
    _ = try await rpc.receiveAsync(#"["pull",1]"#)

    let push = Task { @MainActor in
        try await rpc.receiveAsync(
            #"["push",["pipeline",-1,["list"],[]]]"#
        )
    }
    while unblockInvocation == nil {
        await Task.yield()
    }
    let pull = Task { @MainActor in
        try await rpc.receiveAsync(#"["pull",2]"#)
    }
    await Task.yield()

    unblockInvocation?.resume()
    _ = try await push.value
    #expect(
        try await pull.value
            == [#"["resolve",2,[[]]]"#]
    )
}

@MainActor
@Test
func desktopAppHostRPCQueuesPullThatArrivesBeforeItsPush()
    async throws
{
    let rpc = CodexDesktopAppHostRPC(
        services: ["status": .rpcObject([:])],
        asyncInvocationHandler: { _ in .bool(true) }
    )

    _ = try await rpc.receiveAsync(
        #"["push",["pipeline",0,["services"]]]"#
    )
    _ = try await rpc.receiveAsync(#"["pull",1]"#)

    let earlyPull = Task { @MainActor in
        try await rpc.receiveAsync(#"["pull",2]"#)
    }
    await Task.yield()

    _ = try await rpc.receiveAsync(
        #"["push",["pipeline",-1,["getState"],[]]]"#
    )

    #expect(
        try await earlyPull.value
            == [#"["resolve",2,true]"#]
    )
}

@Test
func desktopAppHostRPCRejectsAFailedPipelineWhenPulled() throws {
    let rpc = CodexDesktopAppHostRPC()

    _ = try rpc.receive(
        #"["push",["pipeline",0,["missing-service"]]]"#
    )
    let responses = try rpc.receive(#"["pull",1]"#)

    #expect(responses.count == 1)
    #expect(
        try CodexDesktopAppHostRPC.decode(responses[0])
            == .reject(
                id: 1,
                error: .error(
                    name: "Error",
                    message: "No RPC value at path: missing-service",
                    stack: nil
                )
            )
    )
    #expect(rpc.snapshot.pendingPullIDs.isEmpty)
}

@Test
func desktopAppHostRPCUsesCapnWebValueEncoding() throws {
    let arrayFrame = CodexDesktopAppHostRPC.Frame.resolve(
        id: 7,
        value: .array([
            .integer(1),
            .string("two"),
        ])
    )
    let undefinedFrame = CodexDesktopAppHostRPC.Frame.resolve(
        id: 8,
        value: .undefined
    )

    #expect(
        try CodexDesktopAppHostRPC.encode(arrayFrame)
            == #"["resolve",7,[[1,"two"]]]"#
    )
    #expect(
        try CodexDesktopAppHostRPC.decode(
            #"["resolve",7,[[1,"two"]]]"#
        ) == arrayFrame
    )
    #expect(
        try CodexDesktopAppHostRPC.encode(undefinedFrame)
            == #"["resolve",8,["undefined"]]"#
    )
}

@Test
func desktopAppHostRPCRejectsMalformedOrUnsupportedFrames() throws {
    #expect(throws: CodexDesktopAppHostRPC.Error.invalidFrame) {
        try CodexDesktopAppHostRPC.decode(#"{"type":"pull"}"#)
    }
    #expect(
        throws:
            CodexDesktopAppHostRPC.Error.unsupportedOperation("mystery")
    ) {
        try CodexDesktopAppHostRPC.decode(#"["mystery",1]"#)
    }
    #expect(throws: CodexDesktopAppHostRPC.Error.invalidPipeline) {
        try CodexDesktopAppHostRPC.decode(
            #"["push",["pipeline","zero",["services"]]]"#
        )
    }
}

@MainActor
@Test
func desktopAppHostRPCPreparesAndCompletesAnAwaitedImportCall()
    async throws
{
    let rpc = CodexDesktopAppHostRPC()

    let call = try rpc.prepareImportCall(
        targetID: 41,
        arguments: [.string("file-1")],
        awaitsResult: true
    )

    #expect(call.resultID == 1)
    #expect(
        call.frames
            == [
                #"["push",["pipeline",41,[],["file-1"]]]"#,
                #"["pull",1]"#,
            ]
    )
    #expect(rpc.snapshot.importIDs == [0, 1])

    let responses = try rpc.receive(
        #"["resolve",1,{"url":"https://example.invalid/file-1"}]"#
    )

    #expect(responses == [#"["release",1,1]"#])
    #expect(
        try await rpc.awaitImportResult(call.resultID)
            == .object([
                "url": .string(
                    "https://example.invalid/file-1"
                )
            ])
    )
    #expect(rpc.snapshot.importIDs == [0])
}

@MainActor
@Test
func desktopAppHostRPCInvalidationTerminatesAnAwaitedImportCall()
    async throws
{
    let rpc = CodexDesktopAppHostRPC()
    let call = try rpc.prepareImportCall(
        targetID: 41,
        arguments: [.string("file-1")],
        awaitsResult: true
    )
    var outcome: Result<
        CodexDesktopAppHostRPC.Value,
        Swift.Error
    >?
    let waiter = Task { @MainActor in
        do {
            outcome = .success(
                try await rpc.awaitImportResult(call.resultID)
            )
        } catch {
            outcome = .failure(error)
        }
    }
    await Task.yield()

    rpc.invalidate()
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
    #expect(rpc.snapshot.importIDs.isEmpty)
    _ = await waiter.result
}
