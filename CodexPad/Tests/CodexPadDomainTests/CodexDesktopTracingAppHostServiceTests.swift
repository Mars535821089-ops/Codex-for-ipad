import Foundation
import Testing

@testable import CodexPadApplication

private actor TracingTransport: CodexDesktopNetworkFetchTransport {
  enum Failure: Swift.Error { case failed }
  private var outcomes: [Result<CodexDesktopNetworkTransportResponse, Swift.Error>]
  private(set) var requests: [CodexDesktopNetworkTransportRequest] = []

  init(_ outcomes: [Result<CodexDesktopNetworkTransportResponse, Swift.Error>]) {
    self.outcomes = outcomes
  }

  func execute(
    _ request: CodexDesktopNetworkTransportRequest
  ) async throws -> CodexDesktopNetworkTransportResponse {
    requests.append(request)
    let outcome = outcomes.removeFirst()
    return try outcome.get()
  }

  func requestSnapshot() -> [CodexDesktopNetworkTransportRequest] {
    requests
  }
}

private actor SleepRecorder {
  private(set) var durations: [Duration] = []
  func record(_ duration: Duration) async throws {
    durations.append(duration)
  }
}

private func traceResponse(
  _ status: Int,
  headers: [String: String] = [:]
) -> CodexDesktopNetworkTransportResponse {
  .init(status: status, headers: headers, body: Data())
}

@Test
func tracingExportTraceBatchPostsJSONAndRetriesRetryableStatus() async throws {
  let transport = TracingTransport([
    .success(traceResponse(503, headers: ["Retry-After": "0.001"])),
    .success(traceResponse(204)),
  ])
  let sleeps = SleepRecorder()
  let service = CodexDesktopTracingAppHostService(
    transport: transport,
    endpointProvider: {
      URL(string: "http://127.0.0.1:4318/o11y/v1/traces")
    },
    sleep: { duration in
      try await sleeps.record(duration)
    }
  )

  let result = try await service.invoke(
    method: "exportTraceBatch",
    arguments: [
      .object([
        "resourceSpans": .array([
          .object(["scope": .string("codex")])
        ])
      ])
    ]
  )

  #expect(result == .undefined)
  let requests = await transport.requestSnapshot()
  #expect(requests.count == 2)
  #expect(requests.allSatisfy { $0.method == "POST" })
  #expect(requests.allSatisfy { $0.timeoutInterval == 9 })
  #expect(
    requests.allSatisfy {
      $0.headers["Content-Type"] == "application/json"
    })
  #expect(
    requests[0].body
      == Data(
        #"{"resourceSpans":[{"scope":"codex"}]}"#.utf8
      ))
  #expect(await sleeps.durations == [.milliseconds(1)])
}

@Test
func tracingExportTraceBatchRetriesOneTransportFailure() async throws {
  let transport = TracingTransport([
    .failure(TracingTransport.Failure.failed),
    .success(traceResponse(200)),
  ])
  let sleeps = SleepRecorder()
  let service = CodexDesktopTracingAppHostService(
    transport: transport,
    endpointProvider: {
      URL(string: "http://localhost:4318/v1/traces")
    },
    sleep: { duration in
      try await sleeps.record(duration)
    }
  )

  _ = try await service.invoke(
    method: "exportTraceBatch",
    arguments: [.object(["spans": .array([])])]
  )
  #expect((await transport.requestSnapshot()).count == 2)
  #expect(await sleeps.durations == [.milliseconds(250)])
}

@Test
func tracingRejectsNonLoopbackConfiguredEndpoint() async throws {
  let transport = TracingTransport([.success(traceResponse(200))])
  let service = CodexDesktopTracingAppHostService(
    transport: transport,
    endpointProvider: {
      URL(string: "https://telemetry.example.test/traces")
    }
  )

  await #expect(throws: CodexDesktopTracingAppHostService.Error.endpointNotAllowed) {
    try await service.invoke(
      method: "exportTraceBatch",
      arguments: [.object(["spans": .array([])])]
    )
  }
  #expect((await transport.requestSnapshot()).isEmpty)
}
