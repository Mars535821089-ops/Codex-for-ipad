from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path
import unittest


ROOT = Path(__file__).parents[1]


class AuditIPadAppHostSemanticsTests(unittest.TestCase):
    def test_classifies_methods_exposed_only_by_registered_services(
        self,
    ) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (
                source_root / "CodexDesktopPeripheralAppHostService.swift"
            ).write_text(
                '''
                public func invokeRemoteControlEnvironments(
                    method: String,
                    arguments: [Value]?
                ) async throws -> Value {
                    switch method {
                    case "renameIfDefault":
                        return try await remoteControlEnvironmentOperation(
                            method,
                            arguments
                        )
                    default:
                        throw Error.unsupportedMethod(
                            service: "remoteControlEnvironments",
                            method: method
                        )
                    }
                }
                ''',
                encoding="utf-8",
            )
            report = audit_apphost_semantics(
                {
                    "resolvedOfficialServiceMethods": [
                        {
                            "service": "remoteControlEnvironments",
                            "method": "renameIfDefault",
                            "className": "RemoteControlEnvironments",
                        }
                    ]
                },
                source_root,
            )

        self.assertEqual(report["directRendererCallCount"], 0)
        self.assertEqual(report["resolvedOfficialServiceMethodCount"], 1)
        self.assertEqual(report["officialMethodSurfaceCount"], 1)
        self.assertEqual(report["classifiedCallCount"], 1)
        self.assertEqual(report["nativeStaticEvidenceCount"], 1)
        self.assertEqual(report["unlocatedCount"], 0)
        self.assertEqual(report["status"], "complete")
        self.assertEqual(
            report["calls"][0]["exposureSources"],
            ["registeredService"],
        )

    def test_peripheral_hotkey_and_remote_environment_handlers_are_wired(self) -> None:
        from scripts.audit_ipad_apphost_semantics import audit_apphost_semantics

        direct_calls = {
            "directRendererCalls": [
                {"service": "hotkeyWindowCommands", "method": "open"},
                {
                    "service": "remoteControlEnvironments",
                    "method": "renameIfDefault",
                },
            ]
        }
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (source_root / "CodexDesktopPeripheralAppHostService.swift").write_text(
                '''
                private func invokeHotkeyWindow(
                    service: String,
                    method: String,
                    arguments: [Value]?
                ) async throws -> Value {
                    guard Self.hotkeyWindowMethods.contains(method) else {
                        throw Error.unsupportedMethod(
                            service: service,
                            method: method
                        )
                    }
                    guard let hotkeyWindowOperation else {
                        throw Error.unavailable(service: service, method: method)
                    }
                    return try await hotkeyWindowOperation(method, arguments)
                }

                private func invokeRemoteControlEnvironments(
                    method: String,
                    arguments: [Value]?
                ) async throws -> Value {
                    guard method == "renameIfDefault" else {
                        throw Error.unsupportedMethod(
                            service: "remoteControlEnvironments",
                            method: method
                        )
                    }
                    guard let remoteControlEnvironmentOperation else {
                        throw Error.unavailable(
                            service: "remoteControlEnvironments",
                            method: method
                        )
                    }
                    return try await remoteControlEnvironmentOperation(method, arguments)
                }
                ''',
                encoding="utf-8",
            )
            (source_root / "CodexDesktopSurfaceController.swift").write_text(
                '''
                let peripheralService = CodexDesktopPeripheralAppHostService(
                    hotkeyWindowOperation: { method, arguments in
                        try await interactionService.invoke(
                            service: "hotkeyWindowHotkeys",
                            method: method,
                            arguments: arguments
                        )
                    },
                    remoteControlEnvironmentOperation: { method, arguments in
                        try await remoteEnvironmentStore.renameIfDefault(
                            method: method,
                            arguments: arguments
                        )
                    }
                )
                ''',
                encoding="utf-8",
            )
            report = audit_apphost_semantics(direct_calls, source_root)

        self.assertEqual(report["placeholderCount"], 0)
        self.assertEqual(report["unlocatedCount"], 0)
        self.assertEqual(report["status"], "complete")

    def test_locates_library_and_remote_project_backend_methods(self) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (source_root / "CodexDesktopLibraryAppHostService.swift").write_text(
                '''
                public func invoke(method: String, arguments: [Value]?) async throws -> Value {
                    switch method {
                    case "releaseFilePreview":
                        releaseFilePreview(previewPath: "preview")
                        return .undefined
                    default:
                        throw Error.unsupportedMethod(method)
                    }
                }
                ''',
                encoding="utf-8",
            )
            (source_root / "CodexDesktopRemoteProjectMutationBackend.swift").write_text(
                '''
                public func handle(method: String, request: Value) async throws -> Value {
                    switch method {
                    case "createRemote":
                        return try await createRemote(request)
                    case "setAppearance":
                        try await setAppearance(request)
                        return .undefined
                    default:
                        throw Error.unsupportedMethod(method)
                    }
                }
                ''',
                encoding="utf-8",
            )
            report = audit_apphost_semantics(
                {
                    "directRendererCalls": [
                        {"service": "libraryFiles", "method": "releaseFilePreview"},
                        {"service": "projects", "method": "createRemote"},
                        {"service": "projects", "method": "setAppearance"},
                    ]
                },
                source_root,
            )

        self.assertEqual(report["unlocatedCount"], 0)
        self.assertEqual(report["placeholderCount"], 0)
        self.assertEqual(report["nativeStaticEvidenceCount"], 3)
        self.assertEqual(report["status"], "complete")

    def test_project_methods_fall_back_to_service_dispatcher(self) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (source_root / "CodexDesktopRemoteProjectMutationBackend.swift").write_text(
                '''
                public func handle(method: String, request: Value) async throws -> Value {
                    switch method {
                    case "createRemote": return .undefined
                    default: throw Error.unsupportedMethod(method)
                    }
                }
                ''',
                encoding="utf-8",
            )
            (source_root / "CodexDesktopProjectAppHostService.swift").write_text(
                '''
                private static let projectQueryMethods: Set<String> = [
                    "getLocalProjects", "getWorkspaceRootOptions"
                ]

                public func invoke(
                    service: String, method: String, arguments: [Value]?
                ) async throws -> Value {
                    switch (service, method) {
                    case ("projects", let projectMethod)
                        where Self.projectQueryMethods.contains(projectMethod):
                        return try await projectQueryHandler(projectMethod, nil)
                    default:
                        throw Error.unsupportedMethod(service: service, method: method)
                    }
                }
                ''',
                encoding="utf-8",
            )
            report = audit_apphost_semantics(
                {
                    "resolvedOfficialServiceMethods": [
                        {"service": "projects", "method": "getLocalProjects"},
                        {"service": "projects", "method": "getWorkspaceRootOptions"},
                    ]
                },
                source_root,
            )

        self.assertEqual(report["unlocatedCount"], 0)
        self.assertEqual(report["placeholderCount"], 0)
        self.assertEqual(report["nativeStaticEvidenceCount"], 2)

    def test_locates_dedicated_method_only_service_dispatchers(self) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        fixtures = {
            "CodexDesktopArtifactDocumentsAppHostService.swift": '''
                public func invoke(service: String, method: String) async throws -> Value {
                    guard service == "artifactDocuments" else { throw Error.unsupported }
                    switch method {
                    case "adopt":
                        return try await runtime.adopt()
                    default:
                        throw Error.unsupported
                    }
                }
            ''',
            "CodexDesktopLocalEnvironmentsAppHostService.swift": '''
                public func invoke(service: String, method: String) async throws -> Value {
                    guard service == "localEnvironments" else { throw Error.unsupported }
                    switch method {
                    case "list":
                        return try await fileSystemHandler()
                    default:
                        throw Error.unsupported
                    }
                }
            ''',
            "CodexDesktopLocalThreadCatalogAppHostService.swift": '''
                public func invoke(service: String, method: String) async throws -> Value {
                    guard service == "localThreadCatalog" else { throw Error.unsupported }
                    switch method {
                    case "readEntries":
                        return try await backend.readEntries()
                    default:
                        throw Error.unsupported
                    }
                }
            ''',
            "CodexDesktopTerminalAppHostService.swift": '''
                public func invoke(service: String, method: String) async throws -> Value {
                    guard service == "terminal" else { throw Error.unsupported }
                    switch method {
                    case "create":
                        try await manager.createOrAttach()
                        return .undefined
                    default:
                        throw Error.unsupported
                    }
                }
            ''',
        }
        calls = [
            ("artifactDocuments", "adopt"),
            ("localEnvironments", "list"),
            ("localThreadCatalog", "readEntries"),
            ("terminal", "create"),
        ]
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            for filename, source in fixtures.items():
                (source_root / filename).write_text(
                    source,
                    encoding="utf-8",
                )
            report = audit_apphost_semantics(
                {
                    "resolvedOfficialServiceMethods": [
                        {"service": service, "method": method}
                        for service, method in calls
                    ]
                },
                source_root,
            )

        self.assertEqual(report["unlocatedCount"], 0)
        self.assertEqual(report["placeholderCount"], 0)
        self.assertEqual(report["nativeStaticEvidenceCount"], 4)
        self.assertEqual(report["status"], "complete")

    def test_optional_platform_method_evidence_is_isolated_per_method(
        self,
    ) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (
                source_root
                / "CodexDesktopOptionalPlatformAppHostService.swift"
            ).write_text(
                '''
                public func invoke(service: String, method: String) async throws -> Value {
                    switch service {
                    case "avatarOverlay":
                        guard method == "setInputShape" else { throw Error.unsupported }
                        avatarInputShape = arguments?.first
                        return .undefined
                    case "chronicle":
                        return try await invokeChronicle(method: method)
                    case "debug":
                        return try await invokeDebug(method: method)
                    default:
                        throw Error.unsupported
                    }
                }

                private func invokeChronicle(method: String) async throws -> Value {
                    let methods: Set<String> = ["getState"]
                    guard methods.contains(method) else { throw Error.unsupported }
                    switch method {
                    case "getState":
                        return disabledChronicleState
                    default:
                        fatalError()
                    }
                }

                private func invokeDebug(method: String) async throws -> Value {
                    let unavailableMethods: Set<String> = [
                        "captureMemoryHeapSnapshots"
                    ]
                    if unavailableMethods.contains(method) {
                        throw Error.unavailable(service: "debug", method: method)
                    }
                    let methods: Set<String> = ["exportLogs"]
                    guard methods.contains(method) else { throw Error.unsupported }
                    return try await debugOperation(method)
                }
                ''',
                encoding="utf-8",
            )
            report = audit_apphost_semantics(
                {
                    "resolvedOfficialServiceMethods": [
                        {"service": "avatarOverlay", "method": "setInputShape"},
                        {"service": "chronicle", "method": "getState"},
                        {
                            "service": "chronicle",
                            "method": "listHistorySuggestions",
                        },
                        {"service": "debug", "method": "exportLogs"},
                        {
                            "service": "debug",
                            "method": "captureMemoryHeapSnapshots",
                        },
                    ]
                },
                source_root,
            )

        by_call = {row["call"]: row for row in report["calls"]}
        self.assertEqual(
            by_call["avatarOverlay.setInputShape"]["classification"],
            "nativeStaticEvidence",
        )
        self.assertEqual(
            by_call["chronicle.getState"]["classification"],
            "nativeStaticEvidence",
        )
        self.assertEqual(
            by_call["debug.exportLogs"]["classification"],
            "nativeStaticEvidence",
        )
        self.assertEqual(
            by_call["debug.captureMemoryHeapSnapshots"]["classification"],
            "placeholder",
        )
        self.assertEqual(
            by_call["chronicle.listHistorySuggestions"]["classification"],
            "unlocated",
        )

    def test_locates_only_the_implemented_dynamic_startup_method(self) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (
                source_root / "CodexDesktopInitialAppHostRouter.swift"
            ).write_text(
                '''
                public func responseAsync(service: String, method: String) async -> Value {
                    switch service {
                    case "startup" where method == "whenReady":
                        await startupReadyHandler()
                        return .undefined
                    default:
                        return .undefined
                    }
                }
                ''',
                encoding="utf-8",
            )
            report = audit_apphost_semantics(
                {
                    "resolvedOfficialServiceMethods": [
                        {"service": "startup", "method": "whenReady"},
                        {"service": "startup", "method": "bufferPhase"},
                    ]
                },
                source_root,
            )

        by_call = {row["call"]: row for row in report["calls"]}
        self.assertEqual(
            by_call["startup.whenReady"]["classification"],
            "nativeStaticEvidence",
        )
        self.assertEqual(
            by_call["startup.bufferPhase"]["classification"],
            "unlocated",
        )

    def test_locates_split_app_updates_service_methods(self) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (
                source_root
                / "CodexDesktopAppUpdatesAppHostService.swift"
            ).write_text(
                '''
                public func invoke(method: String, arguments: [Value]?) async throws -> Value {
                    switch method {
                    case "setSparkleQueryParams":
                        try await manager.setSparkleQueryParameters(parameters)
                        return .undefined
                    case "checkForUpdates":
                        try await manager.checkForUpdates()
                        return .undefined
                    case "installUpdate":
                        try await manager.installUpdate()
                        return .undefined
                    default:
                        throw Error.unsupportedMethod(method)
                    }
                }
                ''',
                encoding="utf-8",
            )
            report = audit_apphost_semantics(
                {
                    "directRendererCalls": [
                        {
                            "service": "appUpdates",
                            "method": "setSparkleQueryParams",
                        },
                        {
                            "service": "appUpdates",
                            "method": "checkForUpdates",
                        },
                        {
                            "service": "appUpdates",
                            "method": "installUpdate",
                        },
                    ]
                },
                source_root,
            )

        self.assertEqual(report["nativeStaticEvidenceCount"], 3)
        self.assertEqual(report["placeholderCount"], 0)
        self.assertEqual(report["unlocatedCount"], 0)
        self.assertEqual(report["status"], "complete")

    def test_app_updates_unavailable_fallback_is_valid_when_updates_are_removed(
        self,
    ) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        service_source = '''
        /// Product-side automatic updates are intentionally
        /// removed: iPadOS
        /// never downloads, stages, installs, or persists an update request.
        public func invoke(method: String, arguments: [Value]?) async throws -> Value {
            switch method {
            case "checkForUpdates":
                guard let manager else {
                    throw Error.unavailable(method: method)
                }
                try await manager.checkForUpdates()
                return .undefined
            default:
                throw Error.unsupportedMethod(method)
            }
        }
        '''
        direct_calls = {
            "directRendererCalls": [
                {
                    "service": "appUpdates",
                    "method": "checkForUpdates",
                }
            ]
        }

        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (
                source_root
                / "CodexDesktopAppUpdatesAppHostService.swift"
            ).write_text(service_source, encoding="utf-8")

            disabled = audit_apphost_semantics(
                direct_calls,
                source_root,
            )
        self.assertEqual(disabled["placeholderCount"], 0)
        self.assertEqual(disabled["nativeStaticEvidenceCount"], 1)
        self.assertEqual(disabled["status"], "complete")
        row = disabled["calls"][0]
        self.assertIn("automatic-updates-disabled", row["signals"])

    def test_accepts_matching_official_unavailable_method(self) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (
                source_root
                / "CodexDesktopOptionalPlatformAppHostService.swift"
            ).write_text(
                '''
                private func invokeDebug(method: String) throws -> Value {
                    let unavailableMethods: Set<String> = [
                        "getMemoryDiagnosticsStatus",
                    ]
                    if unavailableMethods.contains(method) {
                        throw Error.unavailable(
                            service: "debug",
                            method: method
                        )
                    }
                    return .undefined
                }
                ''',
                encoding="utf-8",
            )
            report = audit_apphost_semantics(
                {
                    "resolvedOfficialServiceMethods": [
                        {
                            "service": "debug",
                            "method": "getMemoryDiagnosticsStatus",
                        }
                    ],
                    "officialExplicitlyUnavailableMethods": [
                        "debug.getMemoryDiagnosticsStatus"
                    ],
                },
                source_root,
            )

        self.assertEqual(report["placeholderCount"], 0)
        self.assertEqual(report["status"], "complete")
        self.assertIn(
            "matches-official-unavailable",
            report["calls"][0]["signals"],
        )

    def test_classifies_documented_ipad_platform_divergences(self) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (source_root / "CodexDesktopPeripheralAppHostService.swift").write_text(
                '''
                private func invokeAppshot(method: String) throws -> Value {
                    switch method {
                    case "getState": return Self.unsupportedAppshotState
                    case "setHotkey": throw Error.unavailable(
                        service: "appshot", method: method
                    )
                    default: return .undefined
                    }
                }
                ''',
                encoding="utf-8",
            )
            (source_root / "CodexDesktopSurfaceController.swift").write_text(
                '''
                let appshotHotkeyOperation = { method, arguments in
                    switch method {
                    case "getState":
                        guard let coordinator = self?.appshotCaptureCoordinator else {
                            return .undefined
                        }
                        return await coordinator.appHostState()
                    case "setHotkey":
                        throw Error.unavailable(service: "appshot", method: method)
                    default: return .undefined
                    }
                }
                ''',
                encoding="utf-8",
            )
            (source_root / "CodexDesktopAsyncFetchRouter.swift").write_text(
                '''
                /// iPad capture is driven by the web view snapshot coordinator itself.
                public func appHostState() -> Value {
                    .object(["supported": .bool(true)])
                }
                ''',
                encoding="utf-8",
            )
            (source_root / "CodexDesktopOptionalPlatformAppHostService.swift").write_text(
                '''
                private func invokeCodexMicro(method: String) -> Value {
                    let methods: Set<String> = [
                        "getInputMonitoringPermissionStatus",
                    ]
                    guard methods.contains(method) else { return .undefined }
                    // iPadOS has no process-wide input-monitoring permission gate.
                    return .string("unavailable")
                }
                ''',
                encoding="utf-8",
            )
            report = audit_apphost_semantics(
                {
                    "resolvedOfficialServiceMethods": [
                        {"service": "appshot", "method": "getState"},
                        {"service": "appshot", "method": "setHotkey"},
                        {
                            "service": "codexMicro",
                            "method": "getInputMonitoringPermissionStatus",
                        },
                    ]
                },
                source_root,
            )

        by_call = {row["call"]: row for row in report["calls"]}
        self.assertEqual(
            by_call["appshot.getState"]["classification"],
            "nativeStaticEvidence",
        )
        self.assertEqual(
            by_call["appshot.setHotkey"]["classification"],
            "platformDivergence",
        )
        self.assertEqual(
            by_call["codexMicro.getInputMonitoringPermissionStatus"][
                "classification"
            ],
            "platformDivergence",
        )
        self.assertEqual(report["platformDivergenceCount"], 2)
        self.assertEqual(report["placeholderCount"], 0)
        self.assertEqual(report["status"], "complete")

    def test_distinguishes_renderer_event_delivery_from_log_only_forwarding(
        self,
    ) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        direct_calls = {
            "directRendererCalls": [
                {
                    "service": "clientCoordination",
                    "method": "invalidateQueryCache",
                }
            ]
        }
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (
                source_root
                / "CodexDesktopCoordinationAppHostService.swift"
            ).write_text(
                '''
                public func invoke(service: String, method: String, arguments: [Value]?) async throws -> Value {
                    switch (service, method) {
                    case ("clientCoordination", "invalidateQueryCache"):
                        _ = try Self.rendererEvent(method: method, arguments: arguments)
                        await eventHandler(service, method, arguments)
                        return .undefined
                    default:
                        throw Error.unsupportedMethod(service: service, method: method)
                    }
                }
                ''',
                encoding="utf-8",
            )
            (
                source_root / "CodexDesktopSurfaceController.swift"
            ).write_text(
                '''
                let coordinationService = CodexDesktopCoordinationAppHostService(
                    eventHandler: { service, method, arguments in
                        if let message = try? CodexDesktopCoordinationAppHostService.rendererEvent(
                            method: method,
                            arguments: arguments
                        ) {
                            await send(message)
                        }
                        record("app-host coordination \(service).\(method)")
                    }
                )
                ''',
                encoding="utf-8",
            )
            report = audit_apphost_semantics(
                direct_calls,
                source_root,
            )

        self.assertEqual(report["rendererEventForwardedCount"], 1)
        self.assertEqual(report["eventForwardedCount"], 0)
        row = report["calls"][0]
        self.assertEqual(
            row["classification"],
            "rendererEventForwarded",
        )
        self.assertIn("renderer-event-send-wired", row["signals"])

    def test_distinguishes_realtime_renderer_callbacks_from_event_logging(
        self,
    ) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (
                source_root / "CodexDesktopRealtimeAppHostService.swift"
            ).write_text(
                '''
                private var realtimeStarter: (request: Int, cancel: Int)?
                private let callbackInvoker: CallbackInvoker?
                case ("realtimeVoiceRuntime", "registerRealtimeStarter"):
                    realtimeStarter = (request: 1, cancel: 2)
                case ("realtimeVoiceRuntime", "requestRealtimeStart"):
                    try await callbackInvoker?(starter.request, [request])
                case ("realtimeVoiceRuntime", "cancelRealtimeSessionStart"):
                    try await callbackInvoker?(starter.cancel, [])
                case ("realtimeVoiceRuntime", "unregisterRealtimeStarter"):
                    realtimeStarter = nil
                default:
                    throw Error.unsupportedMethod
                ''',
                encoding="utf-8",
            )
            (
                source_root / "CodexDesktopSurfaceController.swift"
            ).write_text(
                '''
                let realtime = CodexDesktopRealtimeAppHostService(
                    callbackInvoker: { callbackID, arguments in
                        try await callbackDispatcher.send(
                            portID: portID,
                            callbackID: callbackID,
                            arguments: arguments
                        )
                    }
                )
                ''',
                encoding="utf-8",
            )
            report = audit_apphost_semantics(
                {
                    "directRendererCalls": [
                        {
                            "service": "realtimeVoiceRuntime",
                            "method": method,
                        }
                        for method in (
                            "registerRealtimeStarter",
                            "requestRealtimeStart",
                            "cancelRealtimeSessionStart",
                            "unregisterRealtimeStarter",
                        )
                    ]
                },
                source_root,
            )

        self.assertEqual(report["rendererCallbackForwardedCount"], 4)
        self.assertEqual(report["eventForwardedCount"], 0)
        self.assertTrue(
            all(
                row["classification"] == "rendererCallbackForwarded"
                for row in report["calls"]
            )
        )

    def test_classifies_every_official_direct_call_conservatively(self) -> None:
        from scripts.audit_ipad_apphost_semantics import (
            audit_apphost_semantics,
        )

        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (source_root / "CodexDesktopBrowserAppHostService.swift").write_text(
                '''
                switch (service, method) {
                case ("browserTabs", "search"):
                    return .object(["candidates": .array([])])
                case ("browserTabs", "focusChromeTab"):
                    await eventHandler(service, method, arguments)
                    return .undefined
                default:
                    throw Error.unsupportedMethod(service: service, method: method)
                }
                ''',
                encoding="utf-8",
            )
            (
                source_root
                / "CodexDesktopVisualizationsAppHostService.swift"
            ).write_text(
                '''
                public func invoke(method: String, arguments: [Value]?) async throws -> Value {
                    switch method {
                    case "getTemporaryRoots":
                        return .array(temporaryRoots.map(Value.string))
                    default:
                        throw Error.unsupportedMethod(method)
                    }
                }
                ''',
                encoding="utf-8",
            )
            report = audit_apphost_semantics(
                {
                    "directRendererCalls": [
                        {"service": "browserTabs", "method": "search"},
                        {
                            "service": "browserTabs",
                            "method": "focusChromeTab",
                        },
                        {
                            "service": "visualizations",
                            "method": "getTemporaryRoots",
                        },
                        {"service": "appInfo", "method": "get"},
                    ]
                },
                source_root,
            )

        self.assertTrue(report["staticEvidenceOnly"])
        self.assertEqual(report["directRendererCallCount"], 4)
        self.assertEqual(report["classifiedCallCount"], 4)
        self.assertEqual(report["placeholderCount"], 1)
        self.assertEqual(report["eventForwardedCount"], 1)
        self.assertEqual(report["nativeStaticEvidenceCount"], 1)
        self.assertEqual(report["unlocatedCount"], 1)
        self.assertEqual(report["status"], "incomplete")
        by_call = {
            row["call"]: row for row in report["calls"]
        }
        self.assertEqual(
            by_call["browserTabs.search"]["classification"],
            "placeholder",
        )
        self.assertEqual(
            by_call["browserTabs.focusChromeTab"]["classification"],
            "eventForwarded",
        )
        self.assertEqual(
            by_call["visualizations.getTemporaryRoots"]["classification"],
            "nativeStaticEvidence",
        )
        self.assertEqual(
            by_call["appInfo.get"]["classification"],
            "unlocated",
        )
        self.assertGreater(
            by_call["browserTabs.search"]["sourceLine"],
            0,
        )

    def test_locates_existing_service_local_dispatchers(self) -> None:
        from scripts.audit_ipad_apphost_semantics import audit_apphost_semantics

        fixtures = {
            "CodexDesktopHistorySnapshotsAppHostService.swift": '''
                public func invoke(method: String, arguments: [Value]?) async throws -> Value {
                    switch method {
                    case "read", "write", "delete", "runAuthorized":
                        return .undefined
                    default: throw Error.unsupportedMethod(method)
                    }
                }
            ''',
            "CodexDesktopConversationalOnboardingAppHostService.swift": '''
                public func invoke(method: String, arguments: [Value]?) async throws -> Value {
                    switch method {
                    case "createDesktopNote", "createSampleChart":
                        return .undefined
                    default: throw Error.unsupportedMethod(method)
                    }
                }
            ''',
            "CodexDesktopProjectAppHostService.swift": '''
                public func invoke(method: String, arguments: [Value]?) async throws -> Value {
                    switch method {
                    case "create", "edit", "remove", "rename", "upsert":
                        return .undefined
                    default: throw Error.unsupportedMethod(method)
                    }
                }
            ''',
            "CodexDesktopThreadStateAppHostService.swift": '''
                public func invoke(service: String, method: String, arguments: [Value]?) async throws -> Value {
                    switch (service, method) {
                    case ("threadTurnSummaries", "publish"), ("threadTurnSummaries", "runAuthorized"):
                        return .undefined
                    default: throw Error.unsupportedMethod(service: service, method: method)
                    }
                }
            ''',
            "CodexDesktopTracingAppHostService.swift": '''
                public func invoke(method: String, arguments: [Value]?) async throws -> Value {
                    switch method {
                    case "exportTraceBatch": return .undefined
                    default: throw Error.invalidArguments
                    }
                }
            ''',
        }
        calls = {
            "resolvedOfficialServiceMethods": [
                {"service": service, "method": method}
                for service, methods in {
                    "appServerHistorySnapshots": ["read", "write", "delete", "runAuthorized"],
                    "conversationalOnboarding": ["createDesktopNote", "createSampleChart"],
                    "localProjects": ["create", "edit", "remove", "rename", "upsert"],
                    "threadTurnSummaries": ["publish", "runAuthorized"],
                    "tracing": ["exportTraceBatch"],
                }.items()
                for method in methods
            ]
        }
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            for name, content in fixtures.items():
                (source_root / name).write_text(content, encoding="utf-8")
            report = audit_apphost_semantics(calls, source_root)

        self.assertEqual(report["unlocatedCount"], 0)
        self.assertEqual(report["placeholderCount"], 0)
        self.assertEqual(report["nativeStaticEvidenceCount"], len(calls["resolvedOfficialServiceMethods"]))

    def test_locates_dynamic_service_method_set_dispatchers(self) -> None:
        from scripts.audit_ipad_apphost_semantics import audit_apphost_semantics

        source = """
            private static let localProjectMethods: Set<String> = [
                "create", "edit", "remove", "rename", "upsert"
            ]

            public func invoke(
                service: String, method: String, arguments: [Value]?
            ) async throws -> Value {
                switch (service, method) {
                case ("localProjects", let projectMethod)
                    where Self.localProjectMethods.contains(projectMethod):
                    let request = try localProjectRequest(
                        method: projectMethod, arguments: arguments
                    )
                    return try await localProjectHandler(projectMethod, request)
                default:
                    throw Error.unsupportedMethod(
                        service: service, method: method
                    )
                }
            }
        """
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary)
            (source_root / "CodexDesktopProjectAppHostService.swift").write_text(
                source, encoding="utf-8"
            )
            report = audit_apphost_semantics(
                {
                    "resolvedOfficialServiceMethods": [
                        {"service": "localProjects", "method": method}
                        for method in (
                            "create", "edit", "remove", "rename", "upsert"
                        )
                    ]
                },
                source_root,
            )

        self.assertEqual(report["unlocatedCount"], 0)
        self.assertEqual(report["placeholderCount"], 0)
        self.assertEqual(
            report["nativeStaticEvidenceCount"],
            5,
        )

    def test_cli_writes_report_before_rejecting_placeholders(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_root = root / "Application"
            source_root.mkdir()
            (source_root / "CodexDesktopBrowserAppHostService.swift").write_text(
                '''
                case ("browserTabs", "getChromeTabLiveness"):
                    return .object(["status": .string("unavailable")])
                default:
                    return .undefined
                ''',
                encoding="utf-8",
            )
            apphost_report = root / "apphost.json"
            apphost_report.write_text(
                json.dumps(
                    {
                        "directRendererCalls": [
                            {
                                "service": "browserTabs",
                                "method": "getChromeTabLiveness",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            output = root / "semantics.json"
            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "scripts/audit_ipad_apphost_semantics.py"),
                    "--apphost-report",
                    str(apphost_report),
                    "--source-root",
                    str(source_root),
                    "--output",
                    str(output),
                    "--require-no-placeholders",
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("AppHost semantic placeholders remain", result.stderr)
            written = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(written["placeholderCount"], 1)


if __name__ == "__main__":
    unittest.main()
