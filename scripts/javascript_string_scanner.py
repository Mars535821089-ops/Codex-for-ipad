#!/usr/bin/env python3
"""Extract static JavaScript string literals without evaluating a bundle."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class JavaScriptString:
    value: str
    quote: str
    start: int
    end: int


_SIMPLE_ESCAPES = {
    ord("b"): "\b",
    ord("f"): "\f",
    ord("n"): "\n",
    ord("r"): "\r",
    ord("t"): "\t",
    ord("v"): "\v",
    ord("\\"): "\\",
    ord("'"): "'",
    ord('"'): '"',
    ord("`"): "`",
    ord("/"): "/",
}


def _decode_raw(raw: bytes) -> str:
    output: list[str] = []
    index = 0
    while index < len(raw):
        byte = raw[index]
        if byte != ord("\\"):
            start = index
            while index < len(raw) and raw[index] != ord("\\"):
                index += 1
            output.append(raw[start:index].decode("utf-8", errors="replace"))
            continue
        index += 1
        if index >= len(raw):
            raise ValueError("unterminated JavaScript escape")
        escaped = raw[index]
        if escaped in _SIMPLE_ESCAPES:
            output.append(_SIMPLE_ESCAPES[escaped])
            index += 1
        elif escaped in (ord("\n"), ord("\r")):
            index += 1
            if escaped == ord("\r") and index < len(raw) and raw[index] == ord("\n"):
                index += 1
        elif escaped == ord("x") and index + 2 < len(raw):
            output.append(chr(int(raw[index + 1 : index + 3], 16)))
            index += 3
        elif escaped == ord("u") and index + 4 < len(raw):
            output.append(chr(int(raw[index + 1 : index + 5], 16)))
            index += 5
        else:
            output.append(chr(escaped))
            index += 1
    return "".join(output)


def _skip_regex(source: bytes, index: int) -> int:
    index += 1
    in_class = False
    escaped = False
    while index < len(source):
        byte = source[index]
        if escaped:
            escaped = False
        elif byte == ord("\\"):
            escaped = True
        elif byte == ord("["):
            in_class = True
        elif byte == ord("]"):
            in_class = False
        elif byte == ord("/") and not in_class:
            index += 1
            while index < len(source) and (
                ord("a") <= source[index] <= ord("z")
                or ord("A") <= source[index] <= ord("Z")
            ):
                index += 1
            return index
        elif byte in (ord("\n"), ord("\r")):
            return index
        index += 1
    return index


def _skip_quoted(source: bytes, start: int, quote: int) -> int:
    index = start + 1
    escaped = False
    while index < len(source):
        current = source[index]
        if escaped:
            escaped = False
        elif current == ord("\\"):
            escaped = True
        elif current == quote:
            return index + 1
        elif current in (ord("\n"), ord("\r")):
            raise ValueError(f"unterminated JavaScript string at byte {start}")
        index += 1
    raise ValueError(f"unterminated JavaScript string at byte {start}")


def _skip_template_expression(source: bytes, index: int) -> int:
    depth = 1
    previous_significant: int | None = None
    regex_prefix = b"([{=:;,!&|?+-*%^~<>"
    while index < len(source):
        byte = source[index]
        if byte in b" \t\r\n":
            index += 1
            continue
        if byte in (ord("'"), ord('"')):
            index = _skip_quoted(source, index, byte)
            previous_significant = byte
            continue
        if byte == ord("`"):
            index, _ = _skip_template(source, index)
            previous_significant = byte
            continue
        if byte == ord("/") and index + 1 < len(source):
            following = source[index + 1]
            if following == ord("/"):
                newline = source.find(b"\n", index + 2)
                index = len(source) if newline < 0 else newline + 1
                continue
            if following == ord("*"):
                end = source.find(b"*/", index + 2)
                if end < 0:
                    raise ValueError("unterminated JavaScript block comment")
                index = end + 2
                continue
            if previous_significant is None or previous_significant in regex_prefix:
                index = _skip_regex(source, index)
                previous_significant = ord("/")
                continue
        if byte == ord("{"):
            depth += 1
        elif byte == ord("}"):
            depth -= 1
            if depth == 0:
                return index + 1
        previous_significant = byte
        index += 1
    raise ValueError("unterminated JavaScript template expression")


def _skip_template(source: bytes, start: int) -> tuple[int, bool]:
    index = start + 1
    dynamic = False
    while index < len(source):
        current = source[index]
        if current == ord("\\"):
            index += 2
            continue
        if current == ord("`"):
            return index + 1, dynamic
        if (
            current == ord("$")
            and index + 1 < len(source)
            and source[index + 1] == ord("{")
        ):
            dynamic = True
            index = _skip_template_expression(source, index + 2)
            continue
        index += 1
    raise ValueError(f"unterminated JavaScript string at byte {start}")


def parse_javascript_string_at(
    source: bytes, start: int
) -> JavaScriptString | None:
    if start < 0 or start >= len(source):
        raise ValueError("JavaScript string offset is outside source")
    quote = source[start]
    if quote not in (ord("'"), ord('"'), ord("`")):
        raise ValueError(f"no JavaScript string at byte {start}")
    if quote == ord("`"):
        end, dynamic = _skip_template(source, start)
        if dynamic:
            return None
    else:
        end = _skip_quoted(source, start, quote)
    return JavaScriptString(
        value=_decode_raw(source[start + 1 : end - 1]),
        quote=chr(quote),
        start=start,
        end=end,
    )


def scan_javascript_strings(source: bytes) -> list[JavaScriptString]:
    results: list[JavaScriptString] = []
    index = 0
    previous_significant: int | None = None
    regex_prefix = b"([{=:;,!&|?+-*%^~<>"
    while index < len(source):
        byte = source[index]
        if byte in b" \t\r\n":
            index += 1
            continue
        if byte == ord("/") and index + 1 < len(source):
            following = source[index + 1]
            if following == ord("/"):
                newline = source.find(b"\n", index + 2)
                index = len(source) if newline < 0 else newline + 1
                continue
            if following == ord("*"):
                end = source.find(b"*/", index + 2)
                if end < 0:
                    raise ValueError("unterminated JavaScript block comment")
                index = end + 2
                continue
            if previous_significant is None or previous_significant in regex_prefix:
                index = _skip_regex(source, index)
                previous_significant = ord("/")
                continue
        if byte not in (ord("'"), ord('"'), ord("`")):
            previous_significant = byte
            index += 1
            continue

        quote = byte
        start = index
        if quote == ord("`"):
            parsed = parse_javascript_string_at(source, start)
            end, _ = _skip_template(source, start)
            if parsed is not None:
                results.append(parsed)
            index = end
            previous_significant = quote
            continue
        index += 1
        content_start = index
        escaped = False
        while index < len(source):
            current = source[index]
            if escaped:
                escaped = False
                index += 1
                continue
            if current == ord("\\"):
                escaped = True
                index += 1
                continue
            if current == quote:
                raw = source[content_start:index]
                index += 1
                results.append(
                    JavaScriptString(
                        value=_decode_raw(raw),
                        quote=chr(quote),
                        start=start,
                        end=index,
                    )
                )
                previous_significant = quote
                break
            if current in (ord("\n"), ord("\r")):
                raise ValueError(f"unterminated JavaScript string at byte {start}")
            index += 1
        else:
            raise ValueError(f"unterminated JavaScript string at byte {start}")
    return results
