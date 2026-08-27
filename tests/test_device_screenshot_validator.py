import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class DeviceScreenshotValidatorTests(unittest.TestCase):
    @property
    def validator(self) -> Path:
        return (
            Path(__file__).parents[1]
            / "scripts"
            / "verify_device_screenshot.swift"
        )

    def test_accepts_ready_surface_when_stage_manager_hides_app_name(
        self,
    ) -> None:
        generator = textwrap.dedent(
            r'''
            import AppKit
            import Foundation

            let output = CommandLine.arguments[1]
            let size = NSSize(width: 1800, height: 1400)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.black.setFill()
            NSRect(origin: .zero, size: size).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 104),
                .foregroundColor: NSColor.white,
            ]
            let text = """
            New Chat
            Projects
            Recents
            Settings
            Ready when you are.
            """
            text.draw(
                in: NSRect(x: 120, y: 120, width: 1560, height: 1160),
                withAttributes: attributes
            )
            image.unlockFocus()
            guard
                let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else {
                fatalError("could not render fixture")
            }
            try png.write(to: URL(fileURLWithPath: output))
            '''
        )

        with tempfile.TemporaryDirectory() as directory:
            screenshot = Path(directory) / "stage-manager-surface.png"
            subprocess.run(
                ["xcrun", "swift", "-e", generator, str(screenshot)],
                check=True,
                capture_output=True,
                text=True,
            )
            result = subprocess.run(
                ["xcrun", "swift", str(self.validator), str(screenshot)],
                capture_output=True,
                text=True,
            )

        self.assertEqual(
            result.returncode,
            0,
            msg=result.stdout + result.stderr,
        )

    def test_accepts_current_simplified_chinese_desktop_surface(self) -> None:
        generator = textwrap.dedent(
            r'''
            import AppKit
            import Foundation

            let output = CommandLine.arguments[1]
            let size = NSSize(width: 1800, height: 1400)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.black.setFill()
            NSRect(origin: .zero, size: size).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 104),
                .foregroundColor: NSColor.white,
            ]
            let text = """
            Codex
            新对话
            项目
            最近
            我们该构建什么？
            """
            text.draw(
                in: NSRect(x: 120, y: 120, width: 1560, height: 1160),
                withAttributes: attributes
            )
            image.unlockFocus()
            guard
                let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else {
                fatalError("could not render fixture")
            }
            try png.write(to: URL(fileURLWithPath: output))
            '''
        )

        with tempfile.TemporaryDirectory() as directory:
            screenshot = Path(directory) / "zh-hans-desktop-surface.png"
            subprocess.run(
                ["xcrun", "swift", "-e", generator, str(screenshot)],
                check=True,
                capture_output=True,
                text=True,
            )
            result = subprocess.run(
                ["xcrun", "swift", str(self.validator), str(screenshot)],
                capture_output=True,
                text=True,
            )

        self.assertEqual(
            result.returncode,
            0,
            msg=result.stdout + result.stderr,
        )

    def test_accepts_restored_thread_without_blank_state_welcome(self) -> None:
        generator = textwrap.dedent(
            r'''
            import AppKit
            import Foundation

            let output = CommandLine.arguments[1]
            let size = NSSize(width: 1800, height: 1400)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.black.setFill()
            NSRect(origin: .zero, size: size).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 104),
                .foregroundColor: NSColor.white,
            ]
            let text = """
            Codex
            新对话
            项目
            最近
            Reply with S04_DEVICE_RESPONSE_OK only.
            S04_DEVICE_RESPONSE_OK
            随心输入
            """
            text.draw(
                in: NSRect(x: 120, y: 120, width: 1560, height: 1160),
                withAttributes: attributes
            )
            image.unlockFocus()
            guard
                let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else {
                fatalError("could not render fixture")
            }
            try png.write(to: URL(fileURLWithPath: output))
            '''
        )

        with tempfile.TemporaryDirectory() as directory:
            screenshot = Path(directory) / "restored-thread-surface.png"
            subprocess.run(
                ["xcrun", "swift", "-e", generator, str(screenshot)],
                check=True,
                capture_output=True,
                text=True,
            )
            result = subprocess.run(
                ["xcrun", "swift", str(self.validator), str(screenshot)],
                capture_output=True,
                text=True,
            )

        self.assertEqual(
            result.returncode,
            0,
            msg=result.stdout + result.stderr,
        )


if __name__ == "__main__":
    unittest.main()
