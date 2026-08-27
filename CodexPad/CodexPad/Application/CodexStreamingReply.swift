public struct CodexStreamingReply: Equatable, Sendable {
    public private(set) var text: String

    public init(text: String = "") {
        self.text = text
    }

    public var isEmpty: Bool {
        text.isEmpty
    }

    public mutating func append(_ delta: String) {
        text.append(delta)
    }

    public mutating func reset() {
        text.removeAll(keepingCapacity: true)
    }
}
