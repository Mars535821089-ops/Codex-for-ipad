import Foundation

public struct CodexRequestUserInputOption: Equatable, Sendable {
    public let label: String
    public let description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

public struct CodexRequestUserInputQuestion: Equatable, Sendable {
    public let id: String
    public let header: String
    public let question: String
    public let options: [CodexRequestUserInputOption]

    public init(
        id: String,
        header: String,
        question: String,
        options: [CodexRequestUserInputOption]
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
    }
}

public struct CodexRequestUserInputPrompt: Equatable, Sendable {
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public let questions: [CodexRequestUserInputQuestion]
    public let autoResolutionMS: Int?

    public init(
        threadID: String,
        turnID: String,
        itemID: String,
        questions: [CodexRequestUserInputQuestion],
        autoResolutionMS: Int?
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.questions = questions
        self.autoResolutionMS = autoResolutionMS
    }
}

public struct CodexRequestUserInputAnswer:
    Codable,
    Equatable,
    Sendable
{
    public let answers: [String]

    public init(answers: [String]) {
        self.answers = answers
    }
}

public struct CodexRequestUserInputAnswers:
    Codable,
    Equatable,
    Sendable
{
    public let answers: [String: CodexRequestUserInputAnswer]

    public init(answers: [String: CodexRequestUserInputAnswer]) {
        self.answers = answers
    }
}
