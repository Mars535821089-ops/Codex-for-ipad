import Foundation

#if SWIFT_PACKAGE
  import CodexPadDomain
#endif

public enum CodexPersistedTurnUpdatePlanError:
  Error,
  Equatable,
  Sendable
{
  case unsupportedTool
  case invalidArguments
}

@MainActor
public final class CodexPersistedTurnUpdatePlanExecutor:
  CodexPersistedTurnToolExecutor
{
  public typealias Publish =
    (CodexUpdatePlan) async throws -> Void

  private let publish: Publish

  public init(publish: @escaping Publish) {
    self.publish = publish
  }

  public func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput {
    try Task.checkCancellation()
    try cancellation.checkCancellation()
    guard request.name == "update_plan" else {
      throw CodexPersistedTurnUpdatePlanError.unsupportedTool
    }

    let update = try Self.update(from: request.arguments)
    try await publish(update)
    try Task.checkCancellation()
    try cancellation.checkCancellation()
    return CodexPersistedTurnLocalToolOutput(
      itemJSON: try Self.outputItemJSON(callID: request.callID)
    )
  }

  private static func update(
    from json: String
  ) throws -> CodexUpdatePlan {
    do {
      let data = Data(json.utf8)
      guard
        let object = try JSONSerialization.jsonObject(with: data)
          as? [String: Any],
        Set(object.keys).isSubset(of: ["explanation", "plan"]),
        let rawPlan = object["plan"] as? [Any],
        rawPlan.allSatisfy({ rawItem in
          guard let item = rawItem as? [String: Any] else {
            return false
          }
          return Set(item.keys) == ["step", "status"]
        })
      else {
        throw CodexPersistedTurnUpdatePlanError.invalidArguments
      }

      let update = try JSONDecoder().decode(CodexUpdatePlan.self, from: data)
      guard
        update.plan.filter({ $0.status == .inProgress }).count <= 1
      else {
        throw CodexPersistedTurnUpdatePlanError.invalidArguments
      }
      return update
    } catch let error as CodexPersistedTurnUpdatePlanError {
      throw error
    } catch {
      throw CodexPersistedTurnUpdatePlanError.invalidArguments
    }
  }

  private static func outputItemJSON(
    callID: String
  ) throws -> String {
    do {
      let item = CodexPersistedTurnUpdatePlanOutputItem(
        type: "function_call_output",
        callID: callID,
        output: "Plan updated"
      )
      let data = try JSONEncoder().encode(item)
      guard let json = String(data: data, encoding: .utf8) else {
        throw CodexPersistedTurnUpdatePlanError.invalidArguments
      }
      return json
    } catch let error as CodexPersistedTurnUpdatePlanError {
      throw error
    } catch {
      throw CodexPersistedTurnUpdatePlanError.invalidArguments
    }
  }
}

private struct CodexPersistedTurnUpdatePlanOutputItem: Encodable {
  let type: String
  let callID: String
  let output: String

  private enum CodingKeys: String, CodingKey {
    case type
    case callID = "call_id"
    case output
  }
}
