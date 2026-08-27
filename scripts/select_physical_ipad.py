#!/usr/bin/env python3
"""Select one connected, available physical iPad for release verification."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any


IOS_DEVICE_PLATFORM = "com.apple.platform.iphoneos"
UDID_PATTERN = re.compile(r"^[0-9A-Fa-f-]{20,64}$")


def _read_devices(path: Path | None) -> list[Any]:
    if path is not None:
        payload = path.read_text(encoding="utf-8")
    else:
        result = subprocess.run(
            ["xcrun", "xcdevice", "list", "--timeout", "5"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        payload = result.stdout

    decoded = json.loads(payload)
    if not isinstance(decoded, list):
        raise TypeError("xcdevice inventory must be a JSON array")
    return decoded


def select_physical_ipad(
    inventory: list[Any],
    selected_udid: str | None = None,
) -> dict[str, str]:
    if selected_udid is not None and not UDID_PATTERN.fullmatch(selected_udid):
        raise ValueError("requested physical iPad UDID is malformed")

    matches: list[dict[str, str]] = []
    for device in inventory:
        if not isinstance(device, dict):
            raise TypeError("xcdevice entry must be an object")
        model_name = device.get("modelName")
        if (
            device.get("platform") != IOS_DEVICE_PLATFORM
            or device.get("simulator") is not False
            or device.get("available") is not True
            or not isinstance(model_name, str)
            or "ipad" not in model_name.lower()
        ):
            continue
        udid = device.get("identifier")
        name = device.get("name")
        os_version = device.get("operatingSystemVersion")
        if not isinstance(udid, str) or not UDID_PATTERN.fullmatch(udid):
            raise ValueError("matching physical iPad has a malformed UDID")
        if not isinstance(name, str) or not name.strip():
            raise ValueError("matching physical iPad has no name")
        if not isinstance(os_version, str) or not os_version.strip():
            raise ValueError("matching physical iPad has no OS version")
        if selected_udid is not None and udid != selected_udid:
            continue
        matches.append(
            {
                "udid": udid,
                "name": name,
                "modelName": model_name,
                "operatingSystemVersion": os_version,
            }
        )

    if len(matches) != 1:
        qualifier = f" matching UDID {selected_udid}" if selected_udid else ""
        raise ValueError(
            "expected exactly one available physical iPad"
            f"{qualifier}; found {len(matches)}"
        )
    return matches[0]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Select the physical iPad release-verification target."
    )
    parser.add_argument(
        "--devices-json",
        type=Path,
        help="read an xcdevice JSON fixture instead of invoking xcrun",
    )
    parser.add_argument(
        "--udid",
        default=os.environ.get("CODEXPAD_DEVICE_UDID"),
        help="require this UDID (defaults to CODEXPAD_DEVICE_UDID)",
    )
    parser.add_argument(
        "--format",
        choices=("udid", "json"),
        default="udid",
        help="print only the UDID or the selected inventory record",
    )
    args = parser.parse_args()

    try:
        selected = select_physical_ipad(
            _read_devices(args.devices_json),
            args.udid,
        )
    except (
        json.JSONDecodeError,
        OSError,
        subprocess.CalledProcessError,
        TypeError,
        ValueError,
    ) as error:
        parser.error(str(error))

    if args.format == "json":
        print(json.dumps(selected, sort_keys=True))
    else:
        print(selected["udid"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
