#!/usr/bin/env python3
"""Select the single supported M5 iPad simulator without launching a GUI."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any


DEVICE_NAME = "iPad Pro 13-inch (M5)"
RUNTIME_PATTERN = re.compile(
    r"^com\.apple\.CoreSimulator\.SimRuntime\.iOS-27(?:-[0-9]+)*$"
)
UDID_PATTERN = re.compile(
    r"^[0-9A-Fa-f]{8}-"
    r"[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{12}$"
)


def _read_devices(path: Path | None) -> dict[str, Any]:
    if path is not None:
        payload = path.read_text(encoding="utf-8")
    else:
        result = subprocess.run(
            ["xcrun", "simctl", "list", "--json", "devices", "available"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        payload = result.stdout

    decoded = json.loads(payload)
    if not isinstance(decoded, dict):
        raise TypeError("simctl device inventory must be a JSON object")
    return decoded


def select_simulator(inventory: dict[str, Any]) -> dict[str, str]:
    devices = inventory.get("devices")
    if not isinstance(devices, dict):
        raise ValueError("simctl device inventory has no devices object")

    matches: list[dict[str, str]] = []
    for runtime, runtime_devices in devices.items():
        if not isinstance(runtime, str) or not RUNTIME_PATTERN.fullmatch(
            runtime
        ):
            continue
        if not isinstance(runtime_devices, list):
            raise TypeError(f"simctl runtime {runtime} must contain a list")
        for device in runtime_devices:
            if not isinstance(device, dict):
                raise TypeError("simctl device entry must be an object")
            if (
                device.get("name") != DEVICE_NAME
                or device.get("isAvailable") is not True
            ):
                continue
            udid = device.get("udid")
            if not isinstance(udid, str) or not UDID_PATTERN.fullmatch(udid):
                raise ValueError("matching iPad simulator has a malformed UDID")
            matches.append(
                {
                    "udid": udid,
                    "name": DEVICE_NAME,
                    "runtimeIdentifier": runtime,
                }
            )

    if len(matches) != 1:
        raise ValueError(
            "expected exactly one available "
            f"{DEVICE_NAME} simulator on iOS 27; found {len(matches)}"
        )
    return matches[0]


def select_simulator_udid(inventory: dict[str, Any]) -> str:
    return select_simulator(inventory)["udid"]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Select the release-gate M5 iPad simulator."
    )
    parser.add_argument(
        "--devices-json",
        type=Path,
        help="read a simctl JSON fixture instead of invoking xcrun",
    )
    parser.add_argument(
        "--format",
        choices=("udid", "json"),
        default="udid",
        help="print only the UDID or the complete selected inventory record",
    )
    args = parser.parse_args()

    try:
        selected = select_simulator(
            _read_devices(args.devices_json)
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
