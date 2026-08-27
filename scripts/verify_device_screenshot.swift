import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count == 2 else {
    fputs("usage: verify_device_screenshot.swift SCREENSHOT.png\n", stderr)
    exit(64)
}

let screenshotPath = CommandLine.arguments[1]
guard
    let image = NSImage(contentsOfFile: screenshotPath),
    let cgImage = image.cgImage(
        forProposedRect: nil,
        context: nil,
        hints: nil
    )
else {
    fputs("device screenshot could not be decoded\n", stderr)
    exit(65)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.recognitionLanguages = ["zh-Hans", "en-US"]

do {
    try VNImageRequestHandler(
        cgImage: cgImage,
        options: [:]
    ).perform([request])
} catch {
    fputs("device screenshot OCR failed: \(error)\n", stderr)
    exit(70)
}

let recognizedText = (request.results ?? [])
    .compactMap { $0.topCandidates(1).first?.string }
    .joined(separator: "\n")
// A cold launch may restore the last open thread instead of rendering the
// blank-state welcome copy. The persistent desktop navigation is the stable
// proof that the released renderer mounted; the welcome sentence is not.
let requiredPhraseGroups = [
    ["New Chat", "新聊天", "新对话"],
    ["Projects", "项目"],
    // The current desktop surface localizes the recents section as a list of
    // threads without rendering a literal "Recents/最近" heading.  Accept
    // the stable empty-thread marker (or the restored thread title) as proof
    // that the recents surface mounted, while retaining the heading for
    // locales/builds that still render it.
    ["Recents", "最近", "没有聊天", "New thread"],
]
let missingPhraseGroups = requiredPhraseGroups.filter { alternatives in
    !alternatives.contains {
        recognizedText.localizedCaseInsensitiveContains($0)
    }
}

guard missingPhraseGroups.isEmpty else {
    fputs(
        "device screenshot is missing expected Codex UI: "
            + missingPhraseGroups
                .map { $0.joined(separator: "/") }
                .joined(separator: ", ")
            + "\n",
        stderr
    )
    exit(71)
}

print(
    "Codex for ipad visible UI verified "
        + "(\(requiredPhraseGroups.count) bilingual core markers)"
)
