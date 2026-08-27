#!/usr/bin/env bash
set -euo pipefail

# Codex for iPad is validated only on the physical iPad.  This entrypoint is
# intentionally non-overridable: it must never copy, re-sign, or launch another
# desktop Codex/ChatGPT process in the user's active macOS session.
echo "Desktop Codex parity capture is permanently disabled" >&2
echo "Codex for iPad validation must run on the physical iPad only" >&2
exit 78
