#!/bin/sh
set -eu

SCRIPT_DIR=$(
    CDPATH= cd -- "$(dirname -- "$0")"
    pwd
)
CODEXPAD_ROOT=$(dirname "$SCRIPT_DIR")
PYTHON_XCFRAMEWORK="$CODEXPAD_ROOT/Vendor/python_apple/Python.xcframework"
SOURCE="$SCRIPT_DIR/CodexPythonRuntimeBridge.m"
INCLUDE="$SCRIPT_DIR/include"
OUTPUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-python-bridge.XXXXXX")
trap 'rm -rf "$OUTPUT_DIR"' EXIT HUP INT TERM

python3 - "$SOURCE" <<'PY'
import ast
import re
import sys
import types
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("static const char *bootstrap_source =")
end = source.index("\n\nstatic bool append_search_path", start)
literals = re.findall(r'^\s*("(?:\\.|[^"\\])*")', source[start:end], re.M)
bootstrap = "".join(ast.literal_eval(literal) for literal in literals)
compile(bootstrap, "<codex-python-bootstrap>", "exec")

events = []
native = types.ModuleType("_codex_stdio")
native.read = lambda session, size=-1: (
    events.append(("read", session, size)) or b""
)
native.readline = lambda session, size=-1: (
    events.append(("readline", session, size)) or b""
)
native.stdout = lambda session, data: events.append(
    ("stdout", session, bytes(data))
)
native.stderr = lambda session, data: events.append(
    ("stderr", session, bytes(data))
)
native.cancelled = lambda session: False
sys.modules["_codex_stdio"] = native

namespace = {}
exec(bootstrap, namespace)
assert sys.stdin.read(0) == ""
assert events == [("read", None, 0)]
events.clear()
assert sys.stdout.write("outside-session") == len("outside-session")
assert events == []

session = object()
result = namespace["_run"](
    session,
    3,
    "print('inside-session')",
    ["python", "-c"],
    {},
    "/tmp",
)
assert result == 0
assert events == [
    ("stdout", session, b"inside-session"),
    ("stdout", session, b"\n"),
]
PY

compile_slice() {
    sdk=$1
    slice=$2
    target=$3
    output="$OUTPUT_DIR/CodexPythonRuntimeBridge-$sdk.o"
    sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
    dylib="$OUTPUT_DIR/CodexPythonRuntimeBridge-$sdk.dylib"

    xcrun --sdk "$sdk" clang \
        -std=c11 \
        -Wall \
        -Wextra \
        -Werror \
        -fmodules \
        -fobjc-arc \
        -target "$target" \
        -isysroot "$sdk_path" \
        -F "$PYTHON_XCFRAMEWORK/$slice" \
        -I "$INCLUDE" \
        -c "$SOURCE" \
        -o "$output"

    file "$output"
    nm -gU "$output" > "$output.symbols"
    for symbol in \
        _codex_python_runtime_initialize \
        _codex_python_session_create \
        _codex_python_session_start \
        _codex_python_session_write \
        _codex_python_session_close_stdin \
        _codex_python_session_cancel \
        _codex_python_session_release \
        _codex_python_error_free
    do
        grep -qx "[0-9a-fA-F][0-9a-fA-F]* T $symbol" "$output.symbols"
    done

    xcrun --sdk "$sdk" clang \
        -std=c11 \
        -Wall \
        -Wextra \
        -Werror \
        -fmodules \
        -fobjc-arc \
        -target "$target" \
        -isysroot "$sdk_path" \
        -F "$PYTHON_XCFRAMEWORK/$slice" \
        -I "$INCLUDE" \
        "$SOURCE" \
        -dynamiclib \
        -framework Python \
        -o "$dylib"
    file "$dylib"
    otool -L "$dylib" \
        | grep -q '@rpath/Python.framework/Python'

    xcrun --sdk "$sdk" clang \
        --analyze \
        -Xanalyzer -analyzer-output=text \
        -std=c11 \
        -Wall \
        -Wextra \
        -Werror \
        -fmodules \
        -fobjc-arc \
        -target "$target" \
        -isysroot "$sdk_path" \
        -F "$PYTHON_XCFRAMEWORK/$slice" \
        -I "$INCLUDE" \
        "$SOURCE"
}

compile_slice \
    iphonesimulator \
    ios-arm64_x86_64-simulator \
    arm64-apple-ios18.0-simulator
compile_slice \
    iphoneos \
    ios-arm64 \
    arm64-apple-ios18.0

echo "CodexPythonRuntimeBridge static verification passed."
