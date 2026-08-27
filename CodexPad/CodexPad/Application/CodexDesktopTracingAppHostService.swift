import Foundation

/// iPad-native tracing exporter matching the desktop `tracing.exportTraceBatch`
/// contract. The exporter is deliberately transport-injected so its retry,
/// endpoint and status semantics can be verified without a simulator or a
/// live telemetry endpoint.
public actor CodexDesktopTracingAppHostService {
  public typealias Value = CodexDesktopAppHostRPC.Value
  public typealias EndpointProvider = @Sendable () -> URL?
  public typealias Sleep = @Sendable (Duration) async throws -> Void

  public enum Error: Swift.Error, Equatable, Sendable {
    case invalidArguments
    case invalidTracePayload
    case invalidEndpoint
    case endpointNotAllowed
    case httpFailure(status: Int)
    case transportFailure
  }

  private let transport: any CodexDesktopNetworkFetchTransport
  private let endpointProvider: EndpointProvider
  private let sleep: Sleep
  private let timeout: TimeInterval
  private let defaultEndpoint: URL

  public init(
    transport: any CodexDesktopNetworkFetchTransport =
      CodexDesktopURLSessionNetworkFetchTransport(),
    endpointProvider: EndpointProvider? = nil,
    defaultEndpoint: URL = URL(
      string: "https://chatgpt.com/backend-api/o11y/v1/traces"
    )!,
    timeout: TimeInterval = 9,
    sleep: @escaping Sleep = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.transport = transport
    self.endpointProvider =
      endpointProvider ?? {
        guard
          let raw = ProcessInfo.processInfo.environment[
            "CODEX_OTEL_TRACES_ENDPOINT"
          ], !raw.isEmpty
        else { return nil }
        return URL(string: raw)
      }
    self.defaultEndpoint = defaultEndpoint
    self.timeout = timeout
    self.sleep = sleep
  }

  public func invoke(
    method: String,
    arguments: [Value]?
  ) async throws -> Value {
    switch method {
    case "exportTraceBatch":
      try await exportTraceBatch(arguments)
      return .undefined
    case "setSampleRate":
      guard let value = arguments?.first,
        arguments?.count == 1,
        finiteNumber(value) != nil
      else { throw Error.invalidArguments }
      return .undefined
    case "confirmTraceRecordingStart", "cancelTraceRecordingStart":
      try requireNoArguments(arguments)
      return .bool(false)
    case "submitTraceRecordingDetails":
      guard arguments?.count == 1,
        case .object? = arguments?.first
      else { throw Error.invalidArguments }
      return .bool(false)
    default:
      throw Error.invalidArguments
    }
  }

  private func exportTraceBatch(_ arguments: [Value]?) async throws {
    guard let arguments, arguments.count == 1 else {
      throw Error.invalidArguments
    }
    let body = try JSONValueEncoder.encode(arguments[0])
    let endpoint = try resolvedEndpoint()
    let request = CodexDesktopNetworkTransportRequest(
      url: endpoint,
      method: "POST",
      headers: ["Content-Type": "application/json"],
      body: body,
      timeoutInterval: timeout
    )

    var response: CodexDesktopNetworkTransportResponse
    do {
      response = try await transport.execute(request)
    } catch {
      try await sleep(.milliseconds(250))
      do {
        response = try await transport.execute(request)
      } catch {
        throw Error.transportFailure
      }
    }
    if (200..<300).contains(response.status) {
      return
    }
    if [429, 502, 503, 504].contains(response.status) {
      let delay = retryAfter(response.headers)
      try await sleep(.milliseconds(delay))
      do {
        response = try await transport.execute(request)
      } catch {
        throw Error.transportFailure
      }
      if (200..<300).contains(response.status) {
        return
      }
    }
    throw Error.httpFailure(status: response.status)
  }

  private func resolvedEndpoint() throws -> URL {
    guard let custom = endpointProvider() else {
      return defaultEndpoint
    }
    guard let scheme = custom.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      custom.user == nil,
      custom.password == nil,
      custom.query == nil,
      custom.fragment == nil,
      custom.host != nil
    else { throw Error.invalidEndpoint }
    guard isLoopback(custom) else { throw Error.endpointNotAllowed }
    return custom
  }

  private func isLoopback(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "[::1]"
      || host == "::1"
  }

  private func retryAfter(_ headers: [String: String]) -> Int64 {
    let value = headers.first { key, _ in
      key.lowercased() == "retry-after"
    }?.value
    guard let seconds = value.flatMap(Double.init), seconds.isFinite else {
      return 250
    }
    return Int64((min(2, max(0, seconds)) * 1000).rounded())
  }

  private func finiteNumber(_ value: Value) -> Double? {
    switch value {
    case .integer(let value): return Double(value)
    case .number(let value) where value.isFinite: return value
    default: return nil
    }
  }

  private func requireNoArguments(_ arguments: [Value]?) throws {
    guard arguments?.isEmpty != false else { throw Error.invalidArguments }
  }
}

private enum JSONValueEncoder {
  static func encode(
    _ value: CodexDesktopAppHostRPC.Value
  ) throws -> Data {
    let object = try foundationValue(value)
    guard JSONSerialization.isValidJSONObject(object) else {
      throw CodexDesktopTracingAppHostService.Error.invalidTracePayload
    }
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    )
  }

  private static func foundationValue(
    _ value: CodexDesktopAppHostRPC.Value
  ) throws -> Any {
    switch value {
    case .null: return NSNull()
    case .bool(let value): return value
    case .integer(let value): return value
    case .number(let value) where value.isFinite: return value
    case .string(let value): return value
    case .array(let values):
      return try values.map(foundationValue)
    case .object(let fields), .rpcObject(let fields):
      return try fields.reduce(into: [String: Any]()) { result, item in
        result[item.key] = try foundationValue(item.value)
      }
    default:
      throw CodexDesktopTracingAppHostService.Error.invalidTracePayload
    }
  }
}
