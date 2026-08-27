import Foundation
import Testing
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

@testable import CodexPadApplication

private typealias AvatarValue = CodexDesktopAppHostRPC.Value

private func validPNG(version: Int = 2) -> Data {
    #if canImport(CoreGraphics) && canImport(ImageIO)
    let width = 1536
    let height = version == 1 ? 1872 : 2288
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        fatalError("unable to create spritesheet fixture")
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        "public.png" as CFString,
        1,
        nil
    ) else {
        fatalError("unable to create PNG fixture destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("unable to finalize PNG fixture")
    }
    return output as Data
    #else
    return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    #endif
}


private func avatarRequest(url: String = "https://example.com/owl.png") -> AvatarValue {
    .object([
        "name": .string("Owl"),
        "description": .string("Night owl"),
        "imageUrl": .string(url),
        "spriteVersionNumber": .integer(2),
    ])
}

@Test
func customAvatarPreviewReturnsReleasedShapeWithoutPersisting() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("avatar-preview-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CodexDesktopCustomAvatarStore(rootURL: root) { _ in
        .init(statusCode: 200, mimeType: "image/png", data: validPNG(version: 2))
    }
    let result = try await store.preview(avatarRequest())
    guard case let .object(fields) = result else {
        Issue.record("expected preview object")
        return
    }
    #expect(fields["displayName"] == .string("Owl"))
    #expect(fields["description"] == .string("Night owl"))
    #expect(fields["spriteVersionNumber"] == .integer(2))
    #expect(fields["spritesheetDataUrl"] == .string("data:image/png;base64,\(validPNG(version: 2).base64EncodedString())"))
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test
func customAvatarInstallPersistsAndLoadsByID() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("avatar-install-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CodexDesktopCustomAvatarStore(rootURL: root) { _ in
        .init(statusCode: 200, mimeType: "image/png; charset=binary", data: validPNG(version: 2))
    }
    let installed = try await store.install(avatarRequest())
    guard case let .object(fields) = installed,
          case let .string(id)? = fields["id"] else {
        Issue.record("expected installed id")
        return
    }
    #expect(id.hasPrefix("custom:"))
    guard case let .object(loaded) = try await store.load(),
          case let .array(avatars)? = loaded["avatars"] else {
        Issue.record("expected load response")
        return
    }
    #expect(loaded["avatarDirectory"] == .string(root.path))
    #expect(avatars.count == 1)
    guard case let .object(avatar) = try await store.loadAvatar(id: id) else {
        Issue.record("expected avatar response")
        return
    }
    #expect(avatar["id"] == .string(id))
    #expect(avatar["spritesheetDataUrl"] == .string("data:image/png;base64,\(validPNG(version: 2).base64EncodedString())"))
}

@Test
func customAvatarRejectsInvalidTransportAndPayload() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("avatar-invalid-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let contentTypeStore = CodexDesktopCustomAvatarStore(rootURL: root) { _ in
        .init(statusCode: 200, mimeType: "image/jpeg", data: validPNG(version: 2))
    }
    await #expect(throws: CodexDesktopCustomAvatarStore.Error.unsupportedContentType) {
        try await contentTypeStore.preview(avatarRequest())
    }
    let statusStore = CodexDesktopCustomAvatarStore(rootURL: root) { _ in
        .init(statusCode: 302, mimeType: "image/png", data: validPNG(version: 2))
    }
    await #expect(throws: CodexDesktopCustomAvatarStore.Error.redirectRejected) {
        try await statusStore.preview(avatarRequest())
    }
    let oversizedStore = CodexDesktopCustomAvatarStore(rootURL: root) { _ in
        .init(statusCode: 200, mimeType: "image/png", data: Data(count: 20 * 1024 * 1024 + 1))
    }
    await #expect(throws: CodexDesktopCustomAvatarStore.Error.payloadTooLarge) {
        try await oversizedStore.preview(avatarRequest())
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test
func customAvatarFailedInstallPreservesExistingStateAndCleansTemporaryFiles() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("avatar-preserve-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let good = CodexDesktopCustomAvatarStore(rootURL: root) { _ in
        .init(statusCode: 200, mimeType: "image/png", data: validPNG(version: 2))
    }
    _ = try await good.install(avatarRequest())
    let before = try await good.load()
    let bad = CodexDesktopCustomAvatarStore(rootURL: root) { _ in
        .init(statusCode: 200, mimeType: "image/png", data: Data([1, 2, 3]))
    }
    await #expect(throws: CodexDesktopCustomAvatarStore.Error.invalidImage) {
        try await bad.install(avatarRequest(url: "https://example.com/bad.png"))
    }
    #expect(try await good.load() == before)
    let leftovers = try FileManager.default.contentsOfDirectory(
        at: FileManager.default.temporaryDirectory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("codex-custom-avatar-") }
    #expect(leftovers.isEmpty)
}

@Test
func customAvatarRejectsSpriteVersionDimensionMismatch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("avatar-layout-mismatch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CodexDesktopCustomAvatarStore(rootURL: root) { _ in
        .init(statusCode: 200, mimeType: "image/png", data: validPNG(version: 2))
    }
    await #expect(throws: CodexDesktopCustomAvatarStore.Error.invalidImage) {
        try await store.preview(
            .object([
                "name": .string("Owl"),
                "description": .string("Night owl"),
                "imageUrl": .string("https://example.com/owl.png"),
                "spriteVersionNumber": .integer(1),
            ])
        )
    }
}
