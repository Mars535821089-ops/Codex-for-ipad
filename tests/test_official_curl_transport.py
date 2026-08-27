import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
TRANSPORT = ROOT / "scripts/official_curl_transport.sh"


class OfficialCurlTransportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.trace = self.root / "trace"
        self.output = self.root / "headers"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_executable(self, name: str, body: str) -> None:
        path = self.bin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def _run(self, url: str) -> subprocess.CompletedProcess[str]:
        self.assertTrue(
            TRANSPORT.is_file(),
            "the reusable official CDN transport helper is missing",
        )
        environment = os.environ.copy()
        environment["PATH"] = f"{self.bin}:{environment['PATH']}"
        environment["TRACE"] = str(self.trace)
        return subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; official_curl "$2" --head --output "$3"',
                "official-curl-test",
                str(TRANSPORT),
                url,
                str(self.output),
            ],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_official_host_retries_directly_with_public_dns_after_proxy_tls_failure(
        self,
    ) -> None:
        self._write_executable(
            "curl",
            """#!/usr/bin/env bash
printf '%s\n' "CALL $*" >>"$TRACE"
if [[ " $* " != *" --resolve persistent.oaistatic.com:443:104.18.41.158 "* ]]; then
  echo 'proxy TLS failure' >&2
  exit 35
fi
output=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == '--output' ]]; then output="$2"; shift 2; continue; fi
  shift
done
printf 'HTTP/1.1 200 OK\ncontent-length: 638683081\n' >"$output"
""",
        )
        self._write_executable(
            "dig",
            """#!/usr/bin/env bash
printf '%s\n' 'DIG' >>"$TRACE"
printf '%s\n' '198.18.0.177' '104.18.41.158'
""",
        )

        result = self._run(
            "https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text(encoding="utf-8")
        self.assertEqual(trace.count("CALL "), 2)
        self.assertIn("DIG", trace)
        self.assertIn("--noproxy *", trace)
        self.assertIn(
            "--resolve persistent.oaistatic.com:443:104.18.41.158",
            trace,
        )
        self.assertNotIn(
            "--resolve persistent.oaistatic.com:443:198.18.0.177",
            trace,
        )
        self.assertIn("content-length: 638683081", self.output.read_text())

    def test_non_official_host_preserves_the_original_curl_failure(self) -> None:
        self._write_executable(
            "curl",
            """#!/usr/bin/env bash
printf '%s\n' "CALL $*" >>"$TRACE"
exit 7
""",
        )
        self._write_executable(
            "dig",
            """#!/usr/bin/env bash
printf '%s\n' 'DIG' >>"$TRACE"
exit 0
""",
        )

        result = self._run("https://example.invalid/ChatGPT.dmg")

        self.assertEqual(result.returncode, 7)
        trace = self.trace.read_text(encoding="utf-8")
        self.assertEqual(trace.count("CALL "), 1)
        self.assertNotIn("DIG", trace)


if __name__ == "__main__":
    unittest.main()
