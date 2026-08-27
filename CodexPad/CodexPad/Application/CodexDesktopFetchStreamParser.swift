#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public struct CodexDesktopParsedStreamEvent: Equatable, Sendable {
    public let event: String?
    public let data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

public struct CodexDesktopFetchStreamParser: Sendable {
    private let format: String
    private var buffer = Data()
    private var sseEvent: String?
    private var sseData: [String] = []

    public init(format: String) {
        self.format = format
    }

    public mutating func append(
        _ chunk: Data
    ) -> [CodexDesktopParsedStreamEvent] {
        buffer.append(chunk)
        var result: [CodexDesktopParsedStreamEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if line.last == 0x0D {
                line = line.dropLast()
            }
            consume(
                String(decoding: line, as: UTF8.self),
                into: &result
            )
        }
        return result
    }

    public mutating func finish()
        -> [CodexDesktopParsedStreamEvent]
    {
        var result: [CodexDesktopParsedStreamEvent] = []
        if !buffer.isEmpty {
            consume(
                String(decoding: buffer, as: UTF8.self),
                into: &result
            )
            buffer.removeAll()
        }
        if format != "ndjson" {
            flushSSE(into: &result)
        }
        return result
    }

    private mutating func consume(
        _ line: String,
        into result: inout [CodexDesktopParsedStreamEvent]
    ) {
        if format == "ndjson" {
            if !line.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                result.append(.init(event: nil, data: line))
            }
            return
        }
        if line.isEmpty {
            flushSSE(into: &result)
        } else if line.hasPrefix("event:") {
            sseEvent = fieldValue(line)
        } else if line.hasPrefix("data:") {
            sseData.append(fieldValue(line))
        }
    }

    private mutating func flushSSE(
        into result: inout [CodexDesktopParsedStreamEvent]
    ) {
        guard !sseData.isEmpty else {
            sseEvent = nil
            return
        }
        result.append(
            .init(
                event: sseEvent,
                data: sseData.joined(separator: "\n")
            )
        )
        sseEvent = nil
        sseData.removeAll(keepingCapacity: true)
    }

    private func fieldValue(_ line: String) -> String {
        let separator = line.firstIndex(of: ":")!
        var value = line[line.index(after: separator)...]
        if value.first == " " {
            value = value.dropFirst()
        }
        return String(value)
    }
}
