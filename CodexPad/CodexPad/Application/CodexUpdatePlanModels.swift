public enum CodexUpdatePlanStepStatus:
  String,
  Codable,
  Equatable,
  Sendable
{
  case pending
  case inProgress = "in_progress"
  case completed
}

public struct CodexUpdatePlanItem:
  Codable,
  Equatable,
  Sendable
{
  public let step: String
  public let status: CodexUpdatePlanStepStatus

  public init(
    step: String,
    status: CodexUpdatePlanStepStatus
  ) {
    self.step = step
    self.status = status
  }
}

public struct CodexUpdatePlan:
  Codable,
  Equatable,
  Sendable
{
  public let explanation: String?
  public let plan: [CodexUpdatePlanItem]

  public init(
    explanation: String? = nil,
    plan: [CodexUpdatePlanItem]
  ) {
    self.explanation = explanation
    self.plan = plan
  }
}
