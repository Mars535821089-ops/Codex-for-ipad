#!/usr/bin/env bash
set -euo pipefail

# Retained only so an old LaunchAgent fails closed after the feature removal.
echo "AUTOMATIC_UPDATE_DISABLED: iPad update request polling is disabled" >&2
exit 78
