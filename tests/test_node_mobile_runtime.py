import base64
import json
import select
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOST = (
    ROOT
    / "CodexPad/CodexPad/Application/Resources/NodeRuntime"
    / "codex-node-mcp-host.js"
)
FILESYSTEM_ENTRYPOINT = (
    ROOT
    / "CodexPad/CodexPad/Application/Resources/MCPPackages"
    / "node_modules/@modelcontextprotocol/server-filesystem/dist/index.js"
)


class NodeMobileRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.node = shutil.which("node")
        if self.node is None:
            self.skipTest("node is not installed")

    def _read_message(
        self,
        channel: socket.socket,
        buffer: bytearray,
        *,
        timeout: float = 5,
    ) -> dict[str, object]:
        deadline = time.monotonic() + timeout
        while True:
            newline = buffer.find(b"\n")
            if newline >= 0:
                line = bytes(buffer[:newline])
                del buffer[: newline + 1]
                return json.loads(line)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self.fail("timed out waiting for Node host message")
            readable, _, _ = select.select(
                [channel],
                [],
                [],
                remaining,
            )
            if not readable:
                self.fail("timed out waiting for Node host message")
            block = channel.recv(64 * 1024)
            if not block:
                self.fail("Node host control channel closed")
            buffer.extend(block)

    def _send(
        self,
        channel: socket.socket,
        message: dict[str, object],
    ) -> None:
        channel.sendall(
            json.dumps(message, separators=(",", ":")).encode()
            + b"\n"
        )

    def _read_session_json(
        self,
        channel: socket.socket,
        control_buffer: bytearray,
        stdout_buffer: bytearray,
        *,
        session_id: str,
        response_id: int,
        timeout: float = 10,
    ) -> dict[str, object]:
        deadline = time.monotonic() + timeout
        while True:
            newline = stdout_buffer.find(b"\n")
            if newline >= 0:
                line = bytes(stdout_buffer[:newline])
                del stdout_buffer[: newline + 1]
                payload = json.loads(line)
                if payload.get("id") == response_id:
                    return payload
                continue
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self.fail(
                    f"timed out waiting for MCP response {response_id}"
                )
            message = self._read_message(
                channel,
                control_buffer,
                timeout=remaining,
            )
            if (
                message.get("type") == "stream"
                and message.get("id") == session_id
                and message.get("stream") == "stdout"
            ):
                stdout_buffer.extend(
                    base64.b64decode(str(message["data"]))
                )

    def test_host_multiplexes_worker_stdio_without_process_fd_redirect(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture.js"
            fixture.write_text(
                """
const readline = require("node:readline");
const input = readline.createInterface({ input: process.stdin });
input.on("line", (line) => {
  const message = JSON.parse(line);
  process.stderr.write(`stderr:${message.value}\\n`);
  process.stdout.write(JSON.stringify({
    jsonrpc: "2.0",
    id: message.id,
    result: `${process.env.FIXTURE}:${message.value}`,
  }) + "\\n");
});
""",
                encoding="utf-8",
            )
            parent, child = socket.socketpair()
            child.set_inheritable(True)
            process = subprocess.Popen(
                [
                    self.node,
                    str(HOST),
                    "--control-fd",
                    str(child.fileno()),
                ],
                pass_fds=(child.fileno(),),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            child.close()
            buffer = bytearray()
            try:
                ready = self._read_message(parent, buffer)
                self.assertEqual(ready["type"], "runtimeReady")

                for session_id in ("one", "two"):
                    self._send(
                        parent,
                        {
                            "op": "start",
                            "id": session_id,
                            "arguments": [str(fixture)],
                            "environment": {
                                "FIXTURE": session_id,
                            },
                            "cwd": directory,
                        },
                    )

                ready_sessions: set[str] = set()
                while ready_sessions != {"one", "two"}:
                    message = self._read_message(parent, buffer)
                    if (
                        message.get("type") == "sessionState"
                        and message.get("state") == "ready"
                    ):
                        ready_sessions.add(str(message["id"]))

                for request_id, session_id in enumerate(
                    ("one", "two"),
                    start=1,
                ):
                    payload = (
                        json.dumps(
                            {
                                "id": request_id,
                                "value": "ping",
                            }
                        ).encode()
                        + b"\n"
                    )
                    self._send(
                        parent,
                        {
                            "op": "stdin",
                            "id": session_id,
                            "data": base64.b64encode(payload).decode(),
                        },
                    )

                stdout: dict[str, str] = {}
                stderr: dict[str, str] = {}
                while (
                    set(stdout) != {"one", "two"}
                    or set(stderr) != {"one", "two"}
                ):
                    message = self._read_message(parent, buffer)
                    if message.get("type") != "stream":
                        continue
                    payload = base64.b64decode(
                        str(message["data"])
                    ).decode()
                    session_id = str(message["id"])
                    if message["stream"] == "stdout":
                        stdout[session_id] = payload
                    elif message["stream"] == "stderr":
                        stderr[session_id] = payload

                self.assertEqual(
                    json.loads(stdout["one"])["result"],
                    "one:ping",
                )
                self.assertEqual(
                    json.loads(stdout["two"])["result"],
                    "two:ping",
                )
                self.assertEqual(stderr["one"], "stderr:ping\n")
                self.assertEqual(stderr["two"], "stderr:ping\n")
            finally:
                parent.close()
                process.terminate()
                process.wait(timeout=5)
                if process.stdout is not None:
                    self.assertEqual(process.stdout.read(), b"")
                    process.stdout.close()
                if process.stderr is not None:
                    self.assertEqual(process.stderr.read(), b"")
                    process.stderr.close()

    def test_vendored_filesystem_server_initializes_and_lists_tools(
        self,
    ) -> None:
        self.assertTrue(
            FILESYSTEM_ENTRYPOINT.is_file(),
            "vendored filesystem MCP entrypoint is missing",
        )
        with tempfile.TemporaryDirectory() as directory:
            parent, child = socket.socketpair()
            child.set_inheritable(True)
            process = subprocess.Popen(
                [
                    self.node,
                    str(HOST),
                    "--control-fd",
                    str(child.fileno()),
                ],
                pass_fds=(child.fileno(),),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            child.close()
            control_buffer = bytearray()
            stdout_buffer = bytearray()
            session_id = "filesystem"
            try:
                self.assertEqual(
                    self._read_message(
                        parent,
                        control_buffer,
                    )["type"],
                    "runtimeReady",
                )
                self._send(
                    parent,
                    {
                        "op": "start",
                        "id": session_id,
                        "arguments": [
                            str(FILESYSTEM_ENTRYPOINT),
                            directory,
                        ],
                        "environment": {},
                        "cwd": directory,
                    },
                )
                while True:
                    state = self._read_message(
                        parent,
                        control_buffer,
                    )
                    if (
                        state.get("type") == "sessionState"
                        and state.get("id") == session_id
                        and state.get("state") == "ready"
                    ):
                        break
                initialize = {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2025-11-25",
                        "capabilities": {},
                        "clientInfo": {
                            "name": "codex-for-ipad-runtime-test",
                            "version": "1.0.0",
                        },
                    },
                }
                self._send(
                    parent,
                    {
                        "op": "stdin",
                        "id": session_id,
                        "data": base64.b64encode(
                            json.dumps(initialize).encode() + b"\n"
                        ).decode(),
                    },
                )
                initialized = self._read_session_json(
                    parent,
                    control_buffer,
                    stdout_buffer,
                    session_id=session_id,
                    response_id=1,
                )
                self.assertEqual(
                    initialized["result"]["serverInfo"]["name"],
                    "secure-filesystem-server",
                )
                for message in (
                    {
                        "jsonrpc": "2.0",
                        "method": "notifications/initialized",
                    },
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/list",
                        "params": {},
                    },
                ):
                    self._send(
                        parent,
                        {
                            "op": "stdin",
                            "id": session_id,
                            "data": base64.b64encode(
                                json.dumps(message).encode() + b"\n"
                            ).decode(),
                        },
                    )
                tools_response = self._read_session_json(
                    parent,
                    control_buffer,
                    stdout_buffer,
                    session_id=session_id,
                    response_id=2,
                )
                tool_names = {
                    tool["name"]
                    for tool in tools_response["result"]["tools"]
                }
                self.assertIn("read_text_file", tool_names)
                self.assertIn("write_file", tool_names)
                self.assertIn("list_directory", tool_names)
            finally:
                try:
                    self._send(
                        parent,
                        {
                            "op": "stop",
                            "id": session_id,
                        },
                    )
                except OSError:
                    pass
                parent.close()
                process.terminate()
                process.wait(timeout=5)
                if process.stdout is not None:
                    self.assertEqual(process.stdout.read(), b"")
                    process.stdout.close()
                if process.stderr is not None:
                    self.assertEqual(process.stderr.read(), b"")
                    process.stderr.close()


if __name__ == "__main__":
    unittest.main()
