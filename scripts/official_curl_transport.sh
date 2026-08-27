#!/usr/bin/env bash

official_curl() {
  local url="$1"
  shift

  local initial_status=0
  if command curl "$@" "$url"; then
    return 0
  else
    initial_status=$?
  fi

  local host
  host="$(
    python3 - "$url" <<'PY'
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1])
if (
    parsed.scheme == "https"
    and parsed.hostname == "persistent.oaistatic.com"
    and parsed.port in (None, 443)
    and parsed.username is None
    and parsed.password is None
):
    print(parsed.hostname)
PY
  )"
  if [[ "$host" != "persistent.oaistatic.com" ]]; then
    return "$initial_status"
  fi
  if ! command -v dig >/dev/null 2>&1; then
    return "$initial_status"
  fi

  local fallback_ip
  fallback_ip="$(
    command dig +time=3 +tries=1 +short @1.1.1.1 "$host" A 2>/dev/null |
      python3 -c '
import ipaddress
import sys

for line in sys.stdin:
    candidate = line.strip()
    try:
        address = ipaddress.ip_address(candidate)
    except ValueError:
        continue
    if address.version == 4 and address.is_global:
        print(address)
        break
'
  )"
  if [[ -z "$fallback_ip" ]]; then
    return "$initial_status"
  fi

  echo "Official CDN proxy route failed; retrying verified HTTPS directly" >&2
  command curl \
    --noproxy '*' \
    --resolve "$host:443:$fallback_ip" \
    "$@" \
    "$url"
}
