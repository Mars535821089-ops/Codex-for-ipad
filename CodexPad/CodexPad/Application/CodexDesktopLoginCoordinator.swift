#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexDesktopLoginAppBrand:
    String,
    Equatable,
    Sendable
{
    case codex
    case chatGPT = "chatgpt"
}

public struct CodexDesktopChatGPTLoginOptions:
    Equatable,
    Sendable
{
    public let codexStreamlinedLogin: Bool
    public let useHostedLoginSuccessPage: Bool
    public let appBrand: CodexDesktopLoginAppBrand?

    public init(
        codexStreamlinedLogin: Bool,
        useHostedLoginSuccessPage: Bool,
        appBrand: CodexDesktopLoginAppBrand?
    ) {
        self.codexStreamlinedLogin = codexStreamlinedLogin
        self.useHostedLoginSuccessPage =
            useHostedLoginSuccessPage
        self.appBrand = appBrand
    }
}

public struct CodexDesktopLoginSessionStart:
    Equatable,
    Sendable
{
    public let loginID: String
    public let authURL: String

    public init(
        loginID: String,
        authURL: String
    ) {
        self.loginID = loginID
        self.authURL = authURL
    }
}

public struct CodexDesktopDeviceCodeLoginSessionStart:
    Equatable,
    Sendable
{
    public let loginID: String
    public let verificationURL: String
    public let userCode: String

    public init(
        loginID: String,
        verificationURL: String,
        userCode: String
    ) {
        self.loginID = loginID
        self.verificationURL = verificationURL
        self.userCode = userCode
    }
}

public enum CodexDesktopLoginSessionCompletion:
    Equatable,
    Sendable
{
    case succeeded(
        loginID: String,
        planType: CodexDesktopMCPPlanType?
    )
    case failed(
        loginID: String,
        error: String?
    )
}

public extension CodexDesktopLoginSessionCompletion {
    /// The loopback driver renders credential and account failures in the
    /// authentication browser. Keep that page visible so the user can read
    /// and retry it; only a fully persisted login should close the browser.
    var shouldDismissAuthenticationBrowser: Bool {
        switch self {
        case .succeeded:
            return true
        case .failed:
            return false
        }
    }
}

public struct CodexDesktopLoginExchange:
    Equatable,
    Sendable
{
    public let response: CodexDesktopHostMessage
    public let postResponseMessages: [CodexDesktopHostMessage]

    public init(
        response: CodexDesktopHostMessage,
        postResponseMessages: [CodexDesktopHostMessage]
    ) {
        self.response = response
        self.postResponseMessages = postResponseMessages
    }
}

/// Secret-free checkpoints for proving that the released renderer request
/// reached native persistence. Values intentionally carry no credential data.
public enum CodexDesktopLoginDiagnostic:
    Equatable,
    Sendable
{
    case apiKeyRequestReceived
    case apiKeyPersistenceSucceeded
    case apiKeyPersistenceFailed
}

public protocol CodexDesktopLoginSessionDriving: Sendable {
    func startChatGPTLogin(
        options: CodexDesktopChatGPTLoginOptions,
        completion:
            @escaping @Sendable
            (CodexDesktopLoginSessionCompletion) async -> Void
    ) async throws -> CodexDesktopLoginSessionStart

    func cancelChatGPTLogin(loginID: String) async -> Bool
}

public protocol CodexDesktopDeviceCodeLoginSessionDriving:
    Sendable
{
    func startDeviceCodeLogin(
        completion:
            @escaping @Sendable
            (CodexDesktopLoginSessionCompletion) async -> Void
    ) async throws -> CodexDesktopDeviceCodeLoginSessionStart

    func cancelDeviceCodeLogin(loginID: String) async -> Bool
}

/// Executes the released app-server device-code flow against the existing
/// ChatGPT auth client while keeping the renderer-facing wire contract in the
/// coordinator.
public actor CodexDesktopDeviceCodeLoginDriver:
    CodexDesktopDeviceCodeLoginSessionDriving
{
    public typealias RequestDeviceCode =
        @Sendable () async throws -> CodexDeviceCode
    public typealias CompleteDeviceCode =
        @Sendable
        (CodexDeviceCode) async throws -> CodexDesktopMCPPlanType?
    public typealias LoginIDFactory =
        @Sendable () async -> String

    private struct ActiveSession {
        let loginID: String
        let task: Task<Void, Never>
    }

    private let requestDeviceCode: RequestDeviceCode
    private let completeDeviceCode: CompleteDeviceCode
    private let makeLoginID: LoginIDFactory
    private var activeSession: ActiveSession?

    public init(
        requestDeviceCode:
            @escaping RequestDeviceCode,
        completeDeviceCode:
            @escaping CompleteDeviceCode,
        makeLoginID:
            @escaping LoginIDFactory = {
                UUID().uuidString
            }
    ) {
        self.requestDeviceCode = requestDeviceCode
        self.completeDeviceCode = completeDeviceCode
        self.makeLoginID = makeLoginID
    }

    public func startDeviceCodeLogin(
        completion:
            @escaping @Sendable
            (CodexDesktopLoginSessionCompletion) async -> Void
    ) async throws -> CodexDesktopDeviceCodeLoginSessionStart {
        let code = try await requestDeviceCode()
        let loginID = await makeLoginID()
        let previous = activeSession
        let task = Task {
            await self.runSession(
                loginID: loginID,
                code: code,
                completion: completion
            )
        }
        activeSession = ActiveSession(
            loginID: loginID,
            task: task
        )
        previous?.task.cancel()

        return CodexDesktopDeviceCodeLoginSessionStart(
            loginID: loginID,
            verificationURL: code.verificationURL.absoluteString,
            userCode: code.userCode
        )
    }

    public func cancelDeviceCodeLogin(
        loginID: String
    ) async -> Bool {
        guard let session = activeSession,
              session.loginID == loginID
        else {
            return false
        }
        activeSession = nil
        session.task.cancel()
        return true
    }

    private func runSession(
        loginID: String,
        code: CodexDeviceCode,
        completion:
            @escaping @Sendable
            (CodexDesktopLoginSessionCompletion) async -> Void
    ) async {
        let result: CodexDesktopLoginSessionCompletion
        do {
            let planType = try await completeDeviceCode(code)
            try Task.checkCancellation()
            result = .succeeded(
                loginID: loginID,
                planType: planType
            )
        } catch is CancellationError {
            result = .failed(
                loginID: loginID,
                error: "Login was not completed"
            )
        } catch {
            result = .failed(
                loginID: loginID,
                error: "Device code login failed"
            )
        }

        if activeSession?.loginID == loginID {
            activeSession = nil
        }
        await completion(result)
    }
}

/// Coordinates the released renderer's managed ChatGPT login MCP slice.
///
/// The platform-specific session driver owns OAuth mechanics and credential
/// persistence. This type owns only the released app-server request, response,
/// and notification wire contracts.
public actor CodexDesktopLoginCoordinator {
    public typealias NotificationSink =
        @Sendable (CodexDesktopHostMessage) async -> Void
    public typealias CompletionSink =
        @Sendable (CodexDesktopLoginSessionCompletion) async -> Void
    public typealias APIKeySink =
        @Sendable (String) async throws -> Void
    public typealias DiagnosticSink =
        @Sendable (CodexDesktopLoginDiagnostic) async -> Void

    private let driver: any CodexDesktopLoginSessionDriving
    private let deviceCodeDriver:
        (any CodexDesktopDeviceCodeLoginSessionDriving)?
    private let completionSink: CompletionSink
    private let acceptAPIKey: APIKeySink?
    private let diagnosticSink: DiagnosticSink
    private let sendNotification: NotificationSink

    public init(
        driver: any CodexDesktopLoginSessionDriving,
        deviceCodeDriver:
            (any CodexDesktopDeviceCodeLoginSessionDriving)? = nil,
        completionSink: @escaping CompletionSink = { _ in },
        acceptAPIKey: APIKeySink? = nil,
        diagnosticSink: @escaping DiagnosticSink = { _ in },
        sendNotification: @escaping NotificationSink
    ) {
        self.driver = driver
        self.deviceCodeDriver = deviceCodeDriver
        self.completionSink = completionSink
        self.acceptAPIKey = acceptAPIKey
        self.diagnosticSink = diagnosticSink
        self.sendNotification = sendNotification
    }

    public func response(
        to request: CodexDesktopMCPRequest
    ) async -> CodexDesktopHostMessage? {
        await exchange(to: request)?.response
    }

    public func exchange(
        to request: CodexDesktopMCPRequest
    ) async -> CodexDesktopLoginExchange? {
        switch request.request.method {
        case "account/login/start":
            if case let .object(params)? = request.request.params,
               case .string("apiKey")? = params["type"]
            {
                return await saveAPIKeyExchange(
                    to: request,
                    params: params
                )
            }
            return CodexDesktopLoginExchange(
                response: await startResponse(to: request),
                postResponseMessages: []
            )

        case "account/login/cancel":
            return CodexDesktopLoginExchange(
                response: await cancelResponse(to: request),
                postResponseMessages: []
            )

        default:
            return nil
        }
    }

    private func startResponse(
        to request: CodexDesktopMCPRequest
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(type)? = params["type"]
        else {
            return Self.invalidParams(request)
        }

        if type == "chatgptDeviceCode" {
            return await startDeviceCodeResponse(to: request)
        }

        guard let options = Self.chatGPTOptions(
            from: request.request.params
        ) else {
            return Self.invalidParams(request)
        }

        let hostID = request.hostID
        let completionSink = self.completionSink
        let sendNotification = self.sendNotification
        do {
            let started = try await driver.startChatGPTLogin(
                options: options,
                completion: { completion in
                    await completionSink(completion)
                    for message in Self.notificationMessages(
                        hostID: hostID,
                        completion: completion
                    ) {
                        await sendNotification(message)
                    }
                }
            )
            return Self.result(
                request,
                value: .object([
                    "type": .string("chatgpt"),
                    "loginId": .string(started.loginID),
                    "authUrl": .string(started.authURL),
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Failed to start ChatGPT login"
            )
        }
    }

    private func saveAPIKeyExchange(
        to request: CodexDesktopMCPRequest,
        params: [String: CodexJSONValue]
    ) async -> CodexDesktopLoginExchange {
        guard case let .string(rawAPIKey)? = params["apiKey"] else {
            return CodexDesktopLoginExchange(
                response: Self.invalidParams(request),
                postResponseMessages: []
            )
        }
        let apiKey = rawAPIKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !apiKey.isEmpty else {
            return CodexDesktopLoginExchange(
                response: Self.invalidParams(request),
                postResponseMessages: []
            )
        }
        await diagnosticSink(.apiKeyRequestReceived)
        guard let acceptAPIKey else {
            await diagnosticSink(.apiKeyPersistenceFailed)
            return CodexDesktopLoginExchange(
                response: Self.error(
                    request,
                    code: -32603,
                    message: "Failed to save API key"
                ),
                postResponseMessages: []
            )
        }

        do {
            try await acceptAPIKey(apiKey)
            await diagnosticSink(.apiKeyPersistenceSucceeded)
            return CodexDesktopLoginExchange(
                response: Self.result(
                    request,
                    value: .object([
                        "type": .string("apiKey")
                    ])
                ),
                postResponseMessages: [
                    Self.notification(
                        hostID: request.hostID,
                        method: "account/login/completed",
                        params: .object([
                            "loginId": .null,
                            "success": .bool(true),
                            "error": .null,
                            "onboardingEntrypoint": .null,
                        ])
                    ),
                    Self.notification(
                        hostID: request.hostID,
                        method: "account/updated",
                        params: .object([
                            "authMode": .string(
                                CodexDesktopMCPAuthMethod.apiKey.rawValue
                            ),
                            "planType": .null,
                        ])
                    ),
                ]
            )
        } catch {
            await diagnosticSink(.apiKeyPersistenceFailed)
            return CodexDesktopLoginExchange(
                response: Self.error(
                    request,
                    code: -32603,
                    message: "Failed to save API key"
                ),
                postResponseMessages: []
            )
        }
    }

    private func startDeviceCodeResponse(
        to request: CodexDesktopMCPRequest
    ) async -> CodexDesktopHostMessage {
        guard let deviceCodeDriver else {
            return Self.error(
                request,
                code: -32603,
                message: "Failed to start ChatGPT device code login"
            )
        }

        let hostID = request.hostID
        let completionSink = self.completionSink
        let sendNotification = self.sendNotification
        do {
            let started =
                try await deviceCodeDriver.startDeviceCodeLogin(
                    completion: { completion in
                        await completionSink(completion)
                        for message in Self.notificationMessages(
                            hostID: hostID,
                            completion: completion
                        ) {
                            await sendNotification(message)
                        }
                    }
                )
            return Self.result(
                request,
                value: .object([
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string(started.loginID),
                    "verificationUrl":
                        .string(started.verificationURL),
                    "userCode": .string(started.userCode),
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Failed to start ChatGPT device code login"
            )
        }
    }

    private func cancelResponse(
        to request: CodexDesktopMCPRequest
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(loginID)? = params["loginId"],
              UUID(uuidString: loginID) != nil
        else {
            return Self.invalidParams(request)
        }

        var canceled = await driver.cancelChatGPTLogin(
            loginID: loginID
        )
        if !canceled, let deviceCodeDriver {
            canceled =
                await deviceCodeDriver.cancelDeviceCodeLogin(
                    loginID: loginID
                )
        }
        return Self.result(
            request,
            value: .object([
                "status": .string(
                    canceled ? "canceled" : "notFound"
                )
            ])
        )
    }

    private static func chatGPTOptions(
        from paramsValue: CodexJSONValue?
    ) -> CodexDesktopChatGPTLoginOptions? {
        guard case let .object(params)? = paramsValue,
              case .string("chatgpt")? = params["type"],
              let codexStreamlinedLogin = optionalBoolean(
                  params,
                  key: "codexStreamlinedLogin"
              ),
              let useHostedLoginSuccessPage = optionalBoolean(
                  params,
                  key: "useHostedLoginSuccessPage"
              )
        else {
            return nil
        }

        let appBrand: CodexDesktopLoginAppBrand?
        switch params["appBrand"] {
        case nil, .null?:
            appBrand = nil

        case let .string(rawValue)?:
            guard let parsed =
                CodexDesktopLoginAppBrand(rawValue: rawValue)
            else {
                return nil
            }
            appBrand = parsed

        default:
            return nil
        }

        return CodexDesktopChatGPTLoginOptions(
            codexStreamlinedLogin: codexStreamlinedLogin,
            useHostedLoginSuccessPage:
                useHostedLoginSuccessPage,
            appBrand: appBrand
        )
    }

    private static func optionalBoolean(
        _ params: [String: CodexJSONValue],
        key: String
    ) -> Bool? {
        guard let value = params[key] else {
            return false
        }
        guard case let .bool(boolean) = value else {
            return nil
        }
        return boolean
    }

    private static func notificationMessages(
        hostID: String,
        completion: CodexDesktopLoginSessionCompletion
    ) -> [CodexDesktopHostMessage] {
        switch completion {
        case let .succeeded(loginID, planType):
            return [
                notification(
                    hostID: hostID,
                    method: "account/login/completed",
                    params: .object([
                        "loginId": .string(loginID),
                        "success": .bool(true),
                        "error": .null,
                    ])
                ),
                notification(
                    hostID: hostID,
                    method: "account/updated",
                    params: .object([
                        "authMode": .string("chatgpt"),
                        "planType":
                            planType.map {
                                .string($0.rawValue)
                            } ?? .null,
                    ])
                ),
            ]

        case let .failed(loginID, completionError):
            return [
                notification(
                    hostID: hostID,
                    method: "account/login/completed",
                    params: .object([
                        "loginId": .string(loginID),
                        "success": .bool(false),
                        "error":
                            completionError.map {
                                .string($0)
                            } ?? .null,
                    ])
                )
            ]
        }
    }

    private static func notification(
        hostID: String,
        method: String,
        params: CodexJSONValue
    ) -> CodexDesktopHostMessage {
        .mcpNotification(
            hostID: hostID,
            method: method,
            params: params,
            metadata: [:]
        )
    }

    private static func invalidParams(
        _ request: CodexDesktopMCPRequest
    ) -> CodexDesktopHostMessage {
        error(
            request,
            code: -32602,
            message:
                "Invalid params for \(request.request.method)"
        )
    }

    private static func result(
        _ request: CodexDesktopMCPRequest,
        value: CodexJSONValue
    ) -> CodexDesktopHostMessage {
        .mcpResponse(
            hostID: request.hostID,
            message: .object([
                "id": requestIDValue(request.request.id),
                "result": value,
            ]),
            metadata: [:]
        )
    }

    private static func error(
        _ request: CodexDesktopMCPRequest,
        code: Int64,
        message: String
    ) -> CodexDesktopHostMessage {
        .mcpResponse(
            hostID: request.hostID,
            message: .object([
                "id": requestIDValue(request.request.id),
                "error": .object([
                    "code": .integer(code),
                    "message": .string(message),
                ]),
            ]),
            metadata: [:]
        )
    }

    private static func requestIDValue(
        _ id: CodexAppServerRequestID
    ) -> CodexJSONValue {
        switch id {
        case let .integer(value):
            return .integer(value)
        case let .string(value):
            return .string(value)
        }
    }
}
