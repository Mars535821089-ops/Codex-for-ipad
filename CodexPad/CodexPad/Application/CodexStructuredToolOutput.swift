import Foundation

public struct CodexStructuredInputImage: Codable, Equatable, Sendable {
  public let type: String
  public let imageURL: String
  public let detail: CodexViewImageDetail

  public init(imageURL: String, detail: CodexViewImageDetail) {
    self.type = "input_image"
    self.imageURL = imageURL
    self.detail = detail
  }

  enum CodingKeys: String, CodingKey {
    case type
    case imageURL = "image_url"
    case detail
  }
}

public struct CodexStructuredFunctionCallOutput: Codable, Equatable, Sendable {
  public let type: String
  public let callID: String
  public let output: [CodexStructuredInputImage]

  public init(callID: String, output: [CodexStructuredInputImage]) {
    self.type = "function_call_output"
    self.callID = callID
    self.output = output
  }

  enum CodingKeys: String, CodingKey {
    case type
    case callID = "call_id"
    case output
  }
}
