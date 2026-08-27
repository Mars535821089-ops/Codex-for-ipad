#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public enum CodexRemoteControlHTTPEndpoint: String, Equatable, Sendable {
    case enroll
    case refresh
    case pair
    case pairStatus
    case clientList
    case clientRevoke
}

public enum CodexRemoteControlHTTPFailureClassification: String, Equatable,
    Sendable
{
    case invalidInput
    case permissionDenied
    case notFound
    case other
}

public enum CodexRemoteControlHTTPError: Error, Equatable, Sendable {
    case invalidBaseURL(String)
    case invalidValue(field: String)
    case invalidHeader(field: String)
    case invalidLimit(UInt32)
    case nonHTTPResponse
    case transport(
        endpoint: CodexRemoteControlHTTPEndpoint,
        message: String
    )
    case timeout(endpoint: CodexRemoteControlHTTPEndpoint)
    case httpStatus(
        endpoint: CodexRemoteControlHTTPEndpoint,
        statusCode: Int,
        classification: CodexRemoteControlHTTPFailureClassification
    )
    case decoding(endpoint: CodexRemoteControlHTTPEndpoint)
    case invalidTimestamp(field: String, value: String)
    case mismatchedEnrollment(
        expectedServerID: String,
        expectedEnvironmentID: String,
        actualServerID: String,
        actualEnvironmentID: String
    )
}

extension CodexRemoteControlHTTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(url):
            "Invalid remote control base URL: \(url)"
        case let .invalidValue(field):
            "Remote control requires a non-empty \(field)"
        case let .invalidHeader(field):
            "Remote control \(field) is not a valid HTTP header value"
        case let .invalidLimit(limit):
            "Remote control client list limit \(limit) is outside 1...100"
        case .nonHTTPResponse:
            "Remote control received a non-HTTP response"
        case let .transport(endpoint, message):
            "Remote control \(endpoint.rawValue) transport failed: \(message)"
        case let .timeout(endpoint):
            "Remote control \(endpoint.rawValue) timed out after 30 seconds"
        case let .httpStatus(endpoint, statusCode, classification):
            "Remote control \(endpoint.rawValue) failed with HTTP \(statusCode) (\(classification.rawValue))"
        case let .decoding(endpoint):
            "Remote control \(endpoint.rawValue) response could not be decoded"
        case let .invalidTimestamp(field, value):
            "Remote control \(field) is not RFC3339: \(value)"
        case let .mismatchedEnrollment(
            expectedServerID,
            expectedEnvironmentID,
            actualServerID,
            actualEnvironmentID
        ):
            "Remote control enrollment mismatch: expected \(expectedServerID)/\(expectedEnvironmentID), received \(actualServerID)/\(actualEnvironmentID)"
        }
    }
}

public struct CodexRemoteControlAccountAuth: Equatable, Sendable {
    public let accessToken: String
    public let accountID: String
    public let providerHeaders: [String: String]

    public init(
        accessToken: String,
        accountID: String,
        providerHeaders: [String: String] = [:]
    ) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.providerHeaders = providerHeaders
    }
}

public struct CodexRemoteControlHTTPHeaderContext: Equatable, Sendable {
    public static let defaultOriginator = "codex_desktop"
    public static let defaultUserAgent =
        "\(defaultOriginator)/\(CodexBuildMetadata.embeddedCliVersion)"

    public let originator: String
    public let userAgent: String
    public let residency: String?

    public init(
        originator: String = Self.defaultOriginator,
        userAgent: String = Self.defaultUserAgent,
        residency: String? = nil
    ) {
        self.originator = originator
        self.userAgent = userAgent
        self.residency = residency
    }
}

public struct CodexRemoteControlHTTPEnrollment: Equatable, Sendable {
    public let serverID: String
    public let environmentID: String
    public let remoteControlToken: String
    public let expiresAt: Int64
    public let accountID: String

    public init(
        serverID: String,
        environmentID: String,
        remoteControlToken: String,
        expiresAt: Int64,
        accountID: String = ""
    ) {
        self.serverID = serverID
        self.environmentID = environmentID
        self.remoteControlToken = remoteControlToken
        self.expiresAt = expiresAt
        self.accountID = accountID
    }
}

public typealias CodexRemoteControlAuthRecovery =
    @Sendable () async throws -> CodexRemoteControlAccountAuth?

public protocol CodexRemoteControlHTTPExecuting: Sendable {
    func execute(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse)
}

public struct CodexRemoteControlURLSessionHTTPExecutor:
    CodexRemoteControlHTTPExecuting,
    Sendable
{
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CodexRemoteControlHTTPError.nonHTTPResponse
        }
        return (data, response)
    }
}

public enum CodexRemoteControlRFC3339 {
    public static func unixSeconds(
        from value: String,
        field: String
    ) throws -> Int64 {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20,
              bytes[4] == ascii("-"),
              bytes[7] == ascii("-"),
              bytes[13] == ascii(":"),
              bytes[16] == ascii(":"),
              let year = decimal(bytes, start: 0, count: 4),
              let month = decimal(bytes, start: 5, count: 2),
              let day = decimal(bytes, start: 8, count: 2),
              let hour = decimal(bytes, start: 11, count: 2),
              let minute = decimal(bytes, start: 14, count: 2),
              let second = decimal(bytes, start: 17, count: 2),
              (1...12).contains(month),
              (1...daysInMonth(year: year, month: month)).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second)
        else {
            throw invalidTimestamp(field: field, value: value)
        }

        // time::Rfc3339 consumes exactly one separator byte and deliberately
        // does not require `T`; the released implementation therefore also
        // accepts a space (and any other single ASCII separator).
        guard bytes[10] < 0x80 else {
            throw invalidTimestamp(field: field, value: value)
        }

        var index = 19
        if bytes[index] == ascii(".") {
            index += 1
            let fractionalStart = index
            while index < bytes.count, isDigit(bytes[index]) {
                index += 1
            }
            guard index > fractionalStart else {
                throw invalidTimestamp(field: field, value: value)
            }
        }

        let offsetSeconds: Int64
        if index < bytes.count,
           bytes[index] == ascii("Z") || bytes[index] == ascii("z")
        {
            guard index + 1 == bytes.count else {
                throw invalidTimestamp(field: field, value: value)
            }
            offsetSeconds = 0
        } else {
            guard index + 6 == bytes.count,
                  bytes[index] == ascii("+")
                    || bytes[index] == ascii("-"),
                  bytes[index + 3] == ascii(":"),
                  let offsetHour = decimal(
                    bytes,
                    start: index + 1,
                    count: 2
                  ),
                  let offsetMinute = decimal(
                    bytes,
                    start: index + 4,
                    count: 2
                  ),
                  (0...23).contains(offsetHour),
                  (0...59).contains(offsetMinute)
            else {
                throw invalidTimestamp(field: field, value: value)
            }
            let magnitude = Int64(offsetHour * 3_600 + offsetMinute * 60)
            offsetSeconds = bytes[index] == ascii("-")
                ? -magnitude
                : magnitude
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let standInSecond = min(second, 59)
        let localSeconds = days * 86_400
            + Int64(hour * 3_600 + minute * 60 + standInSecond)
        let timestamp = localSeconds - offsetSeconds

        if second == 60 {
            // `time::Rfc3339` represents a leap second as the preceding
            // 23:59:59.999999999 UTC and only permits it at a UTC month end.
            let nextSecond = timestamp + 1
            guard floorMod(nextSecond, divisor: 86_400) == 0 else {
                throw invalidTimestamp(field: field, value: value)
            }
            let nextUTCDate = civilFromDays(
                floorDiv(nextSecond, divisor: 86_400)
            )
            guard nextUTCDate.day == 1 else {
                throw invalidTimestamp(field: field, value: value)
            }
        }

        return timestamp
    }

    public static func string(fromUnixSeconds seconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(seconds))
        )
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (ascii("0")...ascii("9")).contains(byte)
    }

    private static func decimal(
        _ bytes: [UInt8],
        start: Int,
        count: Int
    ) -> Int? {
        guard start >= 0, count > 0, start + count <= bytes.count else {
            return nil
        }
        var result = 0
        for byte in bytes[start..<(start + count)] {
            guard isDigit(byte) else {
                return nil
            }
            result = result * 10 + Int(byte - ascii("0"))
        }
        return result
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = year.isMultiple(of: 4)
                && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    // Proleptic Gregorian conversion with 1970-01-01 as day zero.
    private static func daysFromCivil(
        year: Int,
        month: Int,
        day: Int
    ) -> Int64 {
        var adjustedYear = Int64(year)
        if month <= 2 {
            adjustedYear -= 1
        }
        let era = floorDiv(adjustedYear, divisor: 400)
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = Int64(month + (month > 2 ? -3 : 9))
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + Int64(day - 1)
        let dayOfEra = yearOfEra * 365
            + yearOfEra / 4
            - yearOfEra / 100
            + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(
        _ daysSince1970: Int64
    ) -> (year: Int, month: Int, day: Int) {
        let shifted = daysSince1970 + 719_468
        let era = floorDiv(shifted, divisor: 146_097)
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (
            dayOfEra
                - dayOfEra / 1_460
                + dayOfEra / 36_524
                - dayOfEra / 146_096
        ) / 365
        var year = yearOfEra + era * 400
        let dayOfYear = dayOfEra
            - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        if month <= 2 {
            year += 1
        }
        return (Int(year), Int(month), Int(day))
    }

    private static func floorDiv(
        _ value: Int64,
        divisor: Int64
    ) -> Int64 {
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? quotient - 1 : quotient
    }

    private static func floorMod(
        _ value: Int64,
        divisor: Int64
    ) -> Int64 {
        value - floorDiv(value, divisor: divisor) * divisor
    }

    private static func invalidTimestamp(
        field: String,
        value: String
    ) -> CodexRemoteControlHTTPError {
        CodexRemoteControlHTTPError.invalidTimestamp(
            field: field,
            value: value
        )
    }
}

public struct CodexRemoteControlHTTPTransport: Sendable {
    public static let defaultBaseURL =
        URL(string: "https://chatgpt.com/backend-api/")!
    public static let requestTimeout: TimeInterval = 30

    public let baseURL: URL
    public let headerContext: CodexRemoteControlHTTPHeaderContext

    private let executor: any CodexRemoteControlHTTPExecuting
    private let authRecovery: CodexRemoteControlAuthRecovery?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        baseURL: URL = Self.defaultBaseURL,
        executor: any CodexRemoteControlHTTPExecuting =
            CodexRemoteControlURLSessionHTTPExecutor(),
        headerContext: CodexRemoteControlHTTPHeaderContext = .init(),
        authRecovery: CodexRemoteControlAuthRecovery? = nil
    ) throws {
        self.baseURL = try Self.normalize(baseURL)
        try Self.validateHeaderContext(headerContext)
        self.headerContext = headerContext
        self.executor = executor
        self.authRecovery = authRecovery
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public func enroll(
        auth: CodexRemoteControlAccountAuth,
        installationID: String,
        serverName: String,
        operatingSystem: String,
        architecture: String,
        appServerVersion: String
    ) async throws -> CodexRemoteControlHTTPEnrollment {
        try validateAccountAuth(auth)
        try validateHeader(installationID, field: "installationId")
        let request = EnrollRemoteServerRequest(
            name: serverName,
            operatingSystem: operatingSystem,
            architecture: architecture,
            appServerVersion: appServerVersion,
            installationID: installationID
        )
        let response: EnrollRemoteServerResponse = try await sendJSON(
            endpoint: .enroll,
            method: "POST",
            pathSegments: [
                "wham", "remote", "control", "server", "enroll",
            ],
            body: request,
            accountAuth: auth,
            serverToken: nil,
            installationID: installationID
        )
        return try enrollment(
            from: response,
            endpoint: .enroll,
            accountID: auth.accountID
        )
    }

    public func refresh(
        auth: CodexRemoteControlAccountAuth,
        installationID: String,
        serverID: String,
        environmentID: String
    ) async throws -> CodexRemoteControlHTTPEnrollment {
        try validateAccountAuth(auth)
        try validateHeader(installationID, field: "installationId")
        try validateNonEmpty(serverID, field: "serverId")
        try validateNonEmpty(environmentID, field: "environmentId")
        let request = RefreshRemoteServerRequest(
            serverID: serverID,
            installationID: installationID
        )
        let response: EnrollRemoteServerResponse = try await sendJSON(
            endpoint: .refresh,
            method: "POST",
            pathSegments: [
                "wham", "remote", "control", "server", "refresh",
            ],
            body: request,
            accountAuth: auth,
            serverToken: nil,
            installationID: installationID
        )
        try validateEnrollmentIdentity(
            response,
            serverID: serverID,
            environmentID: environmentID
        )
        return try enrollment(
            from: response,
            endpoint: .refresh,
            accountID: auth.accountID
        )
    }

    public func startPairing(
        serverToken: String,
        serverID: String,
        environmentID: String,
        manualCode: Bool
    ) async throws -> CodexRemoteControlPairingStartResponse {
        try validateHeader(serverToken, field: "remoteControlToken")
        try validateNonEmpty(serverID, field: "serverId")
        try validateNonEmpty(environmentID, field: "environmentId")
        let response: StartRemoteControlPairingResponse = try await sendJSON(
            endpoint: .pair,
            method: "POST",
            pathSegments: [
                "wham", "remote", "control", "server", "pair",
            ],
            body: StartRemoteControlPairingRequest(manualCode: manualCode),
            accountAuth: nil,
            serverToken: serverToken,
            installationID: nil
        )
        guard response.serverID == serverID,
              response.environmentID == environmentID
        else {
            throw CodexRemoteControlHTTPError.mismatchedEnrollment(
                expectedServerID: serverID,
                expectedEnvironmentID: environmentID,
                actualServerID: response.serverID,
                actualEnvironmentID: response.environmentID
            )
        }
        return CodexRemoteControlPairingStartResponse(
            pairingCode: response.pairingCode,
            manualPairingCode: response.manualPairingCode,
            environmentId: response.environmentID,
            expiresAt: try CodexRemoteControlRFC3339.unixSeconds(
                from: response.expiresAt,
                field: "expires_at"
            )
        )
    }

    public func pairingStatus(
        serverToken: String,
        pairingCode: String? = nil,
        manualPairingCode: String? = nil
    ) async throws -> CodexRemoteControlPairingStatusResponse {
        try validateHeader(serverToken, field: "remoteControlToken")
        let pairingCodePresent = pairingCode != nil
        let manualCodePresent = manualPairingCode != nil
        guard pairingCodePresent != manualCodePresent else {
            throw CodexRemoteControlHTTPError.invalidValue(
                field: "exactly one pairingCode or manualPairingCode"
            )
        }
        let response: RemoteControlPairingStatusResponse = try await sendJSON(
            endpoint: .pairStatus,
            method: "POST",
            pathSegments: [
                "wham", "remote", "control", "server", "pair", "status",
            ],
            body: RemoteControlPairingStatusRequest(
                pairingCode: pairingCodePresent ? pairingCode : nil,
                manualPairingCode: manualCodePresent
                    ? manualPairingCode
                    : nil
            ),
            accountAuth: nil,
            serverToken: serverToken,
            installationID: nil
        )
        return CodexRemoteControlPairingStatusResponse(
            claimed: response.claimed
        )
    }

    public func listClients(
        auth: CodexRemoteControlAccountAuth,
        params: CodexRemoteControlClientsListParams
    ) async throws -> CodexRemoteControlClientsListResponse {
        try validateAccountAuth(auth)
        try validateNonEmpty(params.environmentId, field: "environmentId")
        if let limit = params.limit, !(1...100).contains(limit) {
            throw CodexRemoteControlHTTPError.invalidLimit(limit)
        }
        var queryItems: [URLQueryItem] = []
        if let cursor = params.cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let limit = params.limit {
            queryItems.append(
                URLQueryItem(name: "limit", value: String(limit))
            )
        }
        if let order = params.order {
            queryItems.append(
                URLQueryItem(name: "order", value: order.rawValue)
            )
        }
        let path = [
            "wham", "remote", "control", "environments",
            params.environmentId, "clients",
        ]
        let raw = try await sendClientManagement(
            endpoint: .clientList,
            method: "GET",
            pathSegments: path,
            queryItems: queryItems,
            auth: auth
        )
        let response: ListRemoteControlClientsResponse = try decode(
            raw.data,
            endpoint: .clientList
        )
        return CodexRemoteControlClientsListResponse(
            data: try response.items.map(client(from:)),
            nextCursor: response.cursor
        )
    }

    public func revokeClient(
        auth: CodexRemoteControlAccountAuth,
        params: CodexRemoteControlClientsRevokeParams
    ) async throws -> CodexRemoteControlClientsRevokeResponse {
        try validateAccountAuth(auth)
        try validateNonEmpty(params.environmentId, field: "environmentId")
        try validateNonEmpty(params.clientId, field: "clientId")
        _ = try await sendClientManagement(
            endpoint: .clientRevoke,
            method: "DELETE",
            pathSegments: [
                "wham", "remote", "control", "environments",
                params.environmentId, "clients", params.clientId,
            ],
            queryItems: [],
            auth: auth
        )
        return CodexRemoteControlClientsRevokeResponse()
    }

    private func sendJSON<Request: Encodable, Response: Decodable>(
        endpoint: CodexRemoteControlHTTPEndpoint,
        method: String,
        pathSegments: [String],
        body: Request,
        accountAuth: CodexRemoteControlAccountAuth?,
        serverToken: String?,
        installationID: String?
    ) async throws -> Response {
        var request = URLRequest(
            url: try makeURL(pathSegments: pathSegments),
            timeoutInterval: Self.requestTimeout
        )
        applyDefaultHeaders(to: &request)
        request.httpMethod = method
        request.httpBody = try encode(body, endpoint: endpoint)
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        if let accountAuth {
            apply(accountAuth, to: &request)
        }
        if let serverToken {
            replaceHeader(
                named: "Authorization",
                value: "Bearer \(serverToken)",
                in: &request
            )
        }
        if let installationID {
            request.setValue(
                installationID,
                forHTTPHeaderField: "x-codex-installation-id"
            )
        }
        let raw = try await perform(request, endpoint: endpoint)
        try ensureSuccess(raw.response, endpoint: endpoint)
        return try decode(raw.data, endpoint: endpoint)
    }

    private func sendClientManagement(
        endpoint: CodexRemoteControlHTTPEndpoint,
        method: String,
        pathSegments: [String],
        queryItems: [URLQueryItem],
        auth: CodexRemoteControlAccountAuth
    ) async throws -> HTTPResult {
        let first = try await perform(
            try clientManagementRequest(
                method: method,
                pathSegments: pathSegments,
                queryItems: queryItems,
                auth: auth
            ),
            endpoint: endpoint
        )
        guard first.response.statusCode == 401,
              let authRecovery
        else {
            try ensureSuccess(first.response, endpoint: endpoint)
            return first
        }

        let recoveredAuth: CodexRemoteControlAccountAuth?
        do {
            recoveredAuth = try await authRecovery()
        } catch {
            try ensureSuccess(first.response, endpoint: endpoint)
            return first
        }
        guard let recoveredAuth else {
            try ensureSuccess(first.response, endpoint: endpoint)
            return first
        }
        try validateAccountAuth(recoveredAuth)
        let retry = try await perform(
            try clientManagementRequest(
                method: method,
                pathSegments: pathSegments,
                queryItems: queryItems,
                auth: recoveredAuth
            ),
            endpoint: endpoint
        )
        try ensureSuccess(retry.response, endpoint: endpoint)
        return retry
    }

    private func clientManagementRequest(
        method: String,
        pathSegments: [String],
        queryItems: [URLQueryItem],
        auth: CodexRemoteControlAccountAuth
    ) throws -> URLRequest {
        var request = URLRequest(
            url: try makeURL(
                pathSegments: pathSegments,
                queryItems: queryItems
            ),
            timeoutInterval: Self.requestTimeout
        )
        applyDefaultHeaders(to: &request)
        request.httpMethod = method
        apply(auth, to: &request)
        return request
    }

    private func perform(
        _ request: URLRequest,
        endpoint: CodexRemoteControlHTTPEndpoint
    ) async throws -> HTTPResult {
        do {
            let (data, response) = try await executor.execute(request)
            return HTTPResult(data: data, response: response)
        } catch let error as CodexRemoteControlHTTPError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw CodexRemoteControlHTTPError.timeout(endpoint: endpoint)
        } catch {
            throw CodexRemoteControlHTTPError.transport(
                endpoint: endpoint,
                message: String(describing: error)
            )
        }
    }

    private func ensureSuccess(
        _ response: HTTPURLResponse,
        endpoint: CodexRemoteControlHTTPEndpoint
    ) throws {
        guard (200...299).contains(response.statusCode) else {
            throw CodexRemoteControlHTTPError.httpStatus(
                endpoint: endpoint,
                statusCode: response.statusCode,
                classification: Self.classification(
                    statusCode: response.statusCode,
                    endpoint: endpoint
                )
            )
        }
    }

    private func encode<Value: Encodable>(
        _ value: Value,
        endpoint: CodexRemoteControlHTTPEndpoint
    ) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw CodexRemoteControlHTTPError.transport(
                endpoint: endpoint,
                message: "request encoding failed"
            )
        }
    }

    private func decode<Value: Decodable>(
        _ data: Data,
        endpoint: CodexRemoteControlHTTPEndpoint
    ) throws -> Value {
        do {
            return try decoder.decode(Value.self, from: data)
        } catch let error as CodexRemoteControlHTTPError {
            throw error
        } catch {
            throw CodexRemoteControlHTTPError.decoding(endpoint: endpoint)
        }
    }

    private func enrollment(
        from response: EnrollRemoteServerResponse,
        endpoint: CodexRemoteControlHTTPEndpoint,
        accountID: String
    ) throws -> CodexRemoteControlHTTPEnrollment {
        try validateNonEmpty(response.serverID, field: "server_id")
        try validateNonEmpty(
            response.environmentID,
            field: "environment_id"
        )
        try validateNonEmpty(
            response.remoteControlToken,
            field: "remote_control_token"
        )
        return CodexRemoteControlHTTPEnrollment(
            serverID: response.serverID,
            environmentID: response.environmentID,
            remoteControlToken: response.remoteControlToken,
            expiresAt: try CodexRemoteControlRFC3339.unixSeconds(
                from: response.expiresAt,
                field: endpoint == .enroll
                    ? "enroll.expires_at"
                    : "refresh.expires_at"
            ),
            accountID: accountID
        )
    }

    private func validateEnrollmentIdentity(
        _ response: EnrollRemoteServerResponse,
        serverID: String,
        environmentID: String
    ) throws {
        guard response.serverID == serverID,
              response.environmentID == environmentID
        else {
            throw CodexRemoteControlHTTPError.mismatchedEnrollment(
                expectedServerID: serverID,
                expectedEnvironmentID: environmentID,
                actualServerID: response.serverID,
                actualEnvironmentID: response.environmentID
            )
        }
    }

    private func client(
        from response: RemoteControlClientResponse
    ) throws -> CodexRemoteControlClient {
        try validateNonEmpty(response.clientID, field: "client_id")
        return CodexRemoteControlClient(
            clientId: response.clientID,
            displayName: response.displayName,
            deviceType: response.deviceType,
            platform: response.platform,
            osVersion: response.osVersion,
            deviceModel: response.deviceModel,
            appVersion: response.appVersion,
            lastSeenAt: try response.lastSeenAt.map {
                try CodexRemoteControlRFC3339.unixSeconds(
                    from: $0,
                    field: "last_seen_at"
                )
            }
        )
    }

    private func applyDefaultHeaders(to request: inout URLRequest) {
        replaceHeader(
            named: "originator",
            value: headerContext.originator,
            in: &request
        )
        replaceHeader(
            named: "User-Agent",
            value: headerContext.userAgent,
            in: &request
        )
        if let residency = headerContext.residency {
            replaceHeader(
                named: "x-openai-internal-codex-residency",
                value: residency,
                in: &request
            )
        }
    }

    private func apply(
        _ auth: CodexRemoteControlAccountAuth,
        to request: inout URLRequest
    ) {
        for (name, value) in auth.providerHeaders {
            replaceHeader(named: name, value: value, in: &request)
        }
        // Match HeaderMap::insert: the selected identity is the only value,
        // regardless of casing or duplicate provider-supplied values.
        replaceHeader(
            named: "Authorization",
            value: "Bearer \(auth.accessToken)",
            in: &request
        )
        replaceHeader(
            named: "chatgpt-account-id",
            value: auth.accountID,
            in: &request
        )
    }

    private func replaceHeader(
        named name: String,
        value: String,
        in request: inout URLRequest
    ) {
        var headers = request.allHTTPHeaderFields ?? [:]
        for existingName in Array(headers.keys) where
            existingName.caseInsensitiveCompare(name) == .orderedSame
        {
            headers.removeValue(forKey: existingName)
        }
        headers[name] = value
        request.allHTTPHeaderFields = headers
    }

    private func validateAccountAuth(
        _ auth: CodexRemoteControlAccountAuth
    ) throws {
        try validateHeader(auth.accessToken, field: "accessToken")
        try validateHeader(auth.accountID, field: "accountId")
        for (name, value) in auth.providerHeaders {
            try Self.validateHeaderName(name)
            try Self.validateHeaderValue(
                value,
                field: "providerHeaders[\(name)]",
                allowsEmpty: true
            )
        }
    }

    private func validateNonEmpty(
        _ value: String,
        field: String
    ) throws {
        guard !value.isEmpty else {
            throw CodexRemoteControlHTTPError.invalidValue(field: field)
        }
    }

    private func validateHeader(
        _ value: String,
        field: String
    ) throws {
        try Self.validateHeaderValue(
            value,
            field: field,
            allowsEmpty: false
        )
    }

    private static func validateHeaderContext(
        _ context: CodexRemoteControlHTTPHeaderContext
    ) throws {
        try validateHeaderValue(
            context.originator,
            field: "originator",
            allowsEmpty: false
        )
        try validateHeaderValue(
            context.userAgent,
            field: "User-Agent",
            allowsEmpty: false
        )
        if let residency = context.residency {
            try validateHeaderValue(
                residency,
                field: "x-openai-internal-codex-residency",
                allowsEmpty: false
            )
        }
    }

    private static func validateHeaderName(_ name: String) throws {
        guard !name.isEmpty else {
            throw CodexRemoteControlHTTPError.invalidValue(
                field: "provider header name"
            )
        }
        let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
        guard name.utf8.allSatisfy({ byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || punctuation.contains(byte)
        }) else {
            throw CodexRemoteControlHTTPError.invalidHeader(
                field: "provider header name"
            )
        }
    }

    private static func validateHeaderValue(
        _ value: String,
        field: String,
        allowsEmpty: Bool
    ) throws {
        if !allowsEmpty, value.isEmpty {
            throw CodexRemoteControlHTTPError.invalidValue(field: field)
        }
        guard value.unicodeScalars.allSatisfy({
            (0x20...0x7E).contains($0.value)
        }) else {
            throw CodexRemoteControlHTTPError.invalidHeader(field: field)
        }
    }

    private func makeURL(
        pathSegments: [String],
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw CodexRemoteControlHTTPError.invalidBaseURL(
                baseURL.absoluteString
            )
        }
        var path = components.percentEncodedPath
        if !path.hasSuffix("/") {
            path.append("/")
        }
        path.append(
            try pathSegments.map(Self.encodePathSegment).joined(
                separator: "/"
            )
        )
        components.percentEncodedPath = path
        components.query = nil
        components.fragment = nil
        components.percentEncodedQuery = queryItems.isEmpty
            ? nil
            : queryItems.map { item in
                "\(Self.encodeFormComponent(item.name))=\(Self.encodeFormComponent(item.value ?? ""))"
            }.joined(separator: "&")
        guard let url = components.url else {
            throw CodexRemoteControlHTTPError.invalidBaseURL(
                baseURL.absoluteString
            )
        }
        return url
    }

    private static func encodeFormComponent(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "*"),
                 UInt8(ascii: "-"),
                 UInt8(ascii: "."),
                 UInt8(ascii: "_"):
                result.unicodeScalars.append(UnicodeScalar(byte))
            case UInt8(ascii: " "):
                result.append("+")
            default:
                result.append(
                    String(format: "%%%02X", Int(byte))
                )
            }
        }
        return result
    }

    private static func encodePathSegment(_ value: String) throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = value.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) else {
            throw CodexRemoteControlHTTPError.invalidValue(
                field: "URL path segment"
            )
        }
        return encoded
    }

    private static func normalize(_ url: URL) throws -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        let rawScheme = components.scheme,
        let rawHost = components.host
        else {
            throw CodexRemoteControlHTTPError.invalidBaseURL(
                url.absoluteString
            )
        }
        let scheme = rawScheme.lowercased()
        let host = rawHost.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: "[]")
        )
        let localhost = isLoopback(host)
        let chatGPT = host == "chatgpt.com"
            || host == "chatgpt-staging.com"
            || host.hasSuffix(".chatgpt.com")
            || host.hasSuffix(".chatgpt-staging.com")
        guard (scheme == "https" && (localhost || chatGPT))
            || (scheme == "http" && localhost)
        else {
            throw CodexRemoteControlHTTPError.invalidBaseURL(
                url.absoluteString
            )
        }
        var normalizedPath = components.percentEncodedPath
        if !normalizedPath.hasSuffix("/") {
            normalizedPath.append("/")
            components.percentEncodedPath = normalizedPath
        }
        guard let normalized = components.url else {
            throw CodexRemoteControlHTTPError.invalidBaseURL(
                url.absoluteString
            )
        }
        return normalized
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1"
            || host == "0:0:0:0:0:0:0:1"
        {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.first == "127",
              octets.allSatisfy({
                  guard let value = UInt8($0) else {
                      return false
                  }
                  return String(value) == $0 || $0 == "0"
              })
        else {
            return false
        }
        return true
    }

    private static func classification(
        statusCode: Int,
        endpoint: CodexRemoteControlHTTPEndpoint
    ) -> CodexRemoteControlHTTPFailureClassification {
        if statusCode == 401 || statusCode == 403 {
            return .permissionDenied
        }
        if endpoint == .pairStatus,
           statusCode == 404 || statusCode == 410
        {
            return .invalidInput
        }
        if endpoint == .clientList || endpoint == .clientRevoke,
           statusCode == 400
        {
            return .invalidInput
        }
        if statusCode == 404 {
            return .notFound
        }
        return .other
    }
}

private struct HTTPResult: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

private struct EnrollRemoteServerRequest: Encodable {
    let name: String
    let operatingSystem: String
    let architecture: String
    let appServerVersion: String
    let installationID: String

    private enum CodingKeys: String, CodingKey {
        case name
        case operatingSystem = "os"
        case architecture = "arch"
        case appServerVersion = "app_server_version"
        case installationID = "installation_id"
    }
}

private struct RefreshRemoteServerRequest: Encodable {
    let serverID: String
    let installationID: String

    private enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case installationID = "installation_id"
    }
}

private struct EnrollRemoteServerResponse: Decodable {
    let serverID: String
    let environmentID: String
    let remoteControlToken: String
    let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case environmentID = "environment_id"
        case remoteControlToken = "remote_control_token"
        case expiresAt = "expires_at"
    }
}

private struct StartRemoteControlPairingRequest: Encodable {
    let manualCode: Bool

    private enum CodingKeys: String, CodingKey {
        case manualCode = "manual_code"
    }
}

private struct StartRemoteControlPairingResponse: Decodable {
    let pairingCode: String
    let manualPairingCode: String?
    let serverID: String
    let environmentID: String
    let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case pairingCode = "pairing_code"
        case manualPairingCode = "manual_pairing_code"
        case serverID = "server_id"
        case environmentID = "environment_id"
        case expiresAt = "expires_at"
    }
}

private struct RemoteControlPairingStatusRequest: Encodable {
    let pairingCode: String?
    let manualPairingCode: String?

    private enum CodingKeys: String, CodingKey {
        case pairingCode = "pairing_code"
        case manualPairingCode = "manual_pairing_code"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(pairingCode, forKey: .pairingCode)
        try container.encodeIfPresent(
            manualPairingCode,
            forKey: .manualPairingCode
        )
    }
}

private struct RemoteControlPairingStatusResponse: Decodable {
    let claimed: Bool
}

private struct ListRemoteControlClientsResponse: Decodable {
    let items: [RemoteControlClientResponse]
    let cursor: String?
}

private struct RemoteControlClientResponse: Decodable {
    let clientID: String
    let displayName: String?
    let deviceType: String?
    let platform: String?
    let osVersion: String?
    let deviceModel: String?
    let appVersion: String?
    let lastSeenAt: String?

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case displayName = "display_name"
        case deviceType = "device_type"
        case platform
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case appVersion = "app_version"
        case lastSeenAt = "last_seen_at"
    }
}
