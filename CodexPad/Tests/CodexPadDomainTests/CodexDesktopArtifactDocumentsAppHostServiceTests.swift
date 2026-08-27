import CryptoKit
import Foundation
import Testing
@testable import CodexPadApplication

private typealias ArtifactValue = CodexDesktopAppHostRPC.Value
private typealias ArtifactService =
    CodexDesktopArtifactDocumentsAppHostService

@Test
func desktopArtifactDocumentsAdoptsFindsReadsAndPersistsReleasedRecord()
    async throws
{
    let fixture = try ArtifactDocumentsFixture()
    defer { fixture.remove() }
    let service = ArtifactService(
        allowedWorkspaceRoots: [fixture.workspace],
        storeDirectory: fixture.store
    )
    let checkpoint = Data([0, 1, 2, 3])
    let expectedRecord = artifactRecord(
        checkpoint: checkpoint,
        documentID: "document-1",
        kind: "presentation",
        publicFileHash: fixture.initialHash,
        publicFilePath: fixture.artifact.path
    )

    #expect(
        try await service.invoke(
            service: "artifactDocuments",
            method: "find",
            arguments: [fixture.baseRequest]
        ) == .object([
            "status": .string("ok"),
            "value": .null,
        ])
    )
    #expect(
        try await service.invoke(
            service: "artifactDocuments",
            method: "adopt",
            arguments: [
                fixture.adoptRequest(
                    checkpoint: checkpoint,
                    documentID: "document-1",
                    kind: "presentation"
                )
            ]
        ) == .object([
            "status": .string("ok"),
            "value": expectedRecord,
        ])
    )
    #expect(
        try await service.invoke(
            service: "artifactDocuments",
            method: "read",
            arguments: [
                fixture.documentRequest(documentID: "document-1")
            ]
        ) == .object([
            "status": .string("ok"),
            "value": expectedRecord,
        ])
    )

    let reopened = ArtifactService(
        allowedWorkspaceRoots: [fixture.workspace],
        storeDirectory: fixture.store
    )
    #expect(
        try await reopened.invoke(
            service: "artifactDocuments",
            method: "find",
            arguments: [fixture.baseRequest]
        ) == .object([
            "status": .string("ok"),
            "value": expectedRecord,
        ])
    )
}

@Test
func desktopArtifactDocumentsAppendIsIdempotentAndPublishesExactUpdate()
    async throws
{
    let fixture = try ArtifactDocumentsFixture()
    defer { fixture.remove() }
    let events = ArtifactEventRecorder()
    let service = ArtifactService(
        allowedWorkspaceRoots: [fixture.workspace],
        storeDirectory: fixture.store,
        subscriptionEventHandler: { callbackID, event in
            await events.record(callbackID: callbackID, event: event)
        }
    )
    try await fixture.adopt(
        using: service,
        checkpoint: Data([10]),
        documentID: "document-append",
        kind: "spreadsheet"
    )

    let subscribed = try await service.invoke(
        service: "artifactDocuments",
        method: "subscribe",
        arguments: [
            fixture.documentRequest(documentID: "document-append"),
            .import(71),
        ]
    )
    guard case let .object(subscribeResult) = subscribed,
          subscribeResult["status"] == .string("ok"),
          case let .object(value)? = subscribeResult["value"]
    else {
        Issue.record("Expected released subscribe result")
        return
    }
    #expect(value["record"] != nil)
    #expect(
        value["subscription"]
            == .rpcObject(["unsubscribe": .rpcObject([:])])
    )

    let update = Data([21, 22, 23])
    let appendRequest = fixture.appendRequest(
        documentID: "document-append",
        update: update,
        updateID: "update-1"
    )
    #expect(
        try await service.invoke(
            service: "artifactDocuments",
            method: "append",
            arguments: [appendRequest]
        ) == .object([
            "status": .string("ok"),
            "value": .object([
                "applied": .bool(true),
                "stateVersion": .integer(1),
            ]),
        ])
    )
    #expect(
        await events.events == [
            .init(
                callbackID: 71,
                event: .object([
                    "checkpointStateVersion": .integer(0),
                    "committedUpdate": .object([
                        "bytes": bytesValue(update),
                        "originId": .string("origin-1"),
                        "source": .string("model"),
                        "stateVersion": .integer(1),
                        "updateId": .string("update-1"),
                    ]),
                    "documentId": .string("document-append"),
                    "materializedStateVersion": .integer(0),
                    "stateVersion": .integer(1),
                ])
            )
        ]
    )

    #expect(
        try await service.invoke(
            service: "artifactDocuments",
            method: "append",
            arguments: [appendRequest]
        ) == .object([
            "status": .string("ok"),
            "value": .object([
                "applied": .bool(false),
                "stateVersion": .integer(1),
            ]),
        ])
    )
    #expect(await events.events.count == 1)
}

@Test
func desktopArtifactDocumentsRefreshHonorsViewerSessionSemantics()
    async throws
{
    let fixture = try ArtifactDocumentsFixture()
    defer { fixture.remove() }
    let service = ArtifactService(
        allowedWorkspaceRoots: [fixture.workspace],
        storeDirectory: fixture.store,
        subscriptionEventHandler: { _, _ in }
    )
    let checkpoint = Data([31])
    try await fixture.adopt(
        using: service,
        checkpoint: checkpoint,
        documentID: "document-clean",
        kind: "presentation"
    )

    for callbackID in [81, 82] {
        _ = try await service.invoke(
            service: "artifactDocuments",
            method: "subscribe",
            arguments: [
                fixture.documentRequest(documentID: "document-clean"),
                .import(callbackID),
            ]
        )
    }

    let refresh = fixture.refreshRequest(
        checkpoint: Data([32]),
        documentID: "document-clean",
        replacementDocumentID: "document-replacement"
    )
    let multipleViewers = try await service.invoke(
        service: "artifactDocuments",
        method: "refreshCleanSession",
        arguments: [refresh]
    )
    guard case let .object(outer) = multipleViewers,
          outer["status"] == .string("ok"),
          case let .object(value)? = outer["value"]
    else {
        Issue.record("Expected multiple-viewers result")
        return
    }
    #expect(value["outcome"] == .string("multiple-viewers"))
    #expect(value["record"] != nil)

    await service.unsubscribe(callbackID: 82)
    let refreshed = try await service.invoke(
        service: "artifactDocuments",
        method: "refreshCleanSession",
        arguments: [refresh]
    )
    guard case let .object(refreshedOuter) = refreshed,
          refreshedOuter["status"] == .string("ok"),
          case let .object(refreshedValue)? =
              refreshedOuter["value"],
          case let .object(record)? = refreshedValue["record"]
    else {
        Issue.record("Expected refreshed result")
        return
    }
    #expect(refreshedValue["applied"] == .bool(true))
    #expect(refreshedValue["outcome"] == .string("refreshed"))
    #expect(record["documentId"] == .string("document-replacement"))
    #expect(record["stateVersion"] == .integer(0))
}

@Test
func desktopArtifactDocumentsMaterializesRealFileAndReportsConflicts()
    async throws
{
    let fixture = try ArtifactDocumentsFixture()
    defer { fixture.remove() }
    let service = ArtifactService(
        allowedWorkspaceRoots: [fixture.workspace],
        storeDirectory: fixture.store
    )
    try await fixture.adopt(
        using: service,
        checkpoint: Data([41]),
        documentID: "document-materialize",
        kind: "spreadsheet"
    )
    _ = try await service.invoke(
        service: "artifactDocuments",
        method: "append",
        arguments: [
            fixture.appendRequest(
                documentID: "document-materialize",
                update: Data([42]),
                updateID: "materialize-update"
            )
        ]
    )

    let publicBytes = Data("materialized artifact".utf8)
    let materializedHash = sha256(publicBytes)
    let materializeRequest = fixture.materializeRequest(
        documentID: "document-materialize",
        expectedStateVersion: 1,
        materializationID: "materialization-1",
        bytes: publicBytes
    )
    #expect(
        try await service.invoke(
            service: "artifactDocuments",
            method: "materialize",
            arguments: [materializeRequest]
        ) == .object([
            "status": .string("ok"),
            "value": .object([
                "applied": .bool(true),
                "materializedStateVersion": .integer(1),
                "outcome": .string("materialized"),
                "publicFileHash": .string(materializedHash),
                "stateVersion": .integer(1),
            ]),
        ])
    )
    #expect(try Data(contentsOf: fixture.artifact) == publicBytes)

    #expect(
        try await service.invoke(
            service: "artifactDocuments",
            method: "materialize",
            arguments: [materializeRequest]
        ) == .object([
            "status": .string("ok"),
            "value": .object([
                "applied": .bool(false),
                "materializedStateVersion": .integer(1),
                "outcome": .string("materialized"),
                "publicFileHash": .string(materializedHash),
                "stateVersion": .integer(1),
            ]),
        ])
    )

    let externalBytes = Data("externally replaced".utf8)
    try externalBytes.write(to: fixture.artifact, options: .atomic)
    _ = try await service.invoke(
        service: "artifactDocuments",
        method: "append",
        arguments: [
            fixture.appendRequest(
                documentID: "document-materialize",
                update: Data([43]),
                updateID: "external-conflict-update"
            )
        ]
    )
    #expect(
        try await service.invoke(
            service: "artifactDocuments",
            method: "materialize",
            arguments: [
                fixture.materializeRequest(
                    documentID: "document-materialize",
                    expectedStateVersion: 2,
                    materializationID: "materialization-2",
                    bytes: Data("second materialization".utf8)
                )
            ]
        ) == .object([
            "actualPublicFileHash": .string(sha256(externalBytes)),
            "expectedPublicFileHash": .string(materializedHash),
            "status": .string("conflict"),
        ])
    )
}

@Test
func desktopArtifactDocumentsExactBindingRejectsPathChanges()
    async throws
{
    let fixture = try ArtifactDocumentsFixture()
    defer { fixture.remove() }
    let other = fixture.workspace.appendingPathComponent("other.bin")
    try Data("other".utf8).write(to: other)
    let service = ArtifactService(
        allowedWorkspaceRoots: [],
        storeDirectory: fixture.store
    )

    #expect(
        try await service.invoke(
            service: "artifactDocuments",
            method: "bindToExactFile",
            arguments: [
                .object([
                    "publicFilePath": .string(fixture.artifact.path)
                ])
            ]
        ) == .rpcObject([:])
    )
    let bound = try await service.bindToExactFile(
        publicFilePath: fixture.artifact.path
    )
    #expect(
        try await bound.invoke(
            service: "artifactDocuments",
            method: "find",
            arguments: [fixture.baseRequest]
        ) == .object([
            "status": .string("ok"),
            "value": .null,
        ])
    )

    let changedRequest: ArtifactValue = .object([
        "publicFilePath": .string(other.path),
        "workspaceRoot": .string(fixture.workspace.path),
    ])
    await #expect(
        throws: ArtifactService.Error.exactFileMismatch
    ) {
        try await bound.invoke(
            service: "artifactDocuments",
            method: "find",
            arguments: [changedRequest]
        )
    }
}

@Test
func desktopArtifactDocumentsRejectsNonReleasedArgumentShapes()
    async throws
{
    let fixture = try ArtifactDocumentsFixture()
    defer { fixture.remove() }
    let service = ArtifactService(
        allowedWorkspaceRoots: [fixture.workspace],
        storeDirectory: fixture.store
    )

    let invalidCalls: [(String, [ArtifactValue]?)] = [
        ("find", nil),
        (
            "find",
            [
                .object([
                    "publicFilePath": .string(fixture.artifact.path),
                    "workspaceRoot": .string(fixture.workspace.path),
                    "extra": .bool(true),
                ])
            ]
        ),
        (
            "adopt",
            [
                fixture.adoptRequest(
                    checkpoint: Data([1]),
                    documentID: "document-invalid",
                    kind: "document"
                )
            ]
        ),
        (
            "append",
            [
                fixture.appendRequest(
                    documentID: "document-invalid",
                    update: Data([1]),
                    updateID: "update-invalid",
                    source: "system"
                )
            ]
        ),
        (
            "subscribe",
            [
                fixture.documentRequest(
                    documentID: "document-invalid"
                ),
                .integer(99),
            ]
        ),
    ]

    for (method, arguments) in invalidCalls {
        await #expect(throws: ArtifactService.Error.invalidArguments) {
            try await service.invoke(
                service: "artifactDocuments",
                method: method,
                arguments: arguments
            )
        }
    }
}

private actor ArtifactEventRecorder {
    struct Event: Equatable, Sendable {
        let callbackID: Int
        let event: ArtifactValue
    }

    private(set) var events: [Event] = []

    func record(callbackID: Int, event: ArtifactValue) {
        events.append(.init(callbackID: callbackID, event: event))
    }
}

private final class ArtifactDocumentsFixture {
    let root: URL
    let workspace: URL
    let store: URL
    let artifact: URL
    let initialHash: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexDesktopArtifactDocuments-\(UUID().uuidString)",
            isDirectory: true
        )
        workspace = root.appendingPathComponent(
            "workspace",
            isDirectory: true
        )
        store = root.appendingPathComponent(
            "store",
            isDirectory: true
        )
        artifact = workspace.appendingPathComponent("artifact.bin")
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        let initial = Data("original artifact".utf8)
        try initial.write(to: artifact)
        initialHash = sha256(initial)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    var baseRequest: ArtifactValue {
        .object([
            "publicFilePath": .string(artifact.path),
            "workspaceRoot": .string(workspace.path),
        ])
    }

    func documentRequest(documentID: String) -> ArtifactValue {
        .object([
            "documentId": .string(documentID),
            "publicFilePath": .string(artifact.path),
            "workspaceRoot": .string(workspace.path),
        ])
    }

    func adoptRequest(
        checkpoint: Data,
        documentID: String,
        kind: String
    ) -> ArtifactValue {
        .object([
            "checkpoint": bytesValue(checkpoint),
            "documentId": .string(documentID),
            "kind": .string(kind),
            "publicFileHash": .string(initialHash),
            "publicFilePath": .string(artifact.path),
            "workspaceRoot": .string(workspace.path),
        ])
    }

    func appendRequest(
        documentID: String,
        update: Data,
        updateID: String,
        source: String = "model"
    ) -> ArtifactValue {
        .object([
            "baseStateVersion": .integer(0),
            "bytes": bytesValue(update),
            "documentId": .string(documentID),
            "originId": .string("origin-1"),
            "publicFilePath": .string(artifact.path),
            "source": .string(source),
            "updateId": .string(updateID),
            "workspaceRoot": .string(workspace.path),
        ])
    }

    func refreshRequest(
        checkpoint: Data,
        documentID: String,
        replacementDocumentID: String
    ) -> ArtifactValue {
        .object([
            "checkpoint": bytesValue(checkpoint),
            "documentId": .string(documentID),
            "expectedPublicFileHash": .string(initialHash),
            "expectedStateVersion": .integer(0),
            "observedPublicFileHash": .string(initialHash),
            "publicFilePath": .string(artifact.path),
            "replacementDocumentId": .string(replacementDocumentID),
            "workspaceRoot": .string(workspace.path),
        ])
    }

    func materializeRequest(
        documentID: String,
        expectedStateVersion: Int64,
        materializationID: String,
        bytes: Data
    ) -> ArtifactValue {
        .object([
            "documentId": .string(documentID),
            "expectedStateVersion": .integer(expectedStateVersion),
            "materializationId": .string(materializationID),
            "publicFileBytes": bytesValue(bytes),
            "publicFilePath": .string(artifact.path),
            "workspaceRoot": .string(workspace.path),
        ])
    }

    func adopt(
        using service: ArtifactService,
        checkpoint: Data,
        documentID: String,
        kind: String
    ) async throws {
        _ = try await service.invoke(
            service: "artifactDocuments",
            method: "adopt",
            arguments: [
                adoptRequest(
                    checkpoint: checkpoint,
                    documentID: documentID,
                    kind: kind
                )
            ]
        )
    }
}

private func artifactRecord(
    checkpoint: Data,
    documentID: String,
    kind: String,
    publicFileHash: String,
    publicFilePath: String
) -> ArtifactValue {
    .object([
        "checkpoint": bytesValue(checkpoint),
        "checkpointStateVersion": .integer(0),
        "documentId": .string(documentID),
        "kind": .string(kind),
        "materializedStateVersion": .integer(0),
        "publicFileHash": .string(publicFileHash),
        "publicFilePath": .string(publicFilePath),
        "stateVersion": .integer(0),
        "updates": .array([]),
    ])
}

private func bytesValue(_ data: Data) -> ArtifactValue {
    .array(data.map { .integer(Int64($0)) })
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
}
