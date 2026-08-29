import Foundation
import Testing

#if os(macOS)
import Darwin
#endif

@testable import CodexPadApplication

@Test
func releasedDesktopSurfaceAlwaysUsesCompleteTreeVerification() {
    #expect(
        CodexDesktopSurfaceVerifier.releasedSurfaceMode
            == .completeTree
    )
}

@Test
func desktopSurfaceVerifierAcceptsPinnedCriticalFilesAndCompleteTree() throws {
    let fixture = try DesktopSurfaceFixture()
    defer { fixture.remove() }

    let critical = try CodexDesktopSurfaceVerifier.verify(
        surfaceDirectory: fixture.surfaceDirectory,
        expectedDesktopVersion: "26.721.81911",
        expectedDesktopBuild: "5973",
        mode: .criticalFiles
    )
    let complete = try CodexDesktopSurfaceVerifier.verify(
        surfaceDirectory: fixture.surfaceDirectory,
        expectedDesktopVersion: "26.721.81911",
        expectedDesktopBuild: "5973",
        mode: .completeTree
    )

    #expect(critical.entryURL == fixture.surfaceDirectory.appending(path: "index.html"))
    #expect(critical.manifest.desktopVersion == "26.721.81911")
    #expect(critical.verifiedFileCount == 2)
    #expect(!critical.didVerifyCompleteTree)
    #expect(complete.verifiedFileCount == 2)
    #expect(complete.didVerifyCompleteTree)
}

@Test
func desktopSurfaceVerifierRejectsCriticalFileTampering() throws {
    let fixture = try DesktopSurfaceFixture()
    defer { fixture.remove() }
    try Data("modified renderer".utf8).write(
        to: fixture.surfaceDirectory.appending(path: "assets/app.js")
    )

    #expect(
        throws: CodexDesktopSurfaceVerificationError.sizeMismatch(
            path: "assets/app.js"
        )
    ) {
        try CodexDesktopSurfaceVerifier.verify(
            surfaceDirectory: fixture.surfaceDirectory,
            expectedDesktopVersion: "26.721.81911",
            expectedDesktopBuild: "5973",
            mode: .criticalFiles
        )
    }
}

@Test
func desktopSurfaceVerifierRejectsVersionDriftAndTraversalRecords() throws {
    let fixture = try DesktopSurfaceFixture()
    defer { fixture.remove() }

    #expect(
        throws: CodexDesktopSurfaceVerificationError.desktopVersionMismatch(
            expected: "26.721.99999",
            actual: "26.721.81911"
        )
    ) {
        try CodexDesktopSurfaceVerifier.verify(
            surfaceDirectory: fixture.surfaceDirectory,
            expectedDesktopVersion: "26.721.99999",
            expectedDesktopBuild: "5973",
            mode: .criticalFiles
        )
    }

    var manifest = try fixture.readManifest()
    manifest.criticalFiles[0].path = "../index.html"
    try fixture.writeManifest(manifest)

    #expect(
        throws: CodexDesktopSurfaceVerificationError.unsafeRelativePath(
            "../index.html"
        )
    ) {
        try CodexDesktopSurfaceVerifier.verify(
            surfaceDirectory: fixture.surfaceDirectory,
            expectedDesktopVersion: "26.721.81911",
            expectedDesktopBuild: "5973",
            mode: .criticalFiles
        )
    }
}

@Test
func desktopSurfaceVerifierExcludesItsManifestFromThePinnedTree() throws {
    let fixture = try DesktopSurfaceFixture()
    defer { fixture.remove() }

    var manifest = try fixture.readManifest()
    manifest.resourceFileCount += 1
    try fixture.writeManifest(manifest)

    #expect(
        throws: CodexDesktopSurfaceVerificationError.resourceFileCountMismatch(
            expected: 3,
            actual: 2
        )
    ) {
        try CodexDesktopSurfaceVerifier.verify(
            surfaceDirectory: fixture.surfaceDirectory,
            expectedDesktopVersion: "26.721.81911",
            expectedDesktopBuild: "5973",
            mode: .completeTree
        )
    }
}

@Test
func releasedDesktopSurfaceReusesCompleteTreeTrustOnlyForSameInstallAndManifest()
    async throws
{
    let fixture = try DesktopSurfaceFixture()
    defer { fixture.remove() }
    let cacheURL = FileManager.default.temporaryDirectory.appending(
        path: "codex-desktop-surface-cache-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: cacheURL) }

    let first = try await CodexDesktopSurfaceVerifier
        .verifyReleasedSurfaceInBackground(
            surfaceDirectory: fixture.surfaceDirectory,
            expectedDesktopVersion: "26.721.81911",
            expectedDesktopBuild: "5973",
            installIdentity: "install-a",
            cacheURL: cacheURL
        )
    let cached = try await CodexDesktopSurfaceVerifier
        .verifyReleasedSurfaceInBackground(
            surfaceDirectory: fixture.surfaceDirectory,
            expectedDesktopVersion: "26.721.81911",
            expectedDesktopBuild: "5973",
            installIdentity: "install-a",
            cacheURL: cacheURL
        )

    #expect(first.didVerifyCompleteTree)
    #expect(!cached.didVerifyCompleteTree)

    var manifest = try fixture.readManifest()
    manifest.criticalFiles[0].role = "entry-after-manifest-change"
    try fixture.writeManifest(manifest)
    let changedManifest = try await CodexDesktopSurfaceVerifier
        .verifyReleasedSurfaceInBackground(
            surfaceDirectory: fixture.surfaceDirectory,
            expectedDesktopVersion: "26.721.81911",
            expectedDesktopBuild: "5973",
            installIdentity: "install-a",
            cacheURL: cacheURL
        )
    #expect(changedManifest.didVerifyCompleteTree)

    let changedInstall = try await CodexDesktopSurfaceVerifier
        .verifyReleasedSurfaceInBackground(
            surfaceDirectory: fixture.surfaceDirectory,
            expectedDesktopVersion: "26.721.81911",
            expectedDesktopBuild: "5973",
            installIdentity: "install-b",
            cacheURL: cacheURL
        )
    #expect(changedInstall.didVerifyCompleteTree)
}

@Test
func releasedSurfaceInstallIdentitySurvivesBundleRelocation() throws {
    let first = try ReleasedInstallBundleFixture(
        name: "first",
        codeResources: "same-signed-release"
    )
    let relocated = try ReleasedInstallBundleFixture(
        name: "relocated",
        codeResources: "same-signed-release"
    )
    defer {
        first.remove()
        relocated.remove()
    }

    #expect(
        CodexDesktopSurfaceVerifier.releasedSurfaceInstallIdentity(
            bundle: first.bundle
        )
            == CodexDesktopSurfaceVerifier.releasedSurfaceInstallIdentity(
                bundle: relocated.bundle
            )
    )
}

@Test
func releasedSurfaceInstallIdentityChangesWithCodeSignatureResources() throws {
    let first = try ReleasedInstallBundleFixture(
        name: "signed-a",
        codeResources: "signed-release-a"
    )
    defer { first.remove() }
    let original = CodexDesktopSurfaceVerifier
        .releasedSurfaceInstallIdentity(bundle: first.bundle)

    try first.writeCodeResources("signed-release-b")
    let changed = CodexDesktopSurfaceVerifier
        .releasedSurfaceInstallIdentity(bundle: first.bundle)

    #expect(original != changed)
}

@Test
func failedCompleteTreeVerificationDoesNotPublishReleasedSurfaceTrust()
    async throws
{
    let fixture = try DesktopSurfaceFixture()
    defer { fixture.remove() }
    let cacheURL = FileManager.default.temporaryDirectory.appending(
        path: "codex-desktop-surface-cache-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    try Data("unmanifested".utf8).write(
        to: fixture.surfaceDirectory.appending(path: "extra.js")
    )

    await #expect(throws: CodexDesktopSurfaceVerificationError.self) {
        try await CodexDesktopSurfaceVerifier
            .verifyReleasedSurfaceInBackground(
                surfaceDirectory: fixture.surfaceDirectory,
                expectedDesktopVersion: "26.721.81911",
                expectedDesktopBuild: "5973",
                installIdentity: "install-a",
                cacheURL: cacheURL
            )
    }
    #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
}

#if os(macOS)
@Test(.serialized)
@MainActor
func releasedDesktopSurfaceVerificationDoesNotBlockMainActor() async throws {
    let fixture = try DesktopSurfaceFixture()
    defer { fixture.remove() }
    let fifo = try fixture.replaceCriticalAssetWithFIFO()
    let clock = ContinuousClock()
    let startedAt = clock.now

    let writer = Task.detached {
        try await Task.sleep(for: .milliseconds(300))
        let handle = try FileHandle(forWritingTo: fifo)
        try handle.close()
    }
    let verification = Task { @MainActor in
        try await CodexDesktopSurfaceVerifier.verifyInBackground(
            surfaceDirectory: fixture.surfaceDirectory,
            expectedDesktopVersion: "26.721.81911",
            expectedDesktopBuild: "5973",
            mode: .criticalFiles
        )
    }
    await Task.yield()
    let heartbeat = Task { @MainActor in clock.now }
    let heartbeatAt = await heartbeat.value

    #expect(
        startedAt.duration(to: heartbeatAt)
            < .milliseconds(500)
    )
    _ = try await verification.value
    try await writer.value
}
#endif

private struct ReleasedInstallBundleFixture {
    let root: URL
    let bundle: Bundle

    init(name: String, codeResources: String) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "codex-released-install-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let bundleURL = root.appending(
            path: "Codex for ipad.app",
            directoryHint: .isDirectory
        )
        let contents = bundleURL.appending(
            path: "Contents",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.mars.codexpad",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "26.803.41515",
            "CFBundleVersion": "6321",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: contents.appending(path: "Info.plist"))
        guard let loaded = Bundle(url: bundleURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        bundle = loaded
        try writeCodeResources(codeResources)
    }

    func writeCodeResources(_ value: String) throws {
        let signatureDirectory = bundle.bundleURL.appending(
            path: "_CodeSignature",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: signatureDirectory,
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(
            to: signatureDirectory.appending(path: "CodeResources")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct DesktopSurfaceFixture {
    let surfaceDirectory: URL

    init() throws {
        surfaceDirectory = FileManager.default.temporaryDirectory
            .appending(
                path: "codex-desktop-surface-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let assets = surfaceDirectory.appending(
            path: "assets",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )
        try Data("<html>Codex</html>".utf8).write(
            to: surfaceDirectory.appending(path: "index.html")
        )
        try Data("console.log('Codex')".utf8).write(
            to: assets.appending(path: "app.js")
        )

        let files = [
            try pinnedFile(path: "index.html", role: "entry"),
            try pinnedFile(path: "assets/app.js", role: "module-entry"),
        ]
        let tree = try CodexDesktopSurfaceVerifier.computeTreeIdentity(
            surfaceDirectory: surfaceDirectory
        )
        try writeManifest(
            CodexDesktopSurfaceManifest(
                schemaVersion: 1,
                desktopVersion: "26.721.81911",
                desktopBuild: "5973",
                productName: "Codex",
                ipadProductName: "Codex for ipad",
                resourceDirectoryName: "CodexDesktopSurface",
                resourceFileCount: tree.fileCount,
                resourceTotalBytes: tree.totalBytes,
                resourceTreeSha256: tree.sha256,
                entry: .init(path: "index.html"),
                criticalFiles: files
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: surfaceDirectory)
    }

    func readManifest() throws -> CodexDesktopSurfaceManifest {
        let data = try Data(
            contentsOf: surfaceDirectory.appending(
                path: CodexDesktopSurfaceVerifier.manifestFileName
            )
        )
        return try JSONDecoder().decode(
            CodexDesktopSurfaceManifest.self,
            from: data
        )
    }

    func writeManifest(_ manifest: CodexDesktopSurfaceManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: surfaceDirectory.appending(
                path: CodexDesktopSurfaceVerifier.manifestFileName
            ),
            options: .atomic
        )
    }

    #if os(macOS)
    func replaceCriticalAssetWithFIFO() throws -> URL {
        let fifo = surfaceDirectory.appending(path: "assets/app.js")
        try FileManager.default.removeItem(at: fifo)
        guard Darwin.mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var manifest = try readManifest()
        manifest.criticalFiles[1].bytes = 0
        manifest.criticalFiles[1].sha256 =
            "e3b0c44298fc1c149afbf4c8996fb924"
            + "27ae41e4649b934ca495991b7852b855"
        try writeManifest(manifest)
        return fifo
    }
    #endif

    private func pinnedFile(
        path: String,
        role: String
    ) throws -> CodexDesktopSurfaceManifest.CriticalFile {
        let url = surfaceDirectory.appending(path: path)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return .init(
            path: path,
            role: role,
            bytes: (attributes[.size] as? NSNumber)?.intValue ?? -1,
            sha256: try CodexDesktopSurfaceVerifier.sha256(of: url)
        )
    }
}
