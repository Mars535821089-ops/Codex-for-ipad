import Foundation

public enum CodexViewImageDetail: String, Codable, Equatable, Sendable {
  case high
  case original
}

public struct CodexViewImageArguments: Decodable, Equatable, Sendable {
  public let path: String
  public let detail: String?

  public init(path: String, detail: String? = nil) {
    self.path = path
    self.detail = detail
  }
}

public enum CodexPersistedTurnViewImageError: Error, Equatable, Sendable {
  case unsupportedTool
  case invalidArguments
  case unsupportedDetail(String)
  case invalidPath
  case pathOutsideWorkspace
  case fileNotFound
  case pathIsNotFile
  case unsupportedImageType
  case unreadableImage
}

extension CodexPersistedTurnViewImageError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .unsupportedTool: return "view_image tool request expected"
    case .invalidArguments: return "view_image arguments are invalid"
    case let .unsupportedDetail(detail):
      return "view_image.detail only supports `high` or `original`; got `\(detail)`"
    case .invalidPath: return "view_image path must not be empty"
    case .pathOutsideWorkspace: return "view_image path is outside the workspace"
    case .fileNotFound: return "view_image file was not found"
    case .pathIsNotFile: return "view_image path is not a file"
    case .unsupportedImageType: return "view_image path is not a supported image"
    case .unreadableImage: return "view_image image could not be read"
    }
  }
}
