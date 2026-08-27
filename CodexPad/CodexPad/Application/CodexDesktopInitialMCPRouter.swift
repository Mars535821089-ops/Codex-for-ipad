#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import CryptoKit
import Foundation

public enum CodexDesktopMCPAuthMethod:
    String,
    CaseIterable,
    Equatable,
    Sendable
{
    case apiKey = "apikey"
    case chatGPT = "chatgpt"
    case chatGPTAuthTokens = "chatgptAuthTokens"
    case headers
    case agentIdentity
    case personalAccessToken
    case bedrockAPIKey = "bedrockApiKey"
}

private extension CodexJSONValue {
    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }
}

public enum CodexDesktopMCPPlanType:
    String,
    CaseIterable,
    Equatable,
    Sendable
{
    case free
    case go
    case plus
    case pro
    case proLite = "prolite"
    case team
    case selfServeBusinessUsageBased =
        "self_serve_business_usage_based"
    case business
    case enterpriseCBPUsageBased =
        "enterprise_cbp_usage_based"
    case enterprise
    case edu
    case unknown
}

public enum CodexDesktopMCPAccount:
    Equatable,
    Sendable
{
    case apiKey
    case chatGPT(
        email: String?,
        planType: CodexDesktopMCPPlanType
    )
    case amazonBedrock(
        usesCodexManagedCredentials: Bool
    )
}

public struct CodexDesktopMCPAccountState:
    Equatable,
    Sendable
{
    public let account: CodexDesktopMCPAccount?
    public let authMethod: CodexDesktopMCPAuthMethod?
    public let requiresOpenAIAuth: Bool

    public init(
        account: CodexDesktopMCPAccount?,
        authMethod: CodexDesktopMCPAuthMethod?,
        requiresOpenAIAuth: Bool
    ) {
        self.account = account
        self.authMethod = authMethod
        self.requiresOpenAIAuth = requiresOpenAIAuth
    }
}

public enum CodexDesktopMCPRemoteControlStatus:
    String,
    CaseIterable,
    Equatable,
    Sendable
{
    case disabled
    case connecting
    case connected
    case errored
}

public struct CodexDesktopMCPRemoteControlState:
    Equatable,
    Sendable
{
    public let status: CodexDesktopMCPRemoteControlStatus
    public let serverName: String
    public let installationID: String
    public let environmentID: String?

    public init(
        status: CodexDesktopMCPRemoteControlStatus,
        serverName: String,
        installationID: String,
        environmentID: String?
    ) {
        self.status = status
        self.serverName = serverName
        self.installationID = installationID
        self.environmentID = environmentID
    }
}

public struct CodexDesktopMCPConfigState:
    Equatable,
    Sendable
{
    public let config: [String: CodexJSONValue]
    public let origins: [String: CodexJSONValue]
    public let layers: [CodexJSONValue]

    public init(
        config: [String: CodexJSONValue],
        origins: [String: CodexJSONValue],
        layers: [CodexJSONValue]
    ) {
        self.config = config
        self.origins = origins
        self.layers = layers
    }
}

public struct CodexDesktopInitialMCPState:
    Equatable,
    Sendable
{
    public let account: CodexDesktopMCPAccountState
    public let config: CodexDesktopMCPConfigState
    public let remoteControl: CodexDesktopMCPRemoteControlState

    public init(
        account: CodexDesktopMCPAccountState,
        config: CodexDesktopMCPConfigState,
        remoteControl: CodexDesktopMCPRemoteControlState
    ) {
        self.account = account
        self.config = config
        self.remoteControl = remoteControl
    }
}

/// Injectable boundary between the released renderer's `thread/list` MCP
/// request and the app-server-backed session directory.
@MainActor
public protocol CodexDesktopThreadSessionListing: AnyObject {
    func listThreads(
        id: CodexAppServerRequestID,
        params: CodexThreadListParams
    ) throws -> CodexThreadPage
}

/// Injectable read capability layered onto the same session-store instance
/// used for the released renderer's thread directory.
@MainActor
public protocol CodexDesktopThreadSessionReading: AnyObject {
    func readThread(
        id: CodexAppServerRequestID,
        params: CodexThreadReadParams
    ) throws -> CodexThreadReadResult
}

/// Injectable resume capability layered onto the same session-store instance
/// used for the released renderer's thread directory.
@MainActor
public protocol CodexDesktopThreadSessionResuming: AnyObject {
    func resumeThread(
        id: CodexAppServerRequestID,
        params: CodexThreadResumeParams
    ) throws -> CodexThreadResumeResult
}

@MainActor
public protocol CodexDesktopThreadSessionStarting: AnyObject {
    func startThread(
        id: CodexAppServerRequestID,
        params: CodexThreadStartParams
    ) throws -> CodexThreadResumeResult
}

@MainActor
public protocol CodexDesktopThreadSessionForking: AnyObject {
    func forkThread(
        id: CodexAppServerRequestID,
        params: CodexThreadForkParams
    ) throws -> CodexThreadResumeResult
}

@MainActor
public protocol CodexDesktopThreadItemsInjecting: AnyObject {
    func injectStoredThreadItems(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        items: [CodexJSONValue]
    ) throws
}

@MainActor
public protocol CodexDesktopGuardianDeniedActionApproving: AnyObject {
    func approveGuardianDeniedAction(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        event: CodexJSONValue
    ) throws
}

@MainActor
public protocol CodexDesktopThreadShellCommandRunning: AnyObject {
    func beginShellCommand(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        command: String
    ) throws -> CodexShellCommandStartedEvent

    func completeShellCommand(
        commandID: String,
        result: CodexDesktopCommandExecResult,
        durationMillis: UInt64
    ) throws
}

/// Persisted thread mutations exposed by the released renderer.
@MainActor
public protocol CodexDesktopThreadSessionMutating: AnyObject {
    func archiveStoredThread(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws

    func unarchiveStoredThread(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws -> CodexThreadUnarchiveResponse

    func deleteStoredThread(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws

    func rollbackStoredThread(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        numTurns: UInt32
    ) throws -> CodexThreadReadResult

    func revertStoredThread(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        beforeTurnID: String
    ) throws -> CodexThreadRevertResult

    func setStoredThreadName(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        name: String
    ) throws
}

@MainActor
public protocol CodexDesktopThreadQueueManaging: AnyObject {
    func addQueuedSubmission(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueAddParams
    ) throws -> CodexThreadQueueAddResponse

    func listQueuedSubmissions(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueListParams
    ) throws -> CodexThreadQueueListResponse

    func updateQueuedSubmission(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueUpdateParams
    ) throws -> CodexThreadQueueUpdateResponse

    func deleteQueuedSubmission(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueDeleteParams
    ) throws -> CodexThreadQueueDeleteResponse

    func reorderQueuedSubmissions(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueReorderParams
    ) throws

    func startQueuedSubmission(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueStartParams
    ) throws -> CodexThreadQueueStartResponse
}

@MainActor
public protocol CodexDesktopThreadSessionSearching: AnyObject {
    func searchThreads(
        id: CodexAppServerRequestID,
        params: CodexThreadSearchParams
    ) throws -> CodexThreadSearchPage
}

@MainActor
public protocol CodexDesktopThreadSectionListing: AnyObject {
    func listThreadSections(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionListParams
    ) throws -> CodexThreadSectionPage
}

@MainActor
public protocol CodexDesktopThreadSectionMutating: AnyObject {
    func createThreadSection(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionCreateParams
    ) throws -> CodexThreadSectionCreateResult

    func updateThreadSection(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionUpdateParams
    ) throws -> CodexThreadSectionUpdateResult

    func deleteThreadSection(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionDeleteParams
    ) throws

    func moveThreadSection(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionMoveParams
    ) throws
}

@MainActor
public protocol CodexDesktopThreadMetadataUpdating: AnyObject {
    func updateThreadMetadata(
        id: CodexAppServerRequestID,
        params: CodexThreadMetadataUpdateParams
    ) throws -> CodexThreadMetadataUpdateResult
}

@MainActor
public protocol CodexDesktopThreadSettingsUpdating: AnyObject {
    func updateThreadSettings(
        id: CodexAppServerRequestID,
        params: CodexThreadSettingsUpdateParams
    ) throws -> CodexThreadSettingsUpdateResponse
}

@MainActor
public protocol CodexDesktopThreadMemoryModeUpdating: AnyObject {
    func setThreadMemoryMode(
        id: CodexAppServerRequestID,
        params: CodexThreadMemoryModeSetParams
    ) throws
}

/// Dedicated non-main-actor boundary for the released app-server
/// `gitDiffToRemote` request.
public protocol CodexDesktopGitDiffing: Actor {
    func gitDiffToRemote(
        id: CodexAppServerRequestID,
        params: CodexGitDiffToRemoteParams
    ) async throws -> CodexGitDiffToRemoteResponse
}

public protocol CodexDesktopEmbeddedGitRequesting: Actor {
    func embeddedGitRead(
        method: String,
        params: CodexJSONValue
    ) async throws -> CodexJSONValue
}

#if !SWIFT_PACKAGE
extension CodexGitDiffWorker: CodexDesktopGitDiffing {}
extension CodexGitDiffWorker: CodexDesktopEmbeddedGitRequesting {}
#endif

/// Stable goal operations used by the released renderer's long-running task
/// controls. The session store remains the single persisted source of truth.
@MainActor
public protocol CodexDesktopThreadGoalManaging: AnyObject {
    func storedThreadGoal(
        threadID: CodexStoredThreadID
    ) throws -> ThreadGoal?

    func setStoredThreadGoal(
        threadID: CodexStoredThreadID,
        objective: String?,
        status: ThreadGoalStatus?,
        tokenBudget: CodexWireOptional<Int64>
    ) throws -> ThreadGoal

    func clearStoredThreadGoal(
        threadID: CodexStoredThreadID
    ) throws -> Bool
}

public struct CodexDesktopLoadedThreadPage: Equatable, Sendable {
    public let data: [CodexStoredThreadID]
    public let nextCursor: String?

    public init(
        data: [CodexStoredThreadID],
        nextCursor: String?
    ) {
        self.data = data
        self.nextCursor = nextCursor
    }
}

@MainActor
public protocol CodexDesktopLoadedThreadListing: AnyObject {
    func loadedStoredThreads(
        cursor: String?,
        limit: Int?
    ) throws -> CodexDesktopLoadedThreadPage
}

@MainActor
public protocol CodexDesktopThreadUnsubscribing: AnyObject {
    func unsubscribeStoredThread(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws -> CodexThreadUnsubscribeResponse
}

@MainActor
public protocol CodexDesktopAccountSigningOut: AnyObject {
    func signOut()
}

@MainActor
public protocol CodexDesktopMCPServerStatusListing: AnyObject {
    func listMCPServerStatuses(
        cursor: String?,
        limit: Int?,
        detail: CodexMCPServerStatusDetail
    ) throws -> CodexMCPServerStatusPage
}

@MainActor
public protocol CodexDesktopMCPResourceReading: AnyObject {
    func readMCPResource(
        threadID: CodexStoredThreadID?,
        server: String,
        uri: String
    ) async throws -> [CodexMCPResourceContent]
}

public struct CodexDesktopMCPToolCallResult:
    Equatable,
    Sendable
{
    public let content: [CodexJSONValue]
    public let structuredContent: CodexJSONValue?
    public let isError: Bool?
    public let meta: CodexJSONValue?

    public init(
        content: [CodexJSONValue],
        structuredContent: CodexJSONValue? = nil,
        isError: Bool? = nil,
        meta: CodexJSONValue? = nil
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
        self.meta = meta
    }
}

@MainActor
public protocol CodexDesktopMCPToolCalling: AnyObject {
    func callMCPTool(
        threadID: CodexStoredThreadID,
        server: String,
        tool: String,
        arguments: CodexJSONValue?,
        meta: CodexJSONValue?
    ) async throws -> CodexDesktopMCPToolCallResult
}

public struct CodexDesktopMCPOAuthLoginResult: Equatable, Sendable {
    public let authorizationURL: String

    public init(authorizationURL: String) {
        self.authorizationURL = authorizationURL
    }
}

@MainActor
public protocol CodexDesktopMCPServerRefreshing: AnyObject {
    func refreshMCPServers() async throws
}

@MainActor
public protocol CodexDesktopSkillCataloging: AnyObject {
    func listSkills(
        cwds: [String],
        forceReload: Bool
    ) throws -> [CodexSkillsListEntry]

    func setSkillExtraRoots(_ roots: [String])

    func setSkillEnabled(
        path: String?,
        name: String?,
        enabled: Bool
    ) throws -> Bool
}

extension CodexSkillCatalogService: CodexDesktopSkillCataloging {
    public func listSkills(
        cwds: [String],
        forceReload: Bool
    ) throws -> [CodexSkillsListEntry] {
        try list(cwds: cwds, forceReload: forceReload)
    }

    public func setSkillExtraRoots(_ roots: [String]) {
        setExtraRoots(roots)
    }

    public func setSkillEnabled(
        path: String?,
        name: String?,
        enabled: Bool
    ) throws -> Bool {
        try setEnabled(
            path: path,
            name: name,
            enabled: enabled
        )
    }
}

@MainActor
public protocol CodexDesktopHookCataloging: AnyObject {
    func listHooks(cwds: [String]) -> [CodexHooksListEntry]
}

extension CodexHookCatalogService: CodexDesktopHookCataloging {}

@MainActor
public protocol CodexDesktopAppCataloging: AnyObject {
    func listApps(
        cursor: String?,
        limit: Int?,
        forceRefetch: Bool
    ) throws -> CodexAppCatalogPage
    func readApps(
        appIDs: [String],
        includeTools: Bool
    ) throws -> CodexAppReadResult
    func installedApps(
        forceRefresh: Bool
    ) -> [CodexInstalledApp]
}

extension CodexAppCatalogService: CodexDesktopAppCataloging {}

@MainActor
public protocol CodexDesktopSettingsCataloging: AnyObject {
    func listCollaborationModes()
        -> [CodexCollaborationModeMask]
    func listExperimentalFeatures(
        cursor: String?,
        limit: Int?
    ) throws -> CodexExperimentalFeaturePage
    func setExperimentalFeatureEnablement(
        _ enablement: [String: Bool]
    )
    func listPermissionProfiles(
        cursor: String?,
        limit: Int?,
        cwd: String?
    ) throws -> CodexPermissionProfilePage
}

extension CodexExperimentalSettingsService:
    CodexDesktopSettingsCataloging
{}

public protocol CodexDesktopMCPOAuthLoggingIn: Sendable {
    func loginMCPServer(
        hostID: String,
        name: String,
        threadID: String?,
        scopes: [String]?,
        timeoutSeconds: Int64?
    ) async throws -> CodexDesktopMCPOAuthLoginResult
}

extension CodexMCPServerStatusService: CodexDesktopMCPServerStatusListing {
    public func listMCPServerStatuses(
        cursor: String?,
        limit: Int?,
        detail: CodexMCPServerStatusDetail
    ) throws -> CodexMCPServerStatusPage {
        try list(cursor: cursor, limit: limit, detail: detail)
    }
}

public protocol CodexDesktopConfigMutating: AnyObject {
    var configSnapshot: [String: CodexJSONValue] { get }
    func writeConfigValue(
        keyPath: String,
        value: CodexJSONValue,
        mergeStrategy: String
    )
    func batchWriteConfig(
        edits: [(keyPath: String, value: CodexJSONValue, mergeStrategy: String)]
    )
}

public protocol CodexDesktopMemoryResetting: AnyObject {
    func resetMemory() throws
}

extension CodexDesktopConfigStore: CodexDesktopConfigMutating {
    public var configSnapshot: [String: CodexJSONValue] { snapshot }
    public func writeConfigValue(
        keyPath: String, value: CodexJSONValue, mergeStrategy: String
    ) {
        _ = write(keyPath: keyPath, value: value, mergeStrategy: mergeStrategy)
    }
    public func batchWriteConfig(
        edits: [(keyPath: String, value: CodexJSONValue, mergeStrategy: String)]
    ) {
        _ = batchWrite(edits: edits)
    }
}

@MainActor
public protocol CodexDesktopPluginCataloging: AnyObject {
    func listPlugins() -> CodexPluginListResponse

    func readPlugin(
        marketplacePath: String,
        pluginName: String
    ) throws -> CodexPluginDetail

    func installPlugin(
        marketplacePath: String,
        pluginName: String
    ) throws -> CodexPluginInstallResult

    func uninstallPlugin(pluginID: String) throws
}

extension CodexPluginCatalogService:
    CodexDesktopPluginCataloging
{
    public func listPlugins() -> CodexPluginListResponse {
        list()
    }

    public func readPlugin(
        marketplacePath: String,
        pluginName: String
    ) throws -> CodexPluginDetail {
        try read(
            marketplacePath: marketplacePath,
            pluginName: pluginName
        )
    }

    public func installPlugin(
        marketplacePath: String,
        pluginName: String
    ) throws -> CodexPluginInstallResult {
        try install(
            marketplacePath: marketplacePath,
            pluginName: pluginName
        )
    }

    public func uninstallPlugin(pluginID: String) throws {
        try uninstall(pluginID: pluginID)
    }
}

@MainActor
public protocol CodexDesktopRemotePluginCataloging: AnyObject {
    func listRemotePlugins(
        marketplaceKinds: [String],
        forceRefetch: Bool
    ) async throws -> CodexRemotePluginListResponse

    func searchRemotePlugins(
        searchTerm: String,
        scope: String?,
        cwds: [String]?,
        cursor: String?,
        limit: Int?
    ) async throws -> CodexRemotePluginSearchResponse

    func listInstalledRemotePlugins() async throws
        -> [CodexRemotePluginMarketplace]

    func readRemotePlugin(
        marketplaceName: String,
        remotePluginID: String
    ) async throws -> CodexRemotePluginDetail

    func installRemotePlugin(
        marketplaceName: String,
        remotePluginID: String
    ) async throws -> CodexPluginInstallResult

    func uninstallRemotePlugin(pluginID: String) async throws

    func readRemotePluginSkill(
        remotePluginID: String,
        skillName: String
    ) async throws -> String?
}

@MainActor
public protocol CodexDesktopRemotePluginSharing: AnyObject {
    func saveRemotePluginShare(
        pluginPath: URL,
        remotePluginID: String?,
        discoverability: String?,
        shareTargets: [CodexRemotePluginShareTarget]?
    ) async throws -> CodexRemotePluginShareSaveResult

    func checkoutRemotePluginShare(
        remotePluginID: String
    ) async throws -> CodexRemotePluginShareCheckoutResult

    func updateRemotePluginShareTargets(
        remotePluginID: String,
        discoverability: String,
        shareTargets: [CodexRemotePluginShareTarget]
    ) async throws -> CodexRemotePluginShareUpdateResult

    func listRemotePluginShares() async throws
        -> [CodexRemotePluginShareListItem]

    func deleteRemotePluginShare(
        remotePluginID: String
    ) async throws
}

extension CodexRemotePluginService:
    CodexDesktopRemotePluginCataloging
{
    public func listRemotePlugins(
        marketplaceKinds: [String],
        forceRefetch: Bool
    ) async throws -> CodexRemotePluginListResponse {
        try await list(
            marketplaceKinds: marketplaceKinds,
            forceRefetch: forceRefetch
        )
    }

    public func searchRemotePlugins(
        searchTerm: String,
        scope: String?,
        cwds: [String]?,
        cursor: String?,
        limit: Int?
    ) async throws -> CodexRemotePluginSearchResponse {
        try await search(
            searchTerm: searchTerm,
            scope: scope,
            cwds: cwds,
            cursor: cursor,
            limit: limit
        )
    }

    public func listInstalledRemotePlugins() async throws
        -> [CodexRemotePluginMarketplace]
    {
        try await installed()
    }

    public func readRemotePlugin(
        marketplaceName: String,
        remotePluginID: String
    ) async throws -> CodexRemotePluginDetail {
        try await read(
            marketplaceName: marketplaceName,
            remotePluginID: remotePluginID
        )
    }

    public func installRemotePlugin(
        marketplaceName: String,
        remotePluginID: String
    ) async throws -> CodexPluginInstallResult {
        try await install(
            marketplaceName: marketplaceName,
            remotePluginID: remotePluginID
        )
    }

    public func uninstallRemotePlugin(
        pluginID: String
    ) async throws {
        try await uninstall(pluginID: pluginID)
    }

    public func readRemotePluginSkill(
        remotePluginID: String,
        skillName: String
    ) async throws -> String? {
        try await skillContents(
            remotePluginID: remotePluginID,
            skillName: skillName
        )
    }
}

extension CodexRemotePluginService:
    CodexDesktopRemotePluginSharing
{
    public func saveRemotePluginShare(
        pluginPath: URL,
        remotePluginID: String?,
        discoverability: String?,
        shareTargets: [CodexRemotePluginShareTarget]?
    ) async throws -> CodexRemotePluginShareSaveResult {
        try await saveShare(
            pluginPath: pluginPath,
            remotePluginID: remotePluginID,
            discoverability: discoverability,
            shareTargets: shareTargets
        )
    }

    public func checkoutRemotePluginShare(
        remotePluginID: String
    ) async throws -> CodexRemotePluginShareCheckoutResult {
        try await checkoutShare(remotePluginID: remotePluginID)
    }

    public func updateRemotePluginShareTargets(
        remotePluginID: String,
        discoverability: String,
        shareTargets: [CodexRemotePluginShareTarget]
    ) async throws -> CodexRemotePluginShareUpdateResult {
        try await updateShareTargets(
            remotePluginID: remotePluginID,
            discoverability: discoverability,
            shareTargets: shareTargets
        )
    }

    public func listRemotePluginShares() async throws
        -> [CodexRemotePluginShareListItem]
    {
        try await listShares()
    }

    public func deleteRemotePluginShare(
        remotePluginID: String
    ) async throws {
        try await deleteShare(remotePluginID: remotePluginID)
    }
}

extension CodexAccountStore: CodexDesktopAccountSigningOut {}

/// Injectable model-list capability layered onto the same app-server
/// transport used by the released renderer.
@MainActor
public protocol CodexDesktopModelSessionListing: AnyObject {
    func listModels(
        id: CodexAppServerRequestID,
        params: CodexModelListParams
    ) throws -> CodexModelListResponse
}

/// Injectable stable turn-start capability used by the released Composer.
@MainActor
public protocol CodexDesktopTurnSessionStarting: AnyObject {
    func startDesktopTurn(
        id: CodexAppServerRequestID,
        params: CodexTurnStartParams
    ) throws -> CodexTurnStartResult
}

@MainActor
public protocol CodexDesktopReviewStarting: AnyObject {
    func startDesktopReview(
        id: CodexAppServerRequestID,
        params: CodexReviewStartParams
    ) throws -> CodexReviewStartResult
}

@MainActor
public protocol CodexDesktopElicitationCounting: AnyObject {
    func incrementDesktopElicitation(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws -> Int64

    func decrementDesktopElicitation(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws -> Int64
}

/// Injectable stable turn-interrupt capability used by the released Composer.
@MainActor
public protocol CodexDesktopTurnSessionInterrupting: AnyObject {
    func interruptDesktopTurn(
        threadID: CodexStoredThreadID,
        turnID: String
    ) throws
}

/// Injectable stable turn-steer capability used while a turn is active.
@MainActor
public protocol CodexDesktopTurnSessionSteering: AnyObject {
    func steerDesktopTurn(
        params: CodexTurnSteerParams
    ) throws -> CodexTurnSteerResult
}

@MainActor
public protocol CodexDesktopThreadCompacting: AnyObject {
    func startDesktopCompaction(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws
}

extension CodexSessionStore:
    CodexDesktopThreadSessionListing,
    CodexDesktopThreadSessionReading,
    CodexDesktopThreadSessionResuming,
    CodexDesktopThreadSessionStarting,
    CodexDesktopThreadSessionForking,
    CodexDesktopThreadItemsInjecting,
    CodexDesktopGuardianDeniedActionApproving,
    CodexDesktopThreadShellCommandRunning,
    CodexDesktopThreadSessionMutating,
    CodexDesktopThreadQueueManaging,
    CodexDesktopThreadSessionSearching,
    CodexDesktopThreadSectionListing,
    CodexDesktopThreadSectionMutating,
    CodexDesktopThreadMetadataUpdating,
    CodexDesktopThreadSettingsUpdating,
    CodexDesktopThreadMemoryModeUpdating,
    CodexDesktopThreadGoalManaging,
    CodexDesktopLoadedThreadListing,
    CodexDesktopThreadUnsubscribing,
    CodexDesktopModelSessionListing,
    CodexDesktopTurnSessionStarting
{}

/// Handles the app-server methods requested by the released renderer before
/// its initial project/thread surface is available.
///
/// The returned envelope matches the desktop main-to-renderer bridge:
/// `{ type: "mcp-response", hostId, message }`. Startup requests carry no
/// trace metadata, so this router never mirrors renderer-side routing fields
/// into the host response.
public enum CodexDesktopInitialMCPRouter {
    private enum ThreadParamsDecodingError: Error {
        case invalidParams
    }

    private enum FileReadOutcome:
        Sendable
    {
        case success(Data)
        case failure(
            domain: String,
            code: Int,
            description: String
        )
    }

    /// Produces a filesystem diagnostic that is useful on a physical iPad
    /// without exposing the app-container root, a workspace root, or UUIDs.
    /// The classification is lexical and performs no filesystem access.
    public static func fileReadDiagnosticSummary(
        path: String,
        applicationRoot: String,
        codexHome: String,
        workspaceRoots: [String]
    ) -> String {
        guard !path.isEmpty,
              !path.contains("\0"),
              (path as NSString).isAbsolutePath
        else {
            return "scope=invalid-path"
        }

        if let relativePath = diagnosticRelativePath(
            path: path,
            root: codexHome
        ) {
            return "scope=codex-home path=\(relativePath)"
        }
        for workspaceRoot in workspaceRoots {
            if let relativePath = diagnosticRelativePath(
                path: path,
                root: workspaceRoot
            ) {
                return "scope=workspace path=\(relativePath)"
            }
        }
        if let relativePath = diagnosticRelativePath(
            path: path,
            root: applicationRoot
        ) {
            return "scope=application-root path=\(relativePath)"
        }
        return "scope=outside-roots"
    }

    /// Extends the released startup router with the app-server
    /// `fs/readFile` contract. iPadOS confines reads to the app container
    /// and user-selected workspace roots supplied by the controller.
    @MainActor
    public static func responseIncludingFileSystem(
        to request: CodexDesktopMCPRequest,
        state: CodexDesktopInitialMCPState,
        allowedFileSystemRoots: [String],
        threadLister:
            (any CodexDesktopThreadSessionListing)? = nil,
        modelLister:
            (any CodexDesktopModelSessionListing)? = nil,
        turnStarter:
            (any CodexDesktopTurnSessionStarting)? = nil,
        commandExecutor:
            (any CodexDesktopCommandExecuting)? = nil,
        accountStore:
            (any CodexDesktopAccountSigningOut)? = nil,
        configStore:
            (any CodexDesktopConfigMutating)? = nil,
        memoryResetter:
            (any CodexDesktopMemoryResetting)? = nil,
        rateLimitsReader:
            (any CodexDesktopAccountRateLimitsReading)? = nil,
        fileWatcher:
            (any CodexDesktopFileWatching)? = nil,
        fuzzyFileSearch:
            (any CodexDesktopFuzzyFileSearching)? = nil,
        mcpStatusLister:
            (any CodexDesktopMCPServerStatusListing)? = nil,
        mcpResourceReader:
            (any CodexDesktopMCPResourceReading)? = nil,
        mcpToolCaller:
            (any CodexDesktopMCPToolCalling)? = nil,
        mcpRefresher:
            (any CodexDesktopMCPServerRefreshing)? = nil,
        mcpOAuthLogin:
            (any CodexDesktopMCPOAuthLoggingIn)? = nil,
        skillCatalog:
            (any CodexDesktopSkillCataloging)? = nil,
        hookCatalog:
            (any CodexDesktopHookCataloging)? = nil,
        appCatalog:
            (any CodexDesktopAppCataloging)? = nil,
        appListUpdated:
            ((CodexDesktopHostMessage) -> Void)? = nil,
        settingsCatalog:
            (any CodexDesktopSettingsCataloging)? = nil,
        marketplaceManager:
            (any CodexDesktopMarketplaceManaging)? = nil,
        pluginCatalog:
            (any CodexDesktopPluginCataloging)? = nil,
        remotePluginCatalog:
            (any CodexDesktopRemotePluginCataloging)? = nil,
        externalAgentConfig:
            (any CodexDesktopExternalAgentConfigMigrating)? = nil,
        gitDiffer:
            (any CodexDesktopGitDiffing)? = nil,
        feedbackUploader:
            (any CodexDesktopFeedbackUploading)? = nil,
        environmentManager:
            (any CodexDesktopEnvironmentManaging)? = nil,
        realtimeManager:
            (any CodexDesktopRealtimeManaging)? = nil,
        extendedSessionBackend:
            (any CodexDesktopExtendedSessionRequesting)? = nil,
        fileManager: FileManager = .default
    ) async -> CodexDesktopHostMessage {
        switch request.request.method {
        case "thread/realtime/listVoices":
            guard case .object? = request.request.params else {
                return invalidParams(request)
            }
            return result(
                request,
                value: realtimeVoicesResult()
            )
        case "thread/realtime/start",
             "thread/realtime/appendAudio",
             "thread/realtime/appendText",
             "thread/realtime/appendSpeech",
             "thread/realtime/stop":
            return await realtimeResponse(
                to: request,
                using: realtimeManager
            )
        case "environment/add",
             "environment/info",
             "environment/status":
            return await environmentResponse(
                to: request,
                using: environmentManager
            )
        case "feedback/upload":
            return await feedbackUploadResponse(
                to: request,
                allowedRoots: allowedFileSystemRoots,
                using: feedbackUploader
            )
        case "externalAgentConfig/detect":
            guard let externalAgentConfig else {
                return error(
                    request,
                    code: -32603,
                    message:
                        "External agent configuration service unavailable"
                )
            }
            guard let options = externalAgentDetectOptions(
                request.request.params
            ) else {
                return invalidParams(request)
            }
            do {
                let items = try externalAgentConfig
                    .detectExternalAgentConfiguration(
                        options: options
                    )
                return result(
                    request,
                    value: .object([
                        "items": .array(
                            items.map(\.wireValue)
                        ),
                    ])
                )
            } catch {
                return Self.error(
                    request,
                    code: -32603,
                    message:
                        "External agent configuration detection failed"
                )
            }
        case "externalAgentConfig/import":
            guard let externalAgentConfig else {
                return error(
                    request,
                    code: -32603,
                    message:
                        "External agent configuration service unavailable"
                )
            }
            guard let decoded = externalAgentImportParams(
                request.request.params
            ) else {
                return invalidParams(request)
            }
            let importID = externalAgentConfig
                .startExternalAgentConfigurationImport(
                    migrationItems: decoded.items,
                    source: decoded.source,
                    providerID: decoded.providerID,
                    migrationSource: decoded.migrationSource
                )
            return result(
                request,
                value: .object([
                    "importId": .string(importID),
                ])
            )
        case "externalAgentConfig/import/recordHistory":
            guard let externalAgentConfig else {
                return error(
                    request,
                    code: -32603,
                    message:
                        "External agent configuration service unavailable"
                )
            }
            guard case let .object(params)? =
                    request.request.params,
                  Set(params.keys)
                    == Set(["providerId", "itemTypeResults"]),
                  case let .string(providerID)? =
                    params["providerId"],
                  !providerID.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  case let .array(results)? =
                    params["itemTypeResults"]
            else {
                return invalidParams(request)
            }
            do {
                let importID = try externalAgentConfig
                    .recordExternalAgentConfigurationImportHistory(
                        providerID: providerID,
                        itemTypeResults: results
                    )
                return result(
                    request,
                    value: .object([
                        "importId": .string(importID),
                    ])
                )
            } catch {
                return invalidParams(request)
            }
        case "externalAgentConfig/import/readHistories":
            guard hasUnitParams(request.request.params) else {
                return invalidParams(request)
            }
            guard let externalAgentConfig else {
                return error(
                    request,
                    code: -32603,
                    message:
                        "External agent configuration service unavailable"
                )
            }
            do {
                return result(
                    request,
                    value: try externalAgentConfig
                        .readExternalAgentConfigurationImportHistories()
                )
            } catch {
                return Self.error(
                    request,
                    code: -32603,
                    message:
                        "External agent import history read failed"
                )
            }
        case "memory/reset":
            guard hasUnitParams(request.request.params) else {
                return invalidParams(request)
            }
            guard let memoryResetter else {
                return error(
                    request,
                    code: -32603,
                    message: "Memory reset unavailable"
                )
            }
            do {
                try memoryResetter.resetMemory()
                return result(request, value: .object([:]))
            } catch {
                return Self.error(
                    request,
                    code: -32603,
                    message: "Memory reset failed"
                )
            }
        case "collaborationMode/list":
            return collaborationModeListResponse(
                to: request,
                using: settingsCatalog
            )
        case "experimentalFeature/list":
            return experimentalFeatureListResponse(
                to: request,
                using: settingsCatalog
            )
        case "experimentalFeature/enablement/set":
            return experimentalFeatureEnablementSetResponse(
                to: request,
                using: settingsCatalog
            )
        case "permissionProfile/list":
            return permissionProfileListResponse(
                to: request,
                using: settingsCatalog
            )
        case "app/list":
            return appsListResponse(
                to: request,
                using: appCatalog,
                appListUpdated: appListUpdated
            )
        case "app/read":
            return appsReadResponse(
                to: request,
                using: appCatalog
            )
        case "app/installed":
            return appsInstalledResponse(
                to: request,
                using: appCatalog
            )
        case "marketplace/add":
            return await marketplaceAddResponse(
                to: request,
                using: marketplaceManager
            )
        case "marketplace/remove":
            return marketplaceRemoveResponse(
                to: request,
                using: marketplaceManager
            )
        case "marketplace/upgrade":
            return await marketplaceUpgradeResponse(
                to: request,
                using: marketplaceManager
            )
        case "plugin/list", "plugin/installed":
            return await pluginListResponse(
                to: request,
                using: pluginCatalog,
                remote: remotePluginCatalog
            )
        case "plugin/search":
            return await pluginSearchResponse(
                to: request,
                using: remotePluginCatalog
            )
        case "plugin/read":
            return await pluginReadResponse(
                to: request,
                using: pluginCatalog,
                remote: remotePluginCatalog
            )
        case "plugin/skill/read":
            return await pluginSkillReadResponse(
                to: request,
                using: remotePluginCatalog
            )
        case "plugin/install":
            return await pluginInstallResponse(
                to: request,
                using: pluginCatalog,
                remote: remotePluginCatalog
            )
        case "plugin/uninstall":
            return await pluginUninstallResponse(
                to: request,
                using: pluginCatalog,
                remote: remotePluginCatalog
            )
        case "plugin/share/save":
            return await pluginShareSaveResponse(
                to: request,
                using: remotePluginCatalog
                    as? any CodexDesktopRemotePluginSharing
            )
        case "plugin/share/updateTargets":
            return await pluginShareUpdateTargetsResponse(
                to: request,
                using: remotePluginCatalog
                    as? any CodexDesktopRemotePluginSharing
            )
        case "plugin/share/list":
            return await pluginShareListResponse(
                to: request,
                using: remotePluginCatalog
                    as? any CodexDesktopRemotePluginSharing
            )
        case "plugin/share/checkout":
            return await pluginShareCheckoutResponse(
                to: request,
                using: remotePluginCatalog
                    as? any CodexDesktopRemotePluginSharing
            )
        case "plugin/share/delete":
            return await pluginShareDeleteResponse(
                to: request,
                using: remotePluginCatalog
                    as? any CodexDesktopRemotePluginSharing
            )
        default:
            break
        }
        if request.request.method == "skills/list" {
            return skillsListResponse(
                to: request,
                using: skillCatalog
            )
        }
        if request.request.method == "hooks/list" {
            return hooksListResponse(
                to: request,
                using: hookCatalog
            )
        }
        if request.request.method == "skills/extraRoots/set" {
            return skillsExtraRootsSetResponse(
                to: request,
                using: skillCatalog
            )
        }
        if request.request.method == "skills/config/write" {
            return skillsConfigWriteResponse(
                to: request,
                using: skillCatalog
            )
        }
        if request.request.method == "config/mcpServer/reload" {
            guard hasUnitParams(request.request.params) else {
                return invalidParams(request)
            }
            guard let mcpRefresher else {
                return Self.error(
                    request,
                    code: -32603,
                    message: "MCP configuration refresh unavailable"
                )
            }
            do {
                try await mcpRefresher.refreshMCPServers()
                return result(request, value: .object([:]))
            } catch {
                return Self.error(
                    request,
                    code: -32603,
                    message: "MCP configuration refresh failed"
                )
            }
        }
        if request.request.method == "mcpServer/oauth/login" {
            return await mcpServerOAuthLoginResponse(
                to: request,
                using: mcpOAuthLogin
            )
        }
        if request.request.method == "mcpServerStatus/list" {
            return mcpServerStatusListResponse(
                to: request,
                using: mcpStatusLister
            )
        }
        if request.request.method == "mcpServer/resource/read" {
            return await mcpServerResourceReadResponse(
                to: request,
                threadReader:
                    threadLister
                        as? any CodexDesktopThreadSessionReading,
                resourceReader: mcpResourceReader
            )
        }
        if request.request.method == "mcpServer/tool/call" {
            return await mcpServerToolCallResponse(
                to: request,
                threadReader:
                    threadLister
                        as? any CodexDesktopThreadSessionReading,
                toolCaller: mcpToolCaller
            )
        }
        if [
            "account/usage/read",
            "account/workspaceMessages/read",
            "account/rateLimitResetCredit/consume",
            "account/sendAddCreditsNudgeEmail",
        ].contains(request.request.method) {
            guard let rateLimitsReader else {
                return error(
                    request,
                    code: -32603,
                    message: "Account service unavailable"
                )
            }
            do {
                let value: CodexJSONValue
                switch request.request.method {
                case "account/usage/read":
                    let threadID: String?
                    switch request.request.params {
                    case nil, .null:
                        threadID = nil
                    case let .object(params):
                        guard Set(params.keys).isSubset(of: ["threadId"]) else {
                            return invalidParams(request)
                        }
                        switch params["threadId"] {
                        case nil, .null:
                            threadID = nil
                        case let .string(value):
                            guard !value.isEmpty,
                                  let uuid = UUID(uuidString: value)
                            else { return invalidParams(request) }
                            // app-server parses ThreadId and re-serializes it
                            // before the backend request. Keep the same
                            // canonical lowercase UUID on iPad so uppercase
                            // client input cannot drift from the official wire
                            // contract.
                            threadID = uuid.uuidString.lowercased()
                        default:
                            return invalidParams(request)
                        }
                    default:
                        return invalidParams(request)
                    }
                    value = try await rateLimitsReader.readAccountUsage(threadID: threadID)
                case "account/workspaceMessages/read":
                    guard hasUnitParams(request.request.params)
                    else { return invalidParams(request) }
                    value = try await rateLimitsReader.readWorkspaceMessages()
                case "account/rateLimitResetCredit/consume":
                    guard case let .object(params)? = request.request.params,
                          case let .string(key)? = params["idempotencyKey"],
                          !key.isEmpty
                    else { return invalidParams(request) }
                    let creditID: String?
                    if case let .string(value)? = params["creditId"] {
                        creditID = value
                    } else if params["creditId"] == nil
                                || params["creditId"] == .null {
                        creditID = nil
                    } else {
                        return invalidParams(request)
                    }
                    value = try await rateLimitsReader
                        .consumeRateLimitResetCredit(
                            idempotencyKey: key,
                            creditID: creditID
                        )
                default:
                    guard case let .object(params)? = request.request.params,
                          case let .string(creditType)? = params["creditType"],
                          ["credits", "usage_limit"].contains(creditType)
                    else { return invalidParams(request) }
                    value = try await rateLimitsReader
                        .sendAddCreditsNudgeEmail(
                            creditType: creditType
                        )
                }
                return result(request, value: value)
            } catch CodexAccountRateLimitsClient.RateLimitError.signedOut {
                return error(
                    request,
                    code: -32600,
                    message:
                        "ChatGPT authentication required for account service"
                )
            } catch {
                return Self.error(
                    request,
                    code: -32603,
                    message: "Account service request failed"
                )
            }
        }
        if request.request.method == "account/rateLimits/read" {
            guard hasUnitParams(request.request.params) else { return invalidParams(request) }
            guard let rateLimitsReader else { return error(request, code: -32603, message: "Account rate limits unavailable") }
            do { return result(request, value: try await rateLimitsReader.readAccountRateLimits()) }
            catch CodexAccountRateLimitsClient.RateLimitError.signedOut { return error(request, code: -32600, message: "ChatGPT authentication required to read rate limits") }
            catch { return Self.error(request, code: -32603, message: "Account rate limits request failed") }
        }
        if request.request.method == "account/logout" {
            guard hasUnitParams(request.request.params) else {
                return invalidParams(request)
            }
            guard let accountStore else {
                return error(
                    request,
                    code: -32603,
                    message: "Account sign-out unavailable"
                )
            }
            accountStore.signOut()
            return result(request, value: .object([:]))
        }
        if request.request.method == "config/value/write" {
            return configValueWriteResponse(to: request, using: configStore)
        }
        if request.request.method == "config/batchWrite" {
            return configBatchWriteResponse(to: request, using: configStore)
        }
        if request.request.method == "process/spawn" {
            return processSpawnResponse(
                to: request,
                allowedRoots: allowedFileSystemRoots,
                using: commandExecutor
                    as? any CodexDesktopProcessManaging
            )
        }
        if request.request.method == "process/writeStdin" {
            return processWriteResponse(
                to: request,
                using: commandExecutor
                    as? any CodexDesktopProcessManaging
            )
        }
        if request.request.method == "process/resizePty" {
            return processResizeResponse(
                to: request,
                using: commandExecutor
                    as? any CodexDesktopProcessManaging
            )
        }
        if request.request.method == "process/kill" {
            return processKillResponse(
                to: request,
                using: commandExecutor
                    as? any CodexDesktopProcessManaging
            )
        }
        if request.request.method == "command/exec" {
            return await commandExecResponse(
                to: request,
                allowedRoots: allowedFileSystemRoots,
                using: commandExecutor
            )
        }
        if request.request.method == "command/exec/write" {
            return commandExecWriteResponse(
                to: request,
                using: commandExecutor
            )
        }
        if request.request.method == "command/exec/resize" {
            return commandExecResizeResponse(
                to: request,
                using: commandExecutor
            )
        }
        if request.request.method == "command/exec/terminate" {
            return commandExecTerminateResponse(
                to: request,
                using: commandExecutor
            )
        }
        if request.request.method
            == "thread/backgroundTerminals/list"
        {
            return threadBackgroundTerminalsListResponse(
                to: request,
                using: commandExecutor
                    as? any CodexDesktopBackgroundTerminalManaging
            )
        }
        if request.request.method
            == "thread/backgroundTerminals/terminate"
        {
            return threadBackgroundTerminalsTerminateResponse(
                to: request,
                using: commandExecutor
                    as? any CodexDesktopBackgroundTerminalManaging
            )
        }
        if request.request.method
            == "thread/backgroundTerminals/clean"
        {
            return threadBackgroundTerminalsCleanResponse(
                to: request,
                using: commandExecutor
                    as? any CodexDesktopBackgroundTerminalManaging
            )
        }
        if request.request.method == "turn/start" {
            return await turnStartResponse(
                to: request,
                using: turnStarter
            )
        }
        if request.request.method == "review/start" {
            return reviewStartResponse(
                to: request,
                using: turnStarter
                    as? any CodexDesktopReviewStarting
            )
        }
        if request.request.method
            == "thread/increment_elicitation"
        {
            return elicitationCountResponse(
                to: request,
                incrementing: true,
                using: turnStarter
                    as? any CodexDesktopElicitationCounting
            )
        }
        if request.request.method
            == "thread/decrement_elicitation"
        {
            return elicitationCountResponse(
                to: request,
                incrementing: false,
                using: turnStarter
                    as? any CodexDesktopElicitationCounting
            )
        }
        if request.request.method == "turn/interrupt" {
            return await turnInterruptResponse(
                to: request,
                using: turnStarter
                    as? any CodexDesktopTurnSessionInterrupting
            )
        }
        if request.request.method == "turn/steer" {
            return await turnSteerResponse(
                to: request,
                using: turnStarter
                    as? any CodexDesktopTurnSessionSteering
            )
        }
        if request.request.method == "thread/compact/start" {
            return await threadCompactStartResponse(
                to: request,
                using: turnStarter
                    as? any CodexDesktopThreadCompacting
            )
        }
        if request.request.method == "model/list" {
            return await modelListResponse(
                to: request,
                using: modelLister
            )
        }
        if request.request.method == "thread/list" {
            return await threadListResponse(
                to: request,
                using: threadLister
            )
        }
        if request.request.method == "thread/loaded/list" {
            return await loadedThreadListResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopLoadedThreadListing
            )
        }
        if request.request.method == "thread/unsubscribe" {
            return await threadUnsubscribeResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadUnsubscribing
            )
        }
        if request.request.method == "thread/read" {
            return await threadReadResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadSessionReading,
                fileManager: fileManager
            )
        }
        if request.request.method == "getConversationSummary" {
            return conversationSummaryResponse(
                to: request,
                using: threadLister
            )
        }
        if request.request.method == "thread/turns/list" {
            return threadTurnsListResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadHistoryPaging
            )
        }
        if request.request.method == "thread/items/list" {
            return threadItemsListResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadHistoryPaging
            )
        }
        if request.request.method == "thread/searchOccurrences" {
            return threadSearchOccurrencesResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadHistoryPaging
            )
        }
        if request.request.method == "thread/resume" {
            return await threadResumeResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadSessionResuming,
                fileManager: fileManager
            )
        }
        if request.request.method == "thread/start" {
            return await threadStartResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadSessionStarting
            )
        }
        if request.request.method == "thread/fork" {
            return await threadForkResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadSessionForking
            )
        }
        if request.request.method == "thread/inject_items" {
            return await threadInjectItemsResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadItemsInjecting
            )
        }
        if request.request.method == "thread/approveGuardianDeniedAction" {
            return await threadApproveGuardianDeniedActionResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopGuardianDeniedActionApproving
            )
        }
        if request.request.method == "thread/shellCommand" {
            return await threadShellCommandResponse(
                to: request,
                allowedRoots: allowedFileSystemRoots,
                using: threadLister
                    as? any CodexDesktopThreadShellCommandRunning,
                executor: commandExecutor
            )
        }
        if request.request.method == "thread/search" {
            return await threadSearchResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadSessionSearching
            )
        }
        if request.request.method == "threadSection/list" {
            return await threadSectionListResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadSectionListing
            )
        }
        if [
            "threadSection/create",
            "threadSection/update",
            "threadSection/delete",
            "thread/section/move",
        ].contains(request.request.method) {
            return await threadSectionMutationResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadSectionMutating
            )
        }
        if request.request.method == "thread/metadata/update" {
            return await threadMetadataUpdateResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadMetadataUpdating
            )
        }
        if request.request.method == "thread/settings/update" {
            return await threadSettingsUpdateResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadSettingsUpdating
            )
        }
        if request.request.method == "thread/memoryMode/set" {
            return await threadMemoryModeSetResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadMemoryModeUpdating
            )
        }
        if request.request.method == "gitDiffToRemote" {
            return await gitDiffToRemoteResponse(
                to: request,
                allowedRoots: allowedFileSystemRoots,
                using: gitDiffer
            )
        }
        if [
            "thread/goal/get",
            "thread/goal/set",
            "thread/goal/clear",
        ].contains(request.request.method) {
            return await threadGoalResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadGoalManaging
            )
        }
        if [
            "thread/queue/add",
            "thread/queue/list",
            "thread/queue/update",
            "thread/queue/delete",
            "thread/queue/reorder",
            "thread/queue/start",
        ].contains(request.request.method) {
            return await threadQueueResponse(
                to: request,
                using: threadLister as? any CodexDesktopThreadQueueManaging
            )
        }
        if [
            "thread/archive",
            "thread/unarchive",
            "thread/delete",
            "thread/name/set",
            "thread/rollback",
            "thread/revert",
        ].contains(request.request.method) {
            return await threadMutationResponse(
                to: request,
                using: threadLister
                    as? any CodexDesktopThreadSessionMutating
            )
        }
        if [
            "fs/writeFile",
            "fs/createDirectory",
            "fs/getMetadata",
            "fs/readDirectory",
            "fs/remove",
            "fs/copy",
        ].contains(request.request.method) {
            return await fileSystemMutationResponse(
                to: request,
                allowedRoots: allowedFileSystemRoots
            )
        }
        if [
            "fuzzyFileSearch",
            "fuzzyFileSearch/sessionStart",
            "fuzzyFileSearch/sessionUpdate",
            "fuzzyFileSearch/sessionStop",
        ].contains(request.request.method) {
            return await fuzzyFileSearchResponse(
                to: request,
                allowedRoots: allowedFileSystemRoots,
                using: fuzzyFileSearch
            )
        }
        if request.request.method == "fs/watch" {
            guard case let .object(params)? = request.request.params,
                  case let .string(watchID)? = params["watchId"],
                  case let .string(rawPath)? = params["path"],
                  let path = confinedFileURL(
                      path: rawPath,
                      allowedRoots: allowedFileSystemRoots
                  ),
                  let fileWatcher
            else { return invalidParams(request) }
            do {
                let canonical = try fileWatcher.watch(
                    watchID: watchID,
                    path: path,
                    hostID: request.hostID
                )
                return result(
                    request,
                    value: .object(["path": .string(canonical)])
                )
            } catch {
                return Self.error(
                    request,
                    code: -32603,
                    message: "Filesystem watch failed"
                )
            }
        }
        if request.request.method == "fs/unwatch" {
            guard case let .object(params)? = request.request.params,
                  case let .string(watchID)? = params["watchId"],
                  !watchID.isEmpty,
                  let fileWatcher
            else { return invalidParams(request) }
            fileWatcher.unwatch(watchID: watchID)
            return result(request, value: .object([:]))
        }
        if CodexDesktopExtendedSessionMethod(
            rawValue: request.request.method
        ) != nil {
            return await extendedSessionResponse(
                to: request,
                using: extendedSessionBackend
            )
        }
        guard request.request.method == "fs/readFile" else {
            return response(
                to: request,
                state: state,
                configStore: configStore
            )
        }
        guard case let .object(params)? = request.request.params else {
            return releasedInvalidRequest(
                request,
                message: "Invalid request: missing field `path`"
            )
        }
        guard let pathValue = params["path"] else {
            return releasedInvalidRequest(
                request,
                message: "Invalid request: missing field `path`"
            )
        }
        guard case let .string(path) = pathValue else {
            return releasedInvalidRequest(
                request,
                message:
                    "Invalid request: \(releasedPathTypeError(pathValue))"
            )
        }
        guard (path as NSString).isAbsolutePath else {
            return releasedInvalidRequest(
                request,
                message:
                    "Invalid request: AbsolutePathBuf deserialized without a base path"
            )
        }
        guard let fileURL = confinedFileURL(
            path: path,
            allowedRoots: allowedFileSystemRoots
        ) else {
            return invalidParams(request)
        }

        let outcome = await Task.detached(
            priority: .userInitiated
        ) {
            do {
                return FileReadOutcome.success(
                    try Data(
                        contentsOf: fileURL,
                        options: [.mappedIfSafe]
                    )
                )
            } catch {
                let error = error as NSError
                return FileReadOutcome.failure(
                    domain: error.domain,
                    code: error.code,
                    description: error.localizedDescription
                )
            }
        }.value

        switch outcome {
        case let .success(data):
            return result(
                request,
                value: .object([
                    "dataBase64": .string(
                        data.base64EncodedString()
                    )
                ])
            )

        case let .failure(domain, code, description):
            return Self.error(
                request,
                code: -32603,
                message: releasedFileSystemErrorMessage(
                    domain: domain,
                    code: code,
                    description: description
                )
            )
        }
    }

    @MainActor
    private static func feedbackUploadResponse(
        to request: CodexDesktopMCPRequest,
        allowedRoots: [String],
        using uploader: (any CodexDesktopFeedbackUploading)?
    ) async -> CodexDesktopHostMessage {
        guard let uploader else {
            return error(
                request,
                code: -32603,
                message: "Feedback upload service unavailable"
            )
        }
        guard case let .object(params)? = request.request.params,
              case let .string(classification)? =
                  params["classification"],
              !classification.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              let reason = nullableString(
                  params["reason"]
              ),
              let threadID = nullableString(
                  params["threadId"]
              ),
              threadID == nil || UUID(uuidString: threadID!) != nil,
              let includeLogs = optionalBool(
                  params["includeLogs"],
                  default: false
              ),
              let rawExtraFiles = nullableStringArray(
                  params["extraLogFiles"]
              ),
              let tags = nullableStringMap(params["tags"])
        else {
            return invalidParams(request)
        }

        var extraFiles: [URL] = []
        for rawPath in rawExtraFiles ?? [] {
            guard let file = confinedFileURL(
                path: rawPath,
                allowedRoots: allowedRoots
            ) else {
                return invalidParams(request)
            }
            extraFiles.append(file)
        }

        do {
            let trackingThreadID = try await uploader.uploadFeedback(
                CodexFeedbackUploadParameters(
                    classification: classification,
                    reason: reason,
                    threadID: threadID,
                    includeLogs: includeLogs,
                    extraLogFiles: extraFiles,
                    tags: tags ?? [:]
                )
            )
            return result(
                request,
                value: .object([
                    "threadId": .string(trackingThreadID),
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Feedback upload failed"
            )
        }
    }

    private static func optionalBool(
        _ value: CodexJSONValue?,
        default defaultValue: Bool
    ) -> Bool? {
        guard let value else { return defaultValue }
        guard case let .bool(boolean) = value else {
            return nil
        }
        return boolean
    }

    private static func nullableStringArray(
        _ value: CodexJSONValue?
    ) -> [String]?? {
        guard let value else { return .some(nil) }
        switch value {
        case .null:
            return .some(nil)
        case let .array(values):
            var result: [String] = []
            for value in values {
                guard case let .string(string) = value else {
                    return nil
                }
                result.append(string)
            }
            return .some(result)
        default:
            return nil
        }
    }

    private static func nullableStringMap(
        _ value: CodexJSONValue?
    ) -> [String: String]?? {
        guard let value else { return .some(nil) }
        switch value {
        case .null:
            return .some(nil)
        case let .object(values):
            var result: [String: String] = [:]
            for (key, value) in values {
                guard case let .string(string) = value else {
                    return nil
                }
                result[key] = string
            }
            return .some(result)
        default:
            return nil
        }
    }

    private static func externalAgentDetectOptions(
        _ value: CodexJSONValue?
    ) -> CodexExternalAgentDetectOptions? {
        guard case let .object(params)? = value,
              Set(params.keys).isSubset(
                  of: Set([
                      "includeHome",
                      "cwds",
                      "maxSessionAgeDays",
                      "maxSessions",
                      "source",
                      "migrationSource",
                  ])
              )
        else { return nil }

        func optionalBool(_ key: String) -> Bool? {
            guard let value = params[key] else { return false }
            if case let .bool(flag) = value { return flag }
            return nil
        }
        func optionalInteger(
            _ key: String,
            default defaultValue: Int
        ) -> Int? {
            guard let value = params[key] else {
                return defaultValue
            }
            if case .null = value {
                return defaultValue
            }
            guard case let .integer(integer) = value,
                  integer >= 0,
                  integer <= Int64(Int.max)
            else { return nil }
            return Int(integer)
        }
        func nullableString(_ key: String) -> String?? {
            guard let value = params[key] else {
                return .some(nil)
            }
            switch value {
            case .null:
                return .some(nil)
            case let .string(text):
                return .some(text)
            default:
                return nil
            }
        }

        guard let includeHome = optionalBool("includeHome"),
              let maxAge = optionalInteger(
                  "maxSessionAgeDays",
                  default: 30
              ),
              let maxSessions = optionalInteger(
                  "maxSessions",
                  default: 50
              ),
              let migrationSource = nullableString(
                  "migrationSource"
              ),
              nullableString("source") != nil
        else { return nil }

        let cwds: [String]
        switch params["cwds"] {
        case nil, .null?:
            cwds = []
        case let .array(values)?:
            let decoded = values.compactMap { value -> String? in
                if case let .string(path) = value,
                   !path.isEmpty
                {
                    return path
                }
                return nil
            }
            guard decoded.count == values.count else {
                return nil
            }
            cwds = decoded
        default:
            return nil
        }

        return CodexExternalAgentDetectOptions(
            includeHome: includeHome,
            cwds: cwds,
            maxSessionAgeDays: maxAge,
            maxSessions: maxSessions,
            migrationSource: migrationSource
        )
    }

    private static func externalAgentImportParams(
        _ value: CodexJSONValue?
    ) -> (
        items: [CodexExternalAgentMigrationItem],
        source: String?,
        providerID: String?,
        migrationSource: String?
    )? {
        guard case let .object(params)? = value,
              Set(params.keys).isSubset(
                  of: Set([
                      "migrationItems",
                      "source",
                      "providerId",
                      "migrationSource",
                  ])
              ),
              case let .array(rawItems)? =
                  params["migrationItems"]
        else { return nil }

        func nullableString(_ key: String) -> String?? {
            guard let value = params[key] else {
                return .some(nil)
            }
            switch value {
            case .null:
                return .some(nil)
            case let .string(text):
                return .some(text)
            default:
                return nil
            }
        }
        guard let source = nullableString("source"),
              let providerID = nullableString("providerId"),
              let migrationSource = nullableString(
                  "migrationSource"
              )
        else { return nil }

        var items: [CodexExternalAgentMigrationItem] = []
        for rawItem in rawItems {
            guard let item = externalAgentMigrationItem(rawItem)
            else { return nil }
            items.append(item)
        }
        return (
            items,
            source,
            providerID,
            migrationSource
        )
    }

    private static func externalAgentMigrationItem(
        _ value: CodexJSONValue
    ) -> CodexExternalAgentMigrationItem? {
        let supported: Set<String> = [
            "AGENTS_MD",
            "CONFIG",
            "SKILLS",
            "PLUGINS",
            "MCP_SERVER_CONFIG",
            "SUBAGENTS",
            "HOOKS",
            "COMMANDS",
            "MEMORY",
            "SESSIONS",
        ]
        guard case let .object(fields) = value,
              Set(fields.keys)
                == Set([
                    "itemType",
                    "description",
                    "cwd",
                    "details",
                ]),
              case let .string(itemType)? =
                    fields["itemType"],
              supported.contains(itemType),
              case let .string(description)? =
                    fields["description"],
              !description.isEmpty
        else { return nil }

        let cwd: String?
        switch fields["cwd"] {
        case .null?:
            cwd = nil
        case let .string(path)?:
            cwd = path.isEmpty ? nil : path
        default:
            return nil
        }

        let details: CodexJSONValue?
        switch fields["details"] {
        case .null?:
            details = nil
        case let .object(value)?:
            let allowed = Set([
                "plugins", "skills", "sessions",
                "mcpServers", "hooks", "subagents",
                "commands", "memory",
            ])
            guard Set(value.keys).isSubset(of: allowed),
                  isValidExternalAgentMigrationDetails(value)
            else { return nil }
            details = .object(value)
        default:
            return nil
        }

        return CodexExternalAgentMigrationItem(
            itemType: itemType,
            description: description,
            cwd: cwd,
            details: details
        )
    }

    private static func isValidExternalAgentMigrationDetails(
        _ fields: [String: CodexJSONValue]
    ) -> Bool {
        func array(_ key: String) -> [CodexJSONValue]? {
            guard let value = fields[key] else { return [] }
            guard case let .array(items) = value else {
                return nil
            }
            return items
        }
        func namedItems(_ key: String) -> Bool {
            guard let items = array(key) else { return false }
            return items.allSatisfy {
                guard case let .object(item) = $0,
                      case .string? = item["name"]
                else { return false }
                return true
            }
        }

        guard namedItems("skills"),
              namedItems("mcpServers"),
              namedItems("hooks"),
              namedItems("subagents"),
              namedItems("commands"),
              let plugins = array("plugins"),
              let sessions = array("sessions"),
              let memory = array("memory")
        else { return false }

        let validPlugins = plugins.allSatisfy {
            guard case let .object(item) = $0,
                  case .string? = item["marketplaceName"],
                  case let .array(names)? = item["pluginNames"]
            else { return false }
            return names.allSatisfy {
                if case .string = $0 { return true }
                return false
            }
        }
        let validSessions = sessions.allSatisfy {
            guard case let .object(item) = $0,
                  case .string? = item["path"],
                  case .string? = item["cwd"]
            else { return false }
            switch item["title"] {
            case .string?, .null?:
                return true
            default:
                return false
            }
        }
        let validMemory = memory.allSatisfy {
            if case .string = $0 { return true }
            return false
        }
        return validPlugins && validSessions && validMemory
    }

    private enum FileSystemOperationOutcome: Sendable {
        case success(CodexJSONValue)
        case invalid(String)
        case failure(String)
    }

    @MainActor
    private static func fileSystemMutationResponse(
        to request: CodexDesktopMCPRequest,
        allowedRoots: [String]
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params
        else { return invalidParams(request) }
        func path(_ key: String) -> URL? {
            guard case let .string(value)? = params[key] else { return nil }
            return confinedFileURL(path: value, allowedRoots: allowedRoots)
        }
        let method = request.request.method
        let source: URL?
        let destination: URL?
        if method == "fs/copy" {
            source = path("sourcePath")
            destination = path("destinationPath")
            guard source != nil, destination != nil
            else { return invalidParams(request) }
        } else {
            source = path("path")
            destination = nil
            guard source != nil else { return invalidParams(request) }
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            do {
                switch method {
                case "fs/writeFile":
                    guard case let .string(encoded)? = params["dataBase64"],
                          let data = Data(base64Encoded: encoded)
                    else {
                        return FileSystemOperationOutcome.invalid(
                            "fs/writeFile requires valid base64 dataBase64"
                        )
                    }
                    try data.write(to: source!, options: [.atomic])
                    return .success(.object([:]))
                case "fs/createDirectory":
                    let recursive =
                        params["recursive"]?.boolValue ?? true
                    try manager.createDirectory(
                        at: source!,
                        withIntermediateDirectories: recursive
                    )
                    return .success(.object([:]))
                case "fs/getMetadata":
                    let values = try source!.resourceValues(
                        forKeys: [
                            .isDirectoryKey, .isRegularFileKey,
                            .isSymbolicLinkKey, .creationDateKey,
                            .contentModificationDateKey,
                        ]
                    )
                    func milliseconds(_ date: Date?) -> CodexJSONValue {
                        .integer(
                            date.map {
                                Int64(($0.timeIntervalSince1970 * 1000).rounded())
                            } ?? 0
                        )
                    }
                    return .success(.object([
                        "isDirectory": .bool(values.isDirectory ?? false),
                        "isFile": .bool(values.isRegularFile ?? false),
                        "isSymlink": .bool(values.isSymbolicLink ?? false),
                        "createdAtMs": milliseconds(values.creationDate),
                        "modifiedAtMs": milliseconds(
                            values.contentModificationDate
                        ),
                    ]))
                case "fs/readDirectory":
                    let children = try manager.contentsOfDirectory(
                        at: source!,
                        includingPropertiesForKeys: [
                            .isDirectoryKey, .isRegularFileKey,
                        ],
                        options: []
                    )
                    let entries = try children.map { child in
                        let values = try child.resourceValues(
                            forKeys: [.isDirectoryKey, .isRegularFileKey]
                        )
                        return CodexJSONValue.object([
                            "fileName": .string(child.lastPathComponent),
                            "isDirectory": .bool(
                                values.isDirectory ?? false
                            ),
                            "isFile": .bool(
                                values.isRegularFile ?? false
                            ),
                        ])
                    }
                    return .success(.object(["entries": .array(entries)]))
                case "fs/remove":
                    let force = params["force"]?.boolValue ?? true
                    let recursive =
                        params["recursive"]?.boolValue ?? true
                    guard manager.fileExists(atPath: source!.path) else {
                        return force
                            ? .success(.object([:]))
                            : .failure("Path does not exist")
                    }
                    if !recursive,
                       (try source!.resourceValues(
                           forKeys: [.isDirectoryKey]
                       ).isDirectory ?? false),
                       !(try manager.contentsOfDirectory(
                           atPath: source!.path
                       )).isEmpty {
                        return .invalid(
                            "Directory is not empty and recursive is false"
                        )
                    }
                    try manager.removeItem(at: source!)
                    return .success(.object([:]))
                case "fs/copy":
                    let isDirectory = try source!.resourceValues(
                        forKeys: [.isDirectoryKey]
                    ).isDirectory ?? false
                    if isDirectory,
                       params["recursive"]?.boolValue != true {
                        return .invalid(
                            "Directory copy requires recursive true"
                        )
                    }
                    try manager.copyItem(at: source!, to: destination!)
                    return .success(.object([:]))
                default:
                    return .failure("Unsupported filesystem operation")
                }
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
        switch outcome {
        case let .success(value):
            return result(request, value: value)
        case let .invalid(message):
            return error(request, code: -32600, message: message)
        case let .failure(message):
            return error(request, code: -32603, message: message)
        }
    }

    @MainActor
    private static func commandExecResponse(
        to request: CodexDesktopMCPRequest,
        allowedRoots: [String],
        using executor: (any CodexDesktopCommandExecuting)?
    ) async -> CodexDesktopHostMessage {
        let params: CodexDesktopCommandExecParams
        do {
            params = try CodexDesktopCommandExecDecoder.decode(
                request.request.params
            )
        } catch {
            return invalidParams(request)
        }
        guard let executor else {
            return Self.error(
                request,
                code: -32603,
                message: "Command execution unavailable"
            )
        }
        do {
            let response = try await executor.execute(
                params,
                allowedRoots: allowedRoots
            )
            return result(request, value: response.json)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Command execution failed"
            )
        }
    }

    @MainActor
    private static func processSpawnResponse(
        to request: CodexDesktopMCPRequest,
        allowedRoots: [String],
        using manager: (any CodexDesktopProcessManaging)?
    ) -> CodexDesktopHostMessage {
        do {
            guard let manager else {
                throw CodexDesktopCommandExecError
                    .processNotFound
            }
            let params =
                try CodexDesktopProcessSpawnDecoder.decode(
                    request.request.params
                )
            try manager.spawnProcess(
                params,
                allowedRoots: allowedRoots
            )
            return result(request, value: .object([:]))
        } catch CodexDesktopCommandExecError.invalidParams {
            return invalidParams(request)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Process spawn failed"
            )
        }
    }

    @MainActor
    private static func processWriteResponse(
        to request: CodexDesktopMCPRequest,
        using manager: (any CodexDesktopProcessManaging)?
    ) -> CodexDesktopHostMessage {
        do {
            guard let manager else {
                throw CodexDesktopCommandExecError
                    .processNotFound
            }
            try manager.writeProcess(
                try CodexDesktopProcessWriteDecoder.decode(
                    request.request.params
                )
            )
            return result(request, value: .object([:]))
        } catch CodexDesktopCommandExecError.invalidParams {
            return invalidParams(request)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Process stdin write failed"
            )
        }
    }

    @MainActor
    private static func processResizeResponse(
        to request: CodexDesktopMCPRequest,
        using manager: (any CodexDesktopProcessManaging)?
    ) -> CodexDesktopHostMessage {
        do {
            guard let manager else {
                throw CodexDesktopCommandExecError
                    .processNotFound
            }
            try manager.resizeProcess(
                try CodexDesktopProcessResizeDecoder.decode(
                    request.request.params
                )
            )
            return result(request, value: .object([:]))
        } catch CodexDesktopCommandExecError.invalidParams {
            return invalidParams(request)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Process PTY resize failed"
            )
        }
    }

    @MainActor
    private static func processKillResponse(
        to request: CodexDesktopMCPRequest,
        using manager: (any CodexDesktopProcessManaging)?
    ) -> CodexDesktopHostMessage {
        do {
            guard let manager else {
                throw CodexDesktopCommandExecError
                    .processNotFound
            }
            try manager.killProcess(
                try CodexDesktopProcessKillDecoder.decode(
                    request.request.params
                )
            )
            return result(request, value: .object([:]))
        } catch CodexDesktopCommandExecError.invalidParams {
            return invalidParams(request)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Process kill failed"
            )
        }
    }

    @MainActor
    private static func commandExecWriteResponse(
        to request: CodexDesktopMCPRequest,
        using executor: (any CodexDesktopCommandExecuting)?
    ) -> CodexDesktopHostMessage {
        do {
            guard let executor else {
                throw CodexDesktopCommandExecError.processNotFound
            }
            try executor.write(
                CodexDesktopCommandExecWriteDecoder.decode(
                    request.request.params
                )
            )
            return result(request, value: .object([:]))
        } catch CodexDesktopCommandExecError.invalidParams {
            return invalidParams(request)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Command write failed"
            )
        }
    }

    @MainActor
    private static func commandExecResizeResponse(
        to request: CodexDesktopMCPRequest,
        using executor: (any CodexDesktopCommandExecuting)?
    ) -> CodexDesktopHostMessage {
        do {
            guard let executor else {
                throw CodexDesktopCommandExecError.processNotFound
            }
            try executor.resize(
                CodexDesktopCommandExecResizeDecoder.decode(
                    request.request.params
                )
            )
            return result(request, value: .object([:]))
        } catch CodexDesktopCommandExecError.invalidParams {
            return invalidParams(request)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Command resize failed"
            )
        }
    }

    @MainActor
    private static func commandExecTerminateResponse(
        to request: CodexDesktopMCPRequest,
        using executor: (any CodexDesktopCommandExecuting)?
    ) -> CodexDesktopHostMessage {
        do {
            guard let executor else {
                throw CodexDesktopCommandExecError.processNotFound
            }
            try executor.terminate(
                CodexDesktopCommandExecTerminateDecoder.decode(
                    request.request.params
                )
            )
            return result(request, value: .object([:]))
        } catch CodexDesktopCommandExecError.invalidParams {
            return invalidParams(request)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Command terminate failed"
            )
        }
    }

    @MainActor
    private static func threadBackgroundTerminalsListResponse(
        to request: CodexDesktopMCPRequest,
        using manager:
            (any CodexDesktopBackgroundTerminalManaging)?
    ) -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(threadID)? = params["threadId"],
              !threadID.isEmpty
        else {
            return invalidParams(request)
        }
        let cursor: String?
        switch params["cursor"] {
        case nil, .null?:
            cursor = nil
        case let .string(value)?:
            cursor = value
        default:
            return invalidParams(request)
        }
        let limit: UInt32?
        switch params["limit"] {
        case nil, .null?:
            limit = nil
        case let .integer(value)?
            where value >= 0 && value <= Int64(UInt32.max):
            limit = UInt32(value)
        default:
            return invalidParams(request)
        }
        guard let manager else {
            return Self.error(
                request,
                code: -32603,
                message: "Background terminals unavailable"
            )
        }
        do {
            let page = try manager.listBackgroundTerminals(
                threadID: threadID,
                cursor: cursor,
                limit: limit
            )
            return result(
                request,
                value: .object([
                    "data": .array(page.data.map(\.json)),
                    "nextCursor": page.nextCursor.map {
                        .string($0)
                    } ?? .null,
                ])
            )
        } catch CodexDesktopCommandExecError.invalidParams {
            return invalidParams(request)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Background terminal listing failed"
            )
        }
    }

    @MainActor
    private static func threadBackgroundTerminalsTerminateResponse(
        to request: CodexDesktopMCPRequest,
        using manager:
            (any CodexDesktopBackgroundTerminalManaging)?
    ) -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(threadID)? = params["threadId"],
              !threadID.isEmpty,
              case let .string(processID)? = params["processId"],
              !processID.isEmpty,
              Int32(processID) != nil
        else {
            return invalidParams(request)
        }
        guard let manager else {
            return error(
                request,
                code: -32603,
                message: "Background terminals unavailable"
            )
        }
        do {
            return result(
                request,
                value: .object([
                    "terminated": .bool(
                        try manager.terminateBackgroundTerminal(
                            threadID: threadID,
                            processID: processID
                        )
                    )
                ])
            )
        } catch CodexDesktopCommandExecError.invalidParams {
            return invalidParams(request)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Background terminal termination failed"
            )
        }
    }

    @MainActor
    private static func threadBackgroundTerminalsCleanResponse(
        to request: CodexDesktopMCPRequest,
        using manager:
            (any CodexDesktopBackgroundTerminalManaging)?
    ) -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(threadID)? = params["threadId"],
              !threadID.isEmpty
        else {
            return invalidParams(request)
        }
        guard let manager else {
            return error(
                request,
                code: -32603,
                message: "Background terminals unavailable"
            )
        }
        manager.cleanBackgroundTerminals(threadID: threadID)
        return result(request, value: .object([:]))
    }

    @MainActor
    private static func threadListResponse(
        to request: CodexDesktopMCPRequest,
        using threadLister:
            (any CodexDesktopThreadSessionListing)?
    ) async -> CodexDesktopHostMessage {
        let params: CodexThreadListParams
        do {
            params = try CodexAppServerThreadListParamsDecoder
                .decode(request.request.params)
        } catch {
            return invalidParams(request)
        }

        guard let threadLister else {
            return error(
                request,
                code: -32603,
                message: "Thread session listing unavailable"
            )
        }

        do {
            let page = try threadLister.listThreads(
                id: request.request.id,
                params: params
            )
            return try result(
                request,
                value: threadListResult(page)
            )
        } catch let listingError as CodexSessionStoreError {
            switch listingError {
            case let .appServerError(code, message, data):
                return error(
                    request,
                    code: code,
                    message: message,
                    data: data
                )
            default:
                return error(
                    request,
                    code: -32603,
                    message: "Thread session listing failed"
                )
            }
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread session listing failed"
            )
        }
    }

    @MainActor
    private static func threadTurnsListResponse(
        to request: CodexDesktopMCPRequest,
        using history: (any CodexDesktopThreadHistoryPaging)?
    ) -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(threadID)? = params["threadId"],
              !threadID.isEmpty,
              let cursor = decodeNullableString(params["cursor"]),
              let limit = decodeNullableLimit(params["limit"]),
              let direction = decodeSortDirection(
                  params["sortDirection"],
                  default: .descending
              ),
              let itemsView = decodeItemsView(
                  params["itemsView"]
              )
        else {
            return invalidParams(request)
        }
        guard let history else {
            return error(
                request,
                code: -32603,
                message: "Thread turn history unavailable"
            )
        }
        do {
            return result(
                request,
                value: try history.listStoredThreadTurns(
                    id: request.request.id,
                    threadID: .init(threadID),
                    cursor: cursor,
                    limit: limit,
                    sortDirection: direction,
                    itemsView: itemsView
                )
            )
        } catch CodexThreadHistoryPagingError.invalidParams,
                CodexThreadHistoryPagingError.invalidCursor {
            return invalidParams(request)
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread turn history failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread turn history failed"
            )
        }
    }

    @MainActor
    private static func threadItemsListResponse(
        to request: CodexDesktopMCPRequest,
        using history: (any CodexDesktopThreadHistoryPaging)?
    ) -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(threadID)? = params["threadId"],
              !threadID.isEmpty,
              let turnID = decodeNullableNonemptyString(
                  params["turnId"]
              ),
              let cursor = decodeNullableString(params["cursor"]),
              let limit = decodeNullableLimit(params["limit"]),
              let direction = decodeSortDirection(
                  params["sortDirection"],
                  default: .ascending
              )
        else {
            return invalidParams(request)
        }
        guard let history else {
            return error(
                request,
                code: -32603,
                message: "Thread item history unavailable"
            )
        }
        do {
            return result(
                request,
                value: try history.listStoredThreadItems(
                    id: request.request.id,
                    threadID: .init(threadID),
                    turnID: turnID,
                    cursor: cursor,
                    limit: limit,
                    sortDirection: direction
                )
            )
        } catch CodexThreadHistoryPagingError.invalidParams,
                CodexThreadHistoryPagingError.invalidCursor {
            return invalidParams(request)
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread item history failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread item history failed"
            )
        }
    }

    @MainActor
    private static func threadSearchOccurrencesResponse(
        to request: CodexDesktopMCPRequest,
        using history: (any CodexDesktopThreadHistoryPaging)?
    ) -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(threadID)? = params["threadId"],
              !threadID.isEmpty,
              case let .string(searchTerm)? = params["searchTerm"],
              !searchTerm.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              let cursor = decodeNullableString(params["cursor"]),
              let limit = decodeNullableLimit(params["limit"])
        else {
            return invalidParams(request)
        }
        guard let history else {
            return error(
                request,
                code: -32603,
                message: "Thread occurrence search unavailable"
            )
        }
        do {
            return result(
                request,
                value: try history.searchStoredThreadOccurrences(
                    id: request.request.id,
                    threadID: .init(threadID),
                    searchTerm: searchTerm,
                    cursor: cursor,
                    limit: limit
                )
            )
        } catch CodexThreadHistoryPagingError.invalidParams,
                CodexThreadHistoryPagingError.invalidCursor {
            return invalidParams(request)
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread occurrence search failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread occurrence search failed"
            )
        }
    }

    private static func decodeNullableString(
        _ value: CodexJSONValue?
    ) -> String?? {
        switch value {
        case nil, .null?:
            return .some(nil)
        case let .string(value)?:
            return .some(value)
        default:
            return nil
        }
    }

    private static func decodeNullableNonemptyString(
        _ value: CodexJSONValue?
    ) -> String?? {
        guard let decoded = decodeNullableString(value) else {
            return nil
        }
        guard decoded == nil || !(decoded?.isEmpty ?? true) else {
            return nil
        }
        return .some(decoded)
    }

    private static func decodeNullableLimit(
        _ value: CodexJSONValue?
    ) -> UInt32?? {
        switch value {
        case nil, .null?:
            return .some(nil)
        case let .integer(value)?
            where value >= 0 && value <= Int64(UInt32.max):
            return .some(UInt32(value))
        default:
            return nil
        }
    }

    private static func decodeSortDirection(
        _ value: CodexJSONValue?,
        default defaultValue: CodexThreadSortDirection
    ) -> CodexThreadSortDirection? {
        switch value {
        case nil, .null?:
            return defaultValue
        case let .string(value)?:
            return .init(rawValue: value)
        default:
            return nil
        }
    }

    private static func decodeItemsView(
        _ value: CodexJSONValue?
    ) -> CodexStoredTurnItemsView? {
        switch value {
        case nil, .null?:
            return .summary
        case let .string(value)?:
            return .init(rawValue: value)
        default:
            return nil
        }
    }

    @MainActor
    private static func modelListResponse(
        to request: CodexDesktopMCPRequest,
        using modelLister: (any CodexDesktopModelSessionListing)?
    ) async -> CodexDesktopHostMessage {
        let params: CodexModelListParams
        do {
            params = try decodeModelListParams(request.request.params)
        } catch {
            return invalidParams(request)
        }

        guard let modelLister else {
            return error(
                request,
                code: -32603,
                message: "Model session listing unavailable"
            )
        }

        do {
            let response = try modelLister.listModels(
                id: request.request.id,
                params: params
            )
            return try result(
                request,
                value: encodedThreadResult(response)
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Model session listing failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Model session listing failed"
            )
        }
    }

    @MainActor
    private static func turnStartResponse(
        to request: CodexDesktopMCPRequest,
        using turnStarter: (any CodexDesktopTurnSessionStarting)?
    ) async -> CodexDesktopHostMessage {
        let params: CodexTurnStartParams
        do {
            params = try CodexAppServerTurnStartParamsDecoder.decode(
                request.request.params
            )
        } catch {
            return invalidParams(request)
        }

        guard let turnStarter else {
            return error(
                request,
                code: -32603,
                message: "Turn session starting unavailable"
            )
        }

        do {
            let response = try turnStarter.startDesktopTurn(
                id: request.request.id,
                params: params
            )
            return try result(
                request,
                value: encodedThreadResult(response)
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Turn session starting failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Turn session starting failed"
            )
        }
    }

    @MainActor
    private static func reviewStartResponse(
        to request: CodexDesktopMCPRequest,
        using reviewer: (any CodexDesktopReviewStarting)?
    ) -> CodexDesktopHostMessage {
        let params: CodexReviewStartParams
        do {
            params = try decodeReviewStartParams(
                request.request.params
            )
        } catch {
            return invalidParams(request)
        }
        guard let reviewer else {
            return error(
                request,
                code: -32603,
                message: "Review session starting unavailable"
            )
        }
        do {
            return try result(
                request,
                value: encodedThreadResult(
                    reviewer.startDesktopReview(
                        id: request.request.id,
                        params: params
                    )
                )
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Review session starting failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Review session starting failed"
            )
        }
    }

    @MainActor
    private static func elicitationCountResponse(
        to request: CodexDesktopMCPRequest,
        incrementing: Bool,
        using counter: (any CodexDesktopElicitationCounting)?
    ) -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              params.count == 1,
              case let .string(rawThreadID)? = params["threadId"],
              !rawThreadID.isEmpty
        else {
            return invalidParams(request)
        }
        guard let counter else {
            return error(
                request,
                code: -32603,
                message: "Elicitation counting unavailable"
            )
        }
        do {
            let threadID = CodexStoredThreadID(rawValue: rawThreadID)
            let count = try incrementing
                ? counter.incrementDesktopElicitation(
                    id: request.request.id,
                    threadID: threadID
                )
                : counter.decrementDesktopElicitation(
                    id: request.request.id,
                    threadID: threadID
                )
            return result(
                request,
                value: .object([
                    "count": .integer(count),
                    "paused": .bool(count > 0),
                ])
            )
        } catch CodexDesktopTurnSessionRunnerError
            .elicitationCountAlreadyZero
        {
            return error(
                request,
                code: -32600,
                message:
                    "out-of-band elicitation count is already zero"
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Elicitation counting failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Elicitation counting failed"
            )
        }
    }

    @MainActor
    private static func threadCompactStartResponse(
        to request: CodexDesktopMCPRequest,
        using compactor: (any CodexDesktopThreadCompacting)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              params.count == 1,
              case let .string(rawThreadID)? = params["threadId"],
              !rawThreadID.isEmpty
        else {
            return invalidParams(request)
        }
        guard let compactor else {
            return error(
                request,
                code: -32603,
                message: "Thread compaction unavailable"
            )
        }
        do {
            try compactor.startDesktopCompaction(
                id: request.request.id,
                threadID: CodexStoredThreadID(rawValue: rawThreadID)
            )
            return result(request, value: .object([:]))
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread compaction failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread compaction failed"
            )
        }
    }

    @MainActor
    private static func turnInterruptResponse(
        to request: CodexDesktopMCPRequest,
        using turnInterrupter:
            (any CodexDesktopTurnSessionInterrupting)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              params.count == 2,
              case let .string(threadID)? = params["threadId"],
              case let .string(turnID)? = params["turnId"]
        else {
            return invalidParams(request)
        }

        guard let turnInterrupter else {
            return error(
                request,
                code: -32603,
                message: "Turn session interruption unavailable"
            )
        }

        do {
            try turnInterrupter.interruptDesktopTurn(
                threadID: CodexStoredThreadID(rawValue: threadID),
                turnID: turnID
            )
            return result(request, value: .object([:]))
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Turn session interruption failed"
            )
        }
    }

    @MainActor
    private static func turnSteerResponse(
        to request: CodexDesktopMCPRequest,
        using turnSteerer:
            (any CodexDesktopTurnSessionSteering)?
    ) async -> CodexDesktopHostMessage {
        let params: CodexTurnSteerParams
        do {
            params = try CodexAppServerTurnSteerParamsDecoder
                .decode(request.request.params)
        } catch {
            return invalidParams(request)
        }

        guard let turnSteerer else {
            return error(
                request,
                code: -32603,
                message: "Turn session steering unavailable"
            )
        }

        do {
            let response = try turnSteerer.steerDesktopTurn(
                params: params
            )
            return try result(
                request,
                value: encodedThreadResult(response)
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Turn session steering failed"
            )
        }
    }

    @MainActor
    private static func threadReadResponse(
        to request: CodexDesktopMCPRequest,
        using threadReader:
            (any CodexDesktopThreadSessionReading)?,
        fileManager: FileManager
    ) async -> CodexDesktopHostMessage {
        let params: CodexThreadReadParams
        do {
            params = try decodeThreadReadParams(
                request.request.params
            )
        } catch {
            return invalidParams(request)
        }

        guard let threadReader else {
            return error(
                request,
                code: -32603,
                message: "Thread session reading unavailable"
            )
        }

        do {
            var readResult = try threadReader.readThread(
                id: request.request.id,
                params: params
            )
            readResult.thread.cwd =
                CodexIOSAppContainerPathMigrator.currentPath(
                    for: readResult.thread.cwd,
                    fileManager: fileManager
                )
            return Self.result(
                request,
                value: try encodedThreadResult(readResult)
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread session reading failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread session reading failed"
            )
        }
    }

    @MainActor
    private static func conversationSummaryResponse(
        to request: CodexDesktopMCPRequest,
        using threadLister:
            (any CodexDesktopThreadSessionListing)?
    ) -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              params.count == 1
        else {
            return invalidParams(request)
        }
        guard let threadLister else {
            return error(
                request,
                code: -32603,
                message: "Conversation summary unavailable"
            )
        }

        do {
            let thread: CodexStoredThread
            if case let .string(conversationID)? =
                params["conversationId"],
                !conversationID.isEmpty
            {
                guard let threadReader = threadLister
                    as? any CodexDesktopThreadSessionReading
                else {
                    return error(
                        request,
                        code: -32603,
                        message: "Conversation summary unavailable"
                    )
                }
                thread = try threadReader.readThread(
                    id: request.request.id,
                    params: .init(
                        threadID: .init(conversationID),
                        includeTurns: false
                    )
                ).thread
            } else if case let .string(rolloutPath)? =
                params["rolloutPath"],
                !rolloutPath.isEmpty
            {
                guard let storedThread = try storedThread(
                    atRolloutPath: rolloutPath,
                    requestID: request.request.id,
                    using: threadLister
                ) else {
                    return error(
                        request,
                        code: -32602,
                        message:
                            "failed to resolve rollout path `\(rolloutPath)`: file does not exist"
                    )
                }
                thread = storedThread
            } else {
                return invalidParams(request)
            }

            return result(
                request,
                value: .object([
                    "summary": try conversationSummaryValue(
                        thread
                    ),
                ])
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Conversation summary failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Conversation summary failed"
            )
        }
    }

    @MainActor
    private static func storedThread(
        atRolloutPath rolloutPath: String,
        requestID: CodexAppServerRequestID,
        using threadLister:
            any CodexDesktopThreadSessionListing
    ) throws -> CodexStoredThread? {
        let requestedPath = (rolloutPath as NSString)
            .standardizingPath
        for archived in [false, true] {
            var cursor: String?
            var seenCursors: Set<String> = []
            repeat {
                let page = try threadLister.listThreads(
                    id: requestID,
                    params: .init(
                        cursor: cursor.map(
                            CodexWireOptional.value
                        ) ?? .omitted,
                        limit: .value(100),
                        sortKey: .value(.updatedAt),
                        archived: .value(archived),
                        useStateDbOnly: true
                    )
                )
                if let match = page.data.first(where: {
                    guard let path = $0.path else {
                        return false
                    }
                    return (path as NSString).standardizingPath
                        == requestedPath
                }) {
                    return match
                }
                cursor = page.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw CodexSessionStoreError.invalidReply
                }
            } while cursor != nil
        }
        return nil
    }

    private static func conversationSummaryValue(
        _ thread: CodexStoredThread
    ) throws -> CodexJSONValue {
        let source = conversationSummarySource(thread)
        let sourceData = try JSONEncoder().encode(source)
        let sourceValue = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: sourceData
        )
        let gitInfo: CodexJSONValue
        if let git = thread.gitInfo {
            gitInfo = .object([
                "sha": git.sha.map(CodexJSONValue.string)
                    ?? .null,
                "branch": git.branch.map(CodexJSONValue.string)
                    ?? .null,
                "origin_url": git.originURL.map(
                    CodexJSONValue.string
                ) ?? .null,
            ])
        } else {
            gitInfo = .null
        }

        return .object([
            "conversationId": .string(thread.id.rawValue),
            "path": .string(thread.path ?? ""),
            "preview": .string(thread.preview),
            "timestamp": .string(
                conversationSummaryTimestamp(thread.createdAt)
            ),
            "updatedAt": .string(
                conversationSummaryTimestamp(thread.updatedAt)
            ),
            "modelProvider": .string(thread.modelProvider),
            "cwd": .string(thread.cwd),
            "cliVersion": .string(thread.cliVersion),
            "source": sourceValue,
            "gitInfo": gitInfo,
        ])
    }

    private static func conversationSummarySource(
        _ thread: CodexStoredThread
    ) -> CodexThreadSessionSource {
        guard case let .subAgent(.threadSpawn(
            parentThreadID,
            depth,
            agentPath,
            agentNickname,
            agentRole,
            model
        )) = thread.source
        else {
            return thread.source
        }
        return .subAgent(
            .threadSpawn(
                parentThreadID: parentThreadID,
                depth: depth,
                agentPath: agentPath,
                agentNickname:
                    thread.agentNickname ?? agentNickname,
                agentRole: thread.agentRole ?? agentRole,
                model: model
            )
        )
    }

    private static func conversationSummaryTimestamp(
        _ seconds: Int64
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(seconds))
        )
    }

    @MainActor
    private static func threadResumeResponse(
        to request: CodexDesktopMCPRequest,
        using threadResumer:
            (any CodexDesktopThreadSessionResuming)?,
        fileManager: FileManager
    ) async -> CodexDesktopHostMessage {
        var params: CodexThreadResumeParams
        do {
            params = try decodeThreadResumeParams(
                request.request.params
            )
        } catch {
            return invalidParams(request)
        }

        guard let threadResumer else {
            return error(
                request,
                code: -32603,
                message: "Thread session resuming unavailable"
            )
        }

        params.cwd = CodexIOSAppContainerPathMigrator.currentPath(
            for: params.cwd,
            fileManager: fileManager
        )

        do {
            let resumeResult = try threadResumer.resumeThread(
                id: request.request.id,
                params: params
            )
            return Self.result(
                request,
                value: try encodedThreadResult(resumeResult)
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread session resuming failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread session resuming failed"
            )
        }
    }

    @MainActor
    private static func threadForkResponse(
        to request: CodexDesktopMCPRequest,
        using threadForker:
            (any CodexDesktopThreadSessionForking)?
    ) async -> CodexDesktopHostMessage {
        let params: CodexThreadForkParams
        do {
            params = try decodeThreadForkParams(request.request.params)
        } catch {
            return invalidParams(request)
        }
        guard let threadForker else {
            return error(
                request,
                code: -32603,
                message: "Thread session forking unavailable"
            )
        }
        do {
            let result = try threadForker.forkThread(
                id: request.request.id,
                params: params
            )
            return try Self.result(
                request,
                value: encodedThreadResult(result)
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread session forking failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread session forking failed"
            )
        }
    }

    @MainActor
    private static func threadInjectItemsResponse(
        to request: CodexDesktopMCPRequest,
        using injector: (any CodexDesktopThreadItemsInjecting)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              params.count == 2,
              case let .string(rawThreadID)? = params["threadId"],
              !rawThreadID.isEmpty,
              case let .array(items)? = params["items"],
              !items.isEmpty,
              items.allSatisfy({
                  if case .object = $0 { return true }
                  return false
              })
        else {
            return invalidParams(request)
        }
        guard let injector else {
            return error(
                request,
                code: -32603,
                message: "Thread item injection unavailable"
            )
        }
        do {
            try injector.injectStoredThreadItems(
                id: request.request.id,
                threadID: CodexStoredThreadID(rawValue: rawThreadID),
                items: items
            )
            return result(request, value: .object([:]))
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread item injection failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread item injection failed"
            )
        }
    }

    @MainActor
    private static func threadApproveGuardianDeniedActionResponse(
        to request: CodexDesktopMCPRequest,
        using approver: (any CodexDesktopGuardianDeniedActionApproving)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(rawThreadID)? = params["threadId"],
              !rawThreadID.isEmpty,
              let event = params["event"]
        else {
            return invalidParams(request)
        }
        guard let approver else {
            return error(
                request,
                code: -32603,
                message: "Guardian denial approval unavailable"
            )
        }
        do {
            try approver.approveGuardianDeniedAction(
                id: request.request.id,
                threadID: CodexStoredThreadID(rawValue: rawThreadID),
                event: event
            )
            return result(request, value: .object([:]))
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Guardian denial approval failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Guardian denial approval failed"
            )
        }
    }

    @MainActor
    private static func threadShellCommandResponse(
        to request: CodexDesktopMCPRequest,
        allowedRoots: [String],
        using runner: (any CodexDesktopThreadShellCommandRunning)?,
        executor: (any CodexDesktopCommandExecuting)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              params.count == 2,
              case let .string(rawThreadID)? = params["threadId"],
              !rawThreadID.isEmpty,
              case let .string(command)? = params["command"],
              !command.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              !command.contains("\u{0}")
        else {
            return invalidParams(request)
        }
        guard let runner, let executor else {
            return error(
                request,
                code: -32603,
                message: "Local environment is not configured"
            )
        }
        do {
            let started = try runner.beginShellCommand(
                id: request.request.id,
                threadID: CodexStoredThreadID(rawValue: rawThreadID),
                command: command
            )
            Task { @MainActor in
                let began = ContinuousClock.now
                let result: CodexDesktopCommandExecResult
                do {
                    result = try await executor.execute(
                        CodexDesktopCommandExecParams(
                            command: ["sh", "-lc", started.command],
                            processID: nil,
                            tty: false,
                            streamStdin: false,
                            streamStdoutStderr: false,
                            outputBytesCap: nil,
                            disableOutputCap: true,
                            disableTimeout: true,
                            timeoutMs: nil,
                            cwd: started.cwd,
                            environment: nil,
                            size: nil,
                            sandboxPolicy: .object([
                                "type": .string("dangerFullAccess"),
                            ])
                        ),
                        allowedRoots: allowedRoots
                    )
                } catch {
                    result = CodexDesktopCommandExecResult(
                        exitCode: 1,
                        stdout: "",
                        stderr: String(describing: error)
                    )
                }
                let elapsed = began.duration(to: .now)
                let components = elapsed.components
                let seconds = UInt64(max(0, components.seconds))
                let attoseconds = UInt64(max(0, components.attoseconds))
                let durationMillis = seconds
                    .multipliedReportingOverflow(by: 1_000).partialValue
                    &+ attoseconds / 1_000_000_000_000_000
                try? runner.completeShellCommand(
                    commandID: started.commandID,
                    result: result,
                    durationMillis: durationMillis
                )
            }
            return result(request, value: .object([:]))
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Shell command start failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Shell command start failed"
            )
        }
    }

    @MainActor
    private static func threadStartResponse(
        to request: CodexDesktopMCPRequest,
        using threadStarter: (any CodexDesktopThreadSessionStarting)?
    ) async -> CodexDesktopHostMessage {
        let params: CodexThreadStartParams
        do {
            params = try decodeThreadStartParams(request.request.params)
        } catch {
            return invalidParams(request)
        }
        guard let threadStarter else {
            return error(request, code: -32603, message: "Thread session starting unavailable")
        }
        do {
            let result = try threadStarter.startThread(
                id: request.request.id,
                params: params
            )
            return try Self.result(request, value: encodedThreadResult(result))
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread session starting failed"
            )
        } catch {
            return Self.error(request, code: -32603, message: "Thread session starting failed")
        }
    }

    @MainActor
    private static func threadMutationResponse(
        to request: CodexDesktopMCPRequest,
        using threadMutator:
            (any CodexDesktopThreadSessionMutating)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(rawThreadID)? = params["threadId"]
        else {
            return invalidParams(request)
        }

        let threadID = CodexStoredThreadID(rawValue: rawThreadID)
        guard let threadMutator else {
            return error(
                request,
                code: -32603,
                message: "Thread session mutation unavailable"
            )
        }

        do {
            switch request.request.method {
            case "thread/archive":
                guard params.count == 1 else {
                    return invalidParams(request)
                }
                try threadMutator.archiveStoredThread(
                    id: request.request.id,
                    threadID: threadID
                )
                return result(request, value: .object([:]))

            case "thread/unarchive":
                guard params.count == 1 else {
                    return invalidParams(request)
                }
                let response = try threadMutator.unarchiveStoredThread(
                    id: request.request.id,
                    threadID: threadID
                )
                return try result(
                    request,
                    value: encodedThreadResult(response)
                )

            case "thread/delete":
                guard params.count == 1 else {
                    return invalidParams(request)
                }
                try threadMutator.deleteStoredThread(
                    id: request.request.id,
                    threadID: threadID
                )
                return result(request, value: .object([:]))

            case "thread/rollback":
                guard params.count == 2,
                      case let .integer(rawNumTurns)? = params["numTurns"],
                      rawNumTurns > 0,
                      rawNumTurns <= Int64(UInt32.max)
                else {
                    return invalidParams(request)
                }
                let response = try threadMutator.rollbackStoredThread(
                    id: request.request.id,
                    threadID: threadID,
                    numTurns: UInt32(rawNumTurns)
                )
                return try result(
                    request,
                    value: encodedThreadResult(response)
                )

            case "thread/revert":
                guard params.count == 2,
                      case let .string(beforeTurnID)? = params["beforeTurnId"],
                      !beforeTurnID.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                else {
                    return invalidParams(request)
                }
                let response = try threadMutator.revertStoredThread(
                    id: request.request.id,
                    threadID: threadID,
                    beforeTurnID: beforeTurnID
                )
                return try result(
                    request,
                    value: encodedThreadResult(response)
                )

            case "thread/name/set":
                guard params.count == 2,
                      case let .string(name)? = params["name"],
                      !name.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                else {
                    return invalidParams(request)
                }
                try threadMutator.setStoredThreadName(
                    id: request.request.id,
                    threadID: threadID,
                    name: name
                )
                return result(request, value: .object([:]))

            default:
                return invalidParams(request)
            }
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread session mutation failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread session mutation failed"
            )
        }
    }

    @MainActor
    private static func threadQueueResponse(
        to request: CodexDesktopMCPRequest,
        using queueManager: (any CodexDesktopThreadQueueManaging)?
    ) async -> CodexDesktopHostMessage {
        guard let queueManager else {
            return error(
                request,
                code: -32603,
                message: "Thread queue service unavailable"
            )
        }
        do {
            switch request.request.method {
            case "thread/queue/add":
                let params = try decodeThreadQueueAddParams(request.request.params)
                return try result(
                    request,
                    value: encodedThreadResult(queueManager.addQueuedSubmission(
                        id: request.request.id,
                        params: params
                    ))
                )
            case "thread/queue/list":
                let params = try decodeThreadQueueListParams(request.request.params)
                return try result(
                    request,
                    value: encodedThreadResult(queueManager.listQueuedSubmissions(
                        id: request.request.id,
                        params: params
                    ))
                )
            case "thread/queue/update":
                let params = try decodeThreadQueueUpdateParams(request.request.params)
                return try result(
                    request,
                    value: encodedThreadResult(queueManager.updateQueuedSubmission(
                        id: request.request.id,
                        params: params
                    ))
                )
            case "thread/queue/delete":
                let params = try decodeThreadQueueDeleteParams(request.request.params)
                return try result(
                    request,
                    value: encodedThreadResult(queueManager.deleteQueuedSubmission(
                        id: request.request.id,
                        params: params
                    ))
                )
            case "thread/queue/reorder":
                let params = try decodeThreadQueueReorderParams(request.request.params)
                try queueManager.reorderQueuedSubmissions(
                    id: request.request.id,
                    params: params
                )
                return result(request, value: .object([:]))
            case "thread/queue/start":
                let params = try decodeThreadQueueStartParams(request.request.params)
                return try result(
                    request,
                    value: encodedThreadResult(queueManager.startQueuedSubmission(
                        id: request.request.id,
                        params: params
                    ))
                )
            default:
                return invalidParams(request)
            }
        } catch is ThreadParamsDecodingError {
            return invalidParams(request)
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread queue request failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread queue request failed"
            )
        }
    }

    @MainActor
    private static func threadGoalResponse(
        to request: CodexDesktopMCPRequest,
        using goalManager: (any CodexDesktopThreadGoalManaging)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(rawThreadID)? = params["threadId"],
              !rawThreadID.isEmpty,
              let goalManager
        else {
            return invalidParams(request)
        }

        let threadID = CodexStoredThreadID(rawValue: rawThreadID)
        do {
            switch request.request.method {
            case "thread/goal/get":
                guard params.count == 1 else {
                    return invalidParams(request)
                }
                let goal = try goalManager.storedThreadGoal(
                    threadID: threadID
                )
                return result(
                    request,
                    value: .object([
                        "goal": goal.map(encodedThreadGoal) ?? .null
                    ])
                )

            case "thread/goal/set":
                guard params.keys.allSatisfy({
                    ["threadId", "objective", "status", "tokenBudget"]
                        .contains($0)
                }) else {
                    return invalidParams(request)
                }
                let objective: String?
                switch params["objective"] {
                case nil, .null?:
                    objective = nil
                case let .string(value)? where
                    !value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty:
                    objective = value
                default:
                    return invalidParams(request)
                }
                let status: ThreadGoalStatus?
                switch params["status"] {
                case nil, .null?:
                    status = nil
                case let .string(value)?:
                    guard let decoded = ThreadGoalStatus(rawValue: value)
                    else { return invalidParams(request) }
                    status = decoded
                default:
                    return invalidParams(request)
                }
                let tokenBudget: CodexWireOptional<Int64>
                switch params["tokenBudget"] {
                case nil:
                    tokenBudget = .omitted
                case .null?:
                    tokenBudget = .null
                case let .integer(value)? where value > 0:
                    tokenBudget = .value(value)
                default:
                    return invalidParams(request)
                }
                let goal = try goalManager.setStoredThreadGoal(
                    threadID: threadID,
                    objective: objective,
                    status: status,
                    tokenBudget: tokenBudget
                )
                return result(
                    request,
                    value: .object([
                        "goal": encodedThreadGoal(goal)
                    ])
                )

            case "thread/goal/clear":
                guard params.count == 1 else {
                    return invalidParams(request)
                }
                return result(
                    request,
                    value: .object([
                        "cleared": .bool(
                            try goalManager.clearStoredThreadGoal(
                                threadID: threadID
                            )
                        )
                    ])
                )

            default:
                return invalidParams(request)
            }
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread goal request failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread goal request failed"
            )
        }
    }

    @MainActor
    private static func loadedThreadListResponse(
        to request: CodexDesktopMCPRequest,
        using lister: (any CodexDesktopLoadedThreadListing)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              params.keys.allSatisfy({
                  ["cursor", "limit"].contains($0)
              }),
              let lister
        else {
            return invalidParams(request)
        }

        let cursor: String?
        switch params["cursor"] {
        case nil, .null?:
            cursor = nil
        case let .string(value)? where !value.isEmpty:
            cursor = value
        default:
            return invalidParams(request)
        }
        let limit: Int?
        switch params["limit"] {
        case nil, .null?:
            limit = nil
        case let .integer(value)? where
            value > 0 && value <= Int64(Int.max):
            limit = Int(value)
        default:
            return invalidParams(request)
        }

        do {
            let page = try lister.loadedStoredThreads(
                cursor: cursor,
                limit: limit
            )
            return result(
                request,
                value: .object([
                    "data": .array(
                        page.data.map {
                            .string($0.rawValue)
                        }
                    ),
                    "nextCursor": page.nextCursor.map(
                        CodexJSONValue.string
                    ) ?? .null,
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Loaded thread listing failed"
            )
        }
    }

    @MainActor
    private static func threadUnsubscribeResponse(
        to request: CodexDesktopMCPRequest,
        using session: (any CodexDesktopThreadUnsubscribing)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              params.count == 1,
              case let .string(rawThreadID)? = params["threadId"],
              !rawThreadID.isEmpty,
              let session
        else {
            return invalidParams(request)
        }
        let threadID = CodexStoredThreadID(rawValue: rawThreadID)
        do {
            let response = try session.unsubscribeStoredThread(
                id: request.request.id,
                threadID: threadID
            )
            return result(
                request,
                value: .object([
                    "status": .string(response.status.rawValue)
                ])
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread unsubscribe failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread unsubscribe failed"
            )
        }
    }

    private static func encodedThreadGoal(
        _ goal: ThreadGoal
    ) -> CodexJSONValue {
        .object([
            "threadId": .string(goal.threadID.uuidString.lowercased()),
            "objective": .string(goal.objective),
            "status": .string(goal.status.rawValue),
            "tokenBudget": goal.tokenBudget.map(CodexJSONValue.integer)
                ?? .null,
            "tokensUsed": .integer(goal.tokensUsed),
            "timeUsedSeconds": .integer(goal.timeUsedSeconds),
            "createdAt": .integer(goal.createdAt),
            "updatedAt": .integer(goal.updatedAt),
        ])
    }

    @MainActor
    private static func threadSearchResponse(
        to request: CodexDesktopMCPRequest,
        using searcher: (any CodexDesktopThreadSessionSearching)?
    ) async -> CodexDesktopHostMessage {
        let params: CodexThreadSearchParams
        do {
            params = try decodeThreadSearchParams(request.request.params)
        } catch {
            return invalidParams(request)
        }
        guard let searcher else {
            return error(
                request,
                code: -32603,
                message: "Thread session search unavailable"
            )
        }
        do {
            let page = try searcher.searchThreads(
                id: request.request.id,
                params: params
            )
            return try result(
                request,
                value: encodedThreadResult(page)
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread session search failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread session search failed"
            )
        }
    }

    @MainActor
    private static func threadSectionListResponse(
        to request: CodexDesktopMCPRequest,
        using sectionLister:
            (any CodexDesktopThreadSectionListing)?
    ) async -> CodexDesktopHostMessage {
        let params: CodexThreadSectionListParams
        do {
            params = try decodeThreadSectionListParams(
                request.request.params
            )
        } catch {
            return invalidParams(request)
        }

        guard let sectionLister else {
            return error(
                request,
                code: -32603,
                message: "Thread section listing unavailable"
            )
        }

        do {
            let page = try sectionLister.listThreadSections(
                id: request.request.id,
                params: params
            )
            return try result(
                request,
                value: threadSectionListResult(page)
            )
        } catch let listingError as CodexSessionStoreError {
            switch listingError {
            case let .appServerError(code, message, data):
                return error(
                    request,
                    code: code,
                    message: message,
                    data: data
                )
            default:
                return error(
                    request,
                    code: -32603,
                    message: "Thread section listing failed"
                )
            }
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread section listing failed"
            )
        }
    }

    @MainActor
    private static func threadSectionMutationResponse(
        to request: CodexDesktopMCPRequest,
        using mutator: (any CodexDesktopThreadSectionMutating)?
    ) async -> CodexDesktopHostMessage {
        guard let mutator else {
            return error(
                request,
                code: -32603,
                message: "Thread section mutation unavailable"
            )
        }

        do {
            switch request.request.method {
            case "threadSection/create":
                let response = try mutator.createThreadSection(
                    id: request.request.id,
                    params: decodeThreadSectionCreateParams(
                        request.request.params
                    )
                )
                return result(
                    request,
                    value: threadSectionResult(response.section)
                )

            case "threadSection/update":
                let response = try mutator.updateThreadSection(
                    id: request.request.id,
                    params: decodeThreadSectionUpdateParams(
                        request.request.params
                    )
                )
                return result(
                    request,
                    value: threadSectionResult(response.section)
                )

            case "threadSection/delete":
                try mutator.deleteThreadSection(
                    id: request.request.id,
                    params: decodeThreadSectionDeleteParams(
                        request.request.params
                    )
                )
                return result(request, value: .object([:]))

            case "thread/section/move":
                try mutator.moveThreadSection(
                    id: request.request.id,
                    params: decodeThreadSectionMoveParams(
                        request.request.params
                    )
                )
                return result(request, value: .object([:]))

            default:
                return invalidParams(request)
            }
        } catch ThreadParamsDecodingError.invalidParams {
            return invalidParams(request)
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread section mutation failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread section mutation failed"
            )
        }
    }

    @MainActor
    private static func threadMetadataUpdateResponse(
        to request: CodexDesktopMCPRequest,
        using updater: (any CodexDesktopThreadMetadataUpdating)?
    ) async -> CodexDesktopHostMessage {
        let params: CodexThreadMetadataUpdateParams
        do {
            params = try decodeThreadMetadataUpdateParams(
                request.request.params
            )
        } catch {
            return invalidParams(request)
        }
        guard let updater else {
            return error(
                request,
                code: -32603,
                message: "Thread metadata updating unavailable"
            )
        }
        do {
            let response = try updater.updateThreadMetadata(
                id: request.request.id,
                params: params
            )
            return try result(
                request,
                value: encodedThreadResult(response)
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread metadata updating failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread metadata updating failed"
            )
        }
    }

    @MainActor
    private static func threadSettingsUpdateResponse(
        to request: CodexDesktopMCPRequest,
        using updater: (any CodexDesktopThreadSettingsUpdating)?
    ) async -> CodexDesktopHostMessage {
        let params: CodexThreadSettingsUpdateParams
        do {
            params = try decodeThreadSettingsUpdateParams(
                request.request.params
            )
        } catch {
            return invalidParams(request)
        }
        guard let updater else {
            return error(
                request,
                code: -32603,
                message: "Thread settings updating unavailable"
            )
        }
        do {
            let response = try updater.updateThreadSettings(
                id: request.request.id,
                params: params
            )
            return try result(
                request,
                value: encodedThreadResult(response)
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread settings updating failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread settings updating failed"
            )
        }
    }

    @MainActor
    private static func threadMemoryModeSetResponse(
        to request: CodexDesktopMCPRequest,
        using updater: (any CodexDesktopThreadMemoryModeUpdating)?
    ) async -> CodexDesktopHostMessage {
        let params: CodexThreadMemoryModeSetParams
        do {
            params = try decodeThreadMemoryModeSetParams(
                request.request.params
            )
        } catch {
            return invalidParams(request)
        }
        guard let updater else {
            return error(
                request,
                code: -32603,
                message: "Thread memory mode updating unavailable"
            )
        }
        do {
            try updater.setThreadMemoryMode(
                id: request.request.id,
                params: params
            )
            return result(request, value: .object([:]))
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "Thread memory mode updating failed"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Thread memory mode updating failed"
            )
        }
    }

    @MainActor
    private static func gitDiffToRemoteResponse(
        to request: CodexDesktopMCPRequest,
        allowedRoots: [String],
        using gitDiffer: (any CodexDesktopGitDiffing)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(fields)? = request.request.params,
              Set(fields.keys) == Set(["cwd"]),
              case let .string(cwd)? = fields["cwd"],
              !cwd.isEmpty,
              let confinedURL = confinedFileURL(
                  path: cwd,
                  allowedRoots: allowedRoots
              )
        else {
            return invalidParams(request)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: confinedURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return invalidParams(request)
        }
        guard let gitDiffer else {
            return error(
                request,
                code: -32603,
                message: "Git diff service unavailable"
            )
        }

        do {
            let response = try await gitDiffer.gitDiffToRemote(
                id: request.request.id,
                params: CodexGitDiffToRemoteParams(
                    cwd: confinedURL.path
                )
            )
            return result(
                request,
                value: .object([
                    "sha": .string(response.sha),
                    "diff": .string(response.diff),
                ])
            )
        } catch {
            return releasedInvalidRequest(
                request,
                message:
                    "failed to compute git diff to remote for cwd: "
                    + String(reflecting: confinedURL.path)
            )
        }
    }

    public static func response(
        to request: CodexDesktopMCPRequest,
        state: CodexDesktopInitialMCPState,
        configStore: (any CodexDesktopConfigMutating)? = nil
    ) -> CodexDesktopHostMessage {
        switch request.request.method {
        case "remoteControl/status/read":
            guard hasUnitParams(request.request.params) else {
                return invalidParams(request)
            }
            return result(
                request,
                value: remoteControlResult(state.remoteControl)
            )

        case "config/read":
            guard case let .object(params)? = request.request.params,
                  let includeLayers = configIncludeLayers(params),
                  hasValidConfigCWD(params)
            else {
                return invalidParams(request)
            }
            let configState = configStore.map {
                CodexDesktopMCPConfigState(
                    config: $0.configSnapshot,
                    origins: state.config.origins,
                    layers: state.config.layers
                )
            } ?? state.config
            return result(
                request,
                value: configResult(
                    configState,
                    includeLayers: includeLayers
                )
            )

        case "configRequirements/read":
            guard hasUnitParams(request.request.params) else {
                return invalidParams(request)
            }
            // The iPad runtime has no managed requirements.toml or MDM
            // provider. Match the desktop protocol's explicit no-policy
            // response rather than inventing local restrictions.
            return result(
                request,
                value: .object(["requirements": .null])
            )

        case "modelProvider/capabilities/read":
            guard hasUnitParams(request.request.params) else {
                return invalidParams(request)
            }
            let config = configStore?.configSnapshot
                ?? state.config.config
            return result(
                request,
                value: modelProviderCapabilitiesResult(config)
            )

        case "getAuthStatus":
            guard case let .object(params)? = request.request.params,
                  hasNullableBoolean(
                    params,
                    key: "includeToken"
                  ),
                  hasNullableBoolean(
                    params,
                    key: "refreshToken"
                  )
            else {
                return invalidParams(request)
            }
            return result(
                request,
                value: authStatusResult(state.account)
            )

        case "account/read":
            guard case let .object(params)? = request.request.params,
                  hasBoolean(params, key: "refreshToken")
            else {
                return invalidParams(request)
            }
            return result(
                request,
                value: accountResult(state.account)
            )

        default:
            return error(
                request,
                code: -32601,
                message:
                    "Method not found: \(request.request.method)"
            )
        }
    }

    @MainActor
    private static func mcpServerStatusListResponse(
        to request: CodexDesktopMCPRequest,
        using lister: (any CodexDesktopMCPServerStatusListing)?
    ) -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              let lister
        else { return invalidParams(request) }
        let cursor: String?
        switch params["cursor"] {
        case nil, .null?: cursor = nil
        case let .string(value)?: cursor = value
        default: return invalidParams(request)
        }
        let limit: Int?
        switch params["limit"] {
        case nil, .null?: limit = nil
        case let .integer(value)? where value > 0 && value <= Int64(Int.max): limit = Int(value)
        default: return invalidParams(request)
        }
        let detail: CodexMCPServerStatusDetail
        switch params["detail"] {
        case nil, .null?, .string("full")?: detail = .full
        case .string("toolsAndAuthOnly")?: detail = .toolsAndAuthOnly
        default: return invalidParams(request)
        }
        if let threadID = params["threadId"], threadID != .null {
            guard case let .string(value) = threadID, !value.isEmpty else { return invalidParams(request) }
        }
        do {
            let page = try lister.listMCPServerStatuses(cursor: cursor, limit: limit, detail: detail)
            return result(request, value: .object([
                "data": .array(page.data.map(mcpServerStatusJSON)),
                "nextCursor": page.nextCursor.map(CodexJSONValue.string) ?? .null,
            ]))
        } catch { return Self.error(request, code: -32602, message: "Invalid MCP server status list parameters") }
    }

    @MainActor
    private static func mcpServerResourceReadResponse(
        to request: CodexDesktopMCPRequest,
        threadReader: (any CodexDesktopThreadSessionReading)?,
        resourceReader: (any CodexDesktopMCPResourceReading)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              params.keys.allSatisfy(
                  Set(["threadId", "server", "uri"]).contains
              ),
              case let .string(server)? = params["server"],
              !server.isEmpty,
              case let .string(uri)? = params["uri"],
              !uri.isEmpty
        else {
            return invalidParams(request)
        }

        let threadID: CodexStoredThreadID?
        switch params["threadId"] {
        case nil, .null?:
            threadID = nil
        case let .string(value)? where !value.isEmpty:
            threadID = CodexStoredThreadID(rawValue: value)
        default:
            return invalidParams(request)
        }

        guard let resourceReader else {
            return error(
                request,
                code: -32603,
                message: "MCP resource reading unavailable"
            )
        }

        do {
            if let threadID {
                guard let threadReader else {
                    return error(
                        request,
                        code: -32603,
                        message: "Thread reading unavailable"
                    )
                }
                _ = try threadReader.readThread(
                    id: request.request.id,
                    params: CodexThreadReadParams(
                        threadID: threadID,
                        includeTurns: false
                    )
                )
            }
            let contents = try await resourceReader.readMCPResource(
                threadID: threadID,
                server: server,
                uri: uri
            )
            let data = try JSONEncoder().encode(contents)
            let value = try JSONDecoder().decode(
                CodexJSONValue.self,
                from: data
            )
            guard case .array = value else {
                throw CodexMCPResourceError.invalidCatalog
            }
            return result(
                request,
                value: .object(["contents": value])
            )
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "MCP resource reading failed"
            )
        } catch CodexMCPResourceError.unknownServer(_) {
            return error(
                request,
                code: -32600,
                message: "MCP server not found"
            )
        } catch CodexMCPResourceError.unknownResource(_, _) {
            return error(
                request,
                code: -32600,
                message: "MCP resource not found"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "MCP resource reading failed"
            )
        }
    }

    @MainActor
    private static func mcpServerToolCallResponse(
        to request: CodexDesktopMCPRequest,
        threadReader: (any CodexDesktopThreadSessionReading)?,
        toolCaller: (any CodexDesktopMCPToolCalling)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              params.keys.allSatisfy(
                  Set([
                      "threadId", "server", "tool",
                      "arguments", "_meta",
                  ]).contains
              ),
              case let .string(rawThreadID)? = params["threadId"],
              !rawThreadID.isEmpty,
              case let .string(server)? = params["server"],
              !server.isEmpty,
              case let .string(tool)? = params["tool"],
              !tool.isEmpty
        else {
            return invalidParams(request)
        }

        let threadID = CodexStoredThreadID(rawValue: rawThreadID)
        let arguments: CodexJSONValue?
        switch params["arguments"] {
        case nil, .null?:
            arguments = nil
        case let value?:
            arguments = value
        }
        let meta: CodexJSONValue?
        switch params["_meta"] {
        case nil, .null?:
            meta = .object([
                "threadId": .string(rawThreadID),
            ])
        case let .object(fields)?:
            var fields = fields
            fields["threadId"] = .string(rawThreadID)
            meta = .object(fields)
        case let value?:
            // Match the app-server: non-object metadata passes through.
            meta = value
        }

        guard let threadReader, let toolCaller else {
            return error(
                request,
                code: -32603,
                message: "MCP tool calling unavailable"
            )
        }

        do {
            _ = try threadReader.readThread(
                id: request.request.id,
                params: CodexThreadReadParams(
                    threadID: threadID,
                    includeTurns: false
                )
            )
            let call = try await toolCaller.callMCPTool(
                threadID: threadID,
                server: server,
                tool: tool,
                arguments: arguments,
                meta: meta
            )
            var value: [String: CodexJSONValue] = [
                "content": .array(call.content),
            ]
            if let structuredContent = call.structuredContent {
                value["structuredContent"] = structuredContent
            }
            if let isError = call.isError {
                value["isError"] = .bool(isError)
            }
            if let meta = call.meta {
                value["_meta"] = meta
            }
            return result(request, value: .object(value))
        } catch let sessionError as CodexSessionStoreError {
            return threadSessionErrorResponse(
                request,
                error: sessionError,
                fallbackMessage: "MCP tool calling failed"
            )
        } catch CodexMCPResourceError.unknownServer(_) {
            return error(
                request,
                code: -32600,
                message: "MCP server not found"
            )
        } catch CodexMCPResourceError.unknownTool(_, _) {
            return error(
                request,
                code: -32600,
                message: "MCP tool not found"
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "MCP tool calling failed"
            )
        }
    }

    @MainActor
    private static func mcpServerOAuthLoginResponse(
        to request: CodexDesktopMCPRequest,
        using handler: (any CodexDesktopMCPOAuthLoggingIn)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(name)? = params["name"],
              !name.isEmpty
        else {
            return invalidParams(request)
        }
        let threadID: String?
        switch params["threadId"] {
        case nil, .null?: threadID = nil
        case let .string(value)? where !value.isEmpty: threadID = value
        default: return invalidParams(request)
        }
        let scopes: [String]?
        switch params["scopes"] {
        case nil, .null?: scopes = nil
        case let .array(values)?:
            let decoded = values.compactMap { value -> String? in
                guard case let .string(scope) = value, !scope.isEmpty else {
                    return nil
                }
                return scope
            }
            guard decoded.count == values.count else { return invalidParams(request) }
            scopes = decoded
        default: return invalidParams(request)
        }
        let timeoutSeconds: Int64?
        switch params["timeoutSecs"] {
        case nil, .null?: timeoutSeconds = nil
        case let .integer(value)? where value > 0: timeoutSeconds = value
        default: return invalidParams(request)
        }
        guard let handler else {
            return error(
                request,
                code: -32603,
                message: "MCP OAuth login unavailable"
            )
        }
        do {
            let login = try await handler.loginMCPServer(
                hostID: request.hostID,
                name: name,
                threadID: threadID,
                scopes: scopes,
                timeoutSeconds: timeoutSeconds
            )
            guard !login.authorizationURL.isEmpty else {
                return Self.error(
                    request,
                    code: -32603,
                    message: "MCP OAuth login returned an empty authorization URL"
                )
            }
            return result(
                request,
                value: .object([
                    "authorizationUrl": .string(login.authorizationURL)
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "MCP OAuth login failed"
            )
        }
    }

    private static func mcpServerStatusJSON(_ status: CodexMCPServerStatus) -> CodexJSONValue {
        .object([
            "name": .string(status.name),
            "serverInfo": status.serverInfo ?? .null,
            "tools": .object(status.tools),
            "resources": .array(status.resources.map { resource in .object([
                "name": .string(resource.name), "uri": .string(resource.uri),
                "description": resource.description.map(CodexJSONValue.string) ?? .null,
                "mimeType": resource.mimeType.map(CodexJSONValue.string) ?? .null,
                "title": resource.title.map(CodexJSONValue.string) ?? .null,
                "size": resource.size.map(CodexJSONValue.integer) ?? .null,
            ]) }),
            "resourceTemplates": .array(status.resourceTemplates.map { template in .object([
                "name": .string(template.name), "uriTemplate": .string(template.uriTemplate),
                "description": template.description.map(CodexJSONValue.string) ?? .null,
                "mimeType": template.mimeType.map(CodexJSONValue.string) ?? .null,
                "title": template.title.map(CodexJSONValue.string) ?? .null,
            ]) }),
            "authStatus": .string(status.authStatus.rawValue),
        ])
    }

    @MainActor
    private static func collaborationModeListResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopSettingsCataloging)?
    ) -> CodexDesktopHostMessage {
        guard let catalog,
              case let .object(params)? = request.request.params,
              params.isEmpty
        else {
            return catalog == nil
                ? error(
                    request,
                    code: -32603,
                    message: "Settings catalog unavailable"
                )
                : invalidParams(request)
        }
        return result(
            request,
            value: .object([
                "data": .array(
                    catalog.listCollaborationModes().map { mode in
                        .object([
                            "name": .string(mode.name),
                            "mode": mode.mode.map(
                                CodexJSONValue.string
                            ) ?? .null,
                            "model": mode.model.map(
                                CodexJSONValue.string
                            ) ?? .null,
                            "reasoning_effort":
                                mode.reasoningEffort.map(
                                    CodexJSONValue.string
                                ) ?? .null,
                        ])
                    }
                ),
            ])
        )
    }

    @MainActor
    private static func experimentalFeatureListResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopSettingsCataloging)?
    ) -> CodexDesktopHostMessage {
        guard let catalog,
              case let .object(params)? = request.request.params,
              let pagination = decodeCatalogPagination(params),
              isOptionalString(params["threadId"])
        else {
            return invalidParams(request)
        }
        do {
            let page = try catalog.listExperimentalFeatures(
                cursor: pagination.cursor,
                limit: pagination.limit
            )
            return result(
                request,
                value: .object([
                    "data": .array(
                        page.data.map(experimentalFeatureValue)
                    ),
                    "nextCursor": page.nextCursor.map(
                        CodexJSONValue.string
                    ) ?? .null,
                ])
            )
        } catch let caught as CodexSettingsCatalogError {
            return releasedInvalidRequest(
                request,
                message: caught.message
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "failed to list experimental features"
            )
        }
    }

    @MainActor
    private static func experimentalFeatureEnablementSetResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopSettingsCataloging)?
    ) -> CodexDesktopHostMessage {
        guard let catalog,
              case let .object(params)? = request.request.params,
              case let .object(rawEnablement)? =
                  params["enablement"]
        else {
            return invalidParams(request)
        }
        var enablement: [String: Bool] = [:]
        for (name, rawValue) in rawEnablement {
            guard case let .bool(enabled) = rawValue else {
                return invalidParams(request)
            }
            enablement[name] = enabled
        }
        catalog.setExperimentalFeatureEnablement(enablement)
        return result(request, value: .object([:]))
    }

    @MainActor
    private static func permissionProfileListResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopSettingsCataloging)?
    ) -> CodexDesktopHostMessage {
        guard let catalog,
              case let .object(params)? = request.request.params,
              let pagination = decodeCatalogPagination(params),
              isOptionalString(params["cwd"])
        else {
            return invalidParams(request)
        }
        let cwd: String?
        if case let .string(value)? = params["cwd"] {
            cwd = value
        } else {
            cwd = nil
        }
        do {
            let page = try catalog.listPermissionProfiles(
                cursor: pagination.cursor,
                limit: pagination.limit,
                cwd: cwd
            )
            return result(
                request,
                value: .object([
                    "data": .array(
                        page.data.map {
                            .object([
                                "id": .string($0.id),
                                "description":
                                    $0.description.map(
                                        CodexJSONValue.string
                                    ) ?? .null,
                                "allowed": .bool($0.allowed),
                            ])
                        }
                    ),
                    "nextCursor": page.nextCursor.map(
                        CodexJSONValue.string
                    ) ?? .null,
                ])
            )
        } catch let caught as CodexSettingsCatalogError {
            return releasedInvalidRequest(
                request,
                message: caught.message
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "failed to list permission profiles"
            )
        }
    }

    private static func experimentalFeatureValue(
        _ feature: CodexExperimentalFeature
    ) -> CodexJSONValue {
        .object([
            "name": .string(feature.name),
            "stage": .string(feature.stage.rawValue),
            "displayName": feature.displayName.map(
                CodexJSONValue.string
            ) ?? .null,
            "description": feature.description.map(
                CodexJSONValue.string
            ) ?? .null,
            "announcement": feature.announcement.map(
                CodexJSONValue.string
            ) ?? .null,
            "enabled": .bool(feature.enabled),
            "defaultEnabled": .bool(feature.defaultEnabled),
        ])
    }

    private static func decodeCatalogPagination(
        _ params: [String: CodexJSONValue]
    ) -> (cursor: String?, limit: Int?)? {
        let cursor: String?
        switch params["cursor"] {
        case let .string(value):
            cursor = value
        case .null, nil:
            cursor = nil
        default:
            return nil
        }

        let limit: Int?
        switch params["limit"] {
        case let .integer(value):
            guard value >= 0, value <= Int64(Int.max) else {
                return nil
            }
            limit = Int(value)
        case let .number(value):
            guard value >= 0,
                  value.rounded(.towardZero) == value,
                  value <= Double(Int.max)
            else {
                return nil
            }
            limit = Int(value)
        case .null, nil:
            limit = nil
        default:
            return nil
        }
        return (cursor, limit)
    }

    private static func isOptionalString(
        _ value: CodexJSONValue?
    ) -> Bool {
        switch value {
        case .string, .null, nil:
            true
        default:
            false
        }
    }

    @MainActor
    private static func appsListResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopAppCataloging)?,
        appListUpdated:
            ((CodexDesktopHostMessage) -> Void)?
    ) -> CodexDesktopHostMessage {
        guard let catalog,
              case let .object(params)? = request.request.params
        else {
            return catalog == nil
                ? error(
                    request,
                    code: -32603,
                    message: "Apps service unavailable"
                )
                : invalidParams(request)
        }
        let cursor: String?
        switch params["cursor"] {
        case let .string(value): cursor = value
        case .null, nil: cursor = nil
        default: return invalidParams(request)
        }
        let limit: Int?
        switch params["limit"] {
        case let .number(value):
            guard value.rounded() == value,
                  value >= 0,
                  value <= Double(UInt32.max)
            else { return invalidParams(request) }
            limit = Int(value)
        case .null, nil: limit = nil
        default: return invalidParams(request)
        }
        let forceRefetch: Bool
        switch params["forceRefetch"] {
        case let .bool(value): forceRefetch = value
        case nil: forceRefetch = false
        default: return invalidParams(request)
        }
        if let threadID = params["threadId"],
           threadID != .null,
           case .string = threadID
        {} else if params["threadId"] != nil,
                  params["threadId"] != .null
        {
            return invalidParams(request)
        }
        do {
            let page = try catalog.listApps(
                cursor: cursor,
                limit: limit,
                forceRefetch: forceRefetch
            )
            if page.shouldPublishUpdate {
                appListUpdated?(
                    .mcpNotification(
                        hostID: request.hostID,
                        method: "app/list/updated",
                        params: .object([
                            "data": .array(
                                page.allData.map(appInfoJSON)
                            )
                        ]),
                        metadata: [:]
                    )
                )
            }
            return result(
                request,
                value: .object([
                    "data": .array(
                        page.data.map(appInfoJSON)
                    ),
                    "nextCursor": page.nextCursor.map(
                        CodexJSONValue.string
                    ) ?? .null,
                ])
            )
        } catch CodexAppCatalogError.invalidCursor {
            return invalidParams(request)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Apps list failed"
            )
        }
    }

    @MainActor
    private static func appsReadResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopAppCataloging)?
    ) -> CodexDesktopHostMessage {
        guard let catalog,
              case let .object(params)? = request.request.params,
              case let .array(values)? = params["appIds"],
              values.allSatisfy({
                  if case .string = $0 { true } else { false }
              })
        else {
            return catalog == nil
                ? error(
                    request,
                    code: -32603,
                    message: "Apps service unavailable"
                )
                : invalidParams(request)
        }
        let includeTools: Bool
        switch params["includeTools"] {
        case let .bool(value): includeTools = value
        case nil: includeTools = false
        default: return invalidParams(request)
        }
        do {
            let response = try catalog.readApps(
                appIDs: values.compactMap {
                    if case let .string(value) = $0 {
                        value
                    } else { nil }
                },
                includeTools: includeTools
            )
            return result(
                request,
                value: .object([
                    "apps": .array(
                        response.apps.map {
                            app in
                            .object([
                                "id": .string(app.id),
                                "name": .string(app.name),
                                "description":
                                    app.description.map(
                                        CodexJSONValue.string
                                    ) ?? .null,
                                "iconUrl": .null,
                                "iconUrlDark": .null,
                                "distributionChannel": .null,
                                "installUrl": .null,
                                "pluginDisplayNames": .array(
                                    app.pluginDisplayNames.map(
                                        CodexJSONValue.string
                                    )
                                ),
                                "toolSummaries":
                                    includeTools
                                    ? .array([]) : .null,
                            ])
                        }
                    ),
                    "missingAppIds": .array(
                        response.missingAppIDs.map(
                            CodexJSONValue.string
                        )
                    ),
                ])
            )
        } catch CodexAppCatalogError.tooManyIDs {
            return invalidParams(request)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Apps read failed"
            )
        }
    }

    @MainActor
    private static func appsInstalledResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopAppCataloging)?
    ) -> CodexDesktopHostMessage {
        guard let catalog,
              case let .object(params)? = request.request.params
        else {
            return catalog == nil
                ? error(
                    request,
                    code: -32603,
                    message: "Apps service unavailable"
                )
                : invalidParams(request)
        }
        let forceRefresh: Bool
        switch params["forceRefresh"] {
        case let .bool(value): forceRefresh = value
        case nil: forceRefresh = false
        default: return invalidParams(request)
        }
        if let threadID = params["threadId"],
           threadID != .null,
           case .string = threadID
        {} else if params["threadId"] != nil,
                  params["threadId"] != .null
        {
            return invalidParams(request)
        }
        return result(
            request,
            value: .object([
                "apps": .array(
                    catalog.installedApps(
                        forceRefresh: forceRefresh
                    ).map {
                        .object([
                            "id": .string($0.id),
                            "runtimeName":
                                $0.runtimeName.map(
                                    CodexJSONValue.string
                                ) ?? .null,
                            "enabled": .bool($0.enabled),
                            "callable": .bool($0.callable),
                        ])
                    }
                ),
            ])
        )
    }

    private static func appInfoJSON(
        _ app: CodexAppCatalogItem
    ) -> CodexJSONValue {
        .object([
            "id": .string(app.id),
            "name": .string(app.name),
            "description":
                app.description.map(
                    CodexJSONValue.string
                ) ?? .null,
            "logoUrl": .null,
            "logoUrlDark": .null,
            "iconAssets": .null,
            "iconDarkAssets": .null,
            "distributionChannel": .null,
            "branding": app.category.map {
                .object([
                    "category": .string($0),
                    "developer": .null,
                    "website": .null,
                    "privacyPolicy": .null,
                    "termsOfService": .null,
                    "isDiscoverableApp": .bool(false),
                ])
            } ?? .null,
            "appMetadata": .null,
            "labels": .null,
            "installUrl": .null,
            "isAccessible": .bool(app.isAccessible),
            "isEnabled": .bool(app.isEnabled),
            "pluginDisplayNames": .array(
                app.pluginDisplayNames.map(
                    CodexJSONValue.string
                )
            ),
        ])
    }

    @MainActor
    private static func hooksListResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopHookCataloging)?
    ) -> CodexDesktopHostMessage {
        guard let catalog,
              case let .object(params)? = request.request.params
        else {
            return catalog == nil
                ? error(
                    request,
                    code: -32603,
                    message: "Hooks service unavailable"
                )
                : invalidParams(request)
        }
        let cwds: [String]
        if let value = params["cwds"] {
            guard case let .array(items) = value,
                  items.allSatisfy({
                      if case .string = $0 { true } else { false }
                  })
            else { return invalidParams(request) }
            cwds = items.compactMap {
                if case let .string(value) = $0 { value }
                else { nil }
            }
        } else {
            cwds = []
        }
        return result(
            request,
            value: .object([
                "data": .array(
                    catalog.listHooks(cwds: cwds).map {
                        entry in
                        .object([
                            "cwd": .string(entry.cwd),
                            "hooks": .array(
                                entry.hooks.map(hookMetadataJSON)
                            ),
                            "warnings": .array(
                                entry.warnings.map(
                                    CodexJSONValue.string
                                )
                            ),
                            "errors": .array(
                                entry.errors.map {
                                    .object([
                                        "path": .string($0.path),
                                        "message": .string(
                                            $0.message
                                        ),
                                    ])
                                }
                            ),
                        ])
                    }
                ),
            ])
        )
    }

    private static func hookMetadataJSON(
        _ hook: CodexHookMetadata
    ) -> CodexJSONValue {
        .object([
            "key": .string(hook.key),
            "eventName": .string(hook.eventName.rawValue),
            "handlerType": .string(
                hook.handlerType.rawValue
            ),
            "executionMode": .string(
                hook.executionMode.rawValue
            ),
            "matcher": hook.matcher.map(
                CodexJSONValue.string
            ) ?? .null,
            "command": hook.command.map(
                CodexJSONValue.string
            ) ?? .null,
            "timeoutSec": .number(Double(hook.timeoutSec)),
            "statusMessage": hook.statusMessage.map(
                CodexJSONValue.string
            ) ?? .null,
            "additionalContextLimit":
                hook.additionalContextLimit.map {
                    .number(Double($0))
                } ?? .null,
            "sourcePath": .string(hook.sourcePath),
            "source": .string(hook.source.rawValue),
            "pluginId": hook.pluginID.map(
                CodexJSONValue.string
            ) ?? .null,
            "displayOrder": .number(
                Double(hook.displayOrder)
            ),
            "enabled": .bool(hook.enabled),
            "isManaged": .bool(hook.isManaged),
            "currentHash": .string(hook.currentHash),
            "trustStatus": .string(
                hook.trustStatus.rawValue
            ),
        ])
    }

    @MainActor
    private static func skillsListResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopSkillCataloging)?
    ) -> CodexDesktopHostMessage {
        guard let catalog,
              case let .object(params)? = request.request.params
        else {
            return catalog == nil
                ? error(
                    request,
                    code: -32603,
                    message: "Skills service unavailable"
                )
                : invalidParams(request)
        }
        let cwds: [String]
        if let value = params["cwds"] {
            guard case let .array(items) = value,
                  items.allSatisfy({
                      if case .string = $0 { true } else { false }
                  })
            else { return invalidParams(request) }
            cwds = items.compactMap {
                if case let .string(value) = $0 {
                    value
                } else {
                    nil
                }
            }
        } else {
            cwds = []
        }
        let forceReload: Bool
        if let value = params["forceReload"] {
            guard case let .bool(flag) = value
            else { return invalidParams(request) }
            forceReload = flag
        } else {
            forceReload = false
        }
        do {
            let entries = try catalog.listSkills(
                cwds: cwds,
                forceReload: forceReload
            )
            return result(
                request,
                value: .object([
                    "data": .array(
                        entries.map(skillsListEntryJSON)
                    ),
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Skills list failed"
            )
        }
    }

    @MainActor
    private static func skillsExtraRootsSetResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopSkillCataloging)?
    ) -> CodexDesktopHostMessage {
        guard let catalog,
              case let .object(params)? = request.request.params,
              case let .array(values)? = params["extraRoots"],
              values.allSatisfy({
                  if case .string = $0 { true } else { false }
              })
        else {
            return catalog == nil
                ? error(
                    request,
                    code: -32603,
                    message: "Skills service unavailable"
                )
                : invalidParams(request)
        }
        catalog.setSkillExtraRoots(
            values.compactMap {
                if case let .string(value) = $0 {
                    value
                } else {
                    nil
                }
            }
        )
        return result(request, value: .object([:]))
    }

    @MainActor
    private static func skillsConfigWriteResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopSkillCataloging)?
    ) -> CodexDesktopHostMessage {
        guard let catalog,
              case let .object(params)? = request.request.params,
              case let .bool(enabled)? = params["enabled"]
        else {
            return catalog == nil
                ? error(
                    request,
                    code: -32603,
                    message: "Skills service unavailable"
                )
                : invalidParams(request)
        }
        let path: String?
        switch params["path"] {
        case let .string(value): path = value
        case .null, nil: path = nil
        default: return invalidParams(request)
        }
        let name: String?
        switch params["name"] {
        case let .string(value): name = value
        case .null, nil: name = nil
        default: return invalidParams(request)
        }
        guard (path != nil) != (name != nil)
        else { return invalidParams(request) }
        do {
            let effective = try catalog.setSkillEnabled(
                path: path,
                name: name,
                enabled: enabled
            )
            return result(
                request,
                value: .object([
                    "effectiveEnabled": .bool(effective),
                ])
            )
        } catch {
            return invalidParams(request)
        }
    }

    private static func skillsListEntryJSON(
        _ entry: CodexSkillsListEntry
    ) -> CodexJSONValue {
        .object([
            "cwd": .string(entry.cwd),
            "skills": .array(
                entry.skills.map(skillMetadataJSON)
            ),
            "errors": .array(
                entry.errors.map {
                    .object([
                        "path": .string($0.path),
                        "message": .string($0.message),
                    ])
                }
            ),
        ])
    }

    private static func skillMetadataJSON(
        _ skill: CodexSkillMetadata
    ) -> CodexJSONValue {
        var fields: [String: CodexJSONValue] = [
            "name": .string(skill.name),
            "description": .string(skill.description),
            "path": .string(skill.path),
            "scope": .string(skill.scope.rawValue),
            "enabled": .bool(skill.enabled),
        ]
        if let shortDescription = skill.shortDescription {
            fields["shortDescription"] = .string(
                shortDescription
            )
        }
        return .object(fields)
    }

    @MainActor
    private static func marketplaceAddResponse(
        to request: CodexDesktopMCPRequest,
        using manager:
            (any CodexDesktopMarketplaceManaging)?
    ) async -> CodexDesktopHostMessage {
        guard let manager else {
            return error(
                request,
                code: -32603,
                message: "Marketplace service unavailable"
            )
        }
        guard case let .object(params)? = request.request.params,
              case let .string(source)? = params["source"],
              !source.isEmpty
        else { return invalidParams(request) }
        let refName: String?
        switch params["refName"] {
        case let .string(value):
            guard !value.isEmpty else {
                return invalidParams(request)
            }
            refName = value
        case .null, nil:
            refName = nil
        default:
            return invalidParams(request)
        }
        let sparsePaths: [String]
        switch params["sparsePaths"] {
        case let .array(values):
            sparsePaths = values.compactMap {
                guard case let .string(value) = $0,
                      !value.isEmpty
                else { return nil }
                return value
            }
            guard sparsePaths.count == values.count else {
                return invalidParams(request)
            }
        case .null, nil:
            sparsePaths = []
        default:
            return invalidParams(request)
        }
        do {
            let added = try await manager.addMarketplace(
                source: source,
                refName: refName,
                sparsePaths: sparsePaths
            )
            return result(
                request,
                value: .object([
                    "marketplaceName":
                        .string(added.marketplaceName),
                    "installedRoot":
                        .string(added.installedRoot),
                    "alreadyAdded":
                        .bool(added.alreadyAdded),
                ])
            )
        } catch {
            return marketplaceError(request, error)
        }
    }

    @MainActor
    private static func marketplaceRemoveResponse(
        to request: CodexDesktopMCPRequest,
        using manager:
            (any CodexDesktopMarketplaceManaging)?
    ) -> CodexDesktopHostMessage {
        guard let manager else {
            return error(
                request,
                code: -32603,
                message: "Marketplace service unavailable"
            )
        }
        guard case let .object(params)? = request.request.params,
              case let .string(name)? = params["marketplaceName"],
              !name.isEmpty
        else { return invalidParams(request) }
        do {
            let removed = try manager.removeMarketplace(named: name)
            return result(
                request,
                value: .object([
                    "marketplaceName":
                        .string(removed.marketplaceName),
                    "installedRoot":
                        removed.installedRoot.map(
                            CodexJSONValue.string
                        ) ?? .null,
                ])
            )
        } catch {
            return marketplaceError(request, error)
        }
    }

    @MainActor
    private static func marketplaceUpgradeResponse(
        to request: CodexDesktopMCPRequest,
        using manager:
            (any CodexDesktopMarketplaceManaging)?
    ) async -> CodexDesktopHostMessage {
        guard let manager else {
            return error(
                request,
                code: -32603,
                message: "Marketplace service unavailable"
            )
        }
        guard case let .object(params)? = request.request.params
        else { return invalidParams(request) }
        let name: String?
        switch params["marketplaceName"] {
        case let .string(value):
            guard !value.isEmpty else {
                return invalidParams(request)
            }
            name = value
        case .null, nil:
            name = nil
        default:
            return invalidParams(request)
        }
        let upgraded = await manager.upgradeMarketplaces(named: name)
        return result(
            request,
            value: .object([
                "selectedMarketplaces": .array(
                    upgraded.selectedMarketplaces.map(
                        CodexJSONValue.string
                    )
                ),
                "upgradedRoots": .array(
                    upgraded.upgradedRoots.map(
                        CodexJSONValue.string
                    )
                ),
                "errors": .array(
                    upgraded.errors.map {
                        .object([
                            "marketplaceName":
                                .string($0.marketplaceName),
                            "message": .string($0.message),
                        ])
                    }
                ),
            ])
        )
    }

    private static func marketplaceError(
        _ request: CodexDesktopMCPRequest,
        _ caught: Error
    ) -> CodexDesktopHostMessage {
        if case let CodexMarketplaceManagementError
            .invalidRequest(message) = caught
        {
            return error(request, code: -32602, message: message)
        }
        let message: String
        if case let CodexMarketplaceManagementError
            .internalFailure(detail) = caught
        {
            message = detail
        } else {
            message = String(describing: caught)
        }
        return error(request, code: -32603, message: message)
    }

    @MainActor
    private static func pluginSearchResponse(
        to request: CodexDesktopMCPRequest,
        using remote:
            (any CodexDesktopRemotePluginCataloging)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(searchTerm)? = params["searchTerm"],
              !searchTerm.isEmpty
        else {
            return invalidParams(request)
        }

        let scope: String?
        switch params["scope"] {
        case nil, .null?:
            scope = nil
        case let .string(value)?:
            guard ["global", "workspace", "personal"].contains(value)
            else { return invalidParams(request) }
            scope = value
        default:
            return invalidParams(request)
        }

        let cwds: [String]?
        switch params["cwds"] {
        case nil, .null?:
            cwds = nil
        case let .array(values)?:
            guard values.allSatisfy({
                if case .string = $0 { true } else { false }
            }) else { return invalidParams(request) }
            cwds = values.compactMap {
                if case let .string(value) = $0 {
                    value
                } else {
                    nil
                }
            }
        default:
            return invalidParams(request)
        }

        let cursor: String?
        switch params["cursor"] {
        case nil, .null?:
            cursor = nil
        case let .string(value)?:
            cursor = value
        default:
            return invalidParams(request)
        }

        let limit: Int?
        switch params["limit"] {
        case nil, .null?:
            limit = nil
        case let .integer(value)?
            where value >= 0 && value <= Int64(UInt32.max):
            limit = Int(value)
        default:
            return invalidParams(request)
        }

        guard let remote else {
            return error(
                request,
                code: -32603,
                message: "Remote plugins service unavailable"
            )
        }
        do {
            let response = try await remote.searchRemotePlugins(
                searchTerm: searchTerm,
                scope: scope,
                cwds: cwds,
                cursor: cursor,
                limit: limit
            )
            return result(
                request,
                value: .object([
                    "data": .array(
                        response.data.map { item in
                            .object([
                                "plugin": remotePluginSummaryJSON(
                                    item.plugin
                                ),
                                "marketplaceName": .string(
                                    item.marketplaceName
                                ),
                                "marketplacePath":
                                    item.marketplacePath.map(
                                        CodexJSONValue.string
                                    ) ?? .null,
                            ])
                        }
                    ),
                    "nextCursor": response.nextCursor.map {
                        .string($0)
                    } ?? .null,
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Plugin search failed"
            )
        }
    }

    @MainActor
    private static func pluginListResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopPluginCataloging)?,
        remote:
            (any CodexDesktopRemotePluginCataloging)?
    ) async -> CodexDesktopHostMessage {
        guard catalog != nil || remote != nil,
              case let .object(params)? = request.request.params
        else {
            return catalog == nil && remote == nil
                ? error(
                    request,
                    code: -32603,
                    message: "Plugins service unavailable"
                )
                : invalidParams(request)
        }
        var marketplaceKinds = ["local"]
        var forceRefetch = false
        if let cwds = params["cwds"], cwds != .null {
            guard case let .array(values) = cwds,
                  values.allSatisfy({
                      if case .string = $0 { true } else { false }
                  })
            else { return invalidParams(request) }
        }
        if request.request.method == "plugin/list" {
            if let forceValue = params["forceRefetch"],
               let value = forceValue.boolValue
            {
                forceRefetch = value
            } else if params["forceRefetch"] != nil {
                return invalidParams(request)
            }
            if let kinds = params["marketplaceKinds"],
               kinds != .null
            {
                guard case let .array(values) = kinds,
                      values.allSatisfy({
                          if case let .string(kind) = $0 {
                              [
                                  "local",
                                  "vertical",
                                  "workspace-directory",
                                  "shared-with-me",
                                  "created-by-me-remote",
                              ].contains(kind)
                          } else {
                              false
                          }
                      })
                else { return invalidParams(request) }
                marketplaceKinds = values.compactMap {
                    if case let .string(value) = $0 {
                        return value
                    }
                    return nil
                }
            }
        }
        let localResponse = catalog?.listPlugins()
        var remoteMarketplaces: [CodexRemotePluginMarketplace] = []
        var featuredPluginIDs: [String] = []
        do {
            if request.request.method == "plugin/installed" {
                remoteMarketplaces =
                    try await remote?
                        .listInstalledRemotePlugins() ?? []
            } else {
                let remoteKinds = marketplaceKinds.filter {
                    $0 != "local"
                }
                if !remoteKinds.isEmpty {
                    let response = try await remote?
                        .listRemotePlugins(
                            marketplaceKinds: remoteKinds,
                            forceRefetch: forceRefetch
                        )
                    remoteMarketplaces =
                        response?.marketplaces ?? []
                    featuredPluginIDs =
                        response?.featuredPluginIDs ?? []
                }
            }
        } catch {}
        let includeLocal =
            request.request.method == "plugin/installed"
                || marketplaceKinds.contains("local")
        let localMarketplaces =
            includeLocal ? (localResponse?.marketplaces ?? []) : []
        var fields: [String: CodexJSONValue] = [
            "marketplaces": .array(
                localMarketplaces.map(pluginMarketplaceJSON)
                    + remoteMarketplaces.map(
                        remotePluginMarketplaceJSON
                    )
            ),
            "marketplaceLoadErrors": .array(
                (localResponse?.marketplaceLoadErrors ?? []).map {
                    .object([
                        "marketplacePath": .string($0.path),
                        "message": .string($0.message),
                    ])
                }
            ),
        ]
        if request.request.method == "plugin/list" {
            fields["featuredPluginIds"] = .array(
                featuredPluginIDs.map(
                    CodexJSONValue.string
                )
            )
        }
        return result(request, value: .object(fields))
    }

    @MainActor
    private static func pluginReadResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopPluginCataloging)?,
        remote:
            (any CodexDesktopRemotePluginCataloging)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(pluginName)? = params["pluginName"],
              !pluginName.isEmpty
        else {
            return invalidParams(request)
        }
        do {
            if case let .string(marketplaceName)? =
                params["remoteMarketplaceName"],
               !marketplaceName.isEmpty,
               params["marketplacePath"] == nil
                    || params["marketplacePath"] == .null
            {
                guard let remote else {
                    return error(
                        request,
                        code: -32603,
                        message: "Remote plugins service unavailable"
                    )
                }
                let detail = try await remote.readRemotePlugin(
                    marketplaceName: marketplaceName,
                    remotePluginID: pluginName
                )
                return result(
                    request,
                    value: .object([
                        "plugin": remotePluginDetailJSON(detail),
                    ])
                )
            }
            guard let catalog,
                  case let .string(marketplacePath)? =
                    params["marketplacePath"],
                  !marketplacePath.isEmpty,
                  params["remoteMarketplaceName"] == nil
                    || params["remoteMarketplaceName"] == .null
            else { return invalidParams(request) }
            return result(
                request,
                value: .object([
                    "plugin": pluginDetailJSON(
                        try catalog.readPlugin(
                            marketplacePath: marketplacePath,
                            pluginName: pluginName
                        )
                    ),
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Plugin read failed"
            )
        }
    }

    @MainActor
    private static func pluginInstallResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopPluginCataloging)?,
        remote:
            (any CodexDesktopRemotePluginCataloging)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(pluginName)? = params["pluginName"],
              !pluginName.isEmpty
        else {
            return invalidParams(request)
        }
        do {
            let installed: CodexPluginInstallResult
            if case let .string(marketplaceName)? =
                params["remoteMarketplaceName"],
               !marketplaceName.isEmpty,
               params["marketplacePath"] == nil
                    || params["marketplacePath"] == .null
            {
                guard let remote else {
                    return error(
                        request,
                        code: -32603,
                        message: "Remote plugins service unavailable"
                    )
                }
                installed = try await remote.installRemotePlugin(
                    marketplaceName: marketplaceName,
                    remotePluginID: pluginName
                )
            } else {
                guard let catalog,
                      case let .string(marketplacePath)? =
                        params["marketplacePath"],
                      !marketplacePath.isEmpty,
                      params["remoteMarketplaceName"] == nil
                        || params["remoteMarketplaceName"] == .null
                else { return invalidParams(request) }
                installed = try catalog.installPlugin(
                    marketplacePath: marketplacePath,
                    pluginName: pluginName
                )
            }
            return result(
                request,
                value: .object([
                    "authPolicy": .string(
                        installed.authPolicy
                    ),
                    "appsNeedingAuth": .array(
                        installed.appsNeedingAuth.map {
                            .object(["id": .string($0)])
                        }
                    ),
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Plugin install failed"
            )
        }
    }

    @MainActor
    private static func pluginUninstallResponse(
        to request: CodexDesktopMCPRequest,
        using catalog:
            (any CodexDesktopPluginCataloging)?,
        remote:
            (any CodexDesktopRemotePluginCataloging)?
    ) async -> CodexDesktopHostMessage {
        guard case let .object(params)? = request.request.params,
              case let .string(pluginID)? = params["pluginId"],
              !pluginID.isEmpty
        else {
            return invalidParams(request)
        }
        do {
            if isRemotePluginConfigID(pluginID) {
                guard let remote else {
                    return error(
                        request,
                        code: -32603,
                        message: "Remote plugins service unavailable"
                    )
                }
                try await remote.uninstallRemotePlugin(
                    pluginID: pluginID
                )
            } else {
                guard let catalog else {
                    return error(
                        request,
                        code: -32603,
                        message: "Plugins service unavailable"
                    )
                }
                try catalog.uninstallPlugin(pluginID: pluginID)
            }
            return result(request, value: .object([:]))
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Plugin uninstall failed"
            )
        }
    }

    @MainActor
    private static func pluginSkillReadResponse(
        to request: CodexDesktopMCPRequest,
        using remote:
            (any CodexDesktopRemotePluginCataloging)?
    ) async -> CodexDesktopHostMessage {
        guard let remote,
              case let .object(params)? = request.request.params,
              case let .string(remotePluginID)? =
                params["remotePluginId"],
              case let .string(skillName)? = params["skillName"],
              case .string? = params["remoteMarketplaceName"],
              !remotePluginID.isEmpty,
              !skillName.isEmpty
        else {
            return remote == nil
                ? error(
                    request,
                    code: -32603,
                    message: "Remote plugins service unavailable"
                )
                : invalidParams(request)
        }
        do {
            let contents = try await remote.readRemotePluginSkill(
                remotePluginID: remotePluginID,
                skillName: skillName
            )
            return result(
                request,
                value: .object([
                    "contents": contents.map(
                        CodexJSONValue.string
                    ) ?? .null,
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Plugin skill read failed"
            )
        }
    }

    @MainActor
    private static func pluginShareSaveResponse(
        to request: CodexDesktopMCPRequest,
        using sharing: (any CodexDesktopRemotePluginSharing)?
    ) async -> CodexDesktopHostMessage {
        guard let sharing else {
            return error(
                request,
                code: -32603,
                message: "Plugin sharing service unavailable"
            )
        }
        guard case let .object(params)? = request.request.params,
              case let .string(pluginPath)? = params["pluginPath"],
              !pluginPath.isEmpty
        else { return invalidParams(request) }
        let remotePluginID: String?
        if case let .string(value)? = params["remotePluginId"] {
            remotePluginID = value
        } else if params["remotePluginId"] == nil
                    || params["remotePluginId"] == .null
        {
            remotePluginID = nil
        } else { return invalidParams(request) }
        let discoverability: String?
        if case let .string(value)? = params["discoverability"] {
            discoverability = value
        } else if params["discoverability"] == nil
                    || params["discoverability"] == .null
        {
            discoverability = nil
        } else { return invalidParams(request) }
        var targets: [CodexRemotePluginShareTarget]?
        if case let .array(rawTargets)? = params["shareTargets"] {
            targets = []
            for rawTarget in rawTargets {
                guard case let .object(target) = rawTarget,
                      case let .string(principalType)? =
                        target["principalType"],
                      case let .string(principalID)? =
                        target["principalId"],
                      case let .string(role)? = target["role"]
                else { return invalidParams(request) }
                targets?.append(
                    CodexRemotePluginShareTarget(
                        principalType: principalType,
                        principalID: principalID,
                        role: role
                    )
                )
            }
        } else if params["shareTargets"] != nil
                    && params["shareTargets"] != .null
        {
            return invalidParams(request)
        }
        do {
            let response = try await sharing.saveRemotePluginShare(
                pluginPath: URL(fileURLWithPath: pluginPath),
                remotePluginID: remotePluginID,
                discoverability: discoverability,
                shareTargets: targets
            )
            return result(
                request,
                value: .object([
                    "remotePluginId": .string(
                        response.remotePluginID
                    ),
                    "shareUrl": response.shareURL.map(
                        CodexJSONValue.string
                    ) ?? .null,
                    "canPublishToWorkspace":
                        response.canPublishToWorkspace.map(
                            CodexJSONValue.bool
                        ) ?? .null,
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Plugin share save failed"
            )
        }
    }

    @MainActor
    private static func pluginShareUpdateTargetsResponse(
        to request: CodexDesktopMCPRequest,
        using sharing: (any CodexDesktopRemotePluginSharing)?
    ) async -> CodexDesktopHostMessage {
        guard let sharing else {
            return error(
                request,
                code: -32603,
                message: "Plugin sharing service unavailable"
            )
        }
        guard case let .object(params)? = request.request.params,
              case let .string(remotePluginID)? =
                params["remotePluginId"],
              case let .string(discoverability)? =
                params["discoverability"],
              case let .array(rawTargets)? = params["shareTargets"],
              !remotePluginID.isEmpty
        else { return invalidParams(request) }
        var targets: [CodexRemotePluginShareTarget] = []
        for rawTarget in rawTargets {
            guard case let .object(target) = rawTarget,
                  case let .string(principalType)? =
                    target["principalType"],
                  case let .string(principalID)? =
                    target["principalId"],
                  case let .string(role)? = target["role"],
                  !principalID.isEmpty
            else { return invalidParams(request) }
            targets.append(
                CodexRemotePluginShareTarget(
                    principalType: principalType,
                    principalID: principalID,
                    role: role
                )
            )
        }
        do {
            let response = try await sharing
                .updateRemotePluginShareTargets(
                    remotePluginID: remotePluginID,
                    discoverability: discoverability,
                    shareTargets: targets
                )
            return result(
                request,
                value: .object([
                    "principals": .array(
                        response.principals.map(
                            remotePluginSharePrincipalJSON
                        )
                    ),
                    "discoverability": .string(
                        response.discoverability
                    ),
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Plugin share target update failed"
            )
        }
    }

    @MainActor
    private static func pluginShareListResponse(
        to request: CodexDesktopMCPRequest,
        using sharing: (any CodexDesktopRemotePluginSharing)?
    ) async -> CodexDesktopHostMessage {
        guard hasUnitParams(request.request.params)
        else { return invalidParams(request) }
        guard let sharing else {
            return error(
                request,
                code: -32603,
                message: "Plugin sharing service unavailable"
            )
        }
        do {
            let shares = try await sharing.listRemotePluginShares()
            return result(
                request,
                value: .object([
                    "data": .array(
                        shares.map { item in
                            .object([
                                "plugin": remotePluginSummaryJSON(
                                    item.plugin
                                ),
                                "localPluginPath":
                                    item.localPluginPath.map(
                                        CodexJSONValue.string
                                    ) ?? .null,
                            ])
                        }
                    ),
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Plugin share list failed"
            )
        }
    }

    @MainActor
    private static func pluginShareCheckoutResponse(
        to request: CodexDesktopMCPRequest,
        using sharing: (any CodexDesktopRemotePluginSharing)?
    ) async -> CodexDesktopHostMessage {
        guard let sharing else {
            return error(
                request,
                code: -32603,
                message: "Plugin sharing service unavailable"
            )
        }
        guard case let .object(params)? = request.request.params,
              case let .string(remotePluginID)? =
                params["remotePluginId"],
              !remotePluginID.isEmpty
        else { return invalidParams(request) }
        do {
            let response = try await sharing
                .checkoutRemotePluginShare(
                    remotePluginID: remotePluginID
                )
            return result(
                request,
                value: .object([
                    "remotePluginId": .string(
                        response.remotePluginID
                    ),
                    "pluginId": .string(response.pluginID),
                    "pluginName": .string(response.pluginName),
                    "pluginPath": .string(response.pluginPath),
                    "marketplaceName": .string(
                        response.marketplaceName
                    ),
                    "marketplacePath": .string(
                        response.marketplacePath
                    ),
                    "remoteVersion": response.remoteVersion.map(
                        CodexJSONValue.string
                    ) ?? .null,
                ])
            )
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Plugin share checkout failed"
            )
        }
    }

    @MainActor
    private static func pluginShareDeleteResponse(
        to request: CodexDesktopMCPRequest,
        using sharing: (any CodexDesktopRemotePluginSharing)?
    ) async -> CodexDesktopHostMessage {
        guard let sharing else {
            return error(
                request,
                code: -32603,
                message: "Plugin sharing service unavailable"
            )
        }
        guard case let .object(params)? = request.request.params,
              case let .string(remotePluginID)? =
                params["remotePluginId"],
              !remotePluginID.isEmpty
        else { return invalidParams(request) }
        do {
            try await sharing.deleteRemotePluginShare(
                remotePluginID: remotePluginID
            )
            return result(request, value: .object([:]))
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Plugin share delete failed"
            )
        }
    }

    private static func remotePluginSharePrincipalJSON(
        _ principal: CodexRemotePluginSharePrincipal
    ) -> CodexJSONValue {
        .object([
            "principalType": .string(principal.principalType),
            "principalId": .string(principal.principalID),
            "role": .string(principal.role),
            "name": .string(principal.name),
        ])
    }

    private static func pluginMarketplaceJSON(
        _ marketplace: CodexPluginMarketplaceEntry
    ) -> CodexJSONValue {
        .object([
            "name": .string(marketplace.name),
            "path": .string(marketplace.path),
            "interface": marketplace.displayName.map {
                .object(["displayName": .string($0)])
            } ?? .null,
            "plugins": .array(
                marketplace.plugins.map(pluginSummaryJSON)
            ),
        ])
    }

    private static func pluginSummaryJSON(
        _ plugin: CodexPluginSummary
    ) -> CodexJSONValue {
        .object([
            "id": .string(plugin.id),
            "remotePluginId": .null,
            "version": plugin.version.map(
                CodexJSONValue.string
            ) ?? .null,
            "localVersion": plugin.localVersion.map(
                CodexJSONValue.string
            ) ?? .null,
            "name": .string(plugin.name),
            "shareContext": .null,
            "source": .object([
                "type": .string("local"),
                "path": .string(plugin.sourcePath),
            ]),
            "installed": .bool(plugin.installed),
            "enabled": .bool(plugin.enabled),
            "installPolicy": .string(plugin.installPolicy),
            "installPolicySource": .null,
            "mustShowInstallationInterstitial": .null,
            "authPolicy": .string(plugin.authPolicy),
            "availability": .string(plugin.availability),
            "interface": .null,
            "keywords": .array(
                plugin.keywords.map(CodexJSONValue.string)
            ),
        ])
    }

    private static func pluginDetailJSON(
        _ detail: CodexPluginDetail
    ) -> CodexJSONValue {
        .object([
            "marketplaceName": .string(detail.marketplaceName),
            "marketplacePath": .string(
                detail.marketplacePath
            ),
            "summary": pluginSummaryJSON(detail.summary),
            "shareUrl": .null,
            "description": detail.description.map(
                CodexJSONValue.string
            ) ?? .null,
            "skills": .array(
                detail.skillNames.map { name in
                    .object([
                        "name": .string(name),
                        "description": .null,
                        "shortDescription": .null,
                        "interface": .null,
                        "path": .null,
                        "enabled": .bool(
                            detail.summary.enabled
                        ),
                    ])
                }
            ),
            "hooks": .array(
                detail.hookKeys.map {
                    .object(["key": .string($0)])
                }
            ),
            "apps": .array(
                detail.appIDs.map {
                    .object(["id": .string($0)])
                }
            ),
            "appTemplates": .array([]),
            "mcpServers": .array(
                detail.mcpServerNames.map(
                    CodexJSONValue.string
                )
            ),
            "scheduledTasks": .null,
        ])
    }

    private static func remotePluginMarketplaceJSON(
        _ marketplace: CodexRemotePluginMarketplace
    ) -> CodexJSONValue {
        .object([
            "name": .string(marketplace.name),
            "path": .null,
            "interface": .object([
                "displayName": .string(marketplace.displayName),
            ]),
            "plugins": .array(
                marketplace.plugins.map(remotePluginSummaryJSON)
            ),
        ])
    }

    private static func remotePluginSummaryJSON(
        _ plugin: CodexRemotePluginSummary
    ) -> CodexJSONValue {
        .object([
            "id": .string(plugin.id),
            "remotePluginId": .string(plugin.remotePluginID),
            "version": plugin.version.map(
                CodexJSONValue.string
            ) ?? .null,
            "localVersion": plugin.localVersion.map(
                CodexJSONValue.string
            ) ?? .null,
            "name": .string(plugin.name),
            "shareContext": plugin.shareContext.map {
                remotePluginShareContextJSON($0)
            } ?? .null,
            "source": .object([
                "type": .string("remote"),
            ]),
            "installed": .bool(plugin.installed),
            "enabled": .bool(plugin.enabled),
            "installPolicy": .string(plugin.installPolicy),
            "installPolicySource":
                plugin.installPolicySource.map(
                    CodexJSONValue.string
                ) ?? .null,
            "mustShowInstallationInterstitial":
                plugin.mustShowInstallationInterstitial.map(
                    CodexJSONValue.bool
                ) ?? .null,
            "authPolicy": .string(plugin.authPolicy),
            "availability": .string(plugin.availability),
            "interface": plugin.interface ?? .null,
            "keywords": .array(
                plugin.keywords.map(CodexJSONValue.string)
            ),
        ])
    }

    private static func remotePluginShareContextJSON(
        _ context: CodexRemotePluginShareContext
    ) -> CodexJSONValue {
        .object([
            "remotePluginId": .string(context.remotePluginID),
            "remoteVersion": context.remoteVersion.map(
                CodexJSONValue.string
            ) ?? .null,
            "discoverability": .string(
                context.discoverability
            ),
            "shareUrl": context.shareURL.map(
                CodexJSONValue.string
            ) ?? .null,
            "creatorAccountUserId":
                context.creatorAccountUserID.map(
                    CodexJSONValue.string
                ) ?? .null,
            "creatorName": context.creatorName.map(
                CodexJSONValue.string
            ) ?? .null,
            "sharePrincipals": context.sharePrincipals.map {
                .array($0.map(remotePluginSharePrincipalJSON))
            } ?? .null,
            "canPublishToWorkspace":
                context.canPublishToWorkspace.map(
                    CodexJSONValue.bool
                ) ?? .null,
        ])
    }

    private static func remotePluginDetailJSON(
        _ detail: CodexRemotePluginDetail
    ) -> CodexJSONValue {
        .object([
            "marketplaceName": .string(detail.marketplaceName),
            "marketplacePath": .null,
            "summary": remotePluginSummaryJSON(detail.summary),
            "shareUrl": detail.shareURL.map(
                CodexJSONValue.string
            ) ?? .null,
            "description": detail.description.map(
                CodexJSONValue.string
            ) ?? .null,
            "skills": .array(
                detail.skills.map {
                    .object([
                        "name": .string($0.name),
                        "description": .string($0.description),
                        "shortDescription": .null,
                        "interface": $0.interface ?? .null,
                        "path": .null,
                        "enabled": .bool($0.enabled),
                    ])
                }
            ),
            "hooks": .array([]),
            "apps": .array(
                detail.appIDs.map {
                    .object(["id": .string($0)])
                }
            ),
            "appTemplates": .array(detail.appTemplates),
            "mcpServers": .array(
                detail.mcpServerNames.map(
                    CodexJSONValue.string
                )
            ),
            "scheduledTasks": detail.scheduledTasks.map {
                .array($0)
            } ?? .null,
        ])
    }

    private static func isRemotePluginConfigID(
        _ pluginID: String
    ) -> Bool {
        [
            CodexRemotePluginService.globalMarketplace,
            CodexRemotePluginService.createdByMeMarketplace,
            CodexRemotePluginService.workspaceMarketplace,
            CodexRemotePluginService.sharedWithMeMarketplace,
            CodexRemotePluginService.sharedPrivateMarketplace,
            CodexRemotePluginService.sharedUnlistedMarketplace,
        ].contains { pluginID.hasSuffix("@\($0)") }
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

    private static func realtimeResponse(
        to request: CodexDesktopMCPRequest,
        using manager: (any CodexDesktopRealtimeManaging)?
    ) async -> CodexDesktopHostMessage {
        guard let manager else {
            return error(
                request,
                code: -32603,
                message: "Realtime service unavailable"
            )
        }
        guard case let .object(params)? = request.request.params,
              case let .string(threadID)? = params["threadId"],
              !threadID.isEmpty
        else {
            return invalidParams(request)
        }

        do {
            switch request.request.method {
            case "thread/realtime/start":
                guard case let .string(outputModality)? =
                    params["outputModality"],
                    outputModality == "audio"
                        || outputModality == "text",
                    let model = nullableString(
                        params,
                        key: "model"
                    ),
                    let prompt = nullableString(
                        params,
                        key: "prompt"
                    ),
                    let realtimeSessionID = nullableString(
                        params,
                        key: "realtimeSessionId"
                    ),
                    let voice = nullableString(
                        params,
                        key: "voice"
                    ),
                    let version = nullableString(
                        params,
                        key: "version"
                    ),
                    let initialItemsValue =
                        nullableArray(
                            params,
                            key: "initialItems"
                        )
                else {
                    return invalidParams(request)
                }
                var initialItems:
                    [CodexRealtimeInitialItem] = []
                for value in initialItemsValue ?? [] {
                    guard case let .object(item) = value,
                          case let .string(role)? =
                              item["role"],
                          [
                              "user",
                              "assistant",
                              "developer",
                          ].contains(role),
                          case let .string(text)? =
                              item["text"],
                          !text.isEmpty
                    else {
                        return invalidParams(request)
                    }
                    initialItems.append(
                        .init(role: role, text: text)
                    )
                }
                guard initialItems.count <= 128 else {
                    return invalidParams(request)
                }
                let transport: CodexRealtimeTransport
                switch params["transport"] {
                case nil, .null:
                    transport = .websocket
                case let .object(value):
                    guard case let .string(type)? = value["type"]
                    else {
                        return invalidParams(request)
                    }
                    if type == "websocket" {
                        transport = .websocket
                    } else if type == "webrtc",
                              case let .string(sdp)? = value["sdp"],
                              !sdp.isEmpty
                    {
                        transport = .webrtc(sdp: sdp)
                    } else {
                        return invalidParams(request)
                    }
                default:
                    return invalidParams(request)
                }
                try await manager.start(
                    CodexRealtimeStartParameters(
                        threadID: threadID,
                        model: model,
                        outputModality: outputModality,
                        prompt: prompt,
                        realtimeSessionID: realtimeSessionID,
                        transport: transport,
                        version: version
                            ?? (
                                transport == .websocket
                                    ? "v2"
                                    : "v1"
                            ),
                        voice: voice,
                        initialItems: initialItems
                    )
                )

            case "thread/realtime/appendAudio":
                guard case let .object(audio)? = params["audio"],
                      case let .string(data)? = audio["data"],
                      !data.isEmpty,
                      case let .integer(sampleRate)? =
                        audio["sampleRate"],
                      sampleRate > 0,
                      sampleRate <= Int64(UInt32.max),
                      case let .integer(numChannels)? =
                        audio["numChannels"],
                      numChannels > 0,
                      numChannels <= Int64(UInt16.max),
                      let samplesPerChannel = optionalUInt32(
                        audio["samplesPerChannel"]
                      ),
                      let itemID = nullableString(
                        audio,
                        key: "itemId"
                      )
                else {
                    return invalidParams(request)
                }
                try await manager.appendAudio(
                    threadID: threadID,
                    audio: CodexRealtimeAudioChunk(
                        data: data,
                        sampleRate: UInt32(sampleRate),
                        numChannels: UInt16(numChannels),
                        samplesPerChannel: samplesPerChannel,
                        itemID: itemID
                    )
                )

            case "thread/realtime/appendText":
                guard case let .string(text)? = params["text"]
                else {
                    return invalidParams(request)
                }
                let role: String
                switch params["role"] {
                case nil, .null:
                    role = "user"
                case let .string(value)
                    where [
                        "user",
                        "assistant",
                        "developer",
                    ].contains(value):
                    role = value
                default:
                    return invalidParams(request)
                }
                try await manager.appendText(
                    threadID: threadID,
                    text: text,
                    role: role
                )

            case "thread/realtime/appendSpeech":
                guard case let .string(text)? = params["text"]
                else {
                    return invalidParams(request)
                }
                try await manager.appendSpeech(
                    threadID: threadID,
                    text: text
                )

            case "thread/realtime/stop":
                try await manager.stop(threadID: threadID)

            default:
                return invalidParams(request)
            }
            return result(request, value: .object([:]))
        } catch {
            return Self.error(
                request,
                code: -32603,
                message:
                    error.localizedDescription
            )
        }
    }

    private static func nullableString(
        _ values: [String: CodexJSONValue],
        key: String
    ) -> String?? {
        guard let value = values[key] else {
            return .some(nil)
        }
        switch value {
        case .null:
            return .some(nil)
        case let .string(value):
            return .some(value)
        default:
            return nil
        }
    }

    private static func nullableArray(
        _ values: [String: CodexJSONValue],
        key: String
    ) -> [CodexJSONValue]?? {
        guard let value = values[key] else {
            return .some(nil)
        }
        switch value {
        case .null:
            return .some(nil)
        case let .array(value):
            return .some(value)
        default:
            return nil
        }
    }

    private static func optionalUInt32(
        _ value: CodexJSONValue?
    ) -> UInt32?? {
        guard let value else {
            return .some(nil)
        }
        switch value {
        case .null:
            return .some(nil)
        case let .integer(value)
            where value >= 0
                && value <= Int64(UInt32.max):
            return .some(UInt32(value))
        default:
            return nil
        }
    }

    private static func environmentResponse(
        to request: CodexDesktopMCPRequest,
        using manager: (any CodexDesktopEnvironmentManaging)?
    ) async -> CodexDesktopHostMessage {
        guard let manager else {
            return error(
                request,
                code: -32603,
                message: "Environment service unavailable"
            )
        }
        guard case let .object(params)? = request.request.params,
              case let .string(environmentID)? =
                  params["environmentId"],
              !environmentID.isEmpty
        else {
            return invalidParams(request)
        }

        switch request.request.method {
        case "environment/add":
            guard case let .string(urlString)? =
                      params["execServerUrl"],
                  let url = URL(string: urlString),
                  let connectTimeoutMs = nullableUInt64(
                      params["connectTimeoutMs"]
                  )
            else {
                return invalidParams(request)
            }
            do {
                try await manager.addEnvironment(
                    CodexEnvironmentAddParameters(
                        environmentID: environmentID,
                        execServerURL: url,
                        connectTimeoutMs: connectTimeoutMs
                    )
                )
                return result(request, value: .object([:]))
            } catch {
                return Self.error(
                    request,
                    code: -32602,
                    message: error.localizedDescription
                )
            }
        case "environment/info":
            do {
                let info = try await manager.environmentInfo(
                    environmentID: environmentID
                )
                return result(
                    request,
                    value: .object([
                        "shell": .object([
                            "name": .string(info.shell.name),
                            "path": .string(info.shell.path),
                        ]),
                        "cwd": info.cwd.map(CodexJSONValue.string)
                            ?? .null,
                    ])
                )
            } catch let error as CodexEnvironmentServiceError {
                switch error {
                case let .unknownEnvironment(environmentID):
                    return releasedInvalidRequest(
                        request,
                        message:
                            "unknown environment id `\(environmentID)`"
                    )
                default:
                    return Self.error(
                        request,
                        code: -32603,
                        message:
                            "failed to get info for environment `\(environmentID)`: \(error.localizedDescription)"
                    )
                }
            } catch {
                return Self.error(
                    request,
                    code: -32603,
                    message:
                        "failed to get info for environment `\(environmentID)`: \(error.localizedDescription)"
                )
            }
        case "environment/status":
            let status = await manager.environmentStatus(
                environmentID: environmentID
            )
            var value: [String: CodexJSONValue] = [
                "status": .string(status.status.rawValue),
            ]
            if let detail = status.error {
                value["error"] = .string(detail)
            }
            return result(request, value: .object(value))
        default:
            return invalidParams(request)
        }
    }

    private static func realtimeVoicesResult() -> CodexJSONValue {
        .object([
            "voices": .object([
                "v1": .array(
                    [
                        "juniper",
                        "maple",
                        "spruce",
                        "ember",
                        "vale",
                        "breeze",
                        "arbor",
                        "sol",
                        "cove",
                    ].map(CodexJSONValue.string)
                ),
                "v2": .array(
                    [
                        "alloy",
                        "ash",
                        "ballad",
                        "coral",
                        "echo",
                        "sage",
                        "shimmer",
                        "verse",
                        "marin",
                        "cedar",
                    ].map(CodexJSONValue.string)
                ),
                "defaultV1": .string("cove"),
                "defaultV2": .string("marin"),
            ]),
        ])
    }

    @MainActor
    private static func fuzzyFileSearchResponse(
        to request: CodexDesktopMCPRequest,
        allowedRoots: [String],
        using searcher:
            (any CodexDesktopFuzzyFileSearching)?
    ) async -> CodexDesktopHostMessage {
        guard let searcher,
              case let .object(params)? = request.request.params
        else {
            return searcher == nil
                ? error(
                    request,
                    code: -32603,
                    message: "Fuzzy file search unavailable"
                )
                : invalidParams(request)
        }

        do {
            switch request.request.method {
            case "fuzzyFileSearch":
                guard case let .string(query)? = params["query"],
                      let roots = stringArray(
                          params["roots"]
                      ),
                      let cancellationToken = nullableString(
                          params["cancellationToken"]
                      )
                else { return invalidParams(request) }
                let files = try await searcher.search(
                    query: query,
                    roots: roots,
                    cancellationToken: cancellationToken,
                    allowedRoots: allowedRoots
                )
                return result(
                    request,
                    value: .object([
                        "files": .array(files.map(\.json))
                    ])
                )
            case "fuzzyFileSearch/sessionStart":
                guard case let .string(sessionID)? =
                          params["sessionId"],
                      !sessionID.isEmpty,
                      let roots = stringArray(params["roots"])
                else { return invalidParams(request) }
                try searcher.startSession(
                    sessionID: sessionID,
                    roots: roots,
                    allowedRoots: allowedRoots
                )
                return result(request, value: .object([:]))
            case "fuzzyFileSearch/sessionUpdate":
                guard case let .string(sessionID)? =
                          params["sessionId"],
                      !sessionID.isEmpty,
                      case let .string(query)? = params["query"]
                else { return invalidParams(request) }
                try await searcher.updateSession(
                    sessionID: sessionID,
                    query: query
                )
                return result(request, value: .object([:]))
            case "fuzzyFileSearch/sessionStop":
                guard case let .string(sessionID)? =
                          params["sessionId"],
                      !sessionID.isEmpty
                else { return invalidParams(request) }
                searcher.stopSession(sessionID: sessionID)
                return result(request, value: .object([:]))
            default:
                return invalidParams(request)
            }
        } catch is CodexDesktopFuzzyFileSearchError {
            return invalidParams(request)
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Fuzzy file search failed"
            )
        }
    }

    private static func stringArray(
        _ value: CodexJSONValue?
    ) -> [String]? {
        guard case let .array(values)? = value else {
            return nil
        }
        var strings: [String] = []
        strings.reserveCapacity(values.count)
        for value in values {
            guard case let .string(string) = value else {
                return nil
            }
            strings.append(string)
        }
        return strings
    }

    private static func nullableString(
        _ value: CodexJSONValue?
    ) -> String?? {
        guard let value else { return .some(nil) }
        switch value {
        case .null:
            return .some(nil)
        case let .string(string):
            return .some(string)
        default:
            return nil
        }
    }

    private static func nullableUInt64(
        _ value: CodexJSONValue?
    ) -> UInt64?? {
        guard let value else { return .some(nil) }
        switch value {
        case .null:
            return .some(nil)
        case let .integer(number) where number >= 0:
            return .some(UInt64(number))
        default:
            return nil
        }
    }

    private static func releasedInvalidRequest(
        _ request: CodexDesktopMCPRequest,
        message: String
    ) -> CodexDesktopHostMessage {
        error(
            request,
            code: -32600,
            message: message
        )
    }

    private static func extendedSessionResponse(
        to request: CodexDesktopMCPRequest,
        using backend:
            (any CodexDesktopExtendedSessionRequesting)?
    ) async -> CodexDesktopHostMessage {
        guard let method = CodexDesktopExtendedSessionMethod(
            rawValue: request.request.method
        ),
              case let .object(params)? = request.request.params
        else {
            return invalidParams(request)
        }

        if method == .threadStop {
            guard case let .string(threadID)? = params["threadId"],
                  !threadID.isEmpty
            else {
                return error(
                    request,
                    code: -32602,
                    message: "Invalid params for thread/stop"
                )
            }
        }

        guard let backend else {
            return error(
                request,
                code: -32603,
                message:
                    "Desktop extended session service not connected"
            )
        }

        do {
            return result(
                request,
                value: try await backend.send(
                    CodexDesktopExtendedSessionRequest(
                        id: request.request.id,
                        method: method,
                        params: params
                    )
                )
            )
        } catch let adapterError as
            CodexDesktopExtendedSessionAdapter.Error
        {
            switch adapterError {
            case .malformedParams:
                return Self.error(
                    request,
                    code: -32602,
                    message:
                        "Invalid params for \(method.rawValue)"
                )
            case .capabilityUnavailable:
                return Self.error(
                    request,
                    code: -32603,
                    message:
                        "Desktop extended session capability unavailable"
                )
            }
        } catch {
            return Self.error(
                request,
                code: -32603,
                message: "Desktop extended session request failed"
            )
        }
    }

    private static func releasedPathTypeError(
        _ value: CodexJSONValue
    ) -> String {
        let received: String
        switch value {
        case .null:
            received = "null"
        case let .bool(value):
            received = "boolean `\(value)`"
        case let .integer(value):
            received = "integer `\(value)`"
        case let .number(value):
            received = "floating point `\(value)`"
        case let .string(value):
            received = "string `\(value)`"
        case .array:
            received = "a sequence"
        case .object:
            received = "a map"
        }
        return "invalid type: \(received), expected path string"
    }

    private static func error(
        _ request: CodexDesktopMCPRequest,
        code: Int64,
        message: String,
        data: CodexJSONValue? = nil
    ) -> CodexDesktopHostMessage {
        var payload: [String: CodexJSONValue] = [
            "code": .integer(code),
            "message": .string(message),
        ]
        if let data {
            payload["data"] = data
        }

        return .mcpResponse(
            hostID: request.hostID,
            message: .object([
                "id": requestIDValue(request.request.id),
                "error": .object(payload),
            ]),
            metadata: [:]
        )
    }

    private static func threadSessionErrorResponse(
        _ request: CodexDesktopMCPRequest,
        error sessionError: CodexSessionStoreError,
        fallbackMessage: String
    ) -> CodexDesktopHostMessage {
        switch sessionError {
        case let .appServerError(code, message, data):
            return error(
                request,
                code: code,
                message: message,
                data: data
            )
        default:
            return error(
                request,
                code: -32603,
                message: fallbackMessage
            )
        }
    }

    private static func requestIDValue(
        _ id: CodexAppServerRequestID
    ) -> CodexJSONValue {
        switch id {
        case let .string(value):
            return .string(value)
        case let .integer(value):
            return .integer(value)
        }
    }

    private static func threadListResult(
        _ page: CodexThreadPage
    ) throws -> CodexJSONValue {
        let encodedData = try JSONEncoder().encode(page.data)
        let data = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: encodedData
        )
        guard case .array = data else {
            throw CodexSessionStoreError.invalidReply
        }

        return .object([
            "data": data,
            "nextCursor":
                page.nextCursor.map(CodexJSONValue.string) ?? .null,
            "backwardsCursor":
                page.backwardsCursor.map(CodexJSONValue.string)
                    ?? .null,
        ])
    }

    private static func threadSectionListResult(
        _ page: CodexThreadSectionPage
    ) throws -> CodexJSONValue {
        let encodedData = try JSONEncoder().encode(page.data)
        let data = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: encodedData
        )
        guard case .array = data else {
            throw CodexSessionStoreError.invalidReply
        }

        return .object([
            "data": data,
            "nextCursor":
                page.nextCursor.map(CodexJSONValue.string) ?? .null,
        ])
    }

    private static func threadSectionResult(
        _ section: CodexThreadSection
    ) -> CodexJSONValue {
        .object([
            "section": .object([
                "id": .string(section.id),
                "name": .string(section.name),
            ]),
        ])
    }

    private static func decodeThreadReadParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadReadParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"]
        else {
            throw ThreadParamsDecodingError.invalidParams
        }

        let includeTurns: Bool?
        if let value = fields["includeTurns"] {
            guard case let .bool(decoded) = value else {
                throw ThreadParamsDecodingError.invalidParams
            }
            includeTurns = decoded
        } else {
            includeTurns = nil
        }

        return CodexThreadReadParams(
            threadID: CodexStoredThreadID(threadID),
            includeTurns: includeTurns
        )
    }

    private static func decodeThreadQueueAddParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadQueueAddParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"],
              case let .array(inputValue)? = fields["input"],
              case let .string(clientID)? = fields["clientUserMessageId"],
              !threadID.isEmpty,
              !clientID.isEmpty,
              Set(fields.keys) == ["threadId", "input", "clientUserMessageId"]
        else { throw ThreadParamsDecodingError.invalidParams }
        return CodexThreadQueueAddParams(
            threadID: CodexStoredThreadID(threadID),
            input: try decodeThreadQueueInput(inputValue),
            clientUserMessageID: clientID
        )
    }

    private static func decodeThreadQueueListParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadQueueListParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"],
              !threadID.isEmpty,
              Set(fields.keys).isSubset(of: ["threadId", "cursor", "limit"])
        else { throw ThreadParamsDecodingError.invalidParams }
        return CodexThreadQueueListParams(
            threadID: CodexStoredThreadID(threadID),
            cursor: try decodeThreadWireOptional(fields, key: "cursor", as: String.self),
            limit: try decodeThreadWireOptional(fields, key: "limit", as: UInt32.self)
        )
    }

    private static func decodeThreadQueueUpdateParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadQueueUpdateParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"],
              case let .string(submissionID)? = fields["queuedSubmissionId"],
              case let .array(inputValue)? = fields["input"],
              !threadID.isEmpty,
              !submissionID.isEmpty,
              Set(fields.keys) == ["threadId", "queuedSubmissionId", "input"]
        else { throw ThreadParamsDecodingError.invalidParams }
        return CodexThreadQueueUpdateParams(
            threadID: CodexStoredThreadID(threadID),
            queuedSubmissionID: submissionID,
            input: try decodeThreadQueueInput(inputValue)
        )
    }

    private static func decodeThreadQueueDeleteParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadQueueDeleteParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"],
              case let .string(submissionID)? = fields["queuedSubmissionId"],
              !threadID.isEmpty,
              !submissionID.isEmpty,
              Set(fields.keys) == ["threadId", "queuedSubmissionId"]
        else { throw ThreadParamsDecodingError.invalidParams }
        return CodexThreadQueueDeleteParams(
            threadID: CodexStoredThreadID(threadID),
            queuedSubmissionID: submissionID
        )
    }

    private static func decodeThreadQueueReorderParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadQueueReorderParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"],
              case let .array(ids)? = fields["queuedSubmissionIds"],
              !threadID.isEmpty,
              Set(fields.keys) == ["threadId", "queuedSubmissionIds"]
        else { throw ThreadParamsDecodingError.invalidParams }
        let submissionIDs = try ids.map { value -> String in
            guard case let .string(id) = value, !id.isEmpty else {
                throw ThreadParamsDecodingError.invalidParams
            }
            return id
        }
        return CodexThreadQueueReorderParams(
            threadID: CodexStoredThreadID(threadID),
            queuedSubmissionIDs: submissionIDs
        )
    }

    private static func decodeThreadQueueStartParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadQueueStartParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"],
              !threadID.isEmpty,
              Set(fields.keys).isSubset(of: ["threadId", "queuedSubmissionId"])
        else { throw ThreadParamsDecodingError.invalidParams }
        let queuedID = try decodeThreadWireOptional(
            fields,
            key: "queuedSubmissionId",
            as: String.self
        )
        if case let .value(value) = queuedID, value.isEmpty {
            throw ThreadParamsDecodingError.invalidParams
        }
        return CodexThreadQueueStartParams(
            threadID: CodexStoredThreadID(threadID),
            queuedSubmissionID: queuedID
        )
    }

    private static func decodeThreadQueueInput(
        _ values: [CodexJSONValue]
    ) throws -> [CodexStoredUserInput] {
        do {
            return try values.map { value in
                try JSONDecoder().decode(
                    CodexStoredUserInput.self,
                    from: JSONEncoder().encode(value)
                )
            }
        } catch {
            throw ThreadParamsDecodingError.invalidParams
        }
    }

    private static func decodeThreadSectionListParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadSectionListParams {
        guard case let .object(fields)? = params else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return CodexThreadSectionListParams(
            cursor: try decodeSearchString(fields["cursor"]),
            limit: try decodeSearchLimit(fields["limit"])
        )
    }

    private static func decodeThreadSectionCreateParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadSectionCreateParams {
        guard case let .object(fields)? = params,
              case let .string(name)? = fields["name"]
        else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return CodexThreadSectionCreateParams(name: name)
    }

    private static func decodeThreadSectionUpdateParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadSectionUpdateParams {
        guard case let .object(fields)? = params,
              case let .string(sectionID)? = fields["sectionId"],
              case let .string(name)? = fields["name"]
        else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return CodexThreadSectionUpdateParams(
            sectionID: sectionID,
            name: name
        )
    }

    private static func decodeThreadSectionDeleteParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadSectionDeleteParams {
        guard case let .object(fields)? = params,
              case let .string(sectionID)? = fields["sectionId"]
        else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return CodexThreadSectionDeleteParams(sectionID: sectionID)
    }

    private static func decodeThreadSectionMoveParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadSectionMoveParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"],
              let sectionValue = fields["sectionId"]
        else {
            throw ThreadParamsDecodingError.invalidParams
        }

        let sectionID: CodexWireOptional<String>
        switch sectionValue {
        case .null:
            sectionID = .null
        case let .string(value):
            sectionID = .value(value)
        default:
            throw ThreadParamsDecodingError.invalidParams
        }

        let beforeThreadID: CodexWireOptional<String>
        switch fields["beforeThreadId"] {
        case nil:
            beforeThreadID = .omitted
        case .null:
            beforeThreadID = .null
        case let .string(value):
            beforeThreadID = .value(value)
        default:
            throw ThreadParamsDecodingError.invalidParams
        }

        return CodexThreadSectionMoveParams(
            threadID: CodexStoredThreadID(threadID),
            sectionID: sectionID,
            beforeThreadID: beforeThreadID
        )
    }

    private static func decodeThreadSearchParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadSearchParams {
        guard case let .object(fields)? = params,
              case let .string(searchTerm)? = fields["searchTerm"],
              !searchTerm.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            throw ThreadParamsDecodingError.invalidParams
        }

        return CodexThreadSearchParams(
            cursor: try decodeSearchString(fields["cursor"]),
            limit: try decodeSearchLimit(fields["limit"]),
            sortKey: try decodeSearchEnum(
                fields["sortKey"],
                transform: CodexThreadSortKey.init(rawValue:)
            ),
            sortDirection: try decodeSearchEnum(
                fields["sortDirection"],
                transform: CodexThreadSortDirection.init(rawValue:)
            ),
            sourceKinds: try decodeSearchSourceKinds(
                fields["sourceKinds"]
            ),
            archived: try decodeSearchBool(fields["archived"]),
            searchTerm: searchTerm
        )
    }

    private static func decodeSearchString(
        _ value: CodexJSONValue?
    ) throws -> CodexWireOptional<String> {
        guard let value else { return .omitted }
        if case .null = value { return .null }
        guard case let .string(decoded) = value else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return .value(decoded)
    }

    private static func decodeSearchLimit(
        _ value: CodexJSONValue?
    ) throws -> CodexWireOptional<UInt32> {
        guard let value else { return .omitted }
        if case .null = value { return .null }
        guard case let .integer(decoded) = value,
              let limit = UInt32(exactly: decoded)
        else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return .value(limit)
    }

    private static func decodeSearchBool(
        _ value: CodexJSONValue?
    ) throws -> CodexWireOptional<Bool> {
        guard let value else { return .omitted }
        if case .null = value { return .null }
        guard case let .bool(decoded) = value else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return .value(decoded)
    }

    private static func decodeSearchEnum<Value>(
        _ value: CodexJSONValue?,
        transform: (String) -> Value?
    ) throws -> CodexWireOptional<Value>
    where Value: Equatable & Sendable {
        guard let value else { return .omitted }
        if case .null = value { return .null }
        guard case let .string(raw) = value,
              let decoded = transform(raw)
        else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return .value(decoded)
    }

    private static func decodeSearchSourceKinds(
        _ value: CodexJSONValue?
    ) throws -> CodexWireOptional<[CodexThreadSourceKind]> {
        guard let value else { return .omitted }
        if case .null = value { return .null }
        guard case let .array(rawKinds) = value else {
            throw ThreadParamsDecodingError.invalidParams
        }
        let kinds = try rawKinds.map { value in
            guard case let .string(raw) = value,
                  let kind = CodexThreadSourceKind(rawValue: raw)
            else {
                throw ThreadParamsDecodingError.invalidParams
            }
            return kind
        }
        return .value(kinds)
    }

    private static func decodeThreadMetadataUpdateParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadMetadataUpdateParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"]
        else {
            throw ThreadParamsDecodingError.invalidParams
        }
        let gitInfo: CodexWireOptional<CodexThreadGitInfoPatch>
        if let value = fields["gitInfo"] {
            if case .null = value {
                gitInfo = .null
            } else if case let .object(fields) = value {
                gitInfo = .value(
                    try CodexThreadGitInfoPatch(
                        sha: try decodeGitPatch(fields["sha"]),
                        branch: try decodeGitPatch(fields["branch"]),
                        originURL: try decodeGitPatch(fields["originUrl"])
                    )
                )
            } else {
                throw ThreadParamsDecodingError.invalidParams
            }
        } else {
            gitInfo = .omitted
        }
        let isPinned = try decodeSearchBool(fields["isPinned"])
        let sectionId = try decodeSearchString(fields["sectionId"])
        guard gitInfo != .omitted
            || isPinned != .omitted
            || sectionId != .omitted
        else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return CodexThreadMetadataUpdateParams(
            threadID: CodexStoredThreadID(rawValue: threadID),
            gitInfo: gitInfo,
            isPinned: isPinned,
            sectionId: sectionId
        )
    }

    private static func decodeGitPatch(
        _ value: CodexJSONValue?
    ) throws -> CodexPatchField<String> {
        guard let value else { return .keep }
        if case .null = value { return .clear }
        guard case let .string(decoded) = value else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return .set(decoded)
    }

    private static func decodeThreadSettingsUpdateParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadSettingsUpdateParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"]
        else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return CodexThreadSettingsUpdateParams(
            threadID: CodexStoredThreadID(rawValue: threadID),
            cwd: try decodeWireValue(fields["cwd"], as: String.self),
            approvalPolicy: try decodeWireValue(
                fields["approvalPolicy"],
                as: CodexAppServerAskForApproval.self
            ),
            approvalsReviewer: try decodeWireValue(
                fields["approvalsReviewer"],
                as: CodexAppServerApprovalsReviewer.self
            ),
            sandboxPolicy: try decodeWireValue(
                fields["sandboxPolicy"],
                as: CodexAppServerSandboxPolicy.self
            ),
            permissions: try decodeWireValue(
                fields["permissions"],
                as: String.self
            ),
            model: try decodeWireValue(
                fields["model"],
                as: String.self
            ),
            serviceTier: try decodeWireValue(
                fields["serviceTier"],
                as: String.self
            ),
            effort: try decodeWireValue(
                fields["effort"],
                as: String.self
            ),
            summary: try decodeWireValue(
                fields["summary"],
                as: CodexAppServerReasoningSummary.self
            ),
            collaborationMode: try decodeWireValue(
                fields["collaborationMode"],
                as: CodexCollaborationMode.self
            ),
            multiAgentMode: try decodeWireValue(
                fields["multiAgentMode"],
                as: CodexMultiAgentMode.self
            ),
            personality: try decodeWireValue(
                fields["personality"],
                as: CodexAppServerPersonality.self
            )
        )
    }

    private static func decodeThreadMemoryModeSetParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadMemoryModeSetParams {
        guard case let .object(fields)? = params,
              Set(fields.keys) == Set(["threadId", "mode"]),
              case let .string(threadID)? = fields["threadId"],
              !threadID.isEmpty,
              case let .string(rawMode)? = fields["mode"],
              let mode = CodexThreadMemoryMode(rawValue: rawMode)
        else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return CodexThreadMemoryModeSetParams(
            threadID: CodexStoredThreadID(rawValue: threadID),
            mode: mode
        )
    }

    private static func decodeWireValue<Value>(
        _ value: CodexJSONValue?,
        as _: Value.Type
    ) throws -> CodexWireOptional<Value>
    where Value: Codable & Equatable & Sendable {
        guard let value else { return .omitted }
        if case .null = value { return .null }
        do {
            let data = try JSONEncoder().encode(value)
            return .value(try JSONDecoder().decode(Value.self, from: data))
        } catch {
            throw ThreadParamsDecodingError.invalidParams
        }
    }

    private static func decodeModelListParams(
        _ params: CodexJSONValue?
    ) throws -> CodexModelListParams {
        let value = params ?? .object([:])
        guard case let .object(fields) = value else {
            throw ThreadParamsDecodingError.invalidParams
        }

        let cursor = try decodeWireOptionalString(
            fields,
            key: "cursor"
        )
        let limit: CodexWireOptional<UInt32>
        if let value = fields["limit"] {
            if case .null = value {
                limit = .null
            } else if case let .integer(raw) = value,
                      raw >= 0,
                      raw <= Int64(UInt32.max)
            {
                limit = .value(UInt32(raw))
            } else {
                throw ThreadParamsDecodingError.invalidParams
            }
        } else {
            limit = .omitted
        }

        let includeHidden: CodexWireOptional<Bool>
        if let value = fields["includeHidden"] {
            switch value {
            case .null:
                includeHidden = .null
            case let .bool(raw):
                includeHidden = .value(raw)
            default:
                throw ThreadParamsDecodingError.invalidParams
            }
        } else {
            includeHidden = .omitted
        }

        return CodexModelListParams(
            cursor: cursor,
            limit: limit,
            includeHidden: includeHidden
        )
    }

    private static func decodeWireOptionalString(
        _ fields: [String: CodexJSONValue],
        key: String
    ) throws -> CodexWireOptional<String> {
        guard let value = fields[key] else {
            return .omitted
        }
        switch value {
        case .null:
            return .null
        case let .string(raw):
            return .value(raw)
        default:
            throw ThreadParamsDecodingError.invalidParams
        }
    }

    private static func decodeThreadResumeParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadResumeParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"]
        else {
            throw ThreadParamsDecodingError.invalidParams
        }

        return try CodexThreadResumeParams(
            threadID: CodexStoredThreadID(threadID),
            model: decodeThreadWireOptional(
                fields,
                key: "model",
                as: String.self
            ),
            modelProvider: decodeThreadWireOptional(
                fields,
                key: "modelProvider",
                as: String.self
            ),
            serviceTier: decodeThreadWireOptional(
                fields,
                key: "serviceTier",
                as: String.self
            ),
            cwd: decodeThreadWireOptional(
                fields,
                key: "cwd",
                as: String.self
            ),
            approvalPolicy: decodeThreadWireOptional(
                fields,
                key: "approvalPolicy",
                as: CodexAppServerAskForApproval.self
            ),
            approvalsReviewer: decodeThreadWireOptional(
                fields,
                key: "approvalsReviewer",
                as: CodexAppServerApprovalsReviewer.self
            ),
            sandbox: decodeThreadWireOptional(
                fields,
                key: "sandbox",
                as: CodexAppServerSandboxMode.self
            ),
            config: decodeThreadWireOptional(
                fields,
                key: "config",
                as: [String: CodexJSONValue].self
            ),
            baseInstructions: decodeThreadWireOptional(
                fields,
                key: "baseInstructions",
                as: String.self
            ),
            developerInstructions: decodeThreadWireOptional(
                fields,
                key: "developerInstructions",
                as: String.self
            ),
            personality: decodeThreadWireOptional(
                fields,
                key: "personality",
                as: CodexAppServerPersonality.self
            )
        )
    }

    static func threadResumeDiagnosticSummary(
        _ rawParams: CodexJSONValue?
    ) -> String? {
        guard case let .object(fields)? = rawParams,
              let params = try? decodeThreadResumeParams(rawParams)
        else {
            return nil
        }

        let cwdKind: String
        switch params.cwd {
        case let .value(cwd):
            cwdKind = cwd.hasPrefix("/") ? "absolute" : "relative"
        case .null:
            cwdKind = "null"
        case .omitted:
            cwdKind = "omitted"
        }

        let optionals = [
            "model:\(wireOptionalState(params.model))",
            "modelProvider:\(wireOptionalState(params.modelProvider))",
            "serviceTier:\(wireOptionalState(params.serviceTier))",
            "cwd:\(wireOptionalState(params.cwd))",
            "approvalPolicy:\(wireOptionalState(params.approvalPolicy))",
            "approvalsReviewer:\(wireOptionalState(params.approvalsReviewer))",
            "sandbox:\(wireOptionalState(params.sandbox))",
            "config:\(wireOptionalState(params.config))",
            "baseInstructions:\(wireOptionalState(params.baseInstructions))",
            "developerInstructions:\(wireOptionalState(params.developerInstructions))",
            "personality:\(wireOptionalState(params.personality))",
        ].joined(separator: ",")

        let configKeys: String
        let configModel: String
        let configEffort: String
        switch params.config {
        case let .value(config):
            configKeys = config.keys.sorted().joined(separator: ",")
            configModel = diagnosticString(config["model"])
            configEffort = diagnosticString(
                config["model_reasoning_effort"]
            )
        case .null:
            configKeys = "null"
            configModel = "null"
            configEffort = "null"
        case .omitted:
            configKeys = "omitted"
            configModel = "omitted"
            configEffort = "omitted"
        }

        let personality: String
        switch params.personality {
        case let .value(value):
            personality = value.rawValue
        case .null:
            personality = "null"
        case .omitted:
            personality = "omitted"
        }

        let developerFingerprint = diagnosticFingerprint(
            params.developerInstructions
        )
        let cwdFingerprint = diagnosticFingerprint(params.cwd)

        return "keys=\(fields.keys.sorted().joined(separator: ",")) "
            + "cwd=\(cwdKind) optionals=\(optionals) "
            + "configKeys=\(configKeys) model=\(configModel) "
            + "effort=\(configEffort) personality=\(personality) "
            + "developerBytes=\(developerFingerprint.bytes) "
            + "developerSha256=\(developerFingerprint.sha256) "
            + "cwdBytes=\(cwdFingerprint.bytes) "
            + "cwdSha256=\(cwdFingerprint.sha256)"
    }

    private static func diagnosticString(
        _ value: CodexJSONValue?
    ) -> String {
        switch value {
        case let .string(value):
            return value
        case .null:
            return "null"
        case nil:
            return "omitted"
        default:
            return "non-string"
        }
    }

    private static func diagnosticFingerprint(
        _ value: CodexWireOptional<String>
    ) -> (bytes: Int, sha256: String) {
        switch value {
        case let .value(value):
            let data = Data(value.utf8)
            let digest = SHA256.hash(data: data)
            return (
                data.count,
                digest.prefix(8).map {
                    String(format: "%02x", $0)
                }.joined()
            )
        case .null:
            return (0, "null")
        case .omitted:
            return (0, "omitted")
        }
    }

    private static func wireOptionalState<Value>(
        _ value: CodexWireOptional<Value>
    ) -> String where Value: Equatable & Sendable {
        switch value {
        case .omitted:
            return "omitted"
        case .null:
            return "null"
        case .value:
            return "value"
        }
    }

    private static func decodeThreadForkParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadForkParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"]
        else {
            throw ThreadParamsDecodingError.invalidParams
        }
        let allowed: Set<String> = [
            "threadId", "lastTurnId", "path", "model", "modelProvider",
            "serviceTier", "cwd", "approvalPolicy", "approvalsReviewer",
            "sandbox", "config", "baseInstructions",
            "developerInstructions", "ephemeral", "threadSource",
            "excludeTurns",
            // Current desktop renderers attach the active workspace roots to
            // thread/fork. The iPad session boundary already derives scoped
            // roots from the selected workspace, so accept and intentionally
            // omit this host-only extension instead of rejecting Side Chat.
            "runtimeWorkspaceRoots",
        ]
        guard fields.keys.allSatisfy(allowed.contains) else {
            throw ThreadParamsDecodingError.invalidParams
        }
        let ephemeral: Bool?
        switch fields["ephemeral"] {
        case nil, .null:
            ephemeral = nil
        case let .bool(value):
            ephemeral = value
        default:
            throw ThreadParamsDecodingError.invalidParams
        }
        let excludeTurns: Bool?
        switch fields["excludeTurns"] {
        case nil, .null:
            excludeTurns = nil
        case let .bool(value):
            excludeTurns = value
        default:
            throw ThreadParamsDecodingError.invalidParams
        }
        return try CodexThreadForkParams(
            threadID: CodexStoredThreadID(threadID),
            lastTurnID: decodeThreadWireOptional(
                fields,
                key: "lastTurnId",
                as: String.self
            ),
            path: decodeThreadWireOptional(
                fields,
                key: "path",
                as: String.self
            ),
            model: decodeThreadWireOptional(fields, key: "model", as: String.self),
            modelProvider: decodeThreadWireOptional(
                fields,
                key: "modelProvider",
                as: String.self
            ),
            serviceTier: decodeThreadWireOptional(
                fields,
                key: "serviceTier",
                as: String.self
            ),
            cwd: decodeThreadWireOptional(fields, key: "cwd", as: String.self),
            approvalPolicy: decodeThreadWireOptional(
                fields,
                key: "approvalPolicy",
                as: CodexAppServerAskForApproval.self
            ),
            approvalsReviewer: decodeThreadWireOptional(
                fields,
                key: "approvalsReviewer",
                as: CodexAppServerApprovalsReviewer.self
            ),
            sandbox: decodeThreadWireOptional(
                fields,
                key: "sandbox",
                as: CodexAppServerSandboxMode.self
            ),
            config: decodeThreadWireOptional(
                fields,
                key: "config",
                as: [String: CodexJSONValue].self
            ),
            baseInstructions: decodeThreadWireOptional(
                fields,
                key: "baseInstructions",
                as: String.self
            ),
            developerInstructions: decodeThreadWireOptional(
                fields,
                key: "developerInstructions",
                as: String.self
            ),
            ephemeral: ephemeral,
            threadSource: decodeThreadWireOptional(
                fields,
                key: "threadSource",
                as: String.self
            ),
            excludeTurns: excludeTurns
        )
    }

    private static func decodeReviewStartParams(
        _ params: CodexJSONValue?
    ) throws -> CodexReviewStartParams {
        guard case let .object(fields)? = params,
              fields.keys.allSatisfy(
                  Set(["threadId", "target", "delivery"]).contains
              ),
              case let .string(rawThreadID)? = fields["threadId"],
              !rawThreadID.isEmpty,
              case let .object(targetFields)? = fields["target"],
              case let .string(type)? = targetFields["type"]
        else {
            throw ThreadParamsDecodingError.invalidParams
        }

        let delivery: CodexReviewDelivery
        switch fields["delivery"] {
        case nil, .null?:
            delivery = .inline
        case let .string(raw)?:
            guard let value = CodexReviewDelivery(rawValue: raw)
            else {
                throw ThreadParamsDecodingError.invalidParams
            }
            delivery = value
        default:
            throw ThreadParamsDecodingError.invalidParams
        }

        let target: CodexReviewTarget
        switch type {
        case "uncommittedChanges":
            guard targetFields.count == 1 else {
                throw ThreadParamsDecodingError.invalidParams
            }
            target = .uncommittedChanges
        case "baseBranch":
            guard targetFields.count == 2,
                  case let .string(rawBranch)? =
                      targetFields["branch"]
            else {
                throw ThreadParamsDecodingError.invalidParams
            }
            let branch = rawBranch.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !branch.isEmpty else {
                throw ThreadParamsDecodingError.invalidParams
            }
            target = .baseBranch(branch: branch)
        case "commit":
            guard targetFields.keys.allSatisfy(
                      Set(["type", "sha", "title"]).contains
                  ),
                  targetFields.keys.contains("title"),
                  case let .string(rawSHA)? = targetFields["sha"]
            else {
                throw ThreadParamsDecodingError.invalidParams
            }
            let sha = rawSHA.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !sha.isEmpty else {
                throw ThreadParamsDecodingError.invalidParams
            }
            let title: String?
            switch targetFields["title"] {
            case .null?:
                title = nil
            case let .string(rawTitle)?:
                let trimmed = rawTitle.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                title = trimmed.isEmpty ? nil : trimmed
            default:
                throw ThreadParamsDecodingError.invalidParams
            }
            target = .commit(sha: sha, title: title)
        case "custom":
            guard targetFields.count == 2,
                  case let .string(rawInstructions)? =
                      targetFields["instructions"]
            else {
                throw ThreadParamsDecodingError.invalidParams
            }
            let instructions = rawInstructions.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !instructions.isEmpty else {
                throw ThreadParamsDecodingError.invalidParams
            }
            target = .custom(instructions: instructions)
        default:
            throw ThreadParamsDecodingError.invalidParams
        }

        return CodexReviewStartParams(
            threadID: CodexStoredThreadID(rawValue: rawThreadID),
            target: target,
            delivery: delivery
        )
    }

    static func decodeThreadStartParams(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadStartParams {
        guard case let .object(fields)? = params else {
            throw ThreadParamsDecodingError.invalidParams
        }
        let allowed: Set<String> = [
            "model", "modelProvider", "serviceTier", "cwd",
            "approvalPolicy", "approvalsReviewer", "sandbox", "config",
            "serviceName", "baseInstructions", "developerInstructions",
            "personality", "ephemeral", "sessionStartSource", "threadSource",
            // Current desktop renderers attach host/runtime extensions to
            // thread/start. The iPad session boundary consumes the portable
            // subset above; accepting these fields preserves forward wire
            // compatibility instead of rejecting the complete request.
            "dynamicTools", "experimentalRawEvents", "mockExperimentalField",
            "permissions", "runtimeWorkspaceRoots",
            "allowProviderModelFallback", "environments", "historyMode",
            "mode", "multiAgentMode", "selectedCapabilityRoots",
            "threadStartKind",
        ]
        guard fields.keys.allSatisfy(allowed.contains) else {
            throw ThreadParamsDecodingError.invalidParams
        }
        return try CodexThreadStartParams(
            model: decodeThreadWireOptional(fields, key: "model", as: String.self),
            modelProvider: decodeThreadWireOptional(
                fields, key: "modelProvider", as: String.self
            ),
            serviceTier: decodeThreadWireOptional(
                fields, key: "serviceTier", as: String.self
            ),
            cwd: try decodeThreadStartCWD(fields),
            approvalPolicy: decodeThreadWireOptional(
                fields, key: "approvalPolicy",
                as: CodexAppServerAskForApproval.self
            ),
            approvalsReviewer: decodeThreadWireOptional(
                fields, key: "approvalsReviewer",
                as: CodexAppServerApprovalsReviewer.self
            ),
            sandbox: decodeThreadWireOptional(
                fields, key: "sandbox", as: CodexAppServerSandboxMode.self
            ),
            config: decodeThreadWireOptional(
                fields, key: "config", as: [String: CodexJSONValue].self
            ),
            serviceName: decodeThreadWireOptional(
                fields, key: "serviceName", as: String.self
            ),
            baseInstructions: decodeThreadWireOptional(
                fields, key: "baseInstructions", as: String.self
            ),
            developerInstructions: decodeThreadWireOptional(
                fields, key: "developerInstructions", as: String.self
            ),
            personality: decodeThreadWireOptional(
                fields, key: "personality",
                as: CodexAppServerPersonality.self
            ),
            ephemeral: decodeThreadWireOptional(
                fields, key: "ephemeral", as: Bool.self
            ),
            sessionStartSource: decodeThreadWireOptional(
                fields, key: "sessionStartSource", as: String.self
            ),
            threadSource: decodeThreadWireOptional(
                fields, key: "threadSource", as: String.self
            ),
            allowProviderModelFallback: decodeThreadWireOptional(
                fields, key: "allowProviderModelFallback", as: Bool.self
            ),
            dynamicTools: decodeThreadWireOptional(
                fields, key: "dynamicTools", as: [CodexJSONValue].self
            ),
            environments: decodeThreadWireOptional(
                fields, key: "environments", as: [CodexJSONValue].self
            ),
            experimentalRawEvents: decodeThreadWireOptional(
                fields, key: "experimentalRawEvents", as: Bool.self
            ),
            historyMode: decodeThreadWireOptional(
                fields, key: "historyMode", as: CodexThreadHistoryMode.self
            ),
            mockExperimentalField: decodeThreadWireOptional(
                fields, key: "mockExperimentalField", as: String.self
            ),
            mode: decodeThreadNonEmptyStringWireOptional(fields, key: "mode"),
            multiAgentMode: decodeThreadWireOptional(
                fields, key: "multiAgentMode", as: CodexMultiAgentMode.self
            ),
            permissions: decodeThreadWireOptional(
                fields, key: "permissions", as: String.self
            ),
            runtimeWorkspaceRoots: decodeThreadWireOptional(
                fields, key: "runtimeWorkspaceRoots", as: [String].self
            ),
            selectedCapabilityRoots: decodeThreadWireOptional(
                fields, key: "selectedCapabilityRoots", as: [CodexJSONValue].self
            ),
            threadStartKind: decodeThreadNonEmptyStringWireOptional(
                fields, key: "threadStartKind"
            )
        )
    }

    private static func decodeThreadNonEmptyStringWireOptional(
        _ fields: [String: CodexJSONValue],
        key: String
    ) throws -> CodexWireOptional<String> {
        let value = try decodeThreadWireOptional(
            fields,
            key: key,
            as: String.self
        )
        if case let .value(string) = value,
           string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw ThreadParamsDecodingError.invalidParams
        }
        return value
    }

    private static func decodeThreadStartCWD(
        _ fields: [String: CodexJSONValue]
    ) throws -> CodexWireOptional<String> {
        let cwd = try decodeThreadWireOptional(
            fields,
            key: "cwd",
            as: String.self
        )
        guard case let .value(path) = cwd else {
            return cwd
        }
        // The released renderer represents the account home workspace as
        // "~". The native app-server contract requires an absolute cwd.
        return .value((path as NSString).expandingTildeInPath)
    }

    private static func decodeThreadWireOptional<Value>(
        _ fields: [String: CodexJSONValue],
        key: String,
        as type: Value.Type
    ) throws -> CodexWireOptional<Value>
    where Value: Decodable & Equatable & Sendable {
        guard let value = fields[key] else {
            return .omitted
        }
        if case .null = value {
            return .null
        }

        do {
            let data = try JSONEncoder().encode(value)
            return .value(
                try JSONDecoder().decode(type, from: data)
            )
        } catch {
            throw ThreadParamsDecodingError.invalidParams
        }
    }

    static func encodedThreadResult<Value: Encodable>(
        _ value: Value
    ) throws -> CodexJSONValue {
        try JSONDecoder().decode(
            CodexJSONValue.self,
            from: JSONEncoder().encode(value)
        )
    }

    private static func remoteControlResult(
        _ state: CodexDesktopMCPRemoteControlState
    ) -> CodexJSONValue {
        .object([
            "status": .string(state.status.rawValue),
            "serverName": .string(state.serverName),
            "installationId": .string(state.installationID),
            "environmentId": state.environmentID.map(
                CodexJSONValue.string
            ) ?? .null,
        ])
    }

    private static func configResult(
        _ state: CodexDesktopMCPConfigState,
        includeLayers: Bool
    ) -> CodexJSONValue {
        var result: [String: CodexJSONValue] = [
            "config": .object(state.config),
            "origins": .object(state.origins),
        ]
        if includeLayers {
            result["layers"] = .array(state.layers)
        }
        return .object(result)
    }

    @MainActor
    private static func configValueWriteResponse(
        to request: CodexDesktopMCPRequest,
        using store: (any CodexDesktopConfigMutating)?
    ) -> CodexDesktopHostMessage {
        guard let store,
              case let .object(params)? = request.request.params,
              case let .string(keyPath)? = params["keyPath"],
              !keyPath.isEmpty,
              case let .string(strategy)? = params["mergeStrategy"],
              strategy == "replace" || strategy == "upsert",
              let value = params["value"]
        else { return invalidParams(request) }
        store.writeConfigValue(
            keyPath: keyPath, value: value, mergeStrategy: strategy
        )
        return result(request, value: .object([:]))
    }

    @MainActor
    private static func configBatchWriteResponse(
        to request: CodexDesktopMCPRequest,
        using store: (any CodexDesktopConfigMutating)?
    ) -> CodexDesktopHostMessage {
        guard let store,
              case let .object(params)? = request.request.params,
              case let .array(edits)? = params["edits"]
        else { return invalidParams(request) }
        var decoded: [(String, CodexJSONValue, String)] = []
        for edit in edits {
            guard case let .object(fields) = edit,
                  case let .string(keyPath)? = fields["keyPath"],
                  !keyPath.isEmpty,
                  case let .string(strategy)? = fields["mergeStrategy"],
                  strategy == "replace" || strategy == "upsert",
                  let value = fields["value"]
            else { return invalidParams(request) }
            decoded.append((keyPath, value, strategy))
        }
        store.batchWriteConfig(
            edits: decoded.map {
                (keyPath: $0.0, value: $0.1, mergeStrategy: $0.2)
            }
        )
        return result(request, value: .object([:]))
    }

    private static func authStatusResult(
        _ state: CodexDesktopMCPAccountState
    ) -> CodexJSONValue {
        .object([
            "authMethod": state.authMethod.map {
                .string($0.rawValue)
            } ?? .null,
            "authToken": .null,
            "requiresOpenaiAuth": .bool(
                state.requiresOpenAIAuth
            ),
        ])
    }

    private static func accountResult(
        _ state: CodexDesktopMCPAccountState
    ) -> CodexJSONValue {
        .object([
            "account": state.account.map(accountValue) ?? .null,
            "requiresOpenaiAuth": .bool(
                state.requiresOpenAIAuth
            ),
        ])
    }

    private static func accountValue(
        _ account: CodexDesktopMCPAccount
    ) -> CodexJSONValue {
        switch account {
        case .apiKey:
            return .object([
                "type": .string("apiKey")
            ])

        case let .chatGPT(email, planType):
            return .object([
                "type": .string("chatgpt"),
                "email": email.map(CodexJSONValue.string) ?? .null,
                "planType": .string(planType.rawValue),
            ])

        case let .amazonBedrock(usesCodexManagedCredentials):
            return .object([
                "type": .string("amazonBedrock"),
                "usesCodexManagedCredentials": .bool(
                    usesCodexManagedCredentials
                ),
            ])
        }
    }

    private static func modelProviderCapabilitiesResult(
        _ config: [String: CodexJSONValue]
    ) -> CodexJSONValue {
        let providerID: String?
        if case let .string(value)? = config["model_provider"] {
            providerID = value
        } else {
            providerID = nil
        }
        let isAmazonBedrock =
            providerID?.caseInsensitiveCompare("amazon-bedrock")
                == .orderedSame
        return .object([
            "namespaceTools": .bool(true),
            "imageGeneration": .bool(!isAmazonBedrock),
            "webSearch": .bool(!isAmazonBedrock),
        ])
    }

    private static func hasUnitParams(
        _ params: CodexJSONValue?
    ) -> Bool {
        switch params {
        case nil, .null:
            return true
        case let .object(value):
            return value.isEmpty
        default:
            return false
        }
    }

    private static func configIncludeLayers(
        _ params: [String: CodexJSONValue]
    ) -> Bool? {
        guard let value = params["includeLayers"] else {
            return false
        }
        guard case let .bool(includeLayers) = value else {
            return nil
        }
        return includeLayers
    }

    private static func hasValidConfigCWD(
        _ params: [String: CodexJSONValue]
    ) -> Bool {
        guard let value = params["cwd"] else {
            return true
        }
        switch value {
        case .null, .string:
            return true
        default:
            return false
        }
    }

    private static func hasNullableBoolean(
        _ params: [String: CodexJSONValue],
        key: String
    ) -> Bool {
        guard let value = params[key] else {
            return true
        }
        switch value {
        case .null, .bool:
            return true
        default:
            return false
        }
    }

    private static func hasBoolean(
        _ params: [String: CodexJSONValue],
        key: String
    ) -> Bool {
        guard let value = params[key] else {
            return true
        }
        guard case .bool = value else {
            return false
        }
        return true
    }

    private static func confinedFileURL(
        path: String,
        allowedRoots: [String]
    ) -> URL? {
        guard !path.isEmpty,
              !path.contains("\0"),
              (path as NSString).isAbsolutePath
        else {
            return nil
        }

        let lexicalURL = URL(
            fileURLWithPath: path,
            isDirectory: false
        ).standardizedFileURL
        let resolvedURL =
            lexicalURL.resolvingSymlinksInPath()

        for root in allowedRoots {
            guard !root.isEmpty,
                  !root.contains("\0"),
                  (root as NSString).isAbsolutePath
            else {
                continue
            }
            let lexicalRoot = URL(
                fileURLWithPath: root,
                isDirectory: true
            ).standardizedFileURL
            let resolvedRoot =
                lexicalRoot.resolvingSymlinksInPath()
            guard contains(
                lexicalURL,
                in: lexicalRoot
            ), contains(
                resolvedURL,
                in: resolvedRoot
            ) else {
                continue
            }
            return resolvedURL
        }
        return nil
    }

    private static func diagnosticRelativePath(
        path: String,
        root: String
    ) -> String? {
        guard !root.isEmpty,
              !root.contains("\0"),
              (root as NSString).isAbsolutePath
        else {
            return nil
        }
        let candidate = URL(
            fileURLWithPath: path,
            isDirectory: false
        ).standardizedFileURL
        let rootURL = URL(
            fileURLWithPath: root,
            isDirectory: true
        ).standardizedFileURL
        guard contains(candidate, in: rootURL) else {
            return nil
        }

        let candidatePath = candidate.path
        let rootPath = rootURL.path
        guard candidatePath != rootPath else {
            return "."
        }
        let relativeStart = candidatePath.index(
            candidatePath.startIndex,
            offsetBy: rootPath.count
                + (rootPath.hasSuffix("/") ? 0 : 1)
        )
        return redactUUIDs(
            in: String(candidatePath[relativeStart...])
        )
    }

    private static func redactUUIDs(in path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { component in
                UUID(uuidString: String(component)) == nil
                    ? String(component)
                    : "[uuid]"
            }
            .joined(separator: "/")
    }

    private static func contains(
        _ candidate: URL,
        in root: URL
    ) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(
                rootPath.hasSuffix("/")
                    ? rootPath
                    : rootPath + "/"
            )
    }

    private static func releasedFileSystemErrorMessage(
        domain: String,
        code: Int,
        description: String
    ) -> String {
        let isMissingFile =
            (domain == NSCocoaErrorDomain
                && (
                    code == NSFileNoSuchFileError
                        || code == NSFileReadNoSuchFileError
                ))
            || (
                domain == NSPOSIXErrorDomain
                    && code == Int(ENOENT)
            )
        if isMissingFile {
            return "No such file or directory (os error 2)"
        }
        return description
    }
}
