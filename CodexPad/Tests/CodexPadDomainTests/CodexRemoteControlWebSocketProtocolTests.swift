import CodexPadDomain
import Foundation
import Testing

@testable import CodexPadApplication

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func inboundDelivery(
    _ action: CodexRemoteControlInboundAction
) throws -> CodexRemoteControlInboundDelivery {
    guard case let .deliver(delivery) = action else {
        Issue.record("Expected deliver, received \(action)")
        throw CodableTestError.wrongShape
    }
    return delivery
}

private enum CodableTestError: Error {
    case wrongShape
}

@Test
func remoteControlClientEnvelopeMatchesOfficialFlattenedWire() throws {
    let envelope = CodexRemoteControlClientEnvelope(
        event: .clientMessage(
            .object([
                "jsonrpc": .string("2.0"),
                "id": .integer(7),
                "method": .string("thread/list"),
            ])
        ),
        clientID: "client-1",
        streamID: "stream-1",
        seqID: 9,
        cursor: "cursor-9"
    )

    let object = try jsonObject(
        try CodexRemoteControlWebSocketCodec.encode(envelope)
    )
    #expect(object["type"] as? String == "client_message")
    #expect(object["client_id"] as? String == "client-1")
    #expect(object["stream_id"] as? String == "stream-1")
    #expect(object["seq_id"] as? Int == 9)
    #expect(object["cursor"] as? String == "cursor-9")
    let message = try #require(object["message"] as? [String: Any])
    #expect(message["jsonrpc"] as? String == "2.0")
    #expect(message["method"] as? String == "thread/list")

    let roundTrip = try CodexRemoteControlWebSocketCodec.decodeClientEnvelope(
        try CodexRemoteControlWebSocketCodec.encode(envelope)
    )
    #expect(roundTrip == envelope)
}

@Test
func remoteControlClientEventTagsAndOptionalAckFieldsAreExact() throws {
    let fixtures: [(CodexRemoteControlClientEvent, String)] = [
        (.ping, "ping"),
        (.clientClosed, "client_closed"),
        (.ack(segmentID: nil), "ack"),
        (
            .clientMessageChunk(
                segmentID: 1,
                segmentCount: 2,
                messageSizeBytes: 3,
                messageChunkBase64: "eA=="
            ),
            "client_message_chunk"
        ),
    ]

    for (event, expectedType) in fixtures {
        let envelope = CodexRemoteControlClientEnvelope(
            event: event,
            clientID: "client",
            streamID: nil,
            seqID: nil,
            cursor: nil
        )
        let object = try jsonObject(
            try CodexRemoteControlWebSocketCodec.encode(envelope)
        )
        #expect(object["type"] as? String == expectedType)
        #expect(object["stream_id"] == nil)
        #expect(object["seq_id"] == nil)
        #expect(object["cursor"] == nil)
        if case .ack(segmentID: nil) = event {
            #expect(object["segment_id"] == nil)
        }
    }
}

@Test
func remoteControlServerEnvelopeMatchesOfficialFlattenedWire() throws {
    let envelope = CodexRemoteControlServerEnvelope(
        event: .pong(status: .active),
        clientID: "client-1",
        streamID: "stream-1",
        seqID: 4
    )
    let data = try CodexRemoteControlWebSocketCodec.encode(envelope)
    let object = try jsonObject(data)
    #expect(object["type"] as? String == "pong")
    #expect(object["status"] as? String == "active")
    #expect(object["client_id"] as? String == "client-1")
    #expect(object["stream_id"] as? String == "stream-1")
    #expect(object["seq_id"] as? Int == 4)
    #expect(
        try CodexRemoteControlWebSocketCodec.decodeServerEnvelope(data)
            == envelope
    )
}

@Test
func remoteControlOutboundSegmentationRespectsWireAndReassemblyLimits()
    throws
{
    var state = CodexRemoteControlWebSocketProtocolState()
    let largeMessage: CodexJSONValue = .object([
        "jsonrpc": .string("2.0"),
        "id": .integer(12),
        "result": .string(
            String(
                repeating: "swift-websocket-segment-",
                count: 8_000
            )
        ),
    ])

    let segments = try state.prepareOutbound(
        event: .serverMessage(largeMessage),
        clientID: "client-1",
        streamID: "stream-1"
    )
    #expect(segments.count >= 2)
    #expect(segments.count <= CodexRemoteControlWebSocketLimits.maximumSegmentCount)
    #expect(state.bufferedEnvelopeCount == segments.count)
    #expect(Set(segments.map(\.seqID)) == [1])

    for (index, envelope) in segments.enumerated() {
        #expect(
            try CodexRemoteControlWebSocketCodec.encode(envelope).count
                <= CodexRemoteControlWebSocketLimits.maximumWireEnvelopeBytes
        )
        guard case let .serverMessageChunk(
            segmentID,
            segmentCount,
            messageSizeBytes,
            messageChunkBase64
        ) = envelope.event else {
            Issue.record("Expected a segmented server message")
            continue
        }
        #expect(segmentID == index)
        #expect(segmentCount == segments.count)
        #expect(messageSizeBytes > 0)
        #expect(Data(base64Encoded: messageChunkBase64) != nil)
    }

    var clientState = CodexRemoteControlWebSocketProtocolState()
    var completed: CodexRemoteControlInboundDelivery?
    for envelope in segments {
        guard case let .serverMessageChunk(
            segmentID,
            segmentCount,
            messageSizeBytes,
            messageChunkBase64
        ) = envelope.event else {
            continue
        }
        let clientEnvelope = CodexRemoteControlClientEnvelope(
            event: .clientMessageChunk(
                segmentID: segmentID,
                segmentCount: segmentCount,
                messageSizeBytes: messageSizeBytes,
                messageChunkBase64: messageChunkBase64
            ),
            clientID: envelope.clientID,
            streamID: envelope.streamID,
            seqID: envelope.seqID,
            cursor: "cursor-segmented"
        )
        let action = clientState.observeInbound(
            clientEnvelope,
            wireSizeBytes: try CodexRemoteControlWebSocketCodec.encode(clientEnvelope).count
        )
        if segmentID + 1 < segmentCount {
            #expect(action == .pending)
        } else {
            completed = try inboundDelivery(action)
        }
    }

    let delivery = try #require(completed)
    #expect(delivery.envelope.event == .clientMessage(largeMessage))
    #expect(clientState.subscribeCursor == nil)
    clientState.confirmDelivered(delivery)
    #expect(clientState.subscribeCursor == "cursor-segmented")

    guard let first = segments.first,
          case let .serverMessageChunk(
              segmentID,
              segmentCount,
              messageSizeBytes,
              messageChunkBase64
          ) = first.event
    else {
        Issue.record("Missing first segment")
        return
    }
    let replay = CodexRemoteControlClientEnvelope(
        event: .clientMessageChunk(
            segmentID: segmentID,
            segmentCount: segmentCount,
            messageSizeBytes: messageSizeBytes,
            messageChunkBase64: messageChunkBase64
        ),
        clientID: first.clientID,
        streamID: first.streamID,
        seqID: first.seqID,
        cursor: "cursor-replayed"
    )
    #expect(
        clientState.observeInbound(
            replay,
            wireSizeBytes: try CodexRemoteControlWebSocketCodec.encode(replay).count
        ) == .discarded(.staleOrDuplicate)
    )
}

@Test
func remoteControlReassemblyDropsOutOfOrderThenAllowsCleanReplay() throws {
    let raw = try CodexRemoteControlWebSocketCodec.encode(
        CodexJSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string("thread/read"),
        ])
    )
    let split = max(1, raw.count / 2)
    let chunks = [raw.prefix(split), raw.suffix(from: split)].map(Data.init)
    var state = CodexRemoteControlWebSocketProtocolState()

    func envelope(_ id: Int) -> CodexRemoteControlClientEnvelope {
        CodexRemoteControlClientEnvelope(
            event: .clientMessageChunk(
                segmentID: id,
                segmentCount: 2,
                messageSizeBytes: raw.count,
                messageChunkBase64: chunks[id].base64EncodedString()
            ),
            clientID: "client",
            streamID: "stream",
            seqID: 8,
            cursor: nil
        )
    }

    #expect(
        state.observeInbound(envelope(1), wireSizeBytes: 200)
            == .discarded(.outOfOrder)
    )
    #expect(state.observeInbound(envelope(0), wireSizeBytes: 200) == .pending)
    let delivery = try inboundDelivery(
        state.observeInbound(envelope(1), wireSizeBytes: 200)
    )
    #expect(delivery.envelope.event == .clientMessage(
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string("thread/read"),
        ])
    ))
}

@Test
func remoteControlInterleavedStreamsForOneClientReassembleIndependently()
    throws
{
    let messages: [(String, CodexJSONValue)] = [
        (
            "stream-1",
            .object([
                "jsonrpc": .string("2.0"),
                "id": .integer(1),
                "method": .string("thread/read"),
            ])
        ),
        (
            "stream-2",
            .object([
                "jsonrpc": .string("2.0"),
                "id": .integer(2),
                "method": .string("thread/list"),
            ])
        ),
    ]
    let chunkSets = try messages.map { streamID, message in
        let raw = try CodexRemoteControlWebSocketCodec.encode(message)
        let split = max(1, raw.count / 2)
        return (
            streamID,
            message,
            raw.count,
            [Data(raw.prefix(split)), Data(raw.suffix(from: split))]
        )
    }
    var state = CodexRemoteControlWebSocketProtocolState()

    func envelope(
        for item: (
            streamID: String,
            message: CodexJSONValue,
            size: Int,
            chunks: [Data]
        ),
        segmentID: Int,
        sequenceID: UInt64
    ) -> CodexRemoteControlClientEnvelope {
        CodexRemoteControlClientEnvelope(
            event: .clientMessageChunk(
                segmentID: segmentID,
                segmentCount: item.chunks.count,
                messageSizeBytes: item.size,
                messageChunkBase64:
                    item.chunks[segmentID].base64EncodedString()
            ),
            clientID: "shared-client",
            streamID: item.streamID,
            seqID: sequenceID,
            cursor: "cursor-\(item.streamID)"
        )
    }

    #expect(
        state.observeInbound(
            envelope(for: chunkSets[0], segmentID: 0, sequenceID: 11),
            wireSizeBytes: 200
        ) == .pending
    )
    #expect(
        state.observeInbound(
            envelope(for: chunkSets[1], segmentID: 0, sequenceID: 22),
            wireSizeBytes: 200
        ) == .pending
    )
    #expect(state.activeAssemblyCount == 2)

    let firstDelivery = try inboundDelivery(
        state.observeInbound(
            envelope(for: chunkSets[0], segmentID: 1, sequenceID: 11),
            wireSizeBytes: 200
        )
    )
    let secondDelivery = try inboundDelivery(
        state.observeInbound(
            envelope(for: chunkSets[1], segmentID: 1, sequenceID: 22),
            wireSizeBytes: 200
        )
    )

    #expect(firstDelivery.envelope.event == .clientMessage(messages[0].1))
    #expect(secondDelivery.envelope.event == .clientMessage(messages[1].1))
    #expect(state.activeAssemblyCount == 0)
}

@Test
func remoteControlOversizedSegmentInvalidatesAssemblyWithoutAdvancingCursor()
    throws
{
    let raw = try CodexRemoteControlWebSocketCodec.encode(
        CodexJSONValue.object(["id": .integer(1)])
    )
    let first = CodexRemoteControlClientEnvelope(
        event: .clientMessageChunk(
            segmentID: 0,
            segmentCount: 2,
            messageSizeBytes: raw.count,
            messageChunkBase64: Data(raw.prefix(1)).base64EncodedString()
        ),
        clientID: "client",
        streamID: "stream",
        seqID: 2,
        cursor: "not-delivered"
    )
    var state = CodexRemoteControlWebSocketProtocolState()
    #expect(state.observeInbound(first, wireSizeBytes: 100) == .pending)
    let oversizedNext = CodexRemoteControlClientEnvelope(
        event: .clientMessageChunk(
            segmentID: 1,
            segmentCount: 2,
            messageSizeBytes: raw.count,
            messageChunkBase64: Data(raw.dropFirst()).base64EncodedString()
        ),
        clientID: "client",
        streamID: "stream",
        seqID: 2,
        cursor: "not-delivered"
    )
    #expect(
        state.observeInbound(
            oversizedNext,
            wireSizeBytes:
                CodexRemoteControlWebSocketLimits.maximumWireEnvelopeBytes + 1
        ) == .discarded(.wireEnvelopeTooLarge)
    )
    #expect(state.subscribeCursor == nil)
    #expect(state.activeAssemblyCount == 0)
}

@Test
func remoteControlAckTrimsOnlyAcknowledgedWireCursorAndStream() throws {
    var state = CodexRemoteControlWebSocketProtocolState()
    let message: CodexJSONValue = .object([
        "value": .string(String(repeating: "x", count: 180_000)),
    ])
    let streamOne = try state.prepareOutbound(
        event: .serverMessage(message),
        clientID: "client",
        streamID: "stream-1"
    )
    let streamTwo = try state.prepareOutbound(
        event: .serverMessage(.string("other")),
        clientID: "client",
        streamID: "stream-2"
    )
    #expect(streamOne.count >= 2)

    let partialAck = CodexRemoteControlClientEnvelope(
        event: .ack(segmentID: 0),
        clientID: "client",
        streamID: "stream-1",
        seqID: 1,
        cursor: "ack-cursor"
    )
    let partialDelivery = try inboundDelivery(
        state.observeInbound(partialAck, wireSizeBytes: 100)
    )
    state.confirmDelivered(partialDelivery)
    #expect(state.subscribeCursor == "ack-cursor")
    #expect(
        state.replayEnvelopes.filter { $0.streamID == "stream-1" }.allSatisfy {
            $0.event.segmentID.map { $0 > 0 } ?? false
        }
    )
    #expect(
        state.replayEnvelopes.filter { $0.streamID == "stream-2" }
            == streamTwo
    )

    let wholeSequenceAck = CodexRemoteControlClientEnvelope(
        event: .ack(segmentID: nil),
        clientID: "client",
        streamID: "stream-1",
        seqID: 1,
        cursor: nil
    )
    let wholeDelivery = try inboundDelivery(
        state.observeInbound(wholeSequenceAck, wireSizeBytes: 100)
    )
    state.confirmDelivered(wholeDelivery)
    #expect(
        state.replayEnvelopes.filter { $0.streamID == "stream-1" }.isEmpty
    )
    #expect(
        state.replayEnvelopes.filter { $0.streamID == "stream-2" }
            == streamTwo
    )
}

@Test
func remoteControlClientClosedCleansChunkStateWithoutDroppingReplay()
    throws
{
    var state = CodexRemoteControlWebSocketProtocolState()
    let streamOne = try state.prepareOutbound(
        event: .serverMessage(.string("one")),
        clientID: "client",
        streamID: "stream-1"
    )
    let retained = try state.prepareOutbound(
        event: .serverMessage(.string("two")),
        clientID: "client",
        streamID: "stream-2"
    )
    let firstChunk = CodexRemoteControlClientEnvelope(
        event: .clientMessageChunk(
            segmentID: 0,
            segmentCount: 2,
            messageSizeBytes: 2,
            messageChunkBase64: Data("{".utf8).base64EncodedString()
        ),
        clientID: "client",
        streamID: "stream-1",
        seqID: 7,
        cursor: nil
    )
    #expect(
        state.observeInbound(firstChunk, wireSizeBytes: 100) == .pending
    )
    #expect(state.activeAssemblyCount == 1)

    let closed = CodexRemoteControlClientEnvelope(
        event: .clientClosed,
        clientID: "client",
        streamID: "stream-1",
        seqID: nil,
        cursor: "closed-cursor"
    )
    let delivery = try inboundDelivery(
        state.observeInbound(closed, wireSizeBytes: 100)
    )
    state.confirmDelivered(delivery)
    #expect(state.subscribeCursor == "closed-cursor")
    #expect(state.replayEnvelopes == streamOne + retained)
    #expect(state.nextSequenceID(clientID: "client", streamID: "stream-1") == 2)
    #expect(state.nextSequenceID(clientID: "client", streamID: "stream-2") == 2)
    #expect(state.activeAssemblyCount == 0)
    #expect(
        state.observeInbound(firstChunk, wireSizeBytes: 100) == .pending
    )
}

@Test
func remoteControlRejectsMessagePastOfficialReassembledLimit() {
    var state = CodexRemoteControlWebSocketProtocolState()
    let oversized = CodexRemoteControlClientEnvelope(
        event: .clientMessageChunk(
            segmentID: 0,
            segmentCount: 1,
            messageSizeBytes:
                CodexRemoteControlWebSocketLimits.maximumReassembledMessageBytes + 1,
            messageChunkBase64: "eA=="
        ),
        clientID: "client",
        streamID: "stream",
        seqID: 1,
        cursor: "must-not-advance"
    )
    #expect(
        state.observeInbound(oversized, wireSizeBytes: 100)
            == .discarded(.invalidSegmentMetadata)
    )
    #expect(state.subscribeCursor == nil)
}

@Test
func remoteControlRejectsInvalidBase64AndSegmentCount() {
    var state = CodexRemoteControlWebSocketProtocolState()
    let invalidBase64 = CodexRemoteControlClientEnvelope(
        event: .clientMessageChunk(
            segmentID: 0,
            segmentCount: 1,
            messageSizeBytes: 1,
            messageChunkBase64: "%%%"
        ),
        clientID: "client",
        streamID: "stream",
        seqID: 1,
        cursor: "must-not-advance"
    )
    #expect(
        state.observeInbound(invalidBase64, wireSizeBytes: 100)
            == .discarded(.invalidBase64)
    )

    let excessiveCount = CodexRemoteControlClientEnvelope(
        event: .clientMessageChunk(
            segmentID: 0,
            segmentCount:
                CodexRemoteControlWebSocketLimits.maximumSegmentCount + 1,
            messageSizeBytes: 1,
            messageChunkBase64: "eA=="
        ),
        clientID: "client",
        streamID: "stream",
        seqID: 2,
        cursor: "must-not-advance"
    )
    #expect(
        state.observeInbound(excessiveCount, wireSizeBytes: 100)
            == .discarded(.invalidSegmentMetadata)
    )
    #expect(state.subscribeCursor == nil)
    #expect(state.activeAssemblyCount == 0)
}

@Test
func remoteControlRejectsNonObjectDirectJSONRPCMessage() throws {
    var state = CodexRemoteControlWebSocketProtocolState()
    let envelope = CodexRemoteControlClientEnvelope(
        event: .clientMessage(.array([.string("not-json-rpc")])),
        clientID: "client",
        streamID: "stream",
        seqID: 1,
        cursor: "must-not-advance"
    )

    #expect(
        state.observeInbound(
            envelope,
            wireSizeBytes: try CodexRemoteControlWebSocketCodec
                .encode(envelope).count
        ) == .discarded(.invalidJSONMessage)
    )
    #expect(state.subscribeCursor == nil)
}
