import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopIntelligenceAppHostReportsAccessibleEnabledApps()
    async throws
{
    let service = CodexDesktopIntelligenceAppHostService(
        hasAccessibleAndEnabledApp: { true }
    )

    #expect(
        try await service.invoke(
            service: "ambientSuggestions",
            method: "hasAccessibleAndEnabledApp",
            arguments: [
                .object(["hostId": .string("local")])
            ]
        ) == .bool(true)
    )
}

@Test
func desktopIntelligenceAppHostGeneratesAndNormalizesThreadMetadata()
    async throws
{
    let recorder = AppHostMetadataRequestRecorder()
    let service = CodexDesktopIntelligenceAppHostService(
        generateTitle: { request in
            await recorder.recordTitle(request)
            return .init(
                title: #"Title: "A deliberately overlong generated title that must be shortened.""#,
                description: "  keyword   index  "
            )
        },
        generateDescription: { request in
            await recorder.recordDescription(request)
            return String(repeating: "x", count: 110) + "   "
        }
    )

    #expect(
        try await service.invoke(
            service: "threadMetadataGeneration",
            method: "generateTitle",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "prompt": .string(" Build a release "),
                    "cwd": .string("/workspace"),
                    "readOnlyAppToolAllowlist": .array([
                        .string("calendar")
                    ]),
                    "threadStartKind": .string("new"),
                    "serviceName": .string("desktop"),
                ])
            ]
        ) == .object([
            "title": .string(
                "A deliberately overlong generated t…"
            ),
            "description": .string("keyword index"),
        ])
    )
    #expect(
        try await service.invoke(
            service: "threadMetadataGeneration",
            method: "generateDescription",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "threadId": .string("thread-1"),
                    "title": .string("Release"),
                    "cwd": .string("/workspace"),
                    "serviceName": .string("desktop"),
                ])
            ]
        ) == .string(String(repeating: "x", count: 100))
    )

    #expect(
        await recorder.titleRequests == [
            .init(
                hostID: "local",
                prompt: "Build a release",
                cwd: "/workspace",
                readOnlyAppToolAllowlist: ["calendar"],
                threadStartKind: "new",
                serviceName: "desktop"
            )
        ]
    )
    #expect(
        await recorder.descriptionRequests == [
            .init(
                hostID: "local",
                threadID: "thread-1",
                title: "Release",
                cwd: "/workspace",
                serviceName: "desktop"
            )
        ]
    )
}

@Test
func desktopIntelligenceAppHostGeneratesLatestThreadActivitySummary()
    async throws
{
    let recorder = AppHostMetadataRequestRecorder()
    let service = CodexDesktopIntelligenceAppHostService(
        generateSummary: { request in
            await recorder.recordSummary(request)
            return .init(
                summary: String(repeating: "s", count: 285) + "   ",
                compactSummary: String(repeating: "c", count: 65)
            )
        }
    )

    #expect(
        try await service.invoke(
            service: "threadMetadataGeneration",
            method: "generateSummary",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "threadId": .string("thread-1"),
                    "title": .string("Repair provider"),
                    "previousUserMessage": .string("Fix chat"),
                    "previousAssistantMessage": .string("Chat fixed"),
                    "latestMessage": .string("  Provider works now  "),
                    "phase": .string("assistant"),
                    "cwd": .string("/workspace"),
                    "includeCompactSummary": .bool(true),
                    "serviceName": .string("desktop"),
                ])
            ]
        ) == .object([
            "summary": .string(String(repeating: "s", count: 280)),
            "compactSummary": .string(String(repeating: "c", count: 60)),
        ])
    )

    #expect(
        await recorder.summaryRequests == [
            .init(
                hostID: "local",
                threadID: "thread-1",
                title: "Repair provider",
                previousUserMessage: "Fix chat",
                previousAssistantMessage: "Chat fixed",
                latestMessage: "Provider works now",
                phase: "assistant",
                cwd: "/workspace",
                includeCompactSummary: true,
                serviceName: "desktop"
            )
        ]
    )
}

@Test
func desktopIntelligenceAppHostPersistsRedactedSummaryDiagnostics()
    async throws
{
    let diagnostics = AppHostSummaryDiagnosticRecorder()
    let service = CodexDesktopIntelligenceAppHostService(
        generateSummary: { _ in
            .init(summary: "Generated summary", compactSummary: "Compact")
        },
        summaryDiagnostic: { key, value in
            await diagnostics.record(key: key, value: value)
        }
    )

    _ = try await service.invoke(
        service: "threadMetadataGeneration",
        method: "generateSummary",
        arguments: [.object([
            "hostId": .string("private-host"),
            "threadId": .string("private-thread"),
            "latestMessage": .string("private conversation text"),
            "phase": .string("assistant"),
            "cwd": .string("/private/workspace"),
            "includeCompactSummary": .bool(true),
        ])]
    )

    let values = await diagnostics.values
    #expect(
        values["codex.desktop.last-summary-generation-diagnostic"]
            == "called=true phase=assistant latestBytes=25 "
                + "result=present summaryLength=17 compactLength=7"
    )
    #expect(!String(describing: values).contains("private"))
}

@Test
func desktopIntelligenceAppHostClassifiesSummaryGeneratorFailures()
    async throws
{
    let diagnostics = AppHostSummaryDiagnosticRecorder()
    let service = CodexDesktopIntelligenceAppHostService(
        generateSummary: { _ in
            throw CodexDesktopThreadMetadataGenerator.Error
                .invalidJSONResponse
        },
        summaryDiagnostic: { key, value in
            await diagnostics.record(key: key, value: value)
        }
    )

    await #expect(throws: CodexDesktopThreadMetadataGenerator.Error.self) {
        _ = try await service.invoke(
            service: "threadMetadataGeneration",
            method: "generateSummary",
            arguments: [.object([
                "hostId": .string("private-host"),
                "threadId": .string("private-thread"),
                "latestMessage": .string("private conversation text"),
                "phase": .string("assistant"),
                "cwd": .string("/private/workspace"),
            ])]
        )
    }

    let values = await diagnostics.values
    #expect(
        values["codex.desktop.last-summary-generation-diagnostic"]
            == "called=true phase=assistant latestBytes=25 "
                + "result=failed error=invalidJSONResponse"
    )
    #expect(!String(describing: values).contains("private"))
}

@Test
func desktopIntelligenceAppHostClassifiesUnknownSummaryFailureByType()
    async throws
{
    let diagnostics = AppHostSummaryDiagnosticRecorder()
    let service = CodexDesktopIntelligenceAppHostService(
        generateSummary: { _ in
            throw MetadataDiagnosticProbeError.probe
        },
        summaryDiagnostic: { key, value in
            await diagnostics.record(key: key, value: value)
        }
    )

    await #expect(throws: MetadataDiagnosticProbeError.self) {
        _ = try await service.invoke(
            service: "threadMetadataGeneration",
            method: "generateSummary",
            arguments: [.object([
                "hostId": .string("private-host"),
                "threadId": .string("private-thread"),
                "latestMessage": .string("private conversation text"),
                "phase": .string("assistant"),
                "cwd": .string("/private/workspace"),
            ])]
        )
    }

    let values = await diagnostics.values
    #expect(
        values["codex.desktop.last-summary-generation-diagnostic"]
            == "called=true phase=assistant latestBytes=25 "
                + "result=failed error=other.MetadataDiagnosticProbeError"
    )
    #expect(!String(describing: values).contains("private"))
}


@Test
func desktopIntelligenceAppHostInvokesReconsiderTitleWithOfficialShape()
    async throws
{
    let recorder = AppHostMetadataRequestRecorder()
    let service = CodexDesktopIntelligenceAppHostService(
        reconsiderTitle: { request in
            await recorder.recordReconsiderTitle(request)
            return .init(
                title: "Updated title",
                description: "updated description"
            )
        }
    )

    let result = try await service.invoke(
        service: "threadMetadataGeneration",
        method: "reconsiderTitle",
        arguments: [.object([
            "hostId": .string("local"),
            "threadId": .string("thread-1"),
            "currentTitle": .string("Old title"),
            "cwd": .string("/workspace"),
            "serviceName": .string("desktop"),
        ])]
    )

    #expect(
        result == .object([
            "title": .string("Updated title"),
            "description": .string("updated description"),
        ])
    )
    #expect(
        await recorder.reconsiderTitleRequests == [
            .init(
                hostID: "local",
                threadID: "thread-1",
                currentTitle: "Old title",
                cwd: "/workspace",
                serviceName: "desktop"
            )
        ]
    )
}

@Test
func desktopIntelligenceAppHostRejectsMalformedReconsiderTitleArguments()
    async throws
{
    let service = CodexDesktopIntelligenceAppHostService(
        reconsiderTitle: { _ in
            Issue.record("invalid arguments must not call generator")
            return nil
        }
    )

    await #expect(throws: CodexDesktopIntelligenceAppHostService.Error.self) {
        _ = try await service.invoke(
            service: "threadMetadataGeneration",
            method: "reconsiderTitle",
            arguments: [.object([
                "hostId": .string("local"),
                "threadId": .string("thread-1"),
                "currentTitle": .string("Old title"),
            ])]
        )
    }
}

@Test
func desktopIntelligenceAppHostSkipsBlankPromptsAndEmptyResults()
    async throws
{
    let service = CodexDesktopIntelligenceAppHostService(
        generateTitle: { _ in
            Issue.record("blank prompts must not start a model request")
            return nil
        },
        generateDescription: { _ in "   " }
    )

    #expect(
        try await service.invoke(
            service: "threadMetadataGeneration",
            method: "generateTitle",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "prompt": .string("  \n "),
                    "cwd": .string("/workspace"),
                ])
            ]
        ) == .null
    )
    #expect(
        try await service.invoke(
            service: "threadMetadataGeneration",
            method: "generateDescription",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "threadId": .string("thread-1"),
                    "cwd": .string("/workspace"),
                ])
            ]
        ) == .null
    )
}

private enum MetadataDiagnosticProbeError: Swift.Error {
    case probe
}

private actor AppHostMetadataRequestRecorder {
    private(set) var titleRequests:
        [CodexDesktopIntelligenceAppHostService.TitleRequest] = []
    private(set) var descriptionRequests:
        [CodexDesktopIntelligenceAppHostService.DescriptionRequest] = []
    private(set) var summaryRequests:
        [CodexDesktopIntelligenceAppHostService.SummaryRequest] = []
    private(set) var reconsiderTitleRequests:
        [CodexDesktopIntelligenceAppHostService.ReconsiderTitleRequest] = []

    func recordTitle(
        _ request: CodexDesktopIntelligenceAppHostService.TitleRequest
    ) {
        titleRequests.append(request)
    }

    func recordDescription(
        _ request:
            CodexDesktopIntelligenceAppHostService.DescriptionRequest
    ) {
        descriptionRequests.append(request)
    }

    func recordSummary(
        _ request: CodexDesktopIntelligenceAppHostService.SummaryRequest
    ) {
        summaryRequests.append(request)
    }

    func recordReconsiderTitle(
        _ request: CodexDesktopIntelligenceAppHostService.ReconsiderTitleRequest
    ) {
        reconsiderTitleRequests.append(request)
    }
}

private actor AppHostSummaryDiagnosticRecorder {
    private(set) var values: [String: String] = [:]

    func record(key: String, value: String) {
        values[key] = value
    }
}

@Test
func desktopIntelligenceAppHostForwardsAmbientSuggestionQueriesAndSelection()
    async throws
{
    actor Recorder {
        var hosts: [String] = []
        var selections: [(String, String)] = []
        func recordHost(_ host: String) { hosts.append(host) }
        func recordSelection(_ host: String, _ suggestion: String) {
            selections.append((host, suggestion))
        }
    }

    let recorder = Recorder()
    let service = CodexDesktopIntelligenceAppHostService(
        getGenerationStatuses: {
            .object(["pending": .integer(2)])
        },
        getWorkTaskSuggestions: { host in
            await recorder.recordHost(host)
            return .array([.object(["id": .string("suggestion-1")])])
        },
        markWorkTaskSuggestionSelected: { host, suggestion in
            await recorder.recordSelection(host, suggestion)
            return .object(["recorded": .bool(true)])
        }
    )

    #expect(
        try await service.invoke(
            service: "ambientSuggestions",
            method: "getGenerationStatuses",
            arguments: nil
        ) == .object(["pending": .integer(2)])
    )
    #expect(
        try await service.invoke(
            service: "ambientSuggestions",
            method: "getChatGptWorkTaskSuggestions",
            arguments: [.object(["hostId": .string("local")])]
        ) == .array([.object(["id": .string("suggestion-1")])])
    )
    #expect(
        try await service.invoke(
            service: "ambientSuggestions",
            method: "markChatGptWorkTaskSuggestionSelected",
            arguments: [.object([
                "hostId": .string("local"),
                "suggestionId": .string("suggestion-1"),
            ])]
        ) == .object(["recorded": .bool(true)])
    )
    #expect(await recorder.hosts == ["local"])
    #expect(await recorder.selections.map { [$0.0, $0.1] } == [["local", "suggestion-1"]])
}

@Test
func desktopIntelligenceAppHostRejectsMalformedAmbientSuggestionArguments()
    async throws
{
    let service = CodexDesktopIntelligenceAppHostService()
    await #expect(throws: CodexDesktopIntelligenceAppHostService.Error.invalidArguments) {
        try await service.invoke(
            service: "ambientSuggestions",
            method: "getGenerationStatuses",
            arguments: [.object([:])]
        )
    }
    await #expect(throws: CodexDesktopIntelligenceAppHostService.Error.invalidArguments) {
        try await service.invoke(
            service: "ambientSuggestions",
            method: "getChatGptWorkTaskSuggestions",
            arguments: [.object(["hostId": .string("")])]
        )
    }
    await #expect(throws: CodexDesktopIntelligenceAppHostService.Error.invalidArguments) {
        try await service.invoke(
            service: "ambientSuggestions",
            method: "markChatGptWorkTaskSuggestionSelected",
            arguments: [.object([
                "hostId": .string("local"),
                "suggestionId": .string(""),
            ])]
        )
    }
}
