#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

public struct CodexFeedbackUploadParameters: Equatable, Sendable {
    public let classification: String
    public let reason: String?
    public let threadID: String?
    public let includeLogs: Bool
    public let extraLogFiles: [URL]
    public let tags: [String: String]

    public init(
        classification: String,
        reason: String?,
        threadID: String?,
        includeLogs: Bool,
        extraLogFiles: [URL],
        tags: [String: String]
    ) {
        self.classification = classification
        self.reason = reason
        self.threadID = threadID
        self.includeLogs = includeLogs
        self.extraLogFiles = extraLogFiles
        self.tags = tags
    }
}

@MainActor
public protocol CodexDesktopFeedbackUploading: AnyObject {
    func uploadFeedback(
        _ parameters: CodexFeedbackUploadParameters
    ) async throws -> String
}

public enum CodexFeedbackUploadError: Error, Equatable, Sendable {
    case invalidResponse
    case http(Int)
}

/// Native implementation of the released app-server `feedback/upload`
/// contract. The desktop implementation emits a Sentry envelope to this DSN;
/// iPad sends the same event shape and only includes logs when requested.
@MainActor
public final class CodexFeedbackUploadService:
    CodexDesktopFeedbackUploading
{
    public static let releasedDSN =
        "https://ae32ed50620d7a7792c1ce5df38b3e3e"
        + "@o33249.ingest.us.sentry.io/4510195390611458"

    private static let maximumAttachmentBytes = 4 * 1_024 * 1_024
    private static let maximumAttachmentCount = 16

    private let transport: any CodexDesktopNetworkFetchTransport
    private let endpoint: URL
    private let diagnosticsProvider: @MainActor () -> [String]
    private let fileManager: FileManager

    public init(
        transport:
            any CodexDesktopNetworkFetchTransport =
                CodexDesktopURLSessionNetworkFetchTransport(),
        endpoint: URL = CodexFeedbackUploadService.releasedEnvelopeEndpoint,
        diagnosticsProvider:
            @escaping @MainActor () -> [String] = { [] },
        fileManager: FileManager = .default
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.diagnosticsProvider = diagnosticsProvider
        self.fileManager = fileManager
    }

    public func uploadFeedback(
        _ parameters: CodexFeedbackUploadParameters
    ) async throws -> String {
        let trackingThreadID =
            parameters.threadID ?? UUID().uuidString.lowercased()
        let eventID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let envelope = try makeEnvelope(
            parameters,
            trackingThreadID: trackingThreadID,
            eventID: eventID
        )
        let response = try await transport.execute(
            CodexDesktopNetworkTransportRequest(
                url: endpoint,
                method: "POST",
                headers: [
                    "Content-Type":
                        "application/x-sentry-envelope",
                    "Accept": "application/json",
                ],
                body: envelope
            )
        )
        guard (200..<300).contains(response.status) else {
            throw CodexFeedbackUploadError.http(response.status)
        }
        return trackingThreadID
    }

    public static var releasedEnvelopeEndpoint: URL {
        URL(
            string:
                "https://o33249.ingest.us.sentry.io/api/"
                + "4510195390611458/envelope/"
                + "?sentry_key=ae32ed50620d7a7792c1ce5df38b3e3e"
                + "&sentry_version=7"
        )!
    }

    private struct Attachment {
        let filename: String
        let contentType: String
        let data: Data
    }

    private func makeEnvelope(
        _ parameters: CodexFeedbackUploadParameters,
        trackingThreadID: String,
        eventID: String
    ) throws -> Data {
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
        var tags = parameters.tags
        tags["thread_id"] = trackingThreadID
        tags["classification"] = parameters.classification
        tags["client"] = "Codex for ipad"
        tags["cli_version"] = CodexBuildMetadata.desktopVersion

        let title =
            "[\(displayClassification(parameters.classification))]: "
            + "Codex session \(trackingThreadID)"
        var event: [String: Any] = [
            "event_id": eventID,
            "timestamp": timestamp,
            "level": errorClassifications.contains(
                parameters.classification
            ) ? "error" : "info",
            "message": title,
            "platform": "native",
            "tags": tags,
        ]
        if let reason = parameters.reason {
            event["exception"] = [
                "values": [[
                    "type": title,
                    "value": reason,
                ]],
            ]
        }

        let eventData = try JSONSerialization.data(
            withJSONObject: event,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let envelopeHeader = try JSONSerialization.data(
            withJSONObject: [
                "event_id": eventID,
                "dsn": Self.releasedDSN,
                "sent_at": timestamp,
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let eventHeader = try JSONSerialization.data(
            withJSONObject: [
                "type": "event",
                "length": eventData.count,
            ],
            options: [.sortedKeys]
        )

        var envelope = Data()
        appendLine(envelopeHeader, to: &envelope)
        appendLine(eventHeader, to: &envelope)
        appendLine(eventData, to: &envelope)
        for attachment in attachments(for: parameters) {
            let header = try JSONSerialization.data(
                withJSONObject: [
                    "type": "attachment",
                    "length": attachment.data.count,
                    "filename": attachment.filename,
                    "content_type": attachment.contentType,
                    "attachment_type": "event.attachment",
                ],
                options: [.sortedKeys]
            )
            appendLine(header, to: &envelope)
            appendLine(attachment.data, to: &envelope)
        }
        return envelope
    }

    private func attachments(
        for parameters: CodexFeedbackUploadParameters
    ) -> [Attachment] {
        var attachments: [Attachment] = []
        if parameters.includeLogs {
            let diagnostics = diagnosticsProvider()
                .suffix(200)
                .joined(separator: "\n")
            if let data = diagnostics.data(using: .utf8),
               !data.isEmpty
            {
                attachments.append(
                    Attachment(
                        filename: "codex-logs.log",
                        contentType: "text/plain",
                        data: Data(
                            data.suffix(
                                Self.maximumAttachmentBytes
                            )
                        )
                    )
                )
            }
        }

        var seen = Set<String>()
        for file in parameters.extraLogFiles
            where attachments.count < Self.maximumAttachmentCount
        {
            let canonical = file.standardizedFileURL.path
            guard seen.insert(canonical).inserted,
                  fileManager.isReadableFile(atPath: canonical),
                  let handle = try? FileHandle(
                      forReadingFrom: file
                  )
            else { continue }
            defer { try? handle.close() }
            let data = (try? handle.read(
                upToCount: Self.maximumAttachmentBytes
            )) ?? nil
            guard let data, !data.isEmpty else { continue }
            attachments.append(
                Attachment(
                    filename: file.lastPathComponent,
                    contentType: contentType(for: file),
                    data: data
                )
            )
        }
        return attachments
    }

    private func contentType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "json", "jsonl":
            return "application/json"
        case "log", "txt":
            return "text/plain"
        default:
            return "application/octet-stream"
        }
    }

    private func displayClassification(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private var errorClassifications: Set<String> {
        ["bug", "bad_result", "safety_check"]
    }

    private func appendLine(_ data: Data, to destination: inout Data) {
        destination.append(data)
        destination.append(0x0A)
    }
}
