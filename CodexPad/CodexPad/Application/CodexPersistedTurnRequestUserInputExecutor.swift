import Foundation

#if SWIFT_PACKAGE
  import CodexPadDomain
#endif

public enum CodexPersistedTurnRequestUserInputError:
  Error,
  Equatable,
  Sendable
{
  case unsupportedTool
  case invalidArguments
}

@MainActor
public final class CodexPersistedTurnRequestUserInputExecutor:
  CodexPersistedTurnToolExecutor
{
  public typealias Prompt =
    (CodexRequestUserInputPrompt) async throws
      -> CodexRequestUserInputAnswers

  private let prompt: Prompt

  public init(prompt: @escaping Prompt) {
    self.prompt = prompt
  }

  public func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput {
    try Task.checkCancellation()
    try cancellation.checkCancellation()
    guard request.name == "request_user_input" else {
      throw CodexPersistedTurnRequestUserInputError.unsupportedTool
    }

    let arguments = try Self.arguments(from: request.arguments)
    let prompt = CodexRequestUserInputPrompt(
      threadID: request.threadID.rawValue,
      turnID: request.turnID,
      itemID: request.callID,
      questions: arguments.questions.map { question in
        CodexRequestUserInputQuestion(
          id: question.id,
          header: question.header,
          question: question.question,
          options: question.options.map {
            CodexRequestUserInputOption(
              label: $0.label,
              description: $0.description
            )
          }
        )
      },
      autoResolutionMS: arguments.autoResolutionMS.map {
        min(max($0, 60_000), 240_000)
      }
    )

    let answers = try await self.prompt(prompt)
    try Task.checkCancellation()
    try cancellation.checkCancellation()
    return CodexPersistedTurnLocalToolOutput(
      itemJSON: try Self.outputItemJSON(
        callID: request.callID,
        answers: answers
      )
    )
  }

  private static func arguments(
    from json: String
  ) throws -> CodexPersistedTurnRequestUserInputArguments {
    let arguments: CodexPersistedTurnRequestUserInputArguments
    do {
      arguments = try JSONDecoder().decode(
        CodexPersistedTurnRequestUserInputArguments.self,
        from: Data(json.utf8)
      )
    } catch {
      throw CodexPersistedTurnRequestUserInputError.invalidArguments
    }

    guard (1...3).contains(arguments.questions.count) else {
      throw CodexPersistedTurnRequestUserInputError.invalidArguments
    }
    var questionIDs = Set<String>()
    for question in arguments.questions {
      guard isPresent(question.id),
        questionIDs.insert(question.id).inserted,
        isPresent(question.header),
        isPresent(question.question),
        (2...3).contains(question.options.count),
        question.options.allSatisfy({
          isPresent($0.label) && isPresent($0.description)
        })
      else {
        throw CodexPersistedTurnRequestUserInputError.invalidArguments
      }
    }
    return arguments
  }

  private static func isPresent(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static func outputItemJSON(
    callID: String,
    answers: CodexRequestUserInputAnswers
  ) throws -> String {
    do {
      let rawAnswers = try JSONEncoder().encode(answers)
      guard let output = String(data: rawAnswers, encoding: .utf8) else {
        throw CodexPersistedTurnRequestUserInputError.invalidArguments
      }
      let item = CodexPersistedTurnRequestUserInputOutputItem(
        type: "function_call_output",
        callID: callID,
        output: output
      )
      let data = try JSONEncoder().encode(item)
      guard let json = String(data: data, encoding: .utf8) else {
        throw CodexPersistedTurnRequestUserInputError.invalidArguments
      }
      return json
    } catch let error as CodexPersistedTurnRequestUserInputError {
      throw error
    } catch {
      throw CodexPersistedTurnRequestUserInputError.invalidArguments
    }
  }
}

private struct CodexPersistedTurnRequestUserInputArguments: Decodable {
  let questions: [CodexPersistedTurnRequestUserInputQuestionArguments]
  let autoResolutionMS: Int?

  private enum CodingKeys: String, CodingKey {
    case questions
    case autoResolutionMS = "autoResolutionMs"
  }
}

private struct CodexPersistedTurnRequestUserInputQuestionArguments:
  Decodable
{
  let id: String
  let header: String
  let question: String
  let options: [CodexPersistedTurnRequestUserInputOptionArguments]
}

private struct CodexPersistedTurnRequestUserInputOptionArguments: Decodable {
  let label: String
  let description: String
}

private struct CodexPersistedTurnRequestUserInputOutputItem: Encodable {
  let type: String
  let callID: String
  let output: String

  private enum CodingKeys: String, CodingKey {
    case type
    case callID = "call_id"
    case output
  }
}
