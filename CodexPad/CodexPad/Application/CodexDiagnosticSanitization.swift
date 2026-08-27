import Foundation

/// Stable, non-sensitive error summaries for diagnostics persisted by the app.
public enum CodexDiagnosticSanitization {
    public static func publicErrorSummary(_ error: any Error) -> String {
        if let nsError = error as NSError? {
            return "\(String(describing: type(of: error))) code=\(nsError.code)"
        }
        return String(describing: type(of: error))
    }

    /// Persist only the endpoint identity needed to debug request routing:
    /// host and path, never a query, credential, header, or body.
    public static func networkFetchSummary(
        method: String,
        requestURL: String,
        status: Int,
        errorCode: String?
    ) -> String {
        let endpoint = networkFetchEndpoint(for: requestURL)
        let stage = errorCode == nil ? "response" : "transport"
        let suffix = errorCode.map { " errorCode=\($0)" } ?? ""
        return "fetch network \(method) \(endpoint) status=\(status)"
            + " stage=\(stage)"
            + suffix
    }

    private static func networkFetchEndpoint(for requestURL: String) -> String {
        if let components = URLComponents(string: requestURL),
           let scheme = components.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           let host = components.host?.lowercased()
        {
            return host + normalizedPath(components.path)
        }

        let pathOnly = requestURL.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? ""
        let suffix = pathOnly.drop(while: { $0 == "/" })
        return "chatgpt.com/backend-api" + normalizedPath(String(suffix))
    }

    private static func normalizedPath(_ path: String) -> String {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("/") ? value : "/" + value
    }
}
