#!/usr/bin/env python3
"""Conservatively classify iPad handlers for official AppHost calls.

This is static evidence only. It deliberately distinguishes a routed method
name from an implementation body and never treats either as physical-device
runtime proof.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import write_json_atomic


TUPLE_LITERAL = re.compile(
    r'\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)'
)
CASE_BLOCK = re.compile(
    r"^\s*case\s+(.*?):\s*(.*?)"
    r"(?=^\s*(?:case\s+|default:))",
    re.MULTILINE | re.DOTALL,
)
METHOD_LITERAL = re.compile(r'"([A-Za-z_$][A-Za-z0-9_$]*)"')

PLACEHOLDER_SIGNALS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "placeholder-status",
        re.compile(
            r'\.string\(\s*"(?:unsupported|unavailable|missing)"\s*\)'
        ),
    ),
    (
        "empty-browser-candidates",
        re.compile(r'"candidates"\s*:\s*\.array\(\s*\[\s*\]\s*\)'),
    ),
    ("unsupported-state", re.compile(r"unsupported[A-Za-z0-9_]*State")),
    ("explicit-unavailable", re.compile(r"throw\s+Error\.unavailable\b")),
)

# A few services intentionally delegate from the top-level tuple router into
# a service-local `switch method` or guard. These hints locate the semantic
# implementation body; absence remains an explicit unlocated result.
METHOD_ONLY_HANDLERS: dict[str, tuple[str, str]] = {
    "appUpdates": (
        "CodexDesktopAppUpdatesAppHostService.swift",
        "invoke",
    ),
    "appshot": (
        "CodexDesktopPeripheralAppHostService.swift",
        "invokeAppshot",
    ),
    "hotkeyWindowCommands": (
        "CodexDesktopPeripheralAppHostService.swift",
        "invokeHotkeyWindow",
    ),
    "remoteControlEnvironments": (
        "CodexDesktopPeripheralAppHostService.swift",
        "invokeRemoteControlEnvironments",
    ),
    "clientCoordination": (
        "CodexDesktopCoordinationAppHostService.swift",
        "updateThreadState",
    ),
    "downloads": (
        "CodexDesktopDownloadsAppHostService.swift",
        "invoke",
    ),
    "owlBrowserCrashCounter": (
        "CodexDesktopOptionalPlatformAppHostService.swift",
        "invokeOwlBrowserCrashCounter",
    ),
    "remoteHostedPIP": (
        "CodexDesktopOptionalPlatformAppHostService.swift",
        "invokeRemoteHostedPIP",
    ),
    "startup": (
        "CodexDesktopInitialAppHostRouter.swift",
        "responseAsync",
    ),
    "artifactDocuments": (
        "CodexDesktopArtifactDocumentsAppHostService.swift",
        "invoke",
    ),
    "avatarOverlay": (
        "CodexDesktopOptionalPlatformAppHostService.swift",
        "invoke",
    ),
    "chronicle": (
        "CodexDesktopOptionalPlatformAppHostService.swift",
        "invokeChronicle",
    ),
    "codexMicro": (
        "CodexDesktopOptionalPlatformAppHostService.swift",
        "invokeCodexMicro",
    ),
    "debug": (
        "CodexDesktopOptionalPlatformAppHostService.swift",
        "invokeDebug",
    ),
    "localEnvironments": (
        "CodexDesktopLocalEnvironmentsAppHostService.swift",
        "invoke",
    ),
    "localThreadCatalog": (
        "CodexDesktopLocalThreadCatalogAppHostService.swift",
        "invoke",
    ),
    "terminal": (
        "CodexDesktopTerminalAppHostService.swift",
        "invoke",
    ),
    "visualizations": (
        "CodexDesktopVisualizationsAppHostService.swift",
        "invoke",
    ),
    # These services are routed through a top-level adapter but their method
    # switch lives in a dedicated backend. Keep the semantic evidence tied to
    # the actual dispatch body instead of misclassifying the calls as
    # unlocated merely because the router uses a dynamic method variable.
    "libraryFiles": (
        "CodexDesktopLibraryAppHostService.swift",
        "invoke",
    ),
    "projects": (
        "CodexDesktopRemoteProjectMutationBackend.swift",
        "handle",
    ),
    "appServerHistorySnapshots": (
        "CodexDesktopHistorySnapshotsAppHostService.swift",
        "invoke",
    ),
    "conversationalOnboarding": (
        "CodexDesktopConversationalOnboardingAppHostService.swift",
        "invoke",
    ),
    "localProjects": (
        "CodexDesktopProjectAppHostService.swift",
        "invoke",
    ),
    "threadTurnSummaries": (
        "CodexDesktopThreadStateAppHostService.swift",
        "invoke",
    ),
    "tracing": (
        "CodexDesktopTracingAppHostService.swift",
        "invoke",
    ),
}

# A few services intentionally split their production dispatch across more
# than one adapter. Try the most specific backend first, then the owning
# service dispatcher for methods such as local/query project operations.
METHOD_ONLY_FALLBACK_HANDLERS: dict[
    str, tuple[tuple[str, str], ...]
] = {
    "projects": (
        ("CodexDesktopProjectAppHostService.swift", "invoke"),
    ),
}


def _line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def _function_body(source: str, function_name: str) -> tuple[str, int] | None:
    match = re.search(
        rf"\bfunc\s+{re.escape(function_name)}\s*\(",
        source,
    )
    if match is None:
        return None
    opening = source.find("{", match.end())
    if opening < 0:
        return None
    depth = 1
    index = opening + 1
    quote: str | None = None
    escaped = False
    line_comment = False
    block_comment = False
    while index < len(source) and depth:
        character = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if line_comment:
            if character == "\n":
                line_comment = False
            index += 1
            continue
        if block_comment:
            if character == "*" and following == "/":
                block_comment = False
                index += 2
            else:
                index += 1
            continue
        if quote is not None:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
            index += 1
            continue
        if character == "/" and following == "/":
            line_comment = True
            index += 2
            continue
        if character == "/" and following == "*":
            block_comment = True
            index += 2
            continue
        if character == '"':
            quote = character
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
        index += 1
    if depth:
        return None
    return source[opening + 1 : index - 1], opening + 1


def _tuple_evidence_index(
    sources: dict[str, tuple[Path, str]],
) -> dict[tuple[str, str], tuple[Path, str, int]]:
    evidence: dict[tuple[str, str], tuple[Path, str, int]] = {}
    for path, source in sources.values():
        for match in CASE_BLOCK.finditer(source):
            body = match.group(2)
            line = _line_number(source, match.start())
            for pair in TUPLE_LITERAL.findall(match.group(1)):
                evidence.setdefault(pair, (path, body, line))
    return evidence


def _method_only_evidence(
    source: str,
    *,
    function_name: str,
    service: str,
    method: str,
) -> tuple[str, int] | None:
    extracted = _function_body(source, function_name)
    if extracted is None:
        return None
    body, body_offset = extracted
    if (
        function_name == "invokeHotkeyWindow"
        and re.search(r"hotkeyWindowMethods\.contains\(method\)", body)
    ):
        return body, _line_number(source, body_offset)
    for match in CASE_BLOCK.finditer(body):
        if method in METHOD_LITERAL.findall(match.group(1)):
            return (
                match.group(2),
                _line_number(source, body_offset + match.start()),
            )

    # Dynamic tuple branches often validate the method through a static
    # `Set<String>` (for example,
    # `case ("localProjects", let projectMethod) where
    # Self.localProjectMethods.contains(projectMethod)`). The method literal
    # is therefore outside the case header and the ordinary tuple index
    # cannot locate it. Resolve the set declaration in the same source file
    # before accepting the branch as semantic evidence.
    for match in CASE_BLOCK.finditer(body):
        head = match.group(1)
        if service not in METHOD_LITERAL.findall(head):
            continue
        guard = re.search(
            r"where\s+Self\.(?P<set>[A-Za-z_][A-Za-z0-9_]*)\.contains\("
            r"(?P<variable>[A-Za-z_][A-Za-z0-9_]*)\)",
            head,
        )
        if guard is None:
            continue
        declaration = re.search(
            r"(?:public\s+|private\s+|internal\s+)?static\s+let\s+"
            rf"{re.escape(guard.group('set'))}\s*:\s*Set<String>\s*=\s*\[(?P<members>.*?)\]",
            source,
            re.DOTALL,
        )
        if declaration is not None and method in METHOD_LITERAL.findall(
            declaration.group("members")
        ):
            return (
                match.group(2),
                _line_number(source, body_offset + match.start()),
            )

    # A shared top-level service router can contain a method guard rather than
    # a nested `switch method`. Limit evidence to that service branch so an
    # unavailable branch for a neighboring service cannot taint the result.
    for match in CASE_BLOCK.finditer(body):
        if service not in METHOD_LITERAL.findall(match.group(1)):
            continue
        service_body = match.group(2)
        literal = re.search(rf'"{re.escape(method)}"', service_body)
        if literal is not None:
            return (
                service_body,
                _line_number(source, body_offset + match.start()),
            )

    # Some service functions validate dynamic methods through named Set
    # literals. When a method belongs to an explicitly unavailable set, use
    # only that conditional body. For the accepted-method set, start evidence
    # at the declaration so an earlier unavailable-method branch cannot make a
    # working method look like a placeholder.
    set_declaration = re.compile(
        r"let\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*"
        r":\s*Set<String>\s*=\s*\[(?P<members>.*?)\]",
        re.DOTALL,
    )
    for declaration in set_declaration.finditer(body):
        if method not in METHOD_LITERAL.findall(declaration.group("members")):
            continue
        set_name = declaration.group("name")
        conditional = re.search(
            rf"if\s+{re.escape(set_name)}\.contains\(method\)\s*\{{"
            r"(?P<body>.*?)\n\s*\}",
            body[declaration.end() :],
            re.DOTALL,
        )
        if conditional is not None:
            conditional_body = conditional.group("body")
            return (
                conditional_body,
                _line_number(
                    source,
                    body_offset + declaration.end() + conditional.start(),
                ),
            )
        return (
            body[declaration.start() :],
            _line_number(source, body_offset + declaration.start()),
        )

    literal = re.search(rf'"{re.escape(method)}"', body)
    if literal is None:
        # The official method manifest also contains service-owned helpers
        # such as `runAuthorized` and `publish`. They are not second public
        # routes, but the helper body is still useful static evidence. Locate
        # that real function rather than marking it missing or inventing a
        # switch case.
        helper = _function_body(source, method)
        if helper is not None:
            helper_body, helper_offset = helper
            return helper_body, _line_number(source, helper_offset)
        return None
    return body, _line_number(source, body_offset + literal.start())


def _classification(body: str) -> tuple[str, list[str]]:
    signals = [
        name for name, pattern in PLACEHOLDER_SIGNALS if pattern.search(body)
    ]
    if signals:
        return "placeholder", signals
    if re.search(r"\beventHandler\s*\(", body):
        return "eventForwarded", ["event-handler-forward"]
    return "nativeStaticEvidence", ["non-placeholder-handler-body"]


def _automatic_updates_intentionally_removed(source: str) -> bool:
    comment_text = re.sub(r"(?m)^\s*///?\s?", "", source)
    normalized = re.sub(r"\s+", " ", comment_text)
    return (
        "automatic updates are intentionally removed" in normalized
        and "never downloads" in normalized
    )


def _app_updates_production_manager_is_wired(
    sources: dict[str, tuple[Path, str]],
) -> bool:
    candidate = sources.get("CodexDesktopSurfaceController.swift")
    if candidate is None:
        return False
    source = candidate[1]
    construction = re.search(
        r"let\s+appUpdatesService\s*=\s*"
        r"CodexDesktopAppUpdatesAppHostService\s*\(\s*"
        r"manager\s*:\s*CodexIPadUpdateRequestManager\s*\(",
        source,
        re.DOTALL,
    )
    router_injection = re.search(
        r"appUpdatesService\s*:\s*appUpdatesService\b",
        source,
    )
    return construction is not None and router_injection is not None


def _peripheral_operation_is_wired(
    sources: dict[str, tuple[Path, str]],
    *,
    service: str,
) -> bool:
    candidate = sources.get("CodexDesktopSurfaceController.swift")
    if candidate is None:
        return False
    source = candidate[1]
    if service == "hotkeyWindowCommands":
        return (
            re.search(r"hotkeyWindowOperation\s*:", source) is not None
            and re.search(
                r"interactionService\s*\.\s*invoke\s*\(\s*"
                r"service\s*:\s*\"hotkeyWindowHotkeys\"",
                source,
                re.DOTALL,
            )
            is not None
        )
    if service == "remoteControlEnvironments":
        operation_injected = re.search(
            r"remoteControlEnvironmentOperation\s*:", source
        )
        backend_invoked = re.search(
            r"(?:remoteControlEnvironmentBackend\s*\.\s*invoke|"
            r"remoteEnvironmentStore\s*\.\s*renameIfDefault)\s*\(",
            source,
            re.DOTALL,
        )
        return operation_injected is not None and backend_invoked is not None
    return False


def _appshot_capture_is_wired(
    sources: dict[str, tuple[Path, str]],
) -> bool:
    controller = sources.get("CodexDesktopSurfaceController.swift")
    coordinator = sources.get("CodexDesktopAsyncFetchRouter.swift")
    if controller is None or coordinator is None:
        return False
    controller_source = controller[1]
    coordinator_source = coordinator[1]
    coordinator_comments = re.sub(
        r"\s+",
        " ",
        re.sub(r"(?m)^\s*///?\s?", "", coordinator_source),
    )
    return (
        "appshotHotkeyOperation" in controller_source
        and "self?.appshotCaptureCoordinator" in controller_source
        and re.search(
            r"return\s+await\s+coordinator\.appHostState\(\)",
            controller_source,
        ) is not None
        and "iPad capture is driven by the web view snapshot coordinator"
        in coordinator_comments
        and re.search(
            r'"supported"\s*:\s*\.bool\(true\)',
            coordinator_source,
        )
        is not None
    )


def _codex_micro_input_monitoring_is_platform_divergence(
    sources: dict[str, tuple[Path, str]],
) -> bool:
    candidate = sources.get(
        "CodexDesktopOptionalPlatformAppHostService.swift"
    )
    return (
        candidate is not None
        and "iPadOS has no process-wide input-monitoring permission gate"
        in candidate[1]
    )


def _coordination_renderer_event_is_wired(
    sources: dict[str, tuple[Path, str]],
) -> bool:
    candidate = sources.get("CodexDesktopSurfaceController.swift")
    if candidate is None:
        return False
    source = candidate[1]
    construction = re.search(
        r"let\s+coordinationService\s*=\s*"
        r"CodexDesktopCoordinationAppHostService\s*\(",
        source,
        re.DOTALL,
    )
    projector = re.search(
        r"CodexDesktopCoordinationAppHostService\s*"
        r"\.\s*rendererEvent\s*\(",
        source,
        re.DOTALL,
    )
    renderer_send = re.search(
        r"await\s+(?:self\?\.)?send\s*\(\s*message\s*\)",
        source,
    )
    return (
        construction is not None
        and projector is not None
        and renderer_send is not None
    )


def _realtime_callback_is_wired(
    sources: dict[str, tuple[Path, str]],
) -> bool:
    service = sources.get("CodexDesktopRealtimeAppHostService.swift")
    surface = sources.get("CodexDesktopSurfaceController.swift")
    if service is None or surface is None:
        return False
    service_source = service[1]
    surface_source = surface[1]
    return (
        "callbackInvoker" in service_source
        and "realtimeStarter" in service_source
        and "callbackInvoker" in surface_source
        and re.search(
            r"callbackDispatcher\.send\(\s*"
            r"portID:\s*portID",
            surface_source,
            re.DOTALL,
        )
        is not None
    )


def _realtime_method_has_behavior(
    sources: dict[str, tuple[Path, str]],
    method: str,
) -> bool:
    candidate = sources.get("CodexDesktopRealtimeAppHostService.swift")
    if candidate is None:
        return False
    source = candidate[1]
    patterns = {
        "registerRealtimeStarter": r"realtimeStarter\s*=",
        "requestRealtimeStart": r"callbackInvoker\??\(\s*starter\.request",
        "cancelRealtimeSessionStart": r"callbackInvoker\??\(\s*starter\.cancel",
        "unregisterRealtimeStarter": r"realtimeStarter\s*=\s*nil",
    }
    pattern = patterns.get(method)
    return pattern is not None and re.search(pattern, source) is not None


def _load_sources(source_root: Path) -> dict[str, tuple[Path, str]]:
    sources: dict[str, tuple[Path, str]] = {}
    for path in sorted(source_root.rglob("*.swift")):
        sources[path.name] = (
            path,
            path.read_text(encoding="utf-8", errors="replace"),
        )
    if not sources:
        raise ValueError(f"no Swift sources found: {source_root}")
    return sources


def audit_apphost_semantics(
    apphost_report: dict[str, Any],
    source_root: Path,
) -> dict[str, Any]:
    raw_calls = apphost_report.get("directRendererCalls")
    raw_resolved_methods = apphost_report.get(
        "resolvedOfficialServiceMethods"
    )
    raw_official_unavailable = apphost_report.get(
        "officialExplicitlyUnavailableMethods",
        [],
    )
    if raw_calls is not None and not isinstance(raw_calls, list):
        raise ValueError("AppHost report directRendererCalls is not an array")
    if raw_resolved_methods is not None and not isinstance(
        raw_resolved_methods,
        list,
    ):
        raise ValueError(
            "AppHost report resolvedOfficialServiceMethods is not an array"
        )
    if raw_calls is None and raw_resolved_methods is None:
        raise ValueError(
            "AppHost report has neither directRendererCalls nor "
            "resolvedOfficialServiceMethods arrays"
        )
    if not isinstance(raw_official_unavailable, list):
        raise ValueError(
            "AppHost report officialExplicitlyUnavailableMethods "
            "is not an array"
        )
    direct_calls = {
        (str(row["service"]), str(row["method"]))
        for row in raw_calls or []
        if isinstance(row, dict) and row.get("service") and row.get("method")
    }
    resolved_methods = {
        (str(row["service"]), str(row["method"]))
        for row in raw_resolved_methods or []
        if isinstance(row, dict) and row.get("service") and row.get("method")
    }
    official_unavailable = {
        str(value) for value in raw_official_unavailable
    }
    calls = sorted(direct_calls | resolved_methods)
    sources = _load_sources(source_root)
    tuple_evidence = _tuple_evidence_index(sources)
    rows: list[dict[str, Any]] = []

    for service, method in calls:
        evidence = tuple_evidence.get((service, method))
        if evidence is None:
            handlers: list[tuple[str, str]] = []
            if service in METHOD_ONLY_HANDLERS:
                handlers.append(METHOD_ONLY_HANDLERS[service])
            handlers.extend(METHOD_ONLY_FALLBACK_HANDLERS.get(service, ()))
            for filename, function_name in handlers:
                candidate = sources.get(filename)
                if candidate is None:
                    continue
                path, source = candidate
                found = _method_only_evidence(
                    source,
                    function_name=function_name,
                    service=service,
                    method=method,
                )
                if found is not None:
                    evidence = (path, found[0], found[1])
                    break

        if evidence is None:
            classification = "unlocated"
            signals = ["no-semantic-handler-body-located"]
            source_path = None
            source_line = None
            body_sha256 = None
        else:
            path, body, source_line = evidence
            classification, signals = _classification(body)
            if (
                classification == "placeholder"
                and signals == ["explicit-unavailable"]
                and f"{service}.{method}" in official_unavailable
            ):
                classification = "nativeStaticEvidence"
                signals = [
                    "non-placeholder-handler-body",
                    "matches-official-unavailable",
                ]
            if (
                service == "appshot"
                and method == "getState"
                and classification == "placeholder"
                and _appshot_capture_is_wired(sources)
            ):
                classification = "nativeStaticEvidence"
                signals = [
                    "non-placeholder-handler-body",
                    "ipad-webview-snapshot-coordinator-wired",
                ]
            if (
                service == "appshot"
                and method == "setHotkey"
                and classification == "placeholder"
                and _appshot_capture_is_wired(sources)
            ):
                classification = "platformDivergence"
                signals = [
                    "ipad-webview-snapshot-replaces-global-hotkey",
                ]
            if (
                service == "codexMicro"
                and method == "getInputMonitoringPermissionStatus"
                and classification == "placeholder"
                and _codex_micro_input_monitoring_is_platform_divergence(
                    sources
                )
            ):
                classification = "platformDivergence"
                signals = [
                    "ipad-no-process-wide-input-monitoring-permission",
                ]
            if (
                service == "appUpdates"
                and classification == "placeholder"
                and signals == ["explicit-unavailable"]
                and (
                    (
                        re.search(r"try\s+await\s+manager\.", body)
                        and _app_updates_production_manager_is_wired(sources)
                    )
                    or (
                        _automatic_updates_intentionally_removed(
                            sources[path.name][1]
                        )
                    )
                )
            ):
                classification = "nativeStaticEvidence"
                signals = [
                    "non-placeholder-handler-body",
                    (
                        "automatic-updates-disabled"
                        if _automatic_updates_intentionally_removed(
                            sources[path.name][1]
                        )
                        else "production-manager-injected"
                    ),
                ]
            if (
                service
                in {"hotkeyWindowCommands", "remoteControlEnvironments"}
                and classification == "placeholder"
                and "explicit-unavailable" in signals
                and _peripheral_operation_is_wired(
                    sources,
                    service=service,
                )
            ):
                classification = "nativeStaticEvidence"
                signals = [
                    "non-placeholder-handler-body",
                    (
                        "production-hotkey-window-operation-injected"
                        if service == "hotkeyWindowCommands"
                        else "production-remote-control-environment-"
                        "operation-injected"
                    ),
                ]
            if (
                service == "clientCoordination"
                and method == "invalidateQueryCache"
                and re.search(r"\brendererEvent\s*\(", body)
                and _coordination_renderer_event_is_wired(sources)
            ):
                classification = "rendererEventForwarded"
                signals = [
                    "renderer-event-projector",
                    "renderer-event-send-wired",
                ]
            if (
                service == "realtimeVoiceRuntime"
                and method in {
                    "registerRealtimeStarter",
                    "requestRealtimeStart",
                    "cancelRealtimeSessionStart",
                    "unregisterRealtimeStarter",
                }
                and _realtime_callback_is_wired(sources)
                and _realtime_method_has_behavior(sources, method)
            ):
                classification = "rendererCallbackForwarded"
                signals = [
                    "realtime-starter-state",
                    "renderer-callback-invoker",
                    "per-port-callback-scope",
                ]
            source_path = path.relative_to(source_root).as_posix()
            body_sha256 = hashlib.sha256(body.encode("utf-8")).hexdigest()
        rows.append({
            "call": f"{service}.{method}",
            "service": service,
            "method": method,
            "exposureSources": [
                source
                for source, members in (
                    ("directRenderer", direct_calls),
                    ("registeredService", resolved_methods),
                )
                if (service, method) in members
            ],
            "classification": classification,
            "signals": signals,
            "sourcePath": source_path,
            "sourceLine": source_line,
            "handlerBodySha256": body_sha256,
            "physicalDeviceRuntimeProof": False,
        })

    counts = {
        name: sum(row["classification"] == name for row in rows)
        for name in (
            "placeholder",
            "eventForwarded",
            "rendererEventForwarded",
            "rendererCallbackForwarded",
            "platformDivergence",
            "nativeStaticEvidence",
            "unlocated",
        )
    }
    return {
        "schemaVersion": 1,
        "status": (
            "complete"
            if counts["placeholder"] == 0 and counts["unlocated"] == 0
            else "incomplete"
        ),
        "staticEvidenceOnly": True,
        "physicalDeviceRuntimeProof": False,
        "classificationBoundary": (
            "nativeStaticEvidence, eventForwarded, rendererEventForwarded, "
            "rendererCallbackForwarded, and platformDivergence identify "
            "static source behavior only; "
            "none proves released behavior on a physical iPad"
        ),
        "directRendererCallCount": len(direct_calls),
        "resolvedOfficialServiceMethodCount": len(resolved_methods),
        "officialMethodSurfaceCount": len(calls),
        "classifiedCallCount": len(rows),
        "placeholderCount": counts["placeholder"],
        "eventForwardedCount": counts["eventForwarded"],
        "rendererEventForwardedCount": counts[
            "rendererEventForwarded"
        ],
        "rendererCallbackForwardedCount": counts[
            "rendererCallbackForwarded"
        ],
        "platformDivergenceCount": counts["platformDivergence"],
        "nativeStaticEvidenceCount": counts["nativeStaticEvidence"],
        "unlocatedCount": counts["unlocated"],
        "calls": rows,
    }


def _load_object(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apphost-report", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-no-placeholders", action="store_true")
    args = parser.parse_args()
    try:
        report = audit_apphost_semantics(
            _load_object(args.apphost_report),
            args.source_root,
        )
    except (KeyError, OSError, ValueError) as error:
        parser.error(str(error))
    write_json_atomic(args.output, report)
    print(args.output)
    print(
        "apphost-semantics "
        f"native={report['nativeStaticEvidenceCount']} "
        f"event={report['eventForwardedCount']} "
        f"renderer_event={report['rendererEventForwardedCount']} "
        f"renderer_callback={report['rendererCallbackForwardedCount']} "
        f"placeholder={report['placeholderCount']} "
        f"unlocated={report['unlocatedCount']}"
    )
    if args.require_no_placeholders and (
        report["placeholderCount"] or report["unlocatedCount"]
    ):
        print("AppHost semantic placeholders remain", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
