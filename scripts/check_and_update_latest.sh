#!/usr/bin/env bash
set -euo pipefail

# Retained as a compatibility stub for old launchers. It must never perform a
# network check, download, install, or cleanup after automatic updates were
# removed from the iPad product.
echo "AUTOMATIC_UPDATE_DISABLED: automatic update checks are disabled" >&2
exit 78
