#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

/// Explicit action bridge used by native recovery surfaces.
public struct CodexNativeSurfaceActionBridge: Sendable {
    public typealias ReviewRevert =
        @MainActor @Sendable (String) async throws -> CodexJSONValue
    public typealias ReviewCommit =
        @MainActor @Sendable (String, String) async throws -> CodexJSONValue
    public typealias Terminal =
        @MainActor @Sendable (String, String) async throws -> CodexJSONValue

    public let revert: ReviewRevert
    public let commit: ReviewCommit
    public let terminal: Terminal

    public init(
        revert: @escaping ReviewRevert,
        commit: @escaping ReviewCommit,
        terminal: @escaping Terminal
    ) {
        self.revert = revert
        self.commit = commit
        self.terminal = terminal
    }
}

/// A small, transport-independent Cap'n Web session for the desktop renderer's
/// `connect-app-host` MessagePort.
///
/// The renderer sends and receives one JSON string per MessagePort message.
/// `receive(_:)` accepts that exact string and returns every string that should
/// be posted back to the renderer. `send` is optional so a WKWebView host can
/// either use the return value or wire responses directly to its native channel.
public final class CodexDesktopAppHostRPC {
    public typealias SendHandler = (String) -> Void
    public typealias InvocationHandler =
        (Pipeline) throws -> Value
    public typealias AsyncInvocationHandler =
        (Pipeline) async throws -> Value

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidFrame
        case unsupportedOperation(String)
        case invalidPipeline
        case invalidValue
        case unknownExport(Int)
        case unknownImport(Int)
        case invalidRelease(
            id: Int,
            count: Int,
            availableRefcount: Int
        )
        case sessionAborted
    }

    public enum PathComponent: Equatable, Sendable {
        case key(String)
        case index(Int)
    }

    /// A logical value before or after Cap'n Web's devaluate/evaluate step.
    ///
    /// Plain Swift arrays use Cap'n Web's one-element array marker on the wire.
    /// `rpcObject` is a local RpcTarget. When it crosses the wire the session
    /// allocates a negative export ID and sends `["export", id]`.
    public indirect enum Value: Equatable, Sendable {
        case undefined
        case null
        case bool(Bool)
        case integer(Int64)
        case number(Double)
        case string(String)
        case array([Value])
        case object([String: Value])
        case rpcObject([String: Value])
        case export(Int)
        case promise(Int)
        case `import`(Int)
        case error(
            name: String,
            message: String,
            stack: String?
        )
        case bigInt(String)
        case positiveInfinity
        case negativeInfinity
        case nan
    }

    public struct ImportRejection:
        Swift.Error,
        Equatable,
        Sendable
    {
        public let value: Value

        public init(value: Value) {
            self.value = value
        }
    }

    public struct Pipeline: Equatable, Sendable {
        public let targetID: Int
        public let path: [PathComponent]
        public let arguments: [Value]?

        public init(
            targetID: Int,
            path: [PathComponent],
            arguments: [Value]?
        ) {
            self.targetID = targetID
            self.path = path
            self.arguments = arguments
        }
    }

    public enum Frame: Equatable, Sendable {
        case push(Pipeline)
        case stream(Pipeline)
        case pipe
        case pull(Int)
        case resolve(id: Int, value: Value)
        case reject(id: Int, error: Value)
        case release(id: Int, count: Int)
        case abort(Value)
    }

    public struct PreparedImportCall:
        Equatable,
        Sendable
    {
        public let resultID: Int
        public let frames: [String]

        public init(
            resultID: Int,
            frames: [String]
        ) {
            self.resultID = resultID
            self.frames = frames
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let importIDs: [Int]
        public let exportIDs: [Int]
        public let pendingPullIDs: [Int]
        public let nextPipelineExportID: Int
        public let nextRPCExportID: Int

        public init(
            importIDs: [Int],
            exportIDs: [Int],
            pendingPullIDs: [Int],
            nextPipelineExportID: Int,
            nextRPCExportID: Int
        ) {
            self.importIDs = importIDs
            self.exportIDs = exportIDs
            self.pendingPullIDs = pendingPullIDs
            self.nextPipelineExportID = nextPipelineExportID
            self.nextRPCExportID = nextRPCExportID
        }
    }

    private enum ExportResolution {
        case pending
        case value(Value)
        case failure(Value)
    }

    private struct ExportEntry {
        var resolution: ExportResolution
        var refcount: Int
        var didRespondToPull: Bool
        let isPipelineResult: Bool
        let autoRelease: Bool
    }

    private enum ImportResolution {
        case pending
        case resolved(Value)
        case rejected(Value)
    }

    private var exports: [Int: ExportEntry]
    private var imports: [Int: ImportResolution]
    private var awaitedImportIDs = Set<Int>()
    private var pendingExportWaiters: [
        Int: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var importWaiters: [
        Int: CheckedContinuation<Value, Swift.Error>
    ] = [:]
    private var nextImportID = 1
    private var nextPipelineExportID = 1
    private var nextRPCExportID = -1
    private var abortValue: Value?
    private let sendHandler: SendHandler?
    private let invocationHandler: InvocationHandler?
    private let asyncInvocationHandler: AsyncInvocationHandler?

    public init(
        services: [String: Value] = [:],
        send: SendHandler? = nil,
        invocationHandler: InvocationHandler? = nil,
        asyncInvocationHandler: AsyncInvocationHandler? = nil
    ) {
        let root = Value.rpcObject([
            // The released host is an RpcTarget, while its `services` getter
            // returns a plain object whose individual service values are
            // RpcTargets. That distinction is visible on the wire: the first
            // pull resolves an object containing export tags rather than one
            // export tag for the services container.
            "services": .object(services)
        ])
        exports = [
            0: ExportEntry(
                resolution: .value(root),
                refcount: 1,
                didRespondToPull: false,
                isPipelineResult: false,
                autoRelease: false
            )
        ]
        imports = [0: .pending]
        sendHandler = send
        self.invocationHandler = invocationHandler
        self.asyncInvocationHandler = asyncInvocationHandler
    }

    public var snapshot: Snapshot {
        Snapshot(
            importIDs: imports.keys.sorted(),
            exportIDs: exports.keys.sorted(),
            pendingPullIDs: exports.compactMap { id, entry in
                guard entry.isPipelineResult,
                      !entry.didRespondToPull
                else {
                    return nil
                }
                return id
            }.sorted(),
            nextPipelineExportID: nextPipelineExportID,
            nextRPCExportID: nextRPCExportID
        )
    }

    /// Terminates this logical MessagePort session and resumes every native
    /// caller that is still waiting on renderer-owned work.
    ///
    /// A document reload can reuse `app-host-1`; the old session must not
    /// retain continuations after the store installs the replacement session.
    public func invalidate() {
        invalidate(with: Self.errorValue("RPC session was replaced"))
    }

    /// Prepares a call to a renderer-owned import.
    ///
    /// Cap'n Web assigns the call result the next positive import ID. Awaited
    /// calls send `push` followed by `pull`; one-way calls reserve the same ID
    /// but preserve their existing single-`push` wire behavior.
    public func prepareImportCall(
        targetID: Int,
        path: [PathComponent] = [],
        arguments: [Value],
        awaitsResult: Bool
    ) throws -> PreparedImportCall {
        guard abortValue == nil else {
            throw Error.sessionAborted
        }

        let pushFrame = try Self.encode(
            .push(
                Pipeline(
                    targetID: targetID,
                    path: path,
                    arguments: arguments
                )
            )
        )
        let resultID = nextImportID
        nextImportID += 1
        imports[resultID] = .pending
        if awaitsResult {
            awaitedImportIDs.insert(resultID)
        }

        var frames = [pushFrame]
        if awaitsResult {
            frames.append(
                try Self.encode(.pull(resultID))
            )
        }
        return PreparedImportCall(
            resultID: resultID,
            frames: frames
        )
    }

    /// Suspends until the peer resolves or rejects a prepared awaited call.
    @MainActor
    public func awaitImportResult(
        _ resultID: Int
    ) async throws -> Value {
        guard abortValue == nil else {
            throw Error.sessionAborted
        }
        return try await withCheckedThrowingContinuation {
            (
                continuation: CheckedContinuation<
                    Value,
                    Swift.Error
                >
            ) in
            guard awaitedImportIDs.contains(resultID),
                  let resolution = imports[resultID]
            else {
                continuation.resume(
                    throwing: Error.unknownImport(resultID)
                )
                return
            }

            switch resolution {
            case .pending:
                importWaiters[resultID] = continuation

            case let .resolved(value):
                awaitedImportIDs.remove(resultID)
                imports.removeValue(forKey: resultID)
                continuation.resume(returning: value)

            case let .rejected(value):
                awaitedImportIDs.remove(resultID)
                imports.removeValue(forKey: resultID)
                continuation.resume(
                    throwing: ImportRejection(value: value)
                )
            }
        }
    }

    /// Decode and process one MessagePort string frame.
    @discardableResult
    public func receive(_ message: String) throws -> [String] {
        guard abortValue == nil else {
            throw Error.sessionAborted
        }

        let responses = try process(Self.decode(message))
        let encoded = try responses.map(Self.encode)
        for response in encoded {
            sendHandler?(response)
        }
        return encoded
    }

    /// Async counterpart used by native services that touch the filesystem,
    /// app-server, permission APIs, or other iPadOS actors.
    @discardableResult
    @MainActor
    public func receiveAsync(_ message: String) async throws -> [String] {
        guard abortValue == nil else {
            throw Error.sessionAborted
        }

        let responses = try await processAsync(Self.decode(message))
        let encoded = try responses.map(Self.encode)
        for response in encoded {
            sendHandler?(response)
        }
        return encoded
    }

    /// Parse a single official string frame without changing session state.
    public static func decode(_ message: String) throws -> Frame {
        guard let data = message.data(using: .utf8) else {
            throw Error.invalidFrame
        }

        let root: AppHostJSONValue
        do {
            root = try JSONDecoder().decode(
                AppHostJSONValue.self,
                from: data
            )
        } catch {
            throw Error.invalidFrame
        }

        guard case let .array(fields) = root,
              let operation = fields.first?.stringValue
        else {
            throw Error.invalidFrame
        }

        switch operation {
        case "push":
            guard fields.count == 2 else {
                throw Error.invalidFrame
            }
            return .push(try decodePipeline(fields[1]))

        case "stream":
            guard fields.count == 2 else {
                throw Error.invalidFrame
            }
            return .stream(try decodePipeline(fields[1]))

        case "pipe":
            guard fields.count == 1 else {
                throw Error.invalidFrame
            }
            return .pipe

        case "pull":
            guard fields.count == 2,
                  let id = fields[1].intValue
            else {
                throw Error.invalidFrame
            }
            return .pull(id)

        case "resolve":
            guard fields.count == 3,
                  let id = fields[1].intValue
            else {
                throw Error.invalidFrame
            }
            return .resolve(
                id: id,
                value: try decodeValue(fields[2])
            )

        case "reject":
            guard fields.count == 3,
                  let id = fields[1].intValue
            else {
                throw Error.invalidFrame
            }
            return .reject(
                id: id,
                error: try decodeValue(fields[2])
            )

        case "release":
            guard fields.count == 3,
                  let id = fields[1].intValue,
                  let count = fields[2].intValue,
                  count > 0
            else {
                throw Error.invalidFrame
            }
            return .release(id: id, count: count)

        case "abort":
            guard fields.count == 2 else {
                throw Error.invalidFrame
            }
            return .abort(try decodeValue(fields[1]))

        default:
            throw Error.unsupportedOperation(operation)
        }
    }

    /// Encode a single frame as the exact JSON string posted on MessagePort.
    public static func encode(_ frame: Frame) throws -> String {
        let wire: AppHostJSONValue
        switch frame {
        case let .push(pipeline):
            wire = .array([
                .string("push"),
                try encodePipeline(pipeline),
            ])

        case let .stream(pipeline):
            wire = .array([
                .string("stream"),
                try encodePipeline(pipeline),
            ])

        case .pipe:
            wire = .array([.string("pipe")])

        case let .pull(id):
            wire = .array([
                .string("pull"),
                .integer(Int64(id)),
            ])

        case let .resolve(id, value):
            wire = .array([
                .string("resolve"),
                .integer(Int64(id)),
                try encodeValue(value),
            ])

        case let .reject(id, error):
            wire = .array([
                .string("reject"),
                .integer(Int64(id)),
                try encodeValue(error),
            ])

        case let .release(id, count):
            guard count > 0 else {
                throw Error.invalidFrame
            }
            wire = .array([
                .string("release"),
                .integer(Int64(id)),
                .integer(Int64(count)),
            ])

        case let .abort(value):
            wire = .array([
                .string("abort"),
                try encodeValue(value),
            ])
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let data: Data
        do {
            data = try encoder.encode(wire)
        } catch {
            throw Error.invalidValue
        }
        guard let message = String(data: data, encoding: .utf8) else {
            throw Error.invalidValue
        }
        return message
    }

    private func process(_ frame: Frame) throws -> [Frame] {
        switch frame {
        case let .push(pipeline):
            appendPipelineExport(
                pipeline,
                autoRelease: false
            )
            return []

        case let .stream(pipeline):
            let id = appendPipelineExport(
                pipeline,
                autoRelease: true
            )
            return try resolveExport(id)

        case .pipe:
            let id = nextPipelineExportID
            nextPipelineExportID += 1
            exports[id] = ExportEntry(
                resolution: .failure(
                    Self.errorValue(
                        "Readable/writable pipe transport is not registered"
                    )
                ),
                refcount: 1,
                didRespondToPull: false,
                isPipelineResult: true,
                autoRelease: false
            )
            return []

        case let .pull(id):
            return try resolveExport(id)

        case let .resolve(id, value):
            return completeImport(
                id: id,
                resolution: .resolved(value)
            )

        case let .reject(id, error):
            return completeImport(
                id: id,
                resolution: .rejected(error)
            )

        case let .release(id, count):
            try releaseExport(id: id, count: count)
            return []

        case let .abort(value):
            invalidate(with: value)
            return []
        }
    }

    private func invalidate(with value: Value) {
        guard abortValue == nil else {
            return
        }
        abortValue = value

        let waiters = Array(importWaiters.values)
        importWaiters.removeAll()
        awaitedImportIDs.removeAll()
        imports.removeAll()
        exports.removeAll()

        let exportWaiters = pendingExportWaiters.values.flatMap { $0 }
        pendingExportWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: Error.sessionAborted)
        }
        for waiter in exportWaiters {
            waiter.resume()
        }
    }

    @MainActor
    private func processAsync(_ frame: Frame) async throws -> [Frame] {
        switch frame {
        case let .push(pipeline):
            await appendPipelineExportAsync(
                pipeline,
                autoRelease: false
            )
            return []

        case let .stream(pipeline):
            let id = await appendPipelineExportAsync(
                pipeline,
                autoRelease: true
            )
            return try resolveExport(id)

        case .pipe:
            return try process(frame)

        case let .pull(id):
            return try await resolveExportAsync(id)

        case let .resolve(id, value):
            return completeImport(
                id: id,
                resolution: .resolved(value)
            )

        case let .reject(id, error):
            return completeImport(
                id: id,
                resolution: .rejected(error)
            )

        case let .release(id, count):
            try releaseExport(id: id, count: count)
            return []

        case let .abort(value):
            abortValue = value
            return []
        }
    }

    @discardableResult
    private func appendPipelineExport(
        _ pipeline: Pipeline,
        autoRelease: Bool
    ) -> Int {
        let id = nextPipelineExportID
        nextPipelineExportID += 1
        exports[id] = ExportEntry(
            resolution: resolve(pipeline),
            refcount: 1,
            didRespondToPull: false,
            isPipelineResult: true,
            autoRelease: autoRelease
        )
        return id
    }

    private func completeImport(
        id: Int,
        resolution: ImportResolution
    ) -> [Frame] {
        guard awaitedImportIDs.contains(id) else {
            imports[id] = resolution
            return []
        }

        imports[id] = resolution
        guard let continuation = importWaiters.removeValue(
            forKey: id
        ) else {
            return [.release(id: id, count: 1)]
        }

        awaitedImportIDs.remove(id)
        imports.removeValue(forKey: id)
        switch resolution {
        case .pending:
            break
        case let .resolved(value):
            continuation.resume(returning: value)
        case let .rejected(value):
            continuation.resume(
                throwing: ImportRejection(value: value)
            )
        }
        return [.release(id: id, count: 1)]
    }

    private func resolve(_ pipeline: Pipeline) -> ExportResolution {
        guard let target = exports[pipeline.targetID] else {
            return .failure(
                Self.errorValue(
                    "No RPC export with ID: \(pipeline.targetID)"
                )
            )
        }

        let initial: Value
        switch target.resolution {
        case .pending:
            return .failure(
                Self.errorValue(
                    "RPC export is still pending: \(pipeline.targetID)"
                )
            )
        case let .value(value):
            initial = value
        case let .failure(error):
            return .failure(error)
        }

        if pipeline.targetID <= 0,
           pipeline.arguments != nil,
           let invocationHandler
        {
            do {
                return .value(try invocationHandler(pipeline))
            } catch {
                return .failure(
                    Self.errorValue(String(describing: error))
                )
            }
        }

        var current = initial
        var consumedPath: [PathComponent] = []
        for component in pipeline.path {
            consumedPath.append(component)
            switch dereference(current) {
            case .pending:
                return .failure(
                    Self.errorValue("RPC export is still pending")
                )
            case let .value(value):
                switch (value, component) {
                case let (.object(fields), .key(key)),
                     let (.rpcObject(fields), .key(key)):
                    guard let next = fields[key] else {
                        return .failure(
                            Self.pathError(consumedPath)
                        )
                    }
                    current = next

                case let (.array(values), .index(index)):
                    guard values.indices.contains(index) else {
                        return .failure(
                            Self.pathError(consumedPath)
                        )
                    }
                    current = values[index]

                case let (.object(fields), .index(index)),
                     let (.rpcObject(fields), .index(index)):
                    guard let next = fields[String(index)] else {
                        return .failure(
                            Self.pathError(consumedPath)
                        )
                    }
                    current = next

                default:
                    return .failure(
                        Self.pathError(consumedPath)
                    )
                }

            case let .failure(error):
                return .failure(error)
            }
        }

        if pipeline.arguments != nil,
           pipeline.targetID <= 0
        {
            return .failure(
                Self.errorValue(
                    "No RPC invocation handler for path: "
                        + Self.render(pipeline.path)
                )
            )
        }

        return dereference(current)
    }

    @discardableResult
    @MainActor
    private func appendPipelineExportAsync(
        _ pipeline: Pipeline,
        autoRelease: Bool
    ) async -> Int {
        let id = nextPipelineExportID
        nextPipelineExportID += 1
        exports[id] = ExportEntry(
            resolution: .pending,
            refcount: 1,
            didRespondToPull: false,
            isPipelineResult: true,
            autoRelease: autoRelease
        )
        let resolution = await resolveAsync(pipeline)
        if var entry = exports[id] {
            entry.resolution = resolution
            exports[id] = entry
        }
        let waiters = pendingExportWaiters.removeValue(
            forKey: id
        ) ?? []
        for waiter in waiters {
            waiter.resume()
        }
        return id
    }

    @MainActor
    private func resolveAsync(
        _ pipeline: Pipeline
    ) async -> ExportResolution {
        if pipeline.targetID <= 0,
           pipeline.arguments != nil,
           let asyncInvocationHandler
        {
            do {
                return .value(
                    try await asyncInvocationHandler(pipeline)
                )
            } catch {
                return .failure(
                    Self.errorValue(String(describing: error))
                )
            }
        }
        if pipeline.targetID > 0 {
            await waitForExportResolution(pipeline.targetID)
        }
        if pipeline.targetID > 0,
           pipeline.path == [.key("wait")],
           pipeline.arguments?.isEmpty == true,
           let target = exports[pipeline.targetID],
           target.isPipelineResult
        {
            return target.resolution
        }
        return resolve(pipeline)
    }

    @MainActor
    private func waitForExportResolution(_ id: Int) async {
        while true {
            if abortValue != nil {
                return
            }
            if let entry = exports[id] {
                guard case .pending = entry.resolution else {
                    return
                }
            } else if id != nextPipelineExportID {
                return
            }
            await withCheckedContinuation { continuation in
                pendingExportWaiters[id, default: []].append(
                    continuation
                )
            }
        }
    }

    private func dereference(_ value: Value) -> ExportResolution {
        guard case let .export(id) = value else {
            return .value(value)
        }
        guard let entry = exports[id] else {
            return .failure(
                Self.errorValue("No RPC export with ID: \(id)")
            )
        }
        if case .pending = entry.resolution {
            return .failure(
                Self.errorValue("RPC export is still pending: \(id)")
            )
        }
        return entry.resolution
    }

    @MainActor
    private func resolveExportAsync(
        _ id: Int
    ) async throws -> [Frame] {
        await waitForExportResolution(id)
        guard abortValue == nil else {
            throw Error.sessionAborted
        }
        return try resolveExport(id)
    }

    private func resolveExport(_ id: Int) throws -> [Frame] {
        guard var entry = exports[id] else {
            return [
                .reject(
                    id: id,
                    error: Self.errorValue(
                        "No RPC export with ID: \(id)"
                    )
                )
            ]
        }
        guard !entry.didRespondToPull else {
            return []
        }

        let response: Frame
        switch entry.resolution {
        case .pending:
            return []
        case let .value(value):
            response = .resolve(
                id: id,
                value: try materializeRPCObjects(value)
            )
        case let .failure(error):
            response = .reject(id: id, error: error)
        }

        entry.didRespondToPull = true
        exports[id] = entry
        if entry.autoRelease {
            try releaseExport(id: id, count: 1)
        }
        return [response]
    }

    private func materializeRPCObjects(
        _ value: Value,
        depth: Int = 0
    ) throws -> Value {
        guard depth < 64 else {
            throw Error.invalidValue
        }

        switch value {
        case let .rpcObject(fields):
            let id = nextRPCExportID
            nextRPCExportID -= 1
            exports[id] = ExportEntry(
                resolution: .value(.rpcObject(fields)),
                refcount: 1,
                didRespondToPull: false,
                isPipelineResult: false,
                autoRelease: false
            )
            return .export(id)

        case let .array(values):
            return .array(
                try values.map {
                    try materializeRPCObjects(
                        $0,
                        depth: depth + 1
                    )
                }
            )

        case let .object(fields):
            var materialized: [String: Value] = [:]
            materialized.reserveCapacity(fields.count)
            // Cap'n Web assigns export IDs while walking object properties.
            // Swift Dictionary iteration is intentionally unordered, so walking
            // it directly makes the same services object produce different
            // negative IDs between processes. A canonical key walk keeps the
            // renderer-visible export table stable.
            for key in fields.keys.sorted() {
                guard let field = fields[key] else {
                    continue
                }
                materialized[key] = try materializeRPCObjects(
                    field,
                    depth: depth + 1
                )
            }
            return .object(materialized)

        default:
            return value
        }
    }

    private func releaseExport(id: Int, count: Int) throws {
        guard var entry = exports[id] else {
            return
        }
        guard count > 0, count <= entry.refcount else {
            throw Error.invalidRelease(
                id: id,
                count: count,
                availableRefcount: entry.refcount
            )
        }

        entry.refcount -= count
        if entry.refcount == 0 {
            exports.removeValue(forKey: id)
        } else {
            exports[id] = entry
        }
    }

    private static func decodePipeline(
        _ wire: AppHostJSONValue
    ) throws -> Pipeline {
        guard case let .array(fields) = wire,
              fields.count == 3 || fields.count == 4,
              fields[0].stringValue == "pipeline",
              let targetID = fields[1].intValue,
              case let .array(pathFields) = fields[2]
        else {
            throw Error.invalidPipeline
        }

        let path: [PathComponent] = try pathFields.map { component in
            if let key = component.stringValue {
                return .key(key)
            }
            if let index = component.intValue {
                return .index(index)
            }
            throw Error.invalidPipeline
        }

        let arguments: [Value]?
        if fields.count == 4 {
            guard case let .array(argumentFields) = fields[3] else {
                throw Error.invalidPipeline
            }
            arguments = try argumentFields.map {
                try decodeValue($0)
            }
        } else {
            arguments = nil
        }

        return Pipeline(
            targetID: targetID,
            path: path,
            arguments: arguments
        )
    }

    private static func encodePipeline(
        _ pipeline: Pipeline
    ) throws -> AppHostJSONValue {
        var fields: [AppHostJSONValue] = [
            .string("pipeline"),
            .integer(Int64(pipeline.targetID)),
            .array(
                pipeline.path.map { component in
                    switch component {
                    case let .key(key):
                        return .string(key)
                    case let .index(index):
                        return .integer(Int64(index))
                    }
                }
            ),
        ]

        if let arguments = pipeline.arguments {
            fields.append(
                .array(
                    try arguments.map {
                        try encodeValue($0)
                    }
                )
            )
        }
        return .array(fields)
    }

    private static func decodeValue(
        _ wire: AppHostJSONValue,
        depth: Int = 0
    ) throws -> Value {
        guard depth < 64 else {
            throw Error.invalidValue
        }

        switch wire {
        case .null:
            return .null
        case let .bool(value):
            return .bool(value)
        case let .integer(value):
            return .integer(value)
        case let .number(value):
            return .number(value)
        case let .string(value):
            return .string(value)

        case let .object(fields):
            return .object(
                try fields.mapValues {
                    try decodeValue($0, depth: depth + 1)
                }
            )

        case let .array(fields):
            if fields.count == 1,
               case let .array(arrayFields) = fields[0]
            {
                return .array(
                    try arrayFields.map {
                        try decodeValue($0, depth: depth + 1)
                    }
                )
            }

            guard let tag = fields.first?.stringValue else {
                throw Error.invalidValue
            }
            switch tag {
            case "undefined":
                guard fields.count == 1 else {
                    throw Error.invalidValue
                }
                return .undefined

            case "export":
                guard fields.count == 2,
                      let id = fields[1].intValue
                else {
                    throw Error.invalidValue
                }
                return .import(id)

            case "promise":
                guard fields.count == 2,
                      let id = fields[1].intValue
                else {
                    throw Error.invalidValue
                }
                return .promise(id)

            case "import":
                guard fields.count == 2,
                      let id = fields[1].intValue
                else {
                    throw Error.invalidValue
                }
                return .export(id)

            case "error":
                guard fields.count == 3 || fields.count == 4,
                      let name = fields[1].stringValue,
                      let message = fields[2].stringValue
                else {
                    throw Error.invalidValue
                }
                let stack: String?
                if fields.count == 4 {
                    guard let decodedStack = fields[3].stringValue else {
                        throw Error.invalidValue
                    }
                    stack = decodedStack
                } else {
                    stack = nil
                }
                return .error(
                    name: name,
                    message: message,
                    stack: stack
                )

            case "bigint":
                guard fields.count == 2,
                      let value = fields[1].stringValue
                else {
                    throw Error.invalidValue
                }
                return .bigInt(value)

            case "inf":
                guard fields.count == 1 else {
                    throw Error.invalidValue
                }
                return .positiveInfinity

            case "-inf":
                guard fields.count == 1 else {
                    throw Error.invalidValue
                }
                return .negativeInfinity

            case "nan":
                guard fields.count == 1 else {
                    throw Error.invalidValue
                }
                return .nan

            default:
                throw Error.invalidValue
            }
        }
    }

    private static func encodeValue(
        _ value: Value,
        depth: Int = 0
    ) throws -> AppHostJSONValue {
        guard depth < 64 else {
            throw Error.invalidValue
        }

        switch value {
        case .undefined:
            return .array([.string("undefined")])
        case .null:
            return .null
        case let .bool(value):
            return .bool(value)
        case let .integer(value):
            return .integer(value)
        case let .number(value):
            guard value.isFinite else {
                throw Error.invalidValue
            }
            return .number(value)
        case let .string(value):
            return .string(value)
        case let .array(values):
            return .array([
                .array(
                    try values.map {
                        try encodeValue($0, depth: depth + 1)
                    }
                )
            ])
        case let .object(fields):
            return .object(
                try fields.mapValues {
                    try encodeValue($0, depth: depth + 1)
                }
            )
        case .rpcObject:
            throw Error.invalidValue
        case let .export(id):
            return .array([
                .string("export"),
                .integer(Int64(id)),
            ])
        case let .promise(id):
            return .array([
                .string("promise"),
                .integer(Int64(id)),
            ])
        case let .import(id):
            return .array([
                .string("import"),
                .integer(Int64(id)),
            ])
        case let .error(name, message, stack):
            var fields: [AppHostJSONValue] = [
                .string("error"),
                .string(name),
                .string(message),
            ]
            if let stack {
                fields.append(.string(stack))
            }
            return .array(fields)
        case let .bigInt(value):
            return .array([
                .string("bigint"),
                .string(value),
            ])
        case .positiveInfinity:
            return .array([.string("inf")])
        case .negativeInfinity:
            return .array([.string("-inf")])
        case .nan:
            return .array([.string("nan")])
        }
    }

    private static func errorValue(_ message: String) -> Value {
        .error(
            name: "Error",
            message: message,
            stack: nil
        )
    }

    private static func pathError(
        _ path: [PathComponent]
    ) -> Value {
        errorValue("No RPC value at path: \(render(path))")
    }

    private static func render(
        _ path: [PathComponent]
    ) -> String {
        path.map { component in
            switch component {
            case let .key(key):
                return key
            case let .index(index):
                return String(index)
            }
        }.joined(separator: ".")
    }
}

private indirect enum AppHostJSONValue:
    Codable,
    Equatable
{
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([AppHostJSONValue])
    case object([String: AppHostJSONValue])

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    var intValue: Int? {
        switch self {
        case let .integer(value):
            return Int(exactly: value)
        case let .number(value):
            guard value.isFinite,
                  value.rounded(.towardZero) == value
            else {
                return nil
            }
            return Int(exactly: value)
        default:
            return nil
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(
            [AppHostJSONValue].self
        ) {
            self = .array(value)
        } else {
            self = .object(
                try container.decode(
                    [String: AppHostJSONValue].self
                )
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}
