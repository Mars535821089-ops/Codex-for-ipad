import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopLoginCompletionDismissesBrowserOnlyAfterSuccess() {
    #expect(
        CodexDesktopLoginSessionCompletion.succeeded(
            loginID: "login-success",
            planType: .plus
        ).shouldDismissAuthenticationBrowser
    )
    #expect(
        !CodexDesktopLoginSessionCompletion.failed(
            loginID: "login-failure",
            error: "Credentials could not be saved"
        ).shouldDismissAuthenticationBrowser
    )
}
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test
func desktopLoginCoordinatorStartsReleasedChatGPTLogin() async {
    let driver = DesktopLoginDriverSpy(
        starts: [
            .init(
                loginID: DesktopLoginIDs.started,
                authURL: "https://example.invalid/authorize"
            )
        ]
    )
    let notifications = DesktopLoginNotificationRecorder()
    let coordinator = CodexDesktopLoginCoordinator(
        driver: driver,
        sendNotification: { message in
            await notifications.append(message)
        }
    )

    let response = await coordinator.response(
        to: desktopLoginRequest(
            id: .string("start-request"),
            method: "account/login/start",
            params: .object([
                "type": .string("chatgpt"),
                "codexStreamlinedLogin": .bool(true),
                "useHostedLoginSuccessPage": .bool(true),
                "appBrand": .string("codex"),
            ])
        )
    )

    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-login",
                message: .object([
                    "id": .string("start-request"),
                    "result": .object([
                        "type": .string("chatgpt"),
                        "loginId": .string(DesktopLoginIDs.started),
                        "authUrl": .string(
                            "https://example.invalid/authorize"
                        ),
                    ]),
                ]),
                metadata: [:]
            )
    )
    #expect(
        await driver.recordedOptions()
            == [
                CodexDesktopChatGPTLoginOptions(
                    codexStreamlinedLogin: true,
                    useHostedLoginSuccessPage: true,
                    appBrand: .codex
                )
            ]
    )
}

@Test
func desktopLoginCoordinatorStartsReleasedDeviceCodeLogin() async {
    let browserDriver = DesktopLoginDriverSpy(starts: [])
    let deviceDriver = DesktopDeviceCodeLoginDriverSpy(
        starts: [
            .init(
                loginID: DesktopLoginIDs.deviceCode,
                verificationURL: "https://auth.example/device",
                userCode: "ABCD-EFGH"
            )
        ]
    )
    let coordinator = CodexDesktopLoginCoordinator(
        driver: browserDriver,
        deviceCodeDriver: deviceDriver,
        sendNotification: { _ in }
    )

    let response = await coordinator.response(
        to: desktopLoginRequest(
            id: .string("device-code-start"),
            method: "account/login/start",
            params: .object([
                "type": .string("chatgptDeviceCode"),
                "releasedExtraField": .bool(true),
            ])
        )
    )

    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-login",
                message: .object([
                    "id": .string("device-code-start"),
                    "result": .object([
                        "type": .string("chatgptDeviceCode"),
                        "loginId": .string(
                            DesktopLoginIDs.deviceCode
                        ),
                        "verificationUrl": .string(
                            "https://auth.example/device"
                        ),
                        "userCode": .string("ABCD-EFGH"),
                    ]),
                ]),
                metadata: [:]
            )
    )
    #expect(await browserDriver.startCount() == 0)
    #expect(await deviceDriver.startCount() == 1)
}

@Test
func desktopLoginCoordinatorSavesReleasedAPIKeyLogin() async {
    let browserDriver = DesktopLoginDriverSpy(starts: [])
    let apiKeys = DesktopAPIKeyRecorder()
    let notifications = DesktopLoginNotificationRecorder()
    let coordinator = CodexDesktopLoginCoordinator(
        driver: browserDriver,
        acceptAPIKey: { apiKey in
            await apiKeys.append(apiKey)
        },
        sendNotification: { message in
            await notifications.append(message)
        }
    )

    let exchange = await coordinator.exchange(
        to: desktopLoginRequest(
            id: .string("api-key-start"),
            method: "account/login/start",
            params: .object([
                "type": .string("apiKey"),
                "apiKey": .string("  TEST_API_KEY_LOGIN  "),
            ])
        )
    )
    let response = exchange?.response

    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-login",
                message: .object([
                    "id": .string("api-key-start"),
                    "result": .object([
                        "type": .string("apiKey")
                    ]),
                ]),
                metadata: [:]
            )
    )
    #expect(await apiKeys.values() == ["TEST_API_KEY_LOGIN"])
    #expect(
        exchange?.postResponseMessages
            == [
                .mcpNotification(
                    hostID: "desktop-host-login",
                    method: "account/login/completed",
                    params: .object([
                        "loginId": .null,
                        "success": .bool(true),
                        "error": .null,
                        "onboardingEntrypoint": .null,
                    ]),
                    metadata: [:]
                ),
                .mcpNotification(
                    hostID: "desktop-host-login",
                    method: "account/updated",
                    params: .object([
                        "authMode": .string("apikey"),
                        "planType": .null,
                    ]),
                    metadata: [:]
                )
            ]
    )
    #expect(await notifications.messages().isEmpty)
    #expect(await browserDriver.startCount() == 0)
    #expect(
        !String(describing: response)
            .contains("TEST_API_KEY_LOGIN")
    )
}

@Test
func desktopLoginCoordinatorReportsSecretFreeAPIKeyPersistenceStages() async {
    let browserDriver = DesktopLoginDriverSpy(starts: [])
    let diagnostics = DesktopLoginDiagnosticRecorder()
    let coordinator = CodexDesktopLoginCoordinator(
        driver: browserDriver,
        acceptAPIKey: { _ in },
        diagnosticSink: { diagnostic in
            await diagnostics.append(diagnostic)
        },
        sendNotification: { _ in }
    )

    _ = await coordinator.exchange(
        to: desktopLoginRequest(
            id: .string("api-key-diagnostic"),
            method: "account/login/start",
            params: .object([
                "type": .string("apiKey"),
                "apiKey": .string("TEST_API_KEY_MUST_NOT_LEAK"),
            ])
        )
    )

    #expect(
        await diagnostics.values()
            == [.apiKeyRequestReceived, .apiKeyPersistenceSucceeded]
    )
    #expect(
        !String(describing: await diagnostics.values())
            .contains("TEST_API_KEY_MUST_NOT_LEAK")
    )
}

@Test
func desktopLoginCoordinatorReportsAPIKeyPersistenceFailure() async {
    let browserDriver = DesktopLoginDriverSpy(starts: [])
    let diagnostics = DesktopLoginDiagnosticRecorder()
    let coordinator = CodexDesktopLoginCoordinator(
        driver: browserDriver,
        acceptAPIKey: { _ in
            throw DesktopAPIKeyPersistenceFixtureError.rejected
        },
        diagnosticSink: { diagnostic in
            await diagnostics.append(diagnostic)
        },
        sendNotification: { _ in }
    )

    _ = await coordinator.exchange(
        to: desktopLoginRequest(
            id: .string("api-key-diagnostic-failure"),
            method: "account/login/start",
            params: .object([
                "type": .string("apiKey"),
                "apiKey": .string("TEST_API_KEY_MUST_NOT_LEAK"),
            ])
        )
    )

    #expect(
        await diagnostics.values()
            == [.apiKeyRequestReceived, .apiKeyPersistenceFailed]
    )
}

@Test
func desktopLoginCoordinatorAppliesReleasedChatGPTDefaultsAndBrands()
    async
{
    let driver = DesktopLoginDriverSpy(
        starts: [
            .init(
                loginID: DesktopLoginIDs.defaultOptions,
                authURL: "https://a.invalid"
            ),
            .init(
                loginID: DesktopLoginIDs.nullBrand,
                authURL: "https://b.invalid"
            ),
            .init(
                loginID: DesktopLoginIDs.chatGPTBrand,
                authURL: "https://c.invalid"
            ),
        ]
    )
    let coordinator = CodexDesktopLoginCoordinator(
        driver: driver,
        sendNotification: { _ in }
    )

    _ = await coordinator.response(
        to: desktopLoginRequest(
            id: .integer(1),
            method: "account/login/start",
            params: .object(["type": .string("chatgpt")])
        )
    )
    _ = await coordinator.response(
        to: desktopLoginRequest(
            id: .integer(2),
            method: "account/login/start",
            params: .object([
                "type": .string("chatgpt"),
                "appBrand": .null,
                "releasedExtraField": .string("ignored"),
            ])
        )
    )
    _ = await coordinator.response(
        to: desktopLoginRequest(
            id: .integer(3),
            method: "account/login/start",
            params: .object([
                "type": .string("chatgpt"),
                "appBrand": .string("chatgpt"),
            ])
        )
    )

    #expect(
        await driver.recordedOptions()
            == [
                .init(
                    codexStreamlinedLogin: false,
                    useHostedLoginSuccessPage: false,
                    appBrand: nil
                ),
                .init(
                    codexStreamlinedLogin: false,
                    useHostedLoginSuccessPage: false,
                    appBrand: nil
                ),
                .init(
                    codexStreamlinedLogin: false,
                    useHostedLoginSuccessPage: false,
                    appBrand: .chatGPT
                ),
            ]
    )
}

@Test
func desktopLoginCoordinatorRejectsInvalidStartParams() async {
    let driver = DesktopLoginDriverSpy(starts: [])
    let coordinator = CodexDesktopLoginCoordinator(
        driver: driver,
        sendNotification: { _ in }
    )
    let invalidParams: [CodexJSONValue?] = [
        nil,
        .null,
        .array([]),
        .object([:]),
        .object(["type": .string("apiKey")]),
        .object([
            "type": .string("chatgpt"),
            "codexStreamlinedLogin": .null,
        ]),
        .object([
            "type": .string("chatgpt"),
            "useHostedLoginSuccessPage": .string("true"),
        ]),
        .object([
            "type": .string("chatgpt"),
            "appBrand": .string("desktop"),
        ]),
        .object([
            "type": .string("chatgpt"),
            "appBrand": .bool(true),
        ]),
    ]

    for (index, params) in invalidParams.enumerated() {
        let response = await coordinator.response(
            to: desktopLoginRequest(
                id: .integer(Int64(index)),
                method: "account/login/start",
                params: params
            )
        )

        #expect(
            response
                == desktopLoginError(
                    id: .integer(Int64(index)),
                    method: "account/login/start"
                )
        )
    }
    #expect(await driver.startCount() == 0)
}

@Test
func desktopLoginCoordinatorCancelsReleasedLoginAndPreservesEnvelope()
    async
{
    let driver = DesktopLoginDriverSpy(
        starts: [],
        cancellationResults: [
            DesktopLoginIDs.active: true,
            DesktopLoginIDs.missing: false,
        ]
    )
    let coordinator = CodexDesktopLoginCoordinator(
        driver: driver,
        sendNotification: { _ in }
    )

    let canceled = await coordinator.response(
        to: desktopLoginRequest(
            id: .integer(71),
            method: "account/login/cancel",
            params: .object([
                "loginId": .string(DesktopLoginIDs.active),
                "releasedExtraField": .bool(true),
            ])
        )
    )
    let notFound = await coordinator.response(
        to: desktopLoginRequest(
            id: .string("cancel-missing"),
            method: "account/login/cancel",
            params: .object([
                "loginId": .string(DesktopLoginIDs.missing)
            ])
        )
    )

    #expect(
        canceled
            == .mcpResponse(
                hostID: "desktop-host-login",
                message: .object([
                    "id": .integer(71),
                    "result": .object([
                        "status": .string("canceled")
                    ]),
                ]),
                metadata: [:]
            )
    )
    #expect(
        notFound
            == .mcpResponse(
                hostID: "desktop-host-login",
                message: .object([
                    "id": .string("cancel-missing"),
                    "result": .object([
                        "status": .string("notFound")
                    ]),
                ]),
                metadata: [:]
            )
    )
    #expect(
        await driver.recordedCancellations()
            == [DesktopLoginIDs.active, DesktopLoginIDs.missing]
    )
}

@Test
func desktopLoginCoordinatorCancelsReleasedDeviceCodeLogin() async {
    let browserDriver = DesktopLoginDriverSpy(
        starts: [],
        cancellationResults: [
            DesktopLoginIDs.deviceCode: false
        ]
    )
    let deviceDriver = DesktopDeviceCodeLoginDriverSpy(
        starts: [],
        cancellationResults: [
            DesktopLoginIDs.deviceCode: true
        ]
    )
    let coordinator = CodexDesktopLoginCoordinator(
        driver: browserDriver,
        deviceCodeDriver: deviceDriver,
        sendNotification: { _ in }
    )

    let response = await coordinator.response(
        to: desktopLoginRequest(
            id: .integer(72),
            method: "account/login/cancel",
            params: .object([
                "loginId": .string(DesktopLoginIDs.deviceCode)
            ])
        )
    )

    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-login",
                message: .object([
                    "id": .integer(72),
                    "result": .object([
                        "status": .string("canceled")
                    ]),
                ]),
                metadata: [:]
            )
    )
    #expect(
        await browserDriver.recordedCancellations()
            == [DesktopLoginIDs.deviceCode]
    )
    #expect(
        await deviceDriver.recordedCancellations()
            == [DesktopLoginIDs.deviceCode]
    )
}

@Test
func desktopLoginCoordinatorRejectsInvalidCancelParams() async {
    let driver = DesktopLoginDriverSpy(starts: [])
    let coordinator = CodexDesktopLoginCoordinator(
        driver: driver,
        sendNotification: { _ in }
    )
    let invalidParams: [CodexJSONValue?] = [
        nil,
        .null,
        .array([]),
        .object([:]),
        .object(["loginId": .null]),
        .object(["loginId": .integer(7)]),
        .object(["loginId": .string("")]),
        .object(["loginId": .string("login-active")]),
        .object([
            "loginId": .string(
                "11111111-1111-4111-8111-11111111111Z"
            )
        ]),
    ]

    for (index, params) in invalidParams.enumerated() {
        let response = await coordinator.response(
            to: desktopLoginRequest(
                id: .string("cancel-invalid-\(index)"),
                method: "account/login/cancel",
                params: params
            )
        )

        #expect(
            response
                == desktopLoginError(
                    id: .string("cancel-invalid-\(index)"),
                    method: "account/login/cancel"
                )
        )
    }
    #expect(await driver.recordedCancellations().isEmpty)
}

@Test
func desktopLoginCoordinatorEmitsReleasedSuccessNotifications()
    async
{
    let driver = DesktopLoginDriverSpy(
        starts: [
            .init(
                loginID: DesktopLoginIDs.success,
                authURL: "https://d.invalid"
            )
        ]
    )
    let notifications = DesktopLoginNotificationRecorder()
    let completions = DesktopLoginCompletionRecorder()
    let coordinator = CodexDesktopLoginCoordinator(
        driver: driver,
        completionSink: { completion in
            await completions.append(completion)
        },
        sendNotification: { message in
            await notifications.append(message)
        }
    )
    _ = await coordinator.response(
        to: desktopLoginRequest(
            id: .integer(17),
            method: "account/login/start",
            params: .object(["type": .string("chatgpt")])
        )
    )

    await driver.complete(
        .succeeded(
            loginID: DesktopLoginIDs.success,
            planType: .plus
        )
    )

    #expect(
        await completions.values()
            == [
                .succeeded(
                    loginID: DesktopLoginIDs.success,
                    planType: .plus
                )
            ]
    )
    #expect(
        await notifications.messages()
            == [
                .mcpNotification(
                    hostID: "desktop-host-login",
                    method: "account/login/completed",
                    params: .object([
                        "loginId": .string(DesktopLoginIDs.success),
                        "success": .bool(true),
                        "error": .null,
                    ]),
                    metadata: [:]
                ),
                .mcpNotification(
                    hostID: "desktop-host-login",
                    method: "account/updated",
                    params: .object([
                        "authMode": .string("chatgpt"),
                        "planType": .string("plus"),
                    ]),
                    metadata: [:]
                ),
            ]
    )
}

@Test
func desktopLoginCoordinatorEmitsOnlyReleasedFailureNotification()
    async
{
    let driver = DesktopLoginDriverSpy(
        starts: [
            .init(
                loginID: DesktopLoginIDs.failure,
                authURL: "https://e.invalid"
            )
        ]
    )
    let notifications = DesktopLoginNotificationRecorder()
    let coordinator = CodexDesktopLoginCoordinator(
        driver: driver,
        sendNotification: { message in
            await notifications.append(message)
        }
    )
    _ = await coordinator.response(
        to: desktopLoginRequest(
            id: .integer(18),
            method: "account/login/start",
            params: .object(["type": .string("chatgpt")])
        )
    )

    await driver.complete(
        .failed(
            loginID: DesktopLoginIDs.failure,
            error: "OAuth callback rejected"
        )
    )

    #expect(
        await notifications.messages()
            == [
                .mcpNotification(
                    hostID: "desktop-host-login",
                    method: "account/login/completed",
                    params: .object([
                        "loginId": .string(DesktopLoginIDs.failure),
                        "success": .bool(false),
                        "error": .string("OAuth callback rejected"),
                    ]),
                    metadata: [:]
                )
            ]
    )
}

@Test
func desktopLoginCoordinatorReturnsNilForOtherMCPMethods() async {
    let driver = DesktopLoginDriverSpy(starts: [])
    let coordinator = CodexDesktopLoginCoordinator(
        driver: driver,
        sendNotification: { _ in }
    )

    let response = await coordinator.response(
        to: desktopLoginRequest(
            id: .integer(99),
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        )
    )

    #expect(response == nil)
    #expect(await driver.startCount() == 0)
    #expect(await driver.recordedCancellations().isEmpty)
}

private actor DesktopLoginDriverSpy:
    CodexDesktopLoginSessionDriving
{
    private var starts: [CodexDesktopLoginSessionStart]
    private var options: [CodexDesktopChatGPTLoginOptions] = []
    private var cancellations: [String] = []
    private let cancellationResults: [String: Bool]
    private var completion:
        (@Sendable (CodexDesktopLoginSessionCompletion) async -> Void)?

    init(
        starts: [CodexDesktopLoginSessionStart],
        cancellationResults: [String: Bool] = [:]
    ) {
        self.starts = starts
        self.cancellationResults = cancellationResults
    }

    func startChatGPTLogin(
        options: CodexDesktopChatGPTLoginOptions,
        completion:
            @escaping @Sendable
            (CodexDesktopLoginSessionCompletion) async -> Void
    ) async throws -> CodexDesktopLoginSessionStart {
        self.options.append(options)
        self.completion = completion
        return starts.removeFirst()
    }

    func cancelChatGPTLogin(loginID: String) async -> Bool {
        cancellations.append(loginID)
        return cancellationResults[loginID] ?? false
    }

    func recordedOptions() -> [CodexDesktopChatGPTLoginOptions] {
        options
    }

    func recordedCancellations() -> [String] {
        cancellations
    }

    func startCount() -> Int {
        options.count
    }

    func complete(
        _ completion: CodexDesktopLoginSessionCompletion
    ) async {
        await self.completion?(completion)
    }
}

private actor DesktopDeviceCodeLoginDriverSpy:
    CodexDesktopDeviceCodeLoginSessionDriving
{
    private var starts:
        [CodexDesktopDeviceCodeLoginSessionStart]
    private var cancellations: [String] = []
    private let cancellationResults: [String: Bool]
    private var completion:
        (@Sendable (CodexDesktopLoginSessionCompletion) async -> Void)?
    private var startsCount = 0

    init(
        starts: [CodexDesktopDeviceCodeLoginSessionStart],
        cancellationResults: [String: Bool] = [:]
    ) {
        self.starts = starts
        self.cancellationResults = cancellationResults
    }

    func startDeviceCodeLogin(
        completion:
            @escaping @Sendable
            (CodexDesktopLoginSessionCompletion) async -> Void
    ) async throws -> CodexDesktopDeviceCodeLoginSessionStart {
        startsCount += 1
        self.completion = completion
        return starts.removeFirst()
    }

    func cancelDeviceCodeLogin(loginID: String) async -> Bool {
        cancellations.append(loginID)
        return cancellationResults[loginID] ?? false
    }

    func startCount() -> Int {
        startsCount
    }

    func recordedCancellations() -> [String] {
        cancellations
    }
}

private enum DesktopLoginIDs {
    static let started =
        "11111111-1111-4111-8111-111111111111"
    static let defaultOptions =
        "22222222-2222-4222-8222-222222222222"
    static let nullBrand =
        "33333333-3333-4333-8333-333333333333"
    static let chatGPTBrand =
        "44444444-4444-4444-8444-444444444444"
    static let active =
        "55555555-5555-4555-8555-555555555555"
    static let missing =
        "66666666-6666-4666-8666-666666666666"
    static let success =
        "77777777-7777-4777-8777-777777777777"
    static let failure =
        "88888888-8888-4888-8888-888888888888"
    static let deviceCode =
        "99999999-9999-4999-8999-999999999999"
}

private actor DesktopLoginNotificationRecorder {
    private var recorded: [CodexDesktopHostMessage] = []

    func append(_ message: CodexDesktopHostMessage) {
        recorded.append(message)
    }

    func messages() -> [CodexDesktopHostMessage] {
        recorded
    }
}

private actor DesktopAPIKeyRecorder {
    private var apiKeys: [String] = []

    func append(_ apiKey: String) {
        apiKeys.append(apiKey)
    }

    func values() -> [String] {
        apiKeys
    }
}

private actor DesktopLoginDiagnosticRecorder {
    private var diagnostics: [CodexDesktopLoginDiagnostic] = []

    func append(_ diagnostic: CodexDesktopLoginDiagnostic) {
        diagnostics.append(diagnostic)
    }

    func values() -> [CodexDesktopLoginDiagnostic] {
        diagnostics
    }
}

private enum DesktopAPIKeyPersistenceFixtureError: Error {
    case rejected
}

private actor DesktopLoginCompletionRecorder {
    private var recorded:
        [CodexDesktopLoginSessionCompletion] = []

    func append(
        _ completion: CodexDesktopLoginSessionCompletion
    ) {
        recorded.append(completion)
    }

    func values() -> [CodexDesktopLoginSessionCompletion] {
        recorded
    }
}

private func desktopLoginRequest(
    id: CodexAppServerRequestID,
    method: String,
    params: CodexJSONValue?
) -> CodexDesktopMCPRequest {
    CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(
            id: id,
            method: method,
            params: params,
            metadata: [
                "requestTrace": .string("must-not-be-mirrored")
            ]
        ),
        hostID: "desktop-host-login",
        dispatchedAtMs: .integer(100),
        priority: .string("interactive"),
        source: .string("renderer"),
        timeoutMs: .integer(5_000),
        expiresAtMs: .integer(5_100),
        metadata: [
            "envelopeTrace": .string("must-not-be-mirrored")
        ]
    )
}

private func desktopLoginError(
    id: CodexAppServerRequestID,
    method: String
) -> CodexDesktopHostMessage {
    let responseID: CodexJSONValue
    switch id {
    case let .string(value):
        responseID = .string(value)
    case let .integer(value):
        responseID = .integer(value)
    }

    return .mcpResponse(
        hostID: "desktop-host-login",
        message: .object([
            "id": responseID,
            "error": .object([
                "code": .integer(-32602),
                "message": .string("Invalid params for \(method)"),
            ]),
        ]),
        metadata: [:]
    )
}
