import Compression
import Foundation

public enum CodexPluginBundleArchiveError:
    Error,
    Equatable,
    Sendable
{
    case invalidPluginPath(String)
    case archiveTooLarge(bytes: Int, maximumBytes: Int)
    case invalidArchive(String)
    case unsafeArchivePath(String)
    case compressionFailed
    case decompressionFailed
}

public protocol CodexPluginBundleArchiving: Sendable {
    func packDirectory(
        at directory: URL,
        maximumBytes: Int
    ) throws -> Data

    func extractGzipTar(
        _ archive: Data,
        to destination: URL,
        maximumExpandedBytes: Int
    ) throws
}

public struct CodexPluginBundleArchiveService:
    CodexPluginBundleArchiving,
    @unchecked Sendable
{
    private let fileManager: FileManager
    private static let blockSize = 512

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func packDirectory(
        at directory: URL,
        maximumBytes: Int
    ) throws -> Data {
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
              fileManager.fileExists(
                  atPath: directory.path,
                  isDirectory: &isDirectory
              ),
              isDirectory.boolValue
        else {
            throw CodexPluginBundleArchiveError.invalidPluginPath(
                directory.path
            )
        }
        let standardizedRoot = directory.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: []
        ) else {
            throw CodexPluginBundleArchiveError.invalidPluginPath(
                directory.path
            )
        }

        let urls = enumerator.compactMap { $0 as? URL }.sorted {
            $0.path < $1.path
        }
        var tar = Data()
        for url in urls {
            let relative = String(
                url.standardizedFileURL.path.dropFirst(
                    standardizedRoot.path.count
                        + (standardizedRoot.path.hasSuffix("/") ? 0 : 1)
                )
            )
            guard !relative.isEmpty else { continue }
            let resourceKeys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]
            let values = try url.resourceValues(forKeys: resourceKeys)
            let type: UInt8
            let contents: Data
            let linkName: String?
            if values.isSymbolicLink == true {
                type = 0x32
                contents = Data()
                linkName = try fileManager.destinationOfSymbolicLink(
                    atPath: url.path
                )
            } else if values.isDirectory == true {
                type = 0x35
                contents = Data()
                linkName = nil
            } else if values.isRegularFile == true {
                type = 0x30
                contents = try Data(
                    contentsOf: url,
                    options: [.mappedIfSafe]
                )
                linkName = nil
            } else {
                continue
            }
            let attributes = try fileManager.attributesOfItem(
                atPath: url.path
            )
            let permissions =
                (attributes[.posixPermissions] as? NSNumber)?
                .uint32Value ?? 0o644
            tar.append(
                try Self.tarHeader(
                    path: relative
                        + (values.isDirectory == true ? "/" : ""),
                    size: contents.count,
                    modificationTime:
                        values.contentModificationDate
                            ?? Date(timeIntervalSince1970: 0),
                    permissions: permissions,
                    type: type,
                    linkName: linkName
                )
            )
            tar.append(contents)
            let remainder = contents.count % Self.blockSize
            if remainder != 0 {
                tar.append(
                    Data(
                        repeating: 0,
                        count: Self.blockSize - remainder
                    )
                )
            }
        }
        tar.append(Data(repeating: 0, count: Self.blockSize * 2))
        let gzip = try Self.gzip(tar)
        guard gzip.count <= maximumBytes else {
            throw CodexPluginBundleArchiveError.archiveTooLarge(
                bytes: gzip.count,
                maximumBytes: maximumBytes
            )
        }
        return gzip
    }

    public func extractGzipTar(
        _ archive: Data,
        to destination: URL,
        maximumExpandedBytes: Int
    ) throws {
        let tar = try Self.gunzip(
            archive,
            maximumExpandedBytes: maximumExpandedBytes
        )
        let root = destination.standardizedFileURL
        if fileManager.fileExists(atPath: root.path) {
            throw CodexPluginBundleArchiveError.invalidPluginPath(
                "checkout destination already exists: \(root.path)"
            )
        }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        do {
            var offset = 0
            var extractedBytes = 0
            var globalPAX: [String: String] = [:]
            var nextPAX: [String: String] = [:]
            while offset + Self.blockSize <= tar.count {
                let header = tar.subdata(
                    in: offset..<(offset + Self.blockSize)
                )
                if header.allSatisfy({ $0 == 0 }) { break }
                let entry = try Self.parseTarHeader(header)
                offset += Self.blockSize
                guard offset + entry.size <= tar.count else {
                    throw CodexPluginBundleArchiveError.invalidArchive(
                        "truncated tar entry"
                    )
                }
                let entryContents = tar.subdata(
                    in: offset..<(offset + entry.size)
                )
                if entry.type == 0x67 || entry.type == 0x78 {
                    let attributes = try Self.parsePAX(entryContents)
                    if entry.type == 0x67 {
                        globalPAX.merge(attributes) { _, new in new }
                    } else {
                        nextPAX = attributes
                    }
                    offset += entry.size
                    let remainder = offset % Self.blockSize
                    if remainder != 0 {
                        offset += Self.blockSize - remainder
                    }
                    continue
                }
                let effectivePath =
                    nextPAX["path"]
                    ?? globalPAX["path"]
                    ?? entry.path
                let effectiveLinkName =
                    nextPAX["linkpath"]
                    ?? globalPAX["linkpath"]
                    ?? entry.linkName
                nextPAX = [:]
                let target = try Self.safeTarget(
                    root: root,
                    relativePath: effectivePath
                )
                switch entry.type {
                case 0x35:
                    try fileManager.createDirectory(
                        at: target,
                        withIntermediateDirectories: true
                    )
                case 0x32:
                    _ = try Self.safeSymlinkTarget(
                        root: root,
                        linkURL: target,
                        linkName: effectiveLinkName ?? ""
                    )
                    try fileManager.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.createSymbolicLink(
                        atPath: target.path,
                        withDestinationPath:
                            effectiveLinkName ?? ""
                    )
                case 0, 0x30:
                    extractedBytes += entry.size
                    guard extractedBytes <= maximumExpandedBytes else {
                        throw CodexPluginBundleArchiveError
                            .archiveTooLarge(
                                bytes: extractedBytes,
                                maximumBytes: maximumExpandedBytes
                            )
                    }
                    try fileManager.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try tar.subdata(
                        in: offset..<(offset + entry.size)
                    ).write(to: target, options: .atomic)
                default:
                    throw CodexPluginBundleArchiveError.invalidArchive(
                        "unsupported tar entry type"
                    )
                }
                offset += entry.size
                let remainder = offset % Self.blockSize
                if remainder != 0 {
                    offset += Self.blockSize - remainder
                }
            }
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    static func testingGzipTar(
        path: String,
        contents: Data
    ) -> Data {
        var tar = Data()
        tar.append(
            try! tarHeader(
                path: path,
                size: contents.count,
                modificationTime: Date(timeIntervalSince1970: 0),
                permissions: 0o644,
                type: 0x30,
                linkName: nil
            )
        )
        tar.append(contents)
        let remainder = contents.count % blockSize
        if remainder != 0 {
            tar.append(
                Data(repeating: 0, count: blockSize - remainder)
            )
        }
        tar.append(Data(repeating: 0, count: blockSize * 2))
        return try! gzip(tar)
    }

    static func testingGzipTarWithGlobalPAX(
        path: String,
        contents: Data
    ) -> Data {
        let pax = Data("28 comment=CodexPad fixture\n".utf8)
        var tar = Data()
        tar.append(
            try! tarHeader(
                path: "pax_global_header",
                size: pax.count,
                modificationTime: Date(timeIntervalSince1970: 0),
                permissions: 0o644,
                type: 0x67,
                linkName: nil
            )
        )
        tar.append(pax)
        tar.append(
            Data(
                repeating: 0,
                count: blockSize - pax.count % blockSize
            )
        )
        tar.append(
            try! tarHeader(
                path: path,
                size: contents.count,
                modificationTime: Date(timeIntervalSince1970: 0),
                permissions: 0o644,
                type: 0x30,
                linkName: nil
            )
        )
        tar.append(contents)
        let remainder = contents.count % blockSize
        if remainder != 0 {
            tar.append(
                Data(repeating: 0, count: blockSize - remainder)
            )
        }
        tar.append(Data(repeating: 0, count: blockSize * 2))
        return try! gzip(tar)
    }
}

private extension CodexPluginBundleArchiveService {
    struct TarEntry {
        let path: String
        let size: Int
        let type: UInt8
        let linkName: String?
    }

    static func tarHeader(
        path: String,
        size: Int,
        modificationTime: Date,
        permissions: UInt32,
        type: UInt8,
        linkName: String?
    ) throws -> Data {
        let (name, prefix) = try splitTarPath(path)
        var header = Data(repeating: 0, count: blockSize)
        try writeString(name, to: &header, offset: 0, length: 100)
        writeOctal(UInt64(permissions), to: &header, offset: 100, length: 8)
        writeOctal(0, to: &header, offset: 108, length: 8)
        writeOctal(0, to: &header, offset: 116, length: 8)
        writeOctal(UInt64(size), to: &header, offset: 124, length: 12)
        writeOctal(
            UInt64(max(0, modificationTime.timeIntervalSince1970)),
            to: &header,
            offset: 136,
            length: 12
        )
        header.replaceSubrange(
            148..<156,
            with: Data(repeating: 0x20, count: 8)
        )
        header[156] = type
        if let linkName {
            try writeString(
                linkName,
                to: &header,
                offset: 157,
                length: 100
            )
        }
        try writeString(
            "ustar",
            to: &header,
            offset: 257,
            length: 6
        )
        try writeString("00", to: &header, offset: 263, length: 2)
        if !prefix.isEmpty {
            try writeString(
                prefix,
                to: &header,
                offset: 345,
                length: 155
            )
        }
        writeOctal(
            UInt64(header.reduce(0) { $0 + UInt64($1) }),
            to: &header,
            offset: 148,
            length: 8
        )
        return header
    }

    static func parseTarHeader(_ header: Data) throws -> TarEntry {
        let storedChecksum = try parseOctal(
            header.subdata(in: 148..<156)
        )
        var checksumHeader = header
        checksumHeader.replaceSubrange(
            148..<156,
            with: Data(repeating: 0x20, count: 8)
        )
        let actual = checksumHeader.reduce(0) {
            $0 + UInt64($1)
        }
        guard storedChecksum == actual else {
            throw CodexPluginBundleArchiveError.invalidArchive(
                "tar checksum mismatch"
            )
        }
        let name = readString(header, offset: 0, length: 100)
        let prefix = readString(header, offset: 345, length: 155)
        let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
        guard !path.isEmpty else {
            throw CodexPluginBundleArchiveError.invalidArchive(
                "empty tar path"
            )
        }
        let sizeValue = try parseOctal(
            header.subdata(in: 124..<136)
        )
        guard sizeValue <= UInt64(Int.max) else {
            throw CodexPluginBundleArchiveError.invalidArchive(
                "tar entry size overflow"
            )
        }
        let linkName = readString(header, offset: 157, length: 100)
        return TarEntry(
            path: path,
            size: Int(sizeValue),
            type: header[156],
            linkName: linkName.isEmpty ? nil : linkName
        )
    }

    static func parsePAX(
        _ data: Data
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        var offset = 0
        while offset < data.count {
            guard let space = data[offset...].firstIndex(of: 0x20)
            else {
                throw CodexPluginBundleArchiveError.invalidArchive(
                    "invalid pax record length"
                )
            }
            let lengthText = String(
                decoding: data[offset..<space],
                as: UTF8.self
            )
            guard let length = Int(lengthText),
                  length > 0,
                  offset + length <= data.count
            else {
                throw CodexPluginBundleArchiveError.invalidArchive(
                    "invalid pax record size"
                )
            }
            let recordStart = space + 1
            let recordEnd = offset + length
            guard recordStart < recordEnd,
                  data[recordEnd - 1] == 0x0a
            else {
                throw CodexPluginBundleArchiveError.invalidArchive(
                    "invalid pax record terminator"
                )
            }
            let payload = data[
                recordStart..<(recordEnd - 1)
            ]
            guard let separator = payload.firstIndex(of: 0x3d)
            else {
                throw CodexPluginBundleArchiveError.invalidArchive(
                    "invalid pax record"
                )
            }
            let key = String(
                decoding: payload[..<separator],
                as: UTF8.self
            )
            let value = String(
                decoding: payload[payload.index(after: separator)...],
                as: UTF8.self
            )
            result[key] = value
            offset = recordEnd
        }
        return result
    }

    static func safeTarget(
        root: URL,
        relativePath: String
    ) throws -> URL {
        guard !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw CodexPluginBundleArchiveError.unsafeArchivePath(
                relativePath
            )
        }
        let target = root.appendingPathComponent(
            relativePath
        ).standardizedFileURL
        let prefix = root.path.hasSuffix("/")
            ? root.path : root.path + "/"
        guard target.path.hasPrefix(prefix) else {
            throw CodexPluginBundleArchiveError.unsafeArchivePath(
                relativePath
            )
        }
        return target
    }

    static func safeSymlinkTarget(
        root: URL,
        linkURL: URL,
        linkName: String
    ) throws -> URL {
        guard !linkName.isEmpty, !linkName.hasPrefix("/") else {
            throw CodexPluginBundleArchiveError.unsafeArchivePath(
                linkName
            )
        }
        let target = linkURL.deletingLastPathComponent()
            .appendingPathComponent(linkName)
            .standardizedFileURL
        let prefix = root.path.hasSuffix("/")
            ? root.path : root.path + "/"
        guard target.path.hasPrefix(prefix) else {
            throw CodexPluginBundleArchiveError.unsafeArchivePath(
                linkName
            )
        }
        return target
    }

    static func splitTarPath(
        _ path: String
    ) throws -> (String, String) {
        guard !path.utf8.isEmpty else {
            throw CodexPluginBundleArchiveError.invalidPluginPath(path)
        }
        if path.utf8.count <= 100 { return (path, "") }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        for index in stride(
            from: components.count - 1,
            through: 1,
            by: -1
        ) {
            let prefix = components[..<index].joined(separator: "/")
            let name = components[index...].joined(separator: "/")
            if prefix.utf8.count <= 155, name.utf8.count <= 100 {
                return (name, prefix)
            }
        }
        throw CodexPluginBundleArchiveError.invalidPluginPath(path)
    }

    static func writeString(
        _ string: String,
        to data: inout Data,
        offset: Int,
        length: Int
    ) throws {
        let bytes = Array(string.utf8)
        guard bytes.count <= length else {
            throw CodexPluginBundleArchiveError.invalidPluginPath(
                string
            )
        }
        data.replaceSubrange(
            offset..<(offset + bytes.count),
            with: bytes
        )
    }

    static func writeOctal(
        _ value: UInt64,
        to data: inout Data,
        offset: Int,
        length: Int
    ) {
        let digits = String(value, radix: 8)
        let padded = String(
            repeating: "0",
            count: max(0, length - digits.count - 1)
        ) + digits + "\0"
        let bytes = Array(padded.utf8.suffix(length))
        data.replaceSubrange(offset..<(offset + length), with: bytes)
    }

    static func readString(
        _ data: Data,
        offset: Int,
        length: Int
    ) -> String {
        let bytes = data[offset..<(offset + length)]
            .prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func parseOctal(_ data: Data) throws -> UInt64 {
        let text = String(
            decoding: data.prefix { $0 != 0 && $0 != 0x20 },
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || text.allSatisfy({ ("0"..."7").contains($0) }),
              let value = UInt64(text.isEmpty ? "0" : text, radix: 8)
        else {
            throw CodexPluginBundleArchiveError.invalidArchive(
                "invalid tar number"
            )
        }
        return value
    }

    static func gzip(_ input: Data) throws -> Data {
        let encoded = try rawDeflate(input)
        var output = Data([
            0x1f, 0x8b, 0x08, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0xff,
        ])
        output.append(encoded)
        output.appendLittleEndian(crc32(input))
        output.appendLittleEndian(UInt32(truncatingIfNeeded: input.count))
        return output
    }

    static func gunzip(
        _ input: Data,
        maximumExpandedBytes: Int
    ) throws -> Data {
        guard input.count >= 18,
              input[0] == 0x1f,
              input[1] == 0x8b,
              input[2] == 0x08
        else {
            throw CodexPluginBundleArchiveError.invalidArchive(
                "unsupported gzip header"
            )
        }
        let flags = input[3]
        guard flags & 0xe0 == 0 else {
            throw CodexPluginBundleArchiveError.invalidArchive(
                "unsupported gzip flags"
            )
        }
        let trailerStart = input.count - 8
        var payloadStart = 10
        if flags & 0x04 != 0 {
            guard payloadStart + 2 <= trailerStart else {
                throw CodexPluginBundleArchiveError.invalidArchive(
                    "truncated gzip extra header"
                )
            }
            let extraLength = Int(input[payloadStart])
                | (Int(input[payloadStart + 1]) << 8)
            payloadStart += 2
            guard payloadStart + extraLength <= trailerStart else {
                throw CodexPluginBundleArchiveError.invalidArchive(
                    "truncated gzip extra field"
                )
            }
            payloadStart += extraLength
        }
        func byteAfterZeroTerminatedField(
            startingAt start: Int
        ) -> Int? {
            var index = start
            while index < trailerStart {
                if input[index] == 0 {
                    return index + 1
                }
                index += 1
            }
            return nil
        }
        if flags & 0x08 != 0 {
            guard let next = byteAfterZeroTerminatedField(
                startingAt: payloadStart
            ) else {
                throw CodexPluginBundleArchiveError.invalidArchive(
                    "truncated gzip filename"
                )
            }
            payloadStart = next
        }
        if flags & 0x10 != 0 {
            guard let next = byteAfterZeroTerminatedField(
                startingAt: payloadStart
            ) else {
                throw CodexPluginBundleArchiveError.invalidArchive(
                    "truncated gzip comment"
                )
            }
            payloadStart = next
        }
        if flags & 0x02 != 0 {
            guard payloadStart + 2 <= trailerStart else {
                throw CodexPluginBundleArchiveError.invalidArchive(
                    "truncated gzip header checksum"
                )
            }
            payloadStart += 2
        }
        let expectedCRC = input.readLittleEndianUInt32(
            at: input.count - 8
        )
        let expandedSize = Int(
            input.readLittleEndianUInt32(at: input.count - 4)
        )
        guard expandedSize <= maximumExpandedBytes else {
            throw CodexPluginBundleArchiveError.archiveTooLarge(
                bytes: expandedSize,
                maximumBytes: maximumExpandedBytes
            )
        }
        let raw = input.subdata(in: payloadStart..<trailerStart)
        let outputCapacity = max(expandedSize, 1)
        var output = Data(count: outputCapacity)
        let decoded = raw.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compression_decode_buffer(
                    destination.bindMemory(
                        to: UInt8.self
                    ).baseAddress!,
                    outputCapacity,
                    source.bindMemory(
                        to: UInt8.self
                    ).baseAddress!,
                    raw.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == expandedSize else {
            throw CodexPluginBundleArchiveError.decompressionFailed
        }
        output.count = decoded
        guard crc32(output) == expectedCRC else {
            throw CodexPluginBundleArchiveError.invalidArchive(
                "gzip checksum mismatch"
            )
        }
        return output
    }

    static func rawDeflate(_ input: Data) throws -> Data {
        var capacity = max(input.count + 65_536, 1_024)
        while capacity <= max(input.count * 4, 4 * 1024 * 1024) {
            var output = Data(count: capacity)
            let count = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    compression_encode_buffer(
                        destination.bindMemory(
                            to: UInt8.self
                        ).baseAddress!,
                        capacity,
                        source.bindMemory(
                            to: UInt8.self
                        ).baseAddress!,
                        input.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if count > 0 {
                output.count = count
                return output
            }
            capacity *= 2
        }
        throw CodexPluginBundleArchiveError.compressionFailed
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1)
                    ^ (0xedb8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }

    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
