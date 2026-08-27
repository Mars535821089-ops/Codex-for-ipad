import Testing

@testable import CodexPadApplication

private typealias ProjectValue = CodexDesktopAppHostRPC.Value

@Test
func desktopProjectAppHostRoutesEveryLocalProjectMutation() async throws {
    let recorder = ProjectAppHostRecorder()
    let service = CodexDesktopProjectAppHostService(
        localProjectHandler: { method, request in
            await recorder.recordProject(method: method, request: request)
            if method == "create" {
                return .object([
                    "projectId": .string("project-1"),
                    "rootPaths": .array([.string("/workspace")]),
                ])
            }
            return .undefined
        }
    )

    let createRequest = ProjectValue.object([
        "appearance": .null,
        "initializeDefaultWorkspaceGitRepository": .bool(true),
        "name": .string("Workspace"),
        "sources": .array([.string("/workspace")]),
    ])
    #expect(
        try await service.invoke(
            service: "localProjects",
            method: "create",
            arguments: [createRequest]
        ) == .object([
            "projectId": .string("project-1"),
            "rootPaths": .array([.string("/workspace")]),
        ])
    )

    let editRequest = ProjectValue.object([
        "name": .string("Edited"),
        "projectId": .string("project-1"),
        "sources": .array([.string("/workspace"), .string("/other")]),
    ])
    let renameRequest = ProjectValue.object([
        "name": .string("Renamed"),
        "projectId": .string("project-1"),
    ])
    for (method, request) in [
        ("edit", editRequest),
        ("rename", renameRequest),
        ("upsert", editRequest),
    ] {
        #expect(
            try await service.invoke(
                service: "localProjects",
                method: method,
                arguments: [request]
            ) == .undefined
        )
    }
    #expect(
        try await service.invoke(
            service: "localProjects",
            method: "remove",
            arguments: [.string("project-1")]
        ) == .undefined
    )

    #expect(
        await recorder.projectMethods
            == ["create", "edit", "rename", "upsert", "remove"]
    )
    #expect(
        await recorder.projectRequests.last == .string("project-1")
    )
}

@Test
func desktopProjectAppHostPersistsThreadAssignmentThroughHandler()
    async throws
{
    let recorder = ProjectAppHostRecorder()
    let service = CodexDesktopProjectAppHostService(
        threadProjectAssignmentHandler: { request in
            await recorder.recordAssignment(request)
        }
    )
    let assignment = ProjectValue.object([
        "cwd": .string("/workspace"),
        "pendingCoreUpdate": .bool(false),
        "projectId": .string("project-1"),
        "projectKind": .string("local"),
        "projectOrigin": .string("chatgpt"),
    ])
    let request = ProjectValue.object([
        "assignment": assignment,
        "threadId": .string("thread-1"),
    ])

    #expect(
        try await service.invoke(
            service: "threadProjectAssignments",
            method: "setAssignment",
            arguments: [request]
        ) == .undefined
    )
    #expect(await recorder.assignments == [request])

    let clearRequest = ProjectValue.object([
        "assignment": .null,
        "threadId": .string("thread-1"),
    ])
    _ = try await service.invoke(
        service: "threadProjectAssignments",
        method: "setAssignment",
        arguments: [clearRequest]
    )
    #expect(await recorder.assignments == [request, clearRequest])
}

@Test
func desktopProjectAppHostDefaultsMissingPendingCoreUpdateToFalse()
    async throws
{
    let recorder = ProjectAppHostRecorder()
    let service = CodexDesktopProjectAppHostService(
        threadProjectAssignmentHandler: { request in
            await recorder.recordAssignment(request)
        }
    )
    let releasedRendererRequest = ProjectValue.object([
        "assignment": .object([
            "projectId": .string("project-1"),
            "projectKind": .string("local"),
        ]),
        "threadId": .string("thread-1"),
    ])

    #expect(
        try await service.invoke(
            service: "threadProjectAssignments",
            method: "setAssignment",
            arguments: [releasedRendererRequest]
        ) == .undefined
    )
    #expect(
        await recorder.assignments == [
            .object([
                "assignment": .object([
                    "pendingCoreUpdate": .bool(false),
                    "projectId": .string("project-1"),
                    "projectKind": .string("local"),
                ]),
                "threadId": .string("thread-1"),
            ]),
        ]
    )
}

@Test
func desktopProjectAppHostArchivesInactiveThreadWithReleasedResult()
    async throws
{
    let recorder = ProjectAppHostRecorder()
    let service = CodexDesktopProjectAppHostService(
        threadArchiveHandler: { request in
            await recorder.recordArchive(request)
            return true
        }
    )
    let request = ProjectValue.object([
        "hostId": .string("local"),
        "removeCatalogEntryIfMissing": .bool(true),
        "threadId": .string("thread-archive"),
    ])

    #expect(
        try await service.invoke(
            service: "threadArchive",
            method: "archiveInactiveThread",
            arguments: [request]
        ) == .object(["success": .bool(true)])
    )
    #expect(await recorder.archives == [request])
}

@Test
func desktopProjectAppHostSynchronizesChatGPTProjectFiles()
    async throws
{
    let recorder = ProjectAppHostRecorder()
    let service = CodexDesktopProjectAppHostService(
        chatGptProjectFileSyncHandler: { request in
            await recorder.recordSync(request)
            return .object([
                "failedFiles": .array([
                    .object([
                        "fileOrdinal": .integer(2),
                        "stage": .string("download"),
                        "status": .integer(503),
                    ]),
                ]),
                "rootPath": .string(
                    "/codex-home/.chatgpt-projects/project-1"
                ),
            ])
        }
    )
    let request = ProjectValue.object([
        "files": .array([
            .object([
                "fileId": .string("file-1"),
                "name": .string("brief.md"),
            ]),
        ]),
        "getFileDownloadRequest": .import(7),
        "instructions": .string("Use the project context."),
        "projectId": .string("project-1"),
        "projectName": .string("Project One"),
    ])

    let result = try await service.invoke(
        service: "chatGptProjectFiles",
        method: "sync",
        arguments: [request]
    )
    #expect(
        result == .object([
            "failedFiles": .array([
                .object([
                    "fileOrdinal": .integer(2),
                    "stage": .string("download"),
                    "status": .integer(503),
                ]),
            ]),
            "rootPath": .string(
                "/codex-home/.chatgpt-projects/project-1"
            ),
        ])
    )
    #expect(await recorder.syncRequests == [request])
}

@Test
func desktopProjectAppHostRoutesReleasedRemoteProjectOperations()
    async throws
{
    let recorder = ProjectAppHostRecorder()
    let service = CodexDesktopProjectAppHostService(
        remoteProjectHandler: { method, request in
            await recorder.recordRemoteProject(
                method: method,
                request: request
            )
            if method == "createRemote" {
                return .object([
                    "hostId": .string("ssh-host-1"),
                    "id": .string("remote-project-1"),
                    "label": .string("Remote repo"),
                    "remotePath": .string("/srv/repo"),
                ])
            }
            return .undefined
        }
    )
    let appearance = ProjectValue.object([
        "color": .string("purple"),
        "marker": .object([
            "icon": .string("code"),
            "kind": .string("icon"),
        ]),
    ])

    let created = try await service.invoke(
        service: "projects",
        method: "createRemote",
        arguments: [
            .object([
                "appearance": appearance,
                "hostId": .string("ssh-host-1"),
                "label": .string("Remote repo"),
                "remotePath": .string("/srv/repo"),
                "unreleased": .bool(true),
            ]),
        ]
    )
    #expect(
        created == .object([
            "hostId": .string("ssh-host-1"),
            "id": .string("remote-project-1"),
            "label": .string("Remote repo"),
            "remotePath": .string("/srv/repo"),
        ])
    )

    #expect(
        try await service.invoke(
            service: "projects",
            method: "setAppearance",
            arguments: [
                .object([
                    "appearance": appearance,
                    "projectId": .string("remote-project-1"),
                ]),
            ]
        ) == .undefined
    )
    #expect(
        await recorder.remoteProjectRequests == [
            .object([
                "appearance": .object([
                    "color": .string("purple"),
                    "marker": .object([
                        "icon": .string("function"),
                        "kind": .string("icon"),
                    ]),
                ]),
                "hostId": .string("ssh-host-1"),
                "label": .string("Remote repo"),
                "remotePath": .string("/srv/repo"),
            ]),
            .object([
                "appearance": .object([
                    "color": .string("purple"),
                    "marker": .object([
                        "icon": .string("function"),
                        "kind": .string("icon"),
                    ]),
                ]),
                "projectId": .string("remote-project-1"),
            ]),
        ]
    )
    #expect(
        await recorder.remoteProjectMethods
            == ["createRemote", "setAppearance"]
    )
}

@Test
func desktopProjectAppHostRoutesReleasedProjectRootQueries()
    async throws
{
    let recorder = ProjectAppHostRecorder()
    let service = CodexDesktopProjectAppHostService(
        projectQueryHandler: { method, request in
            await recorder.recordQuery(method: method, request: request)
            switch method {
            case "getRemoteProjects":
                return .array([])
            case "getProjectAppearances":
                return .object([:])
            case "getProjectRootPathsForHost":
                return .array([.string("/remote/root")])
            case "createOrSelectLocalProjects":
                return .array([.object([
                    "id": .string("project-1"),
                    "rootPaths": .array([.string("/workspace")]),
                ])])
            case "createProjectForRoot":
                return .object([
                    "id": .string("project-1"),
                    "rootPaths": .array([.string("/workspace")]),
                ])
            case "assignUnassignedThreadsBeforeProjectRootsChange":
                return .undefined
            default:
                Issue.record("unexpected query \(method)")
                return .undefined
            }
        }
    )

    #expect(
        try await service.invoke(
            service: "projects",
            method: "getRemoteProjects",
            arguments: nil
        ) == .array([])
    )
    #expect(
        try await service.invoke(
            service: "projects",
            method: "getProjectAppearances",
            arguments: []
        ) == .object([:])
    )
    #expect(
        try await service.invoke(
            service: "projects",
            method: "getProjectRootPathsForHost",
            arguments: [.string("ssh-host-1")]
        ) == .array([.string("/remote/root")])
    )
    #expect(
        try await service.invoke(
            service: "projects",
            method: "createOrSelectLocalProjects",
            arguments: [.array([.string("/workspace")])]
        ) == .array([.object([
            "id": .string("project-1"),
            "rootPaths": .array([.string("/workspace")]),
        ])])
    )
    #expect(
        try await service.invoke(
            service: "projects",
            method: "createProjectForRoot",
            arguments: [.string("/workspace"), .string("Workspace")]
        ) == .object([
            "id": .string("project-1"),
            "rootPaths": .array([.string("/workspace")]),
        ])
    )
    #expect(
        try await service.invoke(
            service: "projects",
            method: "assignUnassignedThreadsBeforeProjectRootsChange",
            arguments: [.array([.string("/workspace")])]
        ) == .undefined
    )

    #expect(
        await recorder.queryMethods == [
            "getRemoteProjects",
            "getProjectAppearances",
            "getProjectRootPathsForHost",
            "createOrSelectLocalProjects",
            "createProjectForRoot",
            "assignUnassignedThreadsBeforeProjectRootsChange",
        ]
    )
    #expect(
        await recorder.queryRequests == [
            nil,
            nil,
            .string("ssh-host-1"),
            .array([.string("/workspace")]),
            .object([
                "name": .string("Workspace"),
                "root": .string("/workspace"),
            ]),
            .array([.string("/workspace")]),
        ]
    )
}

@Test
func desktopProjectAppHostRejectsMalformedReleasedRequests() async {
    let service = CodexDesktopProjectAppHostService(
        localProjectHandler: { _, _ in .undefined },
        threadProjectAssignmentHandler: { _ in },
        threadArchiveHandler: { _ in false },
        chatGptProjectFileSyncHandler: { _ in
            .object([
                "failedFiles": .array([]),
                "rootPath": .string("/valid"),
            ])
        }
    )

    await #expect(
        throws: CodexDesktopProjectAppHostService.Error.invalidArguments
    ) {
        _ = try await service.invoke(
            service: "localProjects",
            method: "create",
            arguments: [
                .object([
                    "appearance": .null,
                    "initializeDefaultWorkspaceGitRepository":
                        .string("yes"),
                    "name": .string("Project"),
                    "sources": .array([]),
                ]),
            ]
        )
    }
    await #expect(
        throws: CodexDesktopProjectAppHostService.Error.invalidArguments
    ) {
        _ = try await service.invoke(
            service: "threadProjectAssignments",
            method: "setAssignment",
            arguments: [
                .object([
                    "assignment": .object([
                        "pendingCoreUpdate": .string("false"),
                        "projectId": .string("local-1"),
                        "projectKind": .string("local"),
                    ]),
                    "threadId": .string("thread-1"),
                ]),
            ]
        )
    }
    await #expect(
        throws: CodexDesktopProjectAppHostService.Error.invalidArguments
    ) {
        _ = try await service.invoke(
            service: "threadProjectAssignments",
            method: "setAssignment",
            arguments: [
                .object([
                    "assignment": .object([
                        "pendingCoreUpdate": .bool(false),
                        "projectId": .string("local-1"),
                        "projectKind": .string("local"),
                        "projectOrigin": .string("unsupported"),
                    ]),
                    "threadId": .string("thread-1"),
                ]),
            ]
        )
    }
    await #expect(
        throws: CodexDesktopProjectAppHostService.Error.invalidArguments
    ) {
        _ = try await service.invoke(
            service: "threadProjectAssignments",
            method: "setAssignment",
            arguments: [
                .object([
                    "assignment": .object([
                        "pendingCoreUpdate": .bool(false),
                        "projectId": .string("remote-1"),
                        "projectKind": .string("remote"),
                    ]),
                    "threadId": .string("thread-1"),
                ]),
            ]
        )
    }
    await #expect(
        throws: CodexDesktopProjectAppHostService.Error.invalidArguments
    ) {
        _ = try await service.invoke(
            service: "chatGptProjectFiles",
            method: "sync",
            arguments: [
                .object([
                    "files": .array([]),
                    "getFileDownloadRequest": .string("not-callable"),
                    "instructions": .string(""),
                    "projectId": .string("../project"),
                    "projectName": .string("Project"),
                ]),
            ]
        )
    }
}

@Test
func desktopProjectAppHostNormalizesReleasedProjectAppearance() async throws {
    let recorder = ProjectAppHostRecorder()
    let service = CodexDesktopProjectAppHostService(
        localProjectHandler: { method, request in
            await recorder.recordProject(method: method, request: request)
            return .object([
                "projectId": .string("project-appearance"),
                "rootPaths": .array([.string("/workspace")]),
            ])
        }
    )

    let request = ProjectValue.object([
        "appearance": .object([
            "color": .string("blue"),
            "marker": .object([
                "kind": .string("icon"),
                "icon": .string("code"),
                "unknownMarkerField": .string("drop"),
            ]),
            "unknownAppearanceField": .string("drop"),
        ]),
        "initializeDefaultWorkspaceGitRepository": .bool(false),
        "name": .string("Project"),
        "sources": .array([]),
        "unknownRequestField": .string("drop"),
    ])

    _ = try await service.invoke(
        service: "localProjects",
        method: "create",
        arguments: [request]
    )

    #expect(
        await recorder.projectRequests.first
            == .object([
                "appearance": .object([
                    "color": .string("blue"),
                    "marker": .object([
                        "kind": .string("icon"),
                        "icon": .string("function"),
                    ]),
                ]),
                "initializeDefaultWorkspaceGitRepository": .bool(false),
                "name": .string("Project"),
                "sources": .array([]),
            ])
    )
}

@Test
func desktopProjectAppHostAcceptsEmojiProjectAppearanceAndNull()
    async throws
{
    let recorder = ProjectAppHostRecorder()
    let service = CodexDesktopProjectAppHostService(
        localProjectHandler: { method, request in
            await recorder.recordProject(method: method, request: request)
            return .object([
                "projectId": .string("project-appearance"),
                "rootPaths": .array([.string("/workspace")]),
            ])
        }
    )

    for appearance in [
        ProjectValue.object([
            "color": .string("pink"),
            "marker": .object([
                "kind": .string("emoji"),
                "emoji": .string("🚀"),
            ]),
        ]),
        .null,
    ] {
        _ = try await service.invoke(
            service: "localProjects",
            method: "create",
            arguments: [
                .object([
                    "appearance": appearance,
                    "initializeDefaultWorkspaceGitRepository":
                        .bool(false),
                    "name": .string("Project"),
                    "sources": .array([]),
                ]),
            ]
        )
    }

    #expect(await recorder.projectRequests.count == 2)
    #expect(
        await recorder.projectRequests.first
            == .object([
                "appearance": .object([
                    "color": .string("pink"),
                    "marker": .object([
                        "kind": .string("emoji"),
                        "emoji": .string("🚀"),
                    ]),
                ]),
                "initializeDefaultWorkspaceGitRepository": .bool(false),
                "name": .string("Project"),
                "sources": .array([]),
            ])
    )
    #expect(
        await recorder.projectRequests.last
            == .object([
                "appearance": .null,
                "initializeDefaultWorkspaceGitRepository": .bool(false),
                "name": .string("Project"),
                "sources": .array([]),
            ])
    )
}

@Test
func desktopProjectAppHostRejectsMalformedProjectAppearances() async {
    let service = CodexDesktopProjectAppHostService(
        localProjectHandler: { _, _ in .undefined }
    )
    let appearances: [ProjectValue] = [
        .object([:]),
        .object([
            "color": .string("teal"),
            "marker": .object([
                "kind": .string("emoji"),
                "emoji": .string("🚀"),
            ]),
        ]),
        .object([
            "color": .string("blue"),
            "marker": .object([
                "type": .string("emoji"),
                "value": .string("🚀"),
            ]),
        ]),
        .object([
            "color": .string("blue"),
            "marker": .object([
                "kind": .string("emoji"),
                "emoji": .string(""),
            ]),
        ]),
        .object([
            "color": .string("blue"),
            "marker": .object([
                "kind": .string("icon"),
                "icon": .string("not-an-icon"),
            ]),
        ]),
    ]

    for appearance in appearances {
        await #expect(
            throws: CodexDesktopProjectAppHostService.Error.invalidArguments
        ) {
            _ = try await service.invoke(
                service: "localProjects",
                method: "create",
                arguments: [
                    .object([
                        "appearance": appearance,
                        "initializeDefaultWorkspaceGitRepository":
                            .bool(false),
                        "name": .string("Project"),
                        "sources": .array([]),
                    ]),
                ]
            )
        }
    }
}

private actor ProjectAppHostRecorder {
    private(set) var projectMethods: [String] = []
    private(set) var projectRequests: [ProjectValue] = []
    private(set) var assignments: [ProjectValue] = []
    private(set) var archives: [ProjectValue] = []
    private(set) var syncRequests: [ProjectValue] = []
    private(set) var remoteProjectMethods: [String] = []
    private(set) var remoteProjectRequests: [ProjectValue] = []
    private(set) var queryMethods: [String] = []
    private(set) var queryRequests: [ProjectValue?] = []

    func recordProject(method: String, request: ProjectValue) {
        projectMethods.append(method)
        projectRequests.append(request)
    }

    func recordAssignment(_ request: ProjectValue) {
        assignments.append(request)
    }

    func recordArchive(_ request: ProjectValue) {
        archives.append(request)
    }

    func recordSync(_ request: ProjectValue) {
        syncRequests.append(request)
    }

    func recordRemoteProject(method: String, request: ProjectValue) {
        remoteProjectMethods.append(method)
        remoteProjectRequests.append(request)
    }

    func recordQuery(method: String, request: ProjectValue?) {
        queryMethods.append(method)
        queryRequests.append(request)
    }
}

@Test
func desktopProjectAppHostRoutesReleasedProjectQueriesWithoutManufacturingState()
    async throws
{
    let service = CodexDesktopProjectAppHostService(
        localProjectHandler: { method, request in
            #expect(method == "edit")
            #expect(request == .object([
                "name": .string("Renamed"),
                "projectId": .string("project-1"),
                "sources": .array([.string("/workspace")]),
            ]))
            return .undefined
        },
        projectQueryHandler: { method, request in
            switch method {
            case "getLocalProjects":
                #expect(request == nil)
                return .object([:])
            case "getActiveWorkspaceRoots":
                #expect(request == nil)
                return .object([
                    "roots": .array([.string("/workspace")]),
                ])
            case "hasProjectNamed":
                #expect(request == .string("Workspace"))
                return .bool(true)
            default:
                Issue.record("unexpected query: \(method)")
                return .undefined
            }
        }
    )

    #expect(
        try await service.invoke(
            service: "projects",
            method: "getActiveWorkspaceRoots",
            arguments: nil
        ) == .object([
            "roots": .array([.string("/workspace")]),
        ])
    )
    #expect(
        try await service.invoke(
            service: "projects",
            method: "getLocalProjects",
            arguments: nil
        ) == .object([:])
    )
    #expect(
        try await service.invoke(
            service: "projects",
            method: "editLocal",
            arguments: [.object([
                "name": .string("Renamed"),
                "projectId": .string("project-1"),
                "sources": .array([.string("/workspace")]),
            ])]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "projects",
            method: "hasProjectNamed",
            arguments: [.string("Workspace")]
        ) == .bool(true)
    )
}

@Test
func desktopProjectAppHostRejectsMalformedProjectQueryArguments()
    async throws
{
    let service = CodexDesktopProjectAppHostService(
        projectQueryHandler: { _, _ in .undefined }
    )

    await #expect(throws: CodexDesktopProjectAppHostService.Error
        .invalidArguments)
    {
        try await service.invoke(
            service: "projects",
            method: "hasProjectNamed",
            arguments: [.string(" ")]
        )
    }

    await #expect(throws: CodexDesktopProjectAppHostService.Error
        .invalidArguments)
    {
        try await service.invoke(
            service: "projects",
            method: "getActiveWorkspaceRoots",
            arguments: [.object([:])]
        )
    }
}
