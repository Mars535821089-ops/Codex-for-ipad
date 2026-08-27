import Foundation

#if SWIFT_PACKAGE
  import CodexPadDomain
#endif

@MainActor
public final class CodexPersistedTurnViewImageExecutor: CodexPersistedTurnToolExecutor {
  private let workspaceRoot: URL
  private let supportsOriginalDetail: Bool
  private let fileManager: FileManager

  public init(
    workspaceRoot: URL,
    supportsOriginalDetail: Bool = false,
    fileManager: FileManager = .default
  ) {
    self.workspaceRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
    self.supportsOriginalDetail = supportsOriginalDetail
    self.fileManager = fileManager
  }

  public func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput {
    try cancellation.checkCancellation()
    guard request.name == "view_image" else { throw CodexPersistedTurnViewImageError.unsupportedTool }
    guard let arguments = try? JSONDecoder().decode(CodexViewImageArguments.self, from: Data(request.arguments.utf8)) else {
      throw CodexPersistedTurnViewImageError.invalidArguments
    }
    let detail: CodexViewImageDetail
    switch arguments.detail {
    case nil, "high": detail = .high
    case "original": detail = supportsOriginalDetail ? .original : .high
    case let value?: throw CodexPersistedTurnViewImageError.unsupportedDetail(value)
    }

    let imageURL = try resolve(arguments.path)
    guard fileManager.fileExists(atPath: imageURL.path) else {
      throw CodexPersistedTurnViewImageError.fileNotFound
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: imageURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      throw CodexPersistedTurnViewImageError.pathIsNotFile
    }
    let data: Data
    do {
      data = try Data(contentsOf: imageURL, options: [.mappedIfSafe])
    } catch {
      throw CodexPersistedTurnViewImageError.unreadableImage
    }
    guard let mimeType = Self.imageMIMEType(data: data) else {
      throw CodexPersistedTurnViewImageError.unsupportedImageType
    }
    try cancellation.checkCancellation()
    let imageURLString = "data:\(mimeType);base64,\(data.base64EncodedString())"
    let output = CodexStructuredFunctionCallOutput(
      callID: request.callID,
      output: [CodexStructuredInputImage(imageURL: imageURLString, detail: detail)]
    )
    let encoded = try JSONEncoder().encode(output)
    return CodexPersistedTurnLocalToolOutput(itemJSON: String(decoding: encoded, as: UTF8.self))
  }

  private func resolve(_ path: String) throws -> URL {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.split(separator: "/").contains("..") else {
      throw trimmed.isEmpty ? CodexPersistedTurnViewImageError.invalidPath : .pathOutsideWorkspace
    }
    let candidate: URL
    if trimmed.hasPrefix("/") {
      candidate = URL(fileURLWithPath: trimmed)
    } else {
      candidate = workspaceRoot.appendingPathComponent(trimmed)
    }
    let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = workspaceRoot.path.hasSuffix("/") ? workspaceRoot.path : workspaceRoot.path + "/"
    guard resolved.path == workspaceRoot.path || resolved.path.hasPrefix(rootPath) else {
      throw CodexPersistedTurnViewImageError.pathOutsideWorkspace
    }
    return resolved
  }

  private static func imageMIMEType(data: Data) -> String? {
    let bytes = [UInt8](data.prefix(16))
    if bytes.count >= 8 && Array(bytes.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] { return "image/png" }
    if bytes.count >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff { return "image/jpeg" }
    if bytes.count >= 6 && (String(bytes: bytes.prefix(6), encoding: .ascii) == "GIF87a" || String(bytes: bytes.prefix(6), encoding: .ascii) == "GIF89a") { return "image/gif" }
    if bytes.count >= 12 && String(bytes: bytes.prefix(4), encoding: .ascii) == "RIFF" && String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return "image/webp" }
    if bytes.count >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d { return "image/bmp" }
    if bytes.count >= 4 && ((bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2a && bytes[3] == 0x00) || (bytes[0] == 0x4d && bytes[1] == 0x4d && bytes[2] == 0x00 && bytes[3] == 0x2a)) { return "image/tiff" }
    if bytes.count >= 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" {
      let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
      if ["avif", "avis"].contains(brand) { return "image/avif" }
      if ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) { return "image/heic" }
    }
    if let text = String(data: data.prefix(512), encoding: .utf8),
       text.range(of: #"<svg(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil {
      return "image/svg+xml"
    }
    return nil
  }
}
