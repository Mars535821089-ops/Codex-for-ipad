#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public enum CodexRemoteControlWebSocketLimits {
    public static let targetSegmentBytes = 100 * 1_024
    public static let maximumWireEnvelopeBytes = 150 * 1_024
    public static let maximumReassembledMessageBytes = 100 * 1_024 * 1_024
    public static let maximumSegmentCount = 1_024
    public static let maximumConcurrentAssemblies = 128
}

public enum CodexRemoteControlClientEvent: Equatable, Sendable {
    case clientMessage(CodexJSONValue)
    case clientMessageChunk(
        segmentID: Int,
        segmentCount: Int,
        messageSizeBytes: Int,
        messageChunkBase64: String
    )
    case ack(segmentID: Int?)
    case ping
    case clientClosed
}

extension CodexRemoteControlClientEvent: Codable {
    private enum EventType: String, Codable {
        case clientMessage = "client_message"
        case clientMessageChunk = "client_message_chunk"
        case ack
        case ping
        case clientClosed = "client_closed"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case message
        case segmentID = "segment_id"
        case segmentCount = "segment_count"
        case messageSizeBytes = "message_size_bytes"
        case messageChunkBase64 = "message_chunk_base64"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EventType.self, forKey: .type) {
        case .clientMessage:
            self = .clientMessage(
                try container.decode(CodexJSONValue.self, forKey: .message)
            )
        case .clientMessageChunk:
            self = .clientMessageChunk(
                segmentID: try container.decode(Int.self, forKey: .segmentID),
                segmentCount: try container.decode(
                    Int.self,
                    forKey: .segmentCount
                ),
                messageSizeBytes: try container.decode(
                    Int.self,
                    forKey: .messageSizeBytes
                ),
                messageChunkBase64: try container.decode(
                    String.self,
                    forKey: .messageChunkBase64
                )
            )
        case .ack:
            self = .ack(
                segmentID: try container.decodeIfPresent(
                    Int.self,
                    forKey: .segmentID
                )
            )
        case .ping:
            self = .ping
        case .clientClosed:
            self = .clientClosed
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .clientMessage(message):
            try container.encode(EventType.clientMessage, forKey: .type)
            try container.encode(message, forKey: .message)
        case let .clientMessageChunk(
            segmentID,
            segmentCount,
            messageSizeBytes,
            messageChunkBase64
        ):
            try container.encode(EventType.clientMessageChunk, forKey: .type)
            try container.encode(segmentID, forKey: .segmentID)
            try container.encode(segmentCount, forKey: .segmentCount)
            try container.encode(messageSizeBytes, forKey: .messageSizeBytes)
            try container.encode(
                messageChunkBase64,
                forKey: .messageChunkBase64
            )
        case let .ack(segmentID):
            try container.encode(EventType.ack, forKey: .type)
            try container.encodeIfPresent(segmentID, forKey: .segmentID)
        case .ping:
            try container.encode(EventType.ping, forKey: .type)
        case .clientClosed:
            try container.encode(EventType.clientClosed, forKey: .type)
        }
    }
}

public struct CodexRemoteControlClientEnvelope:
    Codable,
    Equatable,
    Sendable
{
    public let event: CodexRemoteControlClientEvent
    public let clientID: String
    public let streamID: String?
    public let seqID: UInt64?
    public let cursor: String?

    public init(
        event: CodexRemoteControlClientEvent,
        clientID: String,
        streamID: String?,
        seqID: UInt64?,
        cursor: String?
    ) {
        self.event = event
        self.clientID = clientID
        self.streamID = streamID
        self.seqID = seqID
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case streamID = "stream_id"
        case seqID = "seq_id"
        case cursor
    }

    public init(from decoder: any Decoder) throws {
        event = try CodexRemoteControlClientEvent(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try container.decode(String.self, forKey: .clientID)
        streamID = try container.decodeIfPresent(String.self, forKey: .streamID)
        seqID = try container.decodeIfPresent(UInt64.self, forKey: .seqID)
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
    }

    public func encode(to encoder: any Encoder) throws {
        try event.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientID, forKey: .clientID)
        try container.encodeIfPresent(streamID, forKey: .streamID)
        try container.encodeIfPresent(seqID, forKey: .seqID)
        try container.encodeIfPresent(cursor, forKey: .cursor)
    }
}

public enum CodexRemoteControlPongStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case active
    case unknown
}

public enum CodexRemoteControlServerEvent: Equatable, Sendable {
    case serverMessage(CodexJSONValue)
    case serverMessageChunk(
        segmentID: Int,
        segmentCount: Int,
        messageSizeBytes: Int,
        messageChunkBase64: String
    )
    case ack
    case pong(status: CodexRemoteControlPongStatus)

    public var segmentID: Int? {
        guard case let .serverMessageChunk(segmentID, _, _, _) = self else {
            return nil
        }
        return segmentID
    }
}

extension CodexRemoteControlServerEvent: Codable {
    private enum EventType: String, Codable {
        case serverMessage = "server_message"
        case serverMessageChunk = "server_message_chunk"
        case ack
        case pong
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case message
        case segmentID = "segment_id"
        case segmentCount = "segment_count"
        case messageSizeBytes = "message_size_bytes"
        case messageChunkBase64 = "message_chunk_base64"
        case status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EventType.self, forKey: .type) {
        case .serverMessage:
            self = .serverMessage(
                try container.decode(CodexJSONValue.self, forKey: .message)
            )
        case .serverMessageChunk:
            self = .serverMessageChunk(
                segmentID: try container.decode(Int.self, forKey: .segmentID),
                segmentCount: try container.decode(
                    Int.self,
                    forKey: .segmentCount
                ),
                messageSizeBytes: try container.decode(
                    Int.self,
                    forKey: .messageSizeBytes
                ),
                messageChunkBase64: try container.decode(
                    String.self,
                    forKey: .messageChunkBase64
                )
            )
        case .ack:
            self = .ack
        case .pong:
            self = .pong(
                status: try container.decode(
                    CodexRemoteControlPongStatus.self,
                    forKey: .status
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .serverMessage(message):
            try container.encode(EventType.serverMessage, forKey: .type)
            try container.encode(message, forKey: .message)
        case let .serverMessageChunk(
            segmentID,
            segmentCount,
            messageSizeBytes,
            messageChunkBase64
        ):
            try container.encode(EventType.serverMessageChunk, forKey: .type)
            try container.encode(segmentID, forKey: .segmentID)
            try container.encode(segmentCount, forKey: .segmentCount)
            try container.encode(messageSizeBytes, forKey: .messageSizeBytes)
            try container.encode(
                messageChunkBase64,
                forKey: .messageChunkBase64
            )
        case .ack:
            try container.encode(EventType.ack, forKey: .type)
        case let .pong(status):
            try container.encode(EventType.pong, forKey: .type)
            try container.encode(status, forKey: .status)
        }
    }
}

public struct CodexRemoteControlServerEnvelope:
    Codable,
    Equatable,
    Sendable
{
    public let event: CodexRemoteControlServerEvent
    public let clientID: String
    public let streamID: String
    public let seqID: UInt64

    public init(
        event: CodexRemoteControlServerEvent,
        clientID: String,
        streamID: String,
        seqID: UInt64
    ) {
        self.event = event
        self.clientID = clientID
        self.streamID = streamID
        self.seqID = seqID
    }

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case streamID = "stream_id"
        case seqID = "seq_id"
    }

    public init(from decoder: any Decoder) throws {
        event = try CodexRemoteControlServerEvent(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try container.decode(String.self, forKey: .clientID)
        streamID = try container.decode(String.self, forKey: .streamID)
        seqID = try container.decode(UInt64.self, forKey: .seqID)
    }

    public func encode(to encoder: any Encoder) throws {
        try event.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(streamID, forKey: .streamID)
        try container.encode(seqID, forKey: .seqID)
    }
}

public enum CodexRemoteControlWebSocketCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decodeClientEnvelope(
        _ data: Data
    ) throws -> CodexRemoteControlClientEnvelope {
        try JSONDecoder().decode(CodexRemoteControlClientEnvelope.self, from: data)
    }

    public static func decodeServerEnvelope(
        _ data: Data
    ) throws -> CodexRemoteControlServerEnvelope {
        try JSONDecoder().decode(CodexRemoteControlServerEnvelope.self, from: data)
    }
}

public enum CodexRemoteControlInboundDiscardReason:
    String,
    Codable,
    Equatable,
    Sendable
{
    case malformedEnvelope
    case missingChunkIdentity
    case invalidSegmentMetadata
    case wireEnvelopeTooLarge
    case staleOrDuplicate
    case metadataMismatch
    case outOfOrder
    case invalidBase64
    case sizeOverflow
    case finalSizeMismatch
    case invalidJSONMessage
}

private struct CodexRemoteControlChunkSequence:
    Hashable,
    Sendable
{
    let clientID: String
    let streamID: String
    let seqID: UInt64
}

public struct CodexRemoteControlInboundDelivery: Equatable, Sendable {
    public let envelope: CodexRemoteControlClientEnvelope
    fileprivate let chunkSequence: CodexRemoteControlChunkSequence?

    fileprivate init(
        envelope: CodexRemoteControlClientEnvelope,
        chunkSequence: CodexRemoteControlChunkSequence?
    ) {
        self.envelope = envelope
        self.chunkSequence = chunkSequence
    }
}

public enum CodexRemoteControlInboundAction: Equatable, Sendable {
    case deliver(CodexRemoteControlInboundDelivery)
    case pending
    case ignored
    case discarded(CodexRemoteControlInboundDiscardReason)
}

public enum CodexRemoteControlWebSocketProtocolError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case messageTooLarge(actualBytes: Int, limitBytes: Int)
    case segmentCountExceedsLimit(actual: Int, limit: Int)
    case wireEnvelopeCannotFit(limitBytes: Int)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .messageTooLarge(actualBytes, limitBytes):
            "Remote-control message is \(actualBytes) bytes; limit is \(limitBytes) bytes"
        case let .segmentCountExceedsLimit(actual, limit):
            "Remote-control message needs \(actual) segments; limit is \(limit)"
        case let .wireEnvelopeCannotFit(limitBytes):
            "Remote-control envelope cannot fit the \(limitBytes)-byte wire limit"
        case let .encodingFailed(message):
            "Remote-control JSON encoding failed: \(message)"
        }
    }
}

private struct CodexRemoteControlStreamKey: Hashable, Sendable {
    let clientID: String
    let streamID: String
}

private struct CodexRemoteControlSegmentMetadata: Equatable, Sendable {
    let seqID: UInt64
    let segmentCount: Int
    let messageSizeBytes: Int
}

private struct CodexRemoteControlSegmentAssembly: Sendable {
    let metadata: CodexRemoteControlSegmentMetadata
    var raw: Data
    var nextSegmentID: Int
    var lastSeenOrder: UInt64
}

public struct CodexRemoteControlWebSocketProtocolState: Sendable {
    public private(set) var subscribeCursor: String?

    private var outboundBuffer: [CodexRemoteControlServerEnvelope] = []
    private var nextSequenceByStream: [CodexRemoteControlStreamKey: UInt64] = [:]
    private var completedChunkSequenceByStream:
        [CodexRemoteControlStreamKey: UInt64] = [:]
    private var assembliesByStream:
        [CodexRemoteControlStreamKey: CodexRemoteControlSegmentAssembly] = [:]
    private var observationOrder: UInt64 = 0

    public init(subscribeCursor: String? = nil) {
        self.subscribeCursor = subscribeCursor
    }

    public var replayEnvelopes: [CodexRemoteControlServerEnvelope] {
        outboundBuffer
    }

    public var bufferedEnvelopeCount: Int {
        outboundBuffer.count
    }

    public var activeAssemblyCount: Int {
        assembliesByStream.count
    }

    public func nextSequenceID(clientID: String, streamID: String) -> UInt64 {
        nextSequenceByStream[
            CodexRemoteControlStreamKey(
                clientID: clientID,
                streamID: streamID
            )
        ] ?? 1
    }

    public mutating func prepareOutbound(
        event: CodexRemoteControlServerEvent,
        clientID: String,
        streamID: String
    ) throws -> [CodexRemoteControlServerEnvelope] {
        let key = CodexRemoteControlStreamKey(
            clientID: clientID,
            streamID: streamID
        )
        let sequenceID = nextSequenceByStream[key] ?? 1
        let logicalEnvelope = CodexRemoteControlServerEnvelope(
            event: event,
            clientID: clientID,
            streamID: streamID,
            seqID: sequenceID
        )
        let wireEnvelopes = try splitForWire(logicalEnvelope)
        outboundBuffer.append(contentsOf: wireEnvelopes)
        nextSequenceByStream[key] = sequenceID == UInt64.max
            ? UInt64.max
            : sequenceID + 1
        return wireEnvelopes
    }

    public mutating func observeInboundText(
        _ text: String
    ) -> CodexRemoteControlInboundAction {
        let data = Data(text.utf8)
        do {
            let envelope = try CodexRemoteControlWebSocketCodec
                .decodeClientEnvelope(data)
            return observeInbound(envelope, wireSizeBytes: data.count)
        } catch {
            return .discarded(.malformedEnvelope)
        }
    }

    public mutating func observeInbound(
        _ envelope: CodexRemoteControlClientEnvelope,
        wireSizeBytes: Int
    ) -> CodexRemoteControlInboundAction {
        switch envelope.event {
        case let .clientMessage(message):
            guard case .object = message else {
                return .discarded(.invalidJSONMessage)
            }
            return .deliver(
                CodexRemoteControlInboundDelivery(
                    envelope: envelope,
                    chunkSequence: nil
                )
            )
        case .clientMessageChunk:
            break
        case .ack, .ping, .clientClosed:
            return .deliver(
                CodexRemoteControlInboundDelivery(
                    envelope: envelope,
                    chunkSequence: nil
                )
            )
        }

        guard case let .clientMessageChunk(
            segmentID,
            segmentCount,
            messageSizeBytes,
            messageChunkBase64
        ) = envelope.event else {
            preconditionFailure("client-message chunks handled after event routing")
        }

        guard let streamID = envelope.streamID,
              let seqID = envelope.seqID
        else {
            return .discarded(.missingChunkIdentity)
        }
        let streamKey = CodexRemoteControlStreamKey(
            clientID: envelope.clientID,
            streamID: streamID
        )
        let chunkSequence = CodexRemoteControlChunkSequence(
            clientID: envelope.clientID,
            streamID: streamID,
            seqID: seqID
        )

        if let completed = completedChunkSequenceByStream[streamKey],
           completed >= seqID
        {
            return .discarded(.staleOrDuplicate)
        }
        if let assembly = assembliesByStream[streamKey],
           (
               seqID < assembly.metadata.seqID
                   || (
                       seqID == assembly.metadata.seqID
                           && segmentID < assembly.nextSegmentID
                   )
           )
        {
            return .discarded(.staleOrDuplicate)
        }
        if wireSizeBytes
            > CodexRemoteControlWebSocketLimits.maximumWireEnvelopeBytes
        {
            removeAssembly(clientID: envelope.clientID, streamID: streamID)
            return .discarded(.wireEnvelopeTooLarge)
        }
        guard segmentCount > 0,
              segmentCount
                <= CodexRemoteControlWebSocketLimits.maximumSegmentCount,
              segmentID >= 0,
              segmentID < segmentCount,
              messageSizeBytes > 0,
              messageSizeBytes
                <= CodexRemoteControlWebSocketLimits
                    .maximumReassembledMessageBytes,
              !messageChunkBase64.isEmpty
        else {
            removeAssembly(clientID: envelope.clientID, streamID: streamID)
            return .discarded(.invalidSegmentMetadata)
        }

        observationOrder = observationOrder == UInt64.max
            ? 0
            : observationOrder + 1
        let metadata = CodexRemoteControlSegmentMetadata(
            seqID: seqID,
            segmentCount: segmentCount,
            messageSizeBytes: messageSizeBytes
        )
        if assembliesByStream[streamKey] == nil {
            evictAssemblyIfFull()
            assembliesByStream[streamKey] =
                CodexRemoteControlSegmentAssembly(
                    metadata: metadata,
                    raw: Data(),
                    nextSegmentID: 0,
                    lastSeenOrder: observationOrder
                )
        }

        guard var assembly = assembliesByStream[streamKey] else {
            return .discarded(.invalidSegmentMetadata)
        }
        if metadata.seqID < assembly.metadata.seqID {
            return .discarded(.staleOrDuplicate)
        }
        guard metadata == assembly.metadata else {
            removeAssembly(clientID: envelope.clientID, streamID: streamID)
            return .discarded(.metadataMismatch)
        }
        if segmentID < assembly.nextSegmentID {
            return .discarded(.staleOrDuplicate)
        }
        guard segmentID == assembly.nextSegmentID else {
            removeAssembly(clientID: envelope.clientID, streamID: streamID)
            return .discarded(.outOfOrder)
        }
        guard let decodedChunk = Data(base64Encoded: messageChunkBase64) else {
            removeAssembly(clientID: envelope.clientID, streamID: streamID)
            return .discarded(.invalidBase64)
        }
        guard decodedChunk.count
            <= messageSizeBytes - min(assembly.raw.count, messageSizeBytes)
        else {
            removeAssembly(clientID: envelope.clientID, streamID: streamID)
            return .discarded(.sizeOverflow)
        }

        assembly.raw.append(decodedChunk)
        assembly.nextSegmentID += 1
        assembly.lastSeenOrder = observationOrder
        if assembly.nextSegmentID < segmentCount {
            assembliesByStream[streamKey] = assembly
            return .pending
        }
        removeAssembly(clientID: envelope.clientID, streamID: streamID)
        guard assembly.raw.count == messageSizeBytes else {
            return .discarded(.finalSizeMismatch)
        }
        guard let message = try? JSONDecoder().decode(
            CodexJSONValue.self,
            from: assembly.raw
        ), case .object = message
        else {
            return .discarded(.invalidJSONMessage)
        }

        let reassembled = CodexRemoteControlClientEnvelope(
            event: .clientMessage(message),
            clientID: envelope.clientID,
            streamID: envelope.streamID,
            seqID: envelope.seqID,
            cursor: envelope.cursor
        )
        return .deliver(
            CodexRemoteControlInboundDelivery(
                envelope: reassembled,
                chunkSequence: chunkSequence
            )
        )
    }

    public mutating func confirmDelivered(
        _ delivery: CodexRemoteControlInboundDelivery
    ) {
        let envelope = delivery.envelope
        if let cursor = envelope.cursor {
            subscribeCursor = cursor
        }
        if let chunkSequence = delivery.chunkSequence {
            let key = CodexRemoteControlStreamKey(
                clientID: chunkSequence.clientID,
                streamID: chunkSequence.streamID
            )
            completedChunkSequenceByStream[key] = max(
                completedChunkSequenceByStream[key] ?? 0,
                chunkSequence.seqID
            )
        }
        if case let .ack(segmentID) = envelope.event,
           let streamID = envelope.streamID,
           let seqID = envelope.seqID
        {
            acknowledge(
                clientID: envelope.clientID,
                streamID: streamID,
                seqID: seqID,
                segmentID: segmentID
            )
        }
        if case .clientClosed = envelope.event {
            cleanupClosedClient(
                clientID: envelope.clientID,
                streamID: envelope.streamID
            )
        }
    }

    public mutating func resetInboundConnectionState() {
        assembliesByStream.removeAll(keepingCapacity: true)
        completedChunkSequenceByStream.removeAll(keepingCapacity: true)
    }

    private mutating func acknowledge(
        clientID: String,
        streamID: String,
        seqID: UInt64,
        segmentID: Int?
    ) {
        let acknowledgedSegment = segmentID ?? Int.max
        outboundBuffer.removeAll { envelope in
            guard envelope.clientID == clientID,
                  envelope.streamID == streamID
            else {
                return false
            }
            let cursor = (envelope.seqID, envelope.event.segmentID ?? 0)
            return cursor <= (seqID, acknowledgedSegment)
        }
    }

    private mutating func cleanupClosedClient(
        clientID: String,
        streamID: String?
    ) {
        if let streamID {
            let key = CodexRemoteControlStreamKey(
                clientID: clientID,
                streamID: streamID
            )
            completedChunkSequenceByStream.removeValue(forKey: key)
            removeAssembly(clientID: clientID, streamID: streamID)
        } else {
            completedChunkSequenceByStream =
                completedChunkSequenceByStream.filter {
                    $0.key.clientID != clientID
                }
            assembliesByStream = assembliesByStream.filter {
                $0.key.clientID != clientID
            }
        }
    }

    private mutating func removeAssembly(
        clientID: String,
        streamID: String
    ) {
        assembliesByStream.removeValue(
            forKey: CodexRemoteControlStreamKey(
                clientID: clientID,
                streamID: streamID
            )
        )
    }

    private mutating func evictAssemblyIfFull() {
        while assembliesByStream.count
            >= CodexRemoteControlWebSocketLimits.maximumConcurrentAssemblies
        {
            guard let oldest = assembliesByStream.min(
                by: { $0.value.lastSeenOrder < $1.value.lastSeenOrder }
            )?.key else {
                return
            }
            assembliesByStream.removeValue(forKey: oldest)
        }
    }

    private func splitForWire(
        _ envelope: CodexRemoteControlServerEnvelope
    ) throws -> [CodexRemoteControlServerEnvelope] {
        let encodedEnvelope = try encodeOrMap(envelope)
        guard case let .serverMessage(message) = envelope.event else {
            guard encodedEnvelope.count
                <= CodexRemoteControlWebSocketLimits.maximumWireEnvelopeBytes
            else {
                throw CodexRemoteControlWebSocketProtocolError
                    .wireEnvelopeCannotFit(
                        limitBytes: CodexRemoteControlWebSocketLimits
                            .maximumWireEnvelopeBytes
                    )
            }
            return [envelope]
        }
        if encodedEnvelope.count
            <= CodexRemoteControlWebSocketLimits.maximumWireEnvelopeBytes
        {
            return [envelope]
        }

        let raw = try encodeOrMap(message)
        guard raw.count
            <= CodexRemoteControlWebSocketLimits.maximumReassembledMessageBytes
        else {
            throw CodexRemoteControlWebSocketProtocolError.messageTooLarge(
                actualBytes: raw.count,
                limitBytes: CodexRemoteControlWebSocketLimits
                    .maximumReassembledMessageBytes
            )
        }

        let minimalSegmentCount = min(
            max(raw.count, 1),
            CodexRemoteControlWebSocketLimits.maximumSegmentCount
        )
        let minimalChunk = Data(raw.prefix(1))
        let minimalEnvelope = chunkEnvelope(
            basedOn: envelope,
            segmentID: 0,
            segmentCount: minimalSegmentCount,
            messageSizeBytes: raw.count,
            chunk: minimalChunk
        )
        guard try encodeOrMap(minimalEnvelope).count
            <= CodexRemoteControlWebSocketLimits.maximumWireEnvelopeBytes
        else {
            throw CodexRemoteControlWebSocketProtocolError
                .wireEnvelopeCannotFit(
                    limitBytes: CodexRemoteControlWebSocketLimits
                        .maximumWireEnvelopeBytes
                )
        }

        var segmentCount = max(
            2,
            raw.count.ceilingDivided(
                by: CodexRemoteControlWebSocketLimits.targetSegmentBytes
            )
        )
        while true {
            guard segmentCount
                <= CodexRemoteControlWebSocketLimits.maximumSegmentCount
            else {
                throw CodexRemoteControlWebSocketProtocolError
                    .segmentCountExceedsLimit(
                        actual: segmentCount,
                        limit: CodexRemoteControlWebSocketLimits
                            .maximumSegmentCount
                    )
            }
            let chunkSize = max(1, raw.count.ceilingDivided(by: segmentCount))
            segmentCount = raw.count.ceilingDivided(by: chunkSize)
            guard segmentCount
                <= CodexRemoteControlWebSocketLimits.maximumSegmentCount
            else {
                throw CodexRemoteControlWebSocketProtocolError
                    .segmentCountExceedsLimit(
                        actual: segmentCount,
                        limit: CodexRemoteControlWebSocketLimits
                            .maximumSegmentCount
                    )
            }

            var wire: [CodexRemoteControlServerEnvelope] = []
            wire.reserveCapacity(segmentCount)
            var allFit = true
            var segmentID = 0
            var offset = 0
            while offset < raw.count {
                let end = min(raw.count, offset + chunkSize)
                let candidate = chunkEnvelope(
                    basedOn: envelope,
                    segmentID: segmentID,
                    segmentCount: segmentCount,
                    messageSizeBytes: raw.count,
                    chunk: raw.subdata(in: offset ..< end)
                )
                if try encodeOrMap(candidate).count
                    > CodexRemoteControlWebSocketLimits.maximumWireEnvelopeBytes
                {
                    allFit = false
                    break
                }
                wire.append(candidate)
                segmentID += 1
                offset = end
            }
            if allFit {
                return wire
            }
            guard chunkSize > 1 else {
                throw CodexRemoteControlWebSocketProtocolError
                    .wireEnvelopeCannotFit(
                        limitBytes: CodexRemoteControlWebSocketLimits
                            .maximumWireEnvelopeBytes
                    )
            }
            let nextSegmentCount = segmentCount + 1
            let nextChunkSize = max(
                1,
                raw.count.ceilingDivided(by: nextSegmentCount)
            )
            segmentCount = nextChunkSize == chunkSize
                ? raw.count
                : nextSegmentCount
        }
    }

    private func chunkEnvelope(
        basedOn envelope: CodexRemoteControlServerEnvelope,
        segmentID: Int,
        segmentCount: Int,
        messageSizeBytes: Int,
        chunk: Data
    ) -> CodexRemoteControlServerEnvelope {
        CodexRemoteControlServerEnvelope(
            event: .serverMessageChunk(
                segmentID: segmentID,
                segmentCount: segmentCount,
                messageSizeBytes: messageSizeBytes,
                messageChunkBase64: chunk.base64EncodedString()
            ),
            clientID: envelope.clientID,
            streamID: envelope.streamID,
            seqID: envelope.seqID
        )
    }

    private func encodeOrMap<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try CodexRemoteControlWebSocketCodec.encode(value)
        } catch {
            throw CodexRemoteControlWebSocketProtocolError.encodingFailed(
                String(describing: error)
            )
        }
    }
}

private extension Int {
    func ceilingDivided(by divisor: Int) -> Int {
        quotientAndRemainder(dividingBy: divisor).remainder == 0
            ? self / divisor
            : self / divisor + 1
    }
}
