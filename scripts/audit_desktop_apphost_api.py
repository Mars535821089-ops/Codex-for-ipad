#!/usr/bin/env python3
"""Audit released desktop AppHost services against the iPad native router."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import write_json_atomic
from scripts.verify_desktop_bridge_api import _top_level_keys


CREATE_APP_HOST = re.compile(
    r"\bcreateAppHost\([^)]*\)\s*\{.*?\breturn\s+new\s+"
    r"[A-Za-z_$][A-Za-z0-9_$]*\s*\(",
    re.DOTALL,
)
RENDERER_CALL = re.compile(
    r"\b([A-Za-z_$][A-Za-z0-9_$]*)\??\."
    r"([A-Za-z_$][A-Za-z0-9_$]*)\??\."
    r"([A-Za-z_$][A-Za-z0-9_$]*)\s*\("
)
APPHOST_SERVICES_ASSIGNMENT = re.compile(
    r"\b([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*await\s+"
    r"[A-Za-z_$][A-Za-z0-9_$]*(?:\??\."
    r"[A-Za-z_$][A-Za-z0-9_$]*)*\.services\b"
)
SERVICE_LIST = re.compile(
    r"\bserviceNames\s*=\s*\[(.*?)\]",
    re.DOTALL,
)
STRING_LITERAL = re.compile(r'["\']([^"\']+)["\']')
ROUTER_CASE = re.compile(
    r"\(\s*[\"']([^\"']+)[\"']\s*,\s*"
    r"[\"']([^\"']+)[\"']\s*\)"
)
ROUTER_CASE_BLOCK = re.compile(r"\bcase\s+(.*?):", re.DOTALL)
METHOD_EQUALITY = re.compile(
    r"\bmethod\s*==\s*[\"']([^\"']+)[\"']"
)
METHOD_SET = re.compile(
    r"\b(?:let|static\s+let)\s+[A-Za-z_][A-Za-z0-9_]*\s*"
    r":\s*Set<String>\s*=\s*\[(.*?)\]",
    re.DOTALL,
)
IPAD_ROOT_VALUE = re.compile(
    r"\[\s*[\"']([^\"']+)[\"']\s*\]\s*=\s*\."
    r"(?:bool|integer|number|string|null)\b"
)
CLASS_MEMBER_PREFIXES = {"async", "get", "set", "static"}
KNOWN_ROOT_VALUE_NAMES = {"notificationPermissionsSupported"}
SHADOW_PRONE_COLLECTION_METHODS = {
    "every",
    "filter",
    "find",
    "findIndex",
    "flatMap",
    "forEach",
    "includes",
    "map",
    "reduce",
    "some",
}
LITERAL_ROOT_VALUE = re.compile(
    r"(?:true|false|null|-?(?:\d+(?:\.\d*)?|\.\d+)"
    r"|[\"'][^\"']*[\"'])"
)


def _read_contract_source(
    path: Path,
    *,
    directory_suffix: str,
) -> tuple[str, bytes]:
    if path.is_file():
        payload = path.read_bytes()
        return payload.decode("utf-8"), payload
    if not path.is_dir():
        raise OSError(f"contract path is missing: {path}")
    files = sorted(
        candidate
        for candidate in path.rglob(f"*{directory_suffix}")
        if candidate.is_file()
    )
    if not files:
        raise OSError(
            f"contract directory has no {directory_suffix} files: {path}"
        )
    source_parts: list[str] = []
    digest_parts: list[bytes] = []
    for candidate in files:
        relative = candidate.relative_to(path).as_posix()
        payload = candidate.read_bytes()
        source_parts.append(payload.decode("utf-8"))
        digest_parts.extend(
            (relative.encode("utf-8"), b"\0", payload, b"\0")
        )
    return "\n".join(source_parts), b"".join(digest_parts)


def _official_service_object_start(source: str) -> int:
    match = CREATE_APP_HOST.search(source)
    if match is None:
        raise ValueError("official createAppHost service object is missing")
    object_start = source.find("{", match.end())
    if object_start < 0:
        raise ValueError("official createAppHost service object is malformed")
    return object_start


def _top_level_property_expressions(
    source: str,
    object_start: int,
) -> dict[str, str]:
    """Return direct property expressions from one JavaScript object literal."""
    expressions: dict[str, str] = {}
    depth = 1
    parenthesis_depth = 0
    bracket_depth = 0
    segment_start = object_start + 1
    index = segment_start
    quote: str | None = None
    escaped = False
    line_comment = False
    block_comment = False

    def record(end: int) -> None:
        segment = source[segment_start:end]
        match = re.match(
            r"\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*(.*?)\s*$",
            segment,
            re.DOTALL,
        )
        if match is not None:
            expressions.setdefault(match.group(1), match.group(2))

    while index < len(source) and depth > 0:
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
        if character in ("'", '"', "`"):
            quote = character
            index += 1
            continue
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                record(index)
                break
        elif depth == 1 and character == "(":
            parenthesis_depth += 1
        elif depth == 1 and character == ")":
            parenthesis_depth = max(0, parenthesis_depth - 1)
        elif depth == 1 and character == "[":
            bracket_depth += 1
        elif depth == 1 and character == "]":
            bracket_depth = max(0, bracket_depth - 1)
        elif (
            depth == 1
            and parenthesis_depth == 0
            and bracket_depth == 0
            and character == ","
        ):
            record(index)
            segment_start = index + 1
        index += 1
    if depth != 0:
        raise ValueError("official createAppHost service object is unterminated")
    return expressions


def official_service_contract(
    source: str,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    services, undefined, _ = official_root_contract(source)
    return services, undefined


def official_root_contract(
    source: str,
) -> tuple[tuple[str, ...], tuple[str, ...], tuple[str, ...]]:
    object_start = _official_service_object_start(source)
    declared = _top_level_keys(source, object_start)
    expressions = _top_level_property_expressions(source, object_start)
    undefined = tuple(
        name
        for name in declared
        if re.fullmatch(r"void\s+0", expressions.get(name, ""))
    )
    root_values = tuple(
        name
        for name in declared
        if name not in undefined
        and (
            name in KNOWN_ROOT_VALUE_NAMES
            or LITERAL_ROOT_VALUE.fullmatch(
                expressions.get(name, "").strip()
            )
        )
    )
    services = tuple(
        name
        for name in declared
        if name not in undefined and name not in root_values
    )
    return services, undefined, root_values


def official_service_names(source: str) -> tuple[str, ...]:
    return official_service_contract(source)[0]


def _service_class_name(
    source: str,
    *,
    expression: str,
    object_start: int,
) -> str | None:
    direct = re.search(
        r"\bnew\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(",
        expression,
    )
    if direct is not None:
        return direct.group(1)

    reference = expression.strip()
    reference_match = re.fullmatch(
        r"(?:this\.)?([A-Za-z_$][A-Za-z0-9_$]*)",
        reference,
    )
    if reference_match is None:
        return None
    identifier = reference_match.group(1)
    direct_assignment = re.compile(
        rf"(?:\b(?:let|const|var)\s+)?"
        rf"(?:this\.)?{re.escape(identifier)}\s*=\s*new\s+"
        r"([A-Za-z_$][A-Za-z0-9_$]*)\s*\("
    )
    conditional_assignment = re.compile(
        rf"(?:\b(?:let|const|var)\s+)?"
        rf"(?:this\.)?{re.escape(identifier)}\s*=\s*"
        r"[^,;{}]*?\?[^,;{}]*?:\s*new\s+"
        r"([A-Za-z_$][A-Za-z0-9_$]*)\s*\("
    )
    matches = sorted(
        (
            *direct_assignment.finditer(source, 0, object_start),
            *conditional_assignment.finditer(source, 0, object_start),
        ),
        key=lambda match: match.start(),
    )
    if not matches:
        return None
    return matches[-1].group(1)


def resolved_official_service_methods(
    source: str,
    service_names: tuple[str, ...],
) -> tuple[
    tuple[tuple[str, str, str], ...],
    tuple[str, ...],
]:
    """Resolve own methods for service objects with statically visible classes.

    The released bundle registers some AppHost services without ever spelling
    a direct renderer call. Resolve the common `new Class`, local alias, and
    `this.member` construction forms so those method surfaces are audited too.
    Services whose construction cannot be proven remain explicitly unresolved.
    """
    object_start = _official_service_object_start(source)
    expressions = _top_level_property_expressions(source, object_start)
    resolved: list[tuple[str, str, str]] = []
    unresolved: list[str] = []
    for service in service_names:
        expression = expressions.get(service)
        if expression is None:
            unresolved.append(service)
            continue
        class_name = _service_class_name(
            source,
            expression=expression,
            object_start=object_start,
        )
        if class_name is None:
            unresolved.append(service)
            continue
        methods = class_public_methods(source, class_name)
        if not methods:
            unresolved.append(service)
            continue
        resolved.extend(
            (service, method, class_name) for method in methods
        )
    return tuple(sorted(resolved)), tuple(sorted(unresolved))


def class_public_methods(
    source: str,
    class_name: str,
) -> tuple[str, ...]:
    """Return named top-level methods from one released minified class."""
    escaped_name = re.escape(class_name)
    patterns = (
        rf"\b{escaped_name}\s*=\s*class"
        r"(?:\s+(?!extends\b)[A-Za-z_$][A-Za-z0-9_$]*)?"
        r"(?:\s+extends\s+[A-Za-z0-9_$.]+)?\s*\{",
        rf"\bclass\s+{escaped_name}"
        r"(?:\s+extends\s+[A-Za-z0-9_$.]+)?\s*\{",
    )
    match = next(
        (
            candidate
            for pattern in patterns
            if (candidate := re.search(pattern, source)) is not None
        ),
        None,
    )
    if match is None:
        return ()

    methods: set[str] = set()
    depth = 1
    index = match.end()
    member_start = True
    quote: str | None = None
    escaped = False
    line_comment = False
    block_comment = False
    while index < len(source) and depth > 0:
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
        if character in ("'", '"', "`"):
            quote = character
            index += 1
            continue
        if character == "{":
            depth += 1
            member_start = False
            index += 1
            continue
        if character == "}":
            depth -= 1
            if depth == 1:
                member_start = True
            index += 1
            continue
        if depth != 1:
            index += 1
            continue
        if character == ";":
            member_start = True
            index += 1
            continue
        if member_start and character.isspace():
            index += 1
            continue
        if member_start and (
            character.isalpha() or character in ("_", "$")
        ):
            end = index + 1
            while end < len(source) and (
                source[end].isalnum() or source[end] in ("_", "$")
            ):
                end += 1
            identifier = source[index:end]
            cursor = end
            while cursor < len(source) and source[cursor].isspace():
                cursor += 1
            if identifier in CLASS_MEMBER_PREFIXES:
                index = cursor
                continue
            if cursor < len(source) and source[cursor] == "(":
                if identifier != "constructor":
                    methods.add(identifier)
            member_start = False
            index = end
            continue
        if member_start:
            member_start = False
        index += 1
    return tuple(sorted(methods))


def _class_body_text(source: str, class_name: str) -> str:
    escaped_name = re.escape(class_name)
    patterns = (
        rf"\b{escaped_name}\s*=\s*class"
        r"(?:\s+(?!extends\b)[A-Za-z_$][A-Za-z0-9_$]*)?"
        r"(?:\s+extends\s+[A-Za-z0-9_$.]+)?\s*\{",
        rf"\bclass\s+{escaped_name}"
        r"(?:\s+extends\s+[A-Za-z0-9_$.]+)?\s*\{",
    )
    match = next(
        (
            candidate
            for pattern in patterns
            if (candidate := re.search(pattern, source)) is not None
        ),
        None,
    )
    if match is None:
        return ""
    depth = 1
    index = match.end()
    quote: str | None = None
    escaped = False
    while index < len(source) and depth > 0:
        character = source[index]
        if quote is not None:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
        elif character in ("'", '"', "`"):
            quote = character
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
        index += 1
    return source[match.end() : index - 1] if depth == 0 else ""


def official_explicitly_unavailable_methods(
    source: str,
    resolved_methods: tuple[tuple[str, str, str], ...],
) -> tuple[str, ...]:
    class_bodies: dict[str, str] = {}
    unavailable: set[str] = set()
    for service, method, class_name in resolved_methods:
        body = class_bodies.setdefault(
            class_name,
            _class_body_text(source, class_name),
        )
        if not body:
            continue
        match = re.search(
            rf"\b(?:async\s+)?{re.escape(method)}\s*\([^)]*\)\s*"
            r"\{\s*throw\s+(?:new\s+)?Error\s*\((?P<message>.*?)\)",
            body,
            re.DOTALL,
        )
        if match is not None and re.search(
            r"\bunavailable\b",
            match.group("message"),
            re.IGNORECASE,
        ):
            unavailable.add(f"{service}.{method}")
    return tuple(sorted(unavailable))


def renderer_calls(
    source: str,
    service_names: tuple[str, ...],
) -> tuple[tuple[str, str], ...]:
    services = set(service_names)
    candidates = [
        (root, service, method)
        for root, service, method in RENDERER_CALL.findall(source)
        if service in services
    ]
    apphost_roots = set(APPHOST_SERVICES_ASSIGNMENT.findall(source))
    if not apphost_roots and candidates:
        services_by_root: dict[str, set[str]] = {}
        for root, service, _ in candidates:
            services_by_root.setdefault(root, set()).add(service)
        largest_contract = max(map(len, services_by_root.values()))
        apphost_roots = {
            root
            for root, referenced_services in services_by_root.items()
            if len(referenced_services) == largest_contract
        }
    return tuple(
        sorted(
            {
                (service, method)
                for root, service, method in candidates
                if root in apphost_roots
                and method not in SHADOW_PRONE_COLLECTION_METHODS
            }
        )
    )


def ipad_contract(
    source: str,
) -> tuple[
    tuple[str, ...],
    tuple[tuple[str, str], ...],
    tuple[str, ...],
]:
    match = SERVICE_LIST.search(source)
    if match is None:
        raise ValueError("iPad AppHost serviceNames are missing")
    services = tuple(STRING_LITERAL.findall(match.group(1)))
    if len(services) != len(set(services)):
        raise ValueError("iPad AppHost serviceNames contain duplicates")
    methods = tuple(sorted(set(ROUTER_CASE.findall(source))))
    delegated_methods = tuple(sorted({
        literal
        for case_match in ROUTER_CASE_BLOCK.finditer(source)
        for literal in STRING_LITERAL.findall(case_match.group(1))
    } | set(METHOD_EQUALITY.findall(source)) | {
        literal
        for set_match in METHOD_SET.finditer(source)
        for literal in STRING_LITERAL.findall(set_match.group(1))
    }))
    return services, methods, delegated_methods


def audit_apphost_api(
    official_main: Path,
    official_renderer: Path,
    ipad_router: Path,
) -> dict[str, object]:
    main_source, main_payload = _read_contract_source(
        official_main,
        directory_suffix=".js",
    )
    renderer_source, renderer_payload = _read_contract_source(
        official_renderer,
        directory_suffix=".js",
    )
    ipad_source, ipad_payload = _read_contract_source(
        ipad_router,
        directory_suffix=".swift",
    )

    official_services, undefined_services, official_root_values = (
        official_root_contract(main_source)
    )
    resolved_service_methods, unresolved_service_methods = (
        resolved_official_service_methods(
            main_source,
            official_services,
        )
    )
    official_unavailable_methods = official_explicitly_unavailable_methods(
        main_source,
        resolved_service_methods,
    )
    calls = renderer_calls(renderer_source, official_services)
    ipad_services, ipad_methods, delegated_methods = ipad_contract(
        ipad_source
    )
    ipad_root_values = tuple(sorted(set(IPAD_ROOT_VALUE.findall(ipad_source))))
    called_services = sorted({service for service, _ in calls})
    missing_services = sorted(set(official_services) - set(ipad_services))
    missing_called_services = sorted(
        set(called_services) - set(ipad_services)
    )
    missing_called_methods = [
        f"{service}.{method}"
        for service, method in calls
        if service in ipad_services
        and (service, method) not in ipad_methods
        and method not in delegated_methods
    ]
    missing_root_values = sorted(
        set(official_root_values) - set(ipad_root_values)
    )
    missing_resolved_service_methods = [
        f"{service}.{method}"
        for service, method, _ in resolved_service_methods
        if (service, method) not in ipad_methods
        and method not in delegated_methods
    ]
    status = (
        "complete"
        if not missing_services
        and not missing_called_services
        and not missing_called_methods
        and not missing_resolved_service_methods
        and not missing_root_values
        else "incomplete"
    )
    return {
        "schemaVersion": 1,
        "status": status,
        "officialMainSha256": hashlib.sha256(
            main_payload
        ).hexdigest(),
        "officialRendererSha256": hashlib.sha256(
            renderer_payload
        ).hexdigest(),
        "ipadRouterSha256": hashlib.sha256(
            ipad_payload
        ).hexdigest(),
        "officialServices": list(official_services),
        "officialServiceCount": len(official_services),
        "officialUndefinedServices": list(undefined_services),
        "officialUndefinedServiceCount": len(undefined_services),
        "officialRootValues": list(official_root_values),
        "officialRootValueCount": len(official_root_values),
        "resolvedOfficialServiceMethods": [
            {
                "service": service,
                "method": method,
                "className": class_name,
            }
            for service, method, class_name in resolved_service_methods
        ],
        "resolvedOfficialServiceMethodCount": len(
            resolved_service_methods
        ),
        "officialExplicitlyUnavailableMethods": list(
            official_unavailable_methods
        ),
        "officialExplicitlyUnavailableMethodCount": len(
            official_unavailable_methods
        ),
        "unresolvedOfficialServiceMethods": list(
            unresolved_service_methods
        ),
        "unresolvedOfficialServiceMethodCount": len(
            unresolved_service_methods
        ),
        "directRendererCalls": [
            {"service": service, "method": method}
            for service, method in calls
        ],
        "directRendererCallCount": len(calls),
        "directRendererServiceCount": len(called_services),
        "ipadServices": list(ipad_services),
        "ipadServiceCount": len(ipad_services),
        "ipadRootValues": list(ipad_root_values),
        "ipadHandledMethods": [
            {"service": service, "method": method}
            for service, method in ipad_methods
        ],
        "ipadHandledMethodCount": len(ipad_methods),
        "missingOfficialServices": missing_services,
        "missingDirectRendererServices": missing_called_services,
        "missingDirectRendererMethods": missing_called_methods,
        "missingResolvedOfficialServiceMethods": (
            missing_resolved_service_methods
        ),
        "missingOfficialRootValues": missing_root_values,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--official-main", type=Path, required=True)
    parser.add_argument("--official-renderer", type=Path, required=True)
    parser.add_argument("--ipad-router", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    try:
        result = audit_apphost_api(
            args.official_main,
            args.official_renderer,
            args.ipad_router,
        )
    except (OSError, ValueError) as error:
        parser.error(str(error))
    write_json_atomic(args.output, result)
    if args.require_complete and result["status"] != "complete":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
