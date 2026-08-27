import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Persistent iPad implementation of the desktop `customAvatars` service.
///
/// The store commits an avatar only after the remote image has passed all
/// transport and format checks. Metadata is written atomically and payloads
/// live below the CodexHome directory, so a failed install cannot corrupt an
/// existing avatar or leave a permanent download in the temporary directory.
public actor CodexDesktopCustomAvatarStore {
    public typealias Value = CodexDesktopAppHostRPC.Value

    public struct Response: Sendable {
        public let statusCode: Int
        public let mimeType: String?
        public let data: Data

        public init(statusCode: Int, mimeType: String?, data: Data) {
            self.statusCode = statusCode
            self.mimeType = mimeType
            self.data = data
        }
    }

    public typealias Fetch = @Sendable (URLRequest) async throws -> Response

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidURL
        case redirectRejected
        case httpStatus(Int)
        case unsupportedContentType
        case payloadTooLarge
        case emptyPayload
        case invalidImage
        case persistenceFailure
        case missingAvatar
    }

    private struct Record: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let description: String?
        let spriteVersionNumber: Int
        let fileName: String
        let mimeType: String
    }

    private struct Metadata: Codable, Sendable {
        var records: [Record]
    }

    private static let maximumPayloadBytes = 20 * 1024 * 1024
    private let rootURL: URL
    private let metadataURL: URL
    private let fetch: Fetch
    private let fileManager: FileManager

    public init(
        rootURL: URL,
        fileManager: FileManager = .default,
        fetch: Fetch? = nil
    ) {
        self.rootURL = rootURL
        self.metadataURL = rootURL.appendingPathComponent(
            "avatars.json",
            isDirectory: false
        )
        self.fileManager = fileManager
        self.fetch = fetch ?? Self.defaultFetch
    }

    public func invoke(
        _ request: CodexDesktopBrowsingStateAppHostService.Request
    ) async throws -> Value {
        switch request {
        case .loadCustomAvatars:
            return try load()
        case let .loadCustomAvatar(id):
            return try loadAvatar(id: id)
        case let .previewCustomAvatarInstall(value):
            return try await preview(value)
        case let .installCustomAvatar(value):
            return try await install(value)
        default:
            throw Error.persistenceFailure
        }
    }

    public func load() throws -> Value {
        let records = try readMetadata().records
        return .object([
            "avatarDirectory": .string(rootURL.path),
            "avatars": .array(records.map { avatarValue($0) })
        ])
    }

    public func loadAvatar(id: String) throws -> Value {
        guard let record = try readMetadata().records.first(where: { $0.id == id })
        else { throw Error.missingAvatar }
        let dataURL = try dataURL(for: record)
        return avatarValue(record, includeSpritesheet: dataURL)
    }

    public func preview(_ value: Value) async throws -> Value {
        let input = try parseInstallInput(value)
        let response = try await download(input.url)
        let image = try validate(response, spriteVersionNumber: input.version)
        return .object([
            "displayName": .string(input.name),
            "description": input.description.map(Value.string) ?? .null,
            "spriteVersionNumber": .integer(Int64(input.version)),
            "spritesheetDataUrl": .string(
                "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
            )
        ])
    }

    public func install(_ value: Value) async throws -> Value {
        let input = try parseInstallInput(value)
        let response = try await download(input.url)
        let image = try validate(response, spriteVersionNumber: input.version)
        let id = "custom:" + stableID(
            name: input.name,
            url: input.url.absoluteString,
            version: input.version,
            data: image.data
        )
        let fileExtension = image.mimeType == "image/webp" ? "webp" : "png"
        let fileName = "\(id.replacingOccurrences(of: ":", with: "-")).\(fileExtension)"
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("codex-custom-avatar-\(UUID().uuidString)", isDirectory: true)
        let temporaryPayload = temporaryDirectory.appendingPathComponent(fileName)
        let destination = rootURL.appendingPathComponent(fileName)
        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            try image.data.write(to: temporaryPayload, options: .atomic)
            let record = Record(
                id: id,
                name: input.name,
                description: input.description,
                spriteVersionNumber: input.version,
                fileName: fileName,
                mimeType: image.mimeType
            )
            var metadata = try readMetadata()
            metadata.records.removeAll { $0.id == id }
            metadata.records.append(record)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporaryPayload, to: destination)
            do {
                try writeMetadata(metadata)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
            try? fileManager.removeItem(at: temporaryDirectory)
            return .object(["id": .string(id)])
        } catch let error as Error {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw Error.persistenceFailure
        }
    }

    private struct InstallInput: Sendable {
        let name: String
        let description: String?
        let url: URL
        let version: Int
    }

    private struct Image: Sendable {
        let mimeType: String
        let data: Data
    }

    private func parseInstallInput(_ value: Value) throws -> InstallInput {
        guard case let .object(fields) = value,
              case let .string(rawName)? = fields["name"],
              let urlString = fields["imageUrl"].flatMap(Self.string),
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              !Self.isLoopback(host)
        else { throw Error.invalidURL }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Error.invalidURL }
        let description: String?
        if let value = fields["description"], value != .null {
            guard case let .string(raw)? = Optional(value) else { throw Error.invalidURL }
            description = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            description = nil
        }
        let version: Int
        if let value = fields["spriteVersionNumber"] {
            guard case let .integer(number) = value,
                  (number == 1 || number == 2)
            else { throw Error.invalidURL }
            version = Int(number)
        } else {
            version = 1
        }
        return InstallInput(
            name: name,
            description: description,
            url: url,
            version: version
        )
    }

    private func download(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("image/png,image/webp", forHTTPHeaderField: "Accept")
        let response = try await fetch(request)
        if (300...399).contains(response.statusCode) {
            throw Error.redirectRejected
        }
        guard response.statusCode >= 200 && response.statusCode < 300 else {
            throw Error.httpStatus(response.statusCode)
        }
        return response
    }

    private func validate(
        _ response: Response,
        spriteVersionNumber: Int
    ) throws -> Image {
        guard response.data.count <= Self.maximumPayloadBytes else {
            throw Error.payloadTooLarge
        }
        guard !response.data.isEmpty else { throw Error.emptyPayload }
        let mime = response.mimeType?.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let mime, mime == "image/png" || mime == "image/webp" else {
            throw Error.unsupportedContentType
        }
        guard Self.isValidImage(
            response.data,
            mimeType: mime,
            spriteVersionNumber: spriteVersionNumber
        ) else {
            throw Error.invalidImage
        }
        return Image(mimeType: mime, data: response.data)
    }

    private func readMetadata() throws -> Metadata {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return Metadata(records: [])
        }
        do {
            return try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
        } catch {
            throw Error.persistenceFailure
        }
    }

    private func writeMetadata(_ metadata: Metadata) throws {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            throw Error.persistenceFailure
        }
    }

    private func dataURL(for record: Record) throws -> String {
        let data = try Data(contentsOf: rootURL.appendingPathComponent(record.fileName))
        return "data:\(record.mimeType);base64,\(data.base64EncodedString())"
    }

    private func avatarValue(_ record: Record, includeSpritesheet: String? = nil) -> Value {
        var object: [String: Value] = [
            "id": .string(record.id),
            "displayName": .string(record.name),
            "description": record.description.map(Value.string) ?? .null,
            "spriteVersionNumber": .integer(Int64(record.spriteVersionNumber))
        ]
        if let includeSpritesheet {
            object["spritesheetDataUrl"] = .string(includeSpritesheet)
        }
        return .object(object)
    }

    private func stableID(name: String, url: String, version: Int, data: Data) -> String {
        let bytes = Data("\(name)\n\(url)\n\(version)\n".utf8) + data
        var hash: UInt64 = 1469598103934665603
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    private static func string(_ value: Value?) -> String? {
        guard case let .string(value)? = value else { return nil }
        return value
    }

    private static func isLoopback(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "localhost" || lower == "127.0.0.1" || lower == "::1" || lower == "[::1]"
    }

    private static func isValidImage(
        _ data: Data,
        mimeType: String,
        spriteVersionNumber: Int
    ) -> Bool {
        let signatureValid: Bool
        if mimeType == "image/png" {
            signatureValid = data.count >= 24
                && data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10])
                && data.subdata(in: 12..<16) == Data("IHDR".utf8)
                && data[16...19].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } > 0
                && data[20...23].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } > 0
        } else {
            signatureValid = data.count >= 16
                && data.prefix(4) == Data("RIFF".utf8)
                && data.subdata(in: 8..<12) == Data("WEBP".utf8)
        }
        guard signatureValid else { return false }
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { return false }
        let expectedHeight: Int?
        switch spriteVersionNumber {
        case 1: expectedHeight = 1872
        case 2: expectedHeight = 2288
        default: expectedHeight = nil
        }
        guard let expectedHeight,
              width.intValue == 1536,
              height.intValue == expectedHeight
        else { return false }
        #endif
        return true
    }

    private static let defaultFetch: Fetch = { request in
        let delegate = RedirectRejectingDelegate(originalURL: request.url)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.httpStatus(0) }
        if response.url != request.url { throw Error.redirectRejected }
        return Response(
            statusCode: http.statusCode,
            mimeType: http.value(forHTTPHeaderField: "Content-Type"),
            data: data
        )
    }
}

private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let originalURL: URL?
    init(originalURL: URL?) { self.originalURL = originalURL }
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
