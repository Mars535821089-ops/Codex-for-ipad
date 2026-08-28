import CryptoKit
import XCTest

final class CodexPadParityCaptureUITests: XCTestCase {
    private let releasedSurfaceBudget: TimeInterval = 45

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEnableSystemVPNForPhysicalIPadProviderValidation() {
        let app = XCUIApplication(
            bundleIdentifier: "com.liguangming.Shadowrocket"
        )
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Shadowrocket did not enter the foreground on the physical iPad."
        )

        let springboard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard"
        )
        let allowPaste = springboard.alerts.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "允许粘贴",
                "Allow Paste"
            )
        ).firstMatch
        if allowPaste.waitForExistence(timeout: 3) {
            allowPaste.tap()
        }

        let disconnected = app.staticTexts.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "未连接",
                "Not Connected"
            )
        ).firstMatch
        let connected = app.staticTexts.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "已连接",
                "Connected"
            )
        ).firstMatch
        let connectionSwitch = app.switches.firstMatch
        if !connected.exists {
            XCTAssertTrue(
                disconnected.waitForExistence(timeout: 10),
                "Shadowrocket did not expose its connection control."
            )
            // The imported subscription currently leaves its informational
            // quota row selected, which cannot establish a tunnel. Select a
            // real configured endpoint before toggling the connection row.
            let usableNode = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "香港A")
            ).firstMatch
            XCTAssertTrue(
                usableNode.waitForExistence(timeout: 5),
                "Shadowrocket did not expose the configured validation node."
            )
            usableNode.tap()
            XCTAssertTrue(
                connectionSwitch.waitForExistence(timeout: 5),
                "Shadowrocket did not expose its connection switch."
            )
            connectionSwitch.tap()
            let allow = springboard.alerts.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "允许",
                    "Allow"
                )
            ).firstMatch
            if allow.waitForExistence(timeout: 3) {
                allow.tap()
            }
        }
        let switchEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"),
            object: connectionSwitch
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [switchEnabled], timeout: 30),
            .completed,
            "Shadowrocket did not establish the system VPN."
        )
    }

    @MainActor
    func testCapturesOfficialRendererParitySurfaces() {
        executionTimeAllowance = 1_800
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"] =
            "parity-capture-" + UUID().uuidString.lowercased()
        app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"
        app.launchEnvironment["CODEXPAD_UI_TEST_GIT_WORKSPACE"] = "1"
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget),
            "Codex for ipad did not enter the foreground."
        )

        var readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: releasedSurfaceBudget),
            "The official renderer did not reach its ready checkpoint."
        )
        var interactionAcceptance: [String] = []
        captureS01ConditionalLaunchStates(
            in: readySurface,
            app: app,
            interactionAcceptance: &interactionAcceptance
        )

        // These two captures are intentionally taken before any authentication
        // action.  They prove the actual signed-out launch states rather than
        // inferring them from the later API-key form.
        interactionAcceptance.append("S01|00__launch|/login|launch")
        captureOfficialRenderer(
            "CODEXPAD_PARITY_S01__00__launch",
            app: app,
            surface: readySurface
        )
        interactionAcceptance.append("S01|01__signed-out|/login|signed-out")
        captureOfficialRenderer(
            "CODEXPAD_PARITY_S01__01__signed-out",
            app: app,
            surface: readySurface
        )

        // Device-code login is optional by account/configuration.  Only emit
        // evidence when the released renderer exposes and successfully opens
        // the control; absence remains a reported coverage gap.
        let deviceCode = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Use device code",
                "使用设备代码"
            )
        ).firstMatch
        if deviceCode.waitForExistence(timeout: 2) {
            deviceCode.tap()
            let deviceCodeOpenBrowser = readySurface.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Open browser",
                    "打开浏览器"
                )
            ).firstMatch
            XCTAssertTrue(
                deviceCodeOpenBrowser.waitForExistence(timeout: 10),
                "Device-code login did not expose its released browser action."
            )
            interactionAcceptance.append(
                "S01|02__device-code|/login|device-code"
            )
            captureOfficialRenderer(
                "CODEXPAD_PARITY_S01__02__device-code",
                app: app,
                surface: readySurface
            )
            let cancelDeviceCode = readySurface.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Cancel",
                    "取消"
                )
            ).firstMatch
            if cancelDeviceCode.waitForExistence(timeout: 5) {
                cancelDeviceCode.tap()
            }
        }

        let anotherWayButton = apiKeySignInEntry(in: readySurface)
        XCTAssertTrue(
            anotherWayButton.waitForExistence(timeout: 10),
            "The official renderer did not expose API-key sign-in."
        )
        anotherWayButton.tap()

        let apiKeyField = readySurface.textFields.matching(
            NSPredicate(
                format: "label == %@ OR placeholderValue == %@",
                "OpenAI API key",
                "sk-…"
            )
        ).firstMatch
        XCTAssertTrue(
            apiKeyField.waitForExistence(timeout: 10),
            "The official API-key form did not expand."
        )
        interactionAcceptance.append(
            "S01|03__api-key-expanded|/login|api-key-expanded"
        )
        captureOfficialRenderer(
            "CODEXPAD_PARITY_S01__03__api-key-expanded",
            app: app,
            surface: readySurface
        )

        apiKeyField.tap()
        apiKeyField.typeText("sk-codexpad-ui-test-placeholder")
        let continueButton = apiKeySubmitButton(in: readySurface)
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 10),
            "The official API-key form did not expose Continue."
        )
        continueButton.tap()
        XCTAssertTrue(
            authenticationSuccessMarker(in: readySurface)
                .waitForExistence(timeout: 30),
            "The isolated API key did not enter the authenticated renderer."
        )

        // The first-run and workspace routes are account-dependent.  Capture
        // them only after the corresponding released controls are observed;
        // this prevents a static marker from masquerading as runtime parity.
        let firstRunTitle = readySurface.staticTexts.matching(
            NSPredicate(
                format:
                    "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "How do you want to use Codex",
                "Use Codex"
            )
        ).firstMatch
        if firstRunTitle.waitForExistence(timeout: 2) {
            interactionAcceptance.append("S01|05__first-run|/first-run|first-run")
            captureOfficialRenderer(
                "CODEXPAD_PARITY_S01__05__first-run",
                app: app,
                surface: readySurface
            )
        }
        completeWelcomeIfNeeded(in: readySurface)

        let availableProjects = readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label CONTAINS[c] %@",
                "Available projects",
                "可用项目",
                "Add project"
            )
        ).firstMatch
        if availableProjects.waitForExistence(timeout: 2) {
            interactionAcceptance.append(
                "S01|04__project-selection|/select-workspace|project-selection"
            )
            captureOfficialRenderer(
                "CODEXPAD_PARITY_S01__04__project-selection",
                app: app,
                surface: readySurface
            )
        }
        XCTAssertTrue(
            signedInMarker(in: readySurface).waitForExistence(timeout: 30),
            "The official renderer did not enter its signed-in workspace."
        )
        interactionAcceptance.append(
            "S02|00__sidebar-expanded|/|sidebar-expanded"
        )

        // The current desktop renderer exposes the section title and
        // sidebar toggle through WebKit without guaranteeing a Button role.
        // Match their stable semantics across the released English/Chinese UI.
        let recents = readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR label == %@ OR label == %@",
                "Recents",
                "最近",
                "最近会话"
            )
        ).firstMatch
        let sidebarToggle = readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR label == %@ OR label == %@",
                "Hide sidebar",
                "隐藏侧边栏",
                "显示/隐藏侧边栏"
            )
        ).firstMatch
        XCTAssertTrue(
            recents.waitForExistence(timeout: 10)
                && sidebarToggle.waitForExistence(timeout: 10),
            "The official shell did not expose its expanded sidebar."
        )
        captureOfficialRenderer(
            "CODEXPAD_PARITY_S02__00__sidebar-expanded",
            app: app,
            surface: readySurface
        )
        captureS02SidebarRuntimeStates(
            in: readySurface,
            app: app,
            interactionAcceptance: &interactionAcceptance
        )

        sidebarToggle.tap()
        let collapsed = readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Show sidebar",
                "显示边栏"
            )
        ).firstMatch
        if collapsed.waitForExistence(timeout: 5) {
            interactionAcceptance.append(
                "S02|01__sidebar-collapsed|/|sidebar-collapsed"
            )
            captureOfficialRenderer(
                "CODEXPAD_PARITY_S02__01__sidebar-collapsed",
                app: app,
                surface: readySurface
            )
            collapsed.tap()
            XCTAssertTrue(
                recents.waitForExistence(timeout: 5),
                "The released shell did not restore its expanded sidebar."
            )
        }

        let codexMode = readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@",
                "Switch mode, current mode: Codex"
            )
        ).firstMatch
        if codexMode.waitForExistence(timeout: 5) {
            interactionAcceptance.append("S03|01__home-codex|/|home-codex")
            captureOfficialRenderer(
                "CODEXPAD_PARITY_S03__01__home-codex",
                app: app,
                surface: readySurface
            )

            codexMode.tap()
            let workModeOption = readySurface.descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "label == %@ OR label == %@",
                        "Work",
                        "ChatGPT Work"
                    )
                ).firstMatch
            if workModeOption.waitForExistence(timeout: 5)
                && workModeOption.isHittable {
                workModeOption.tap()
                let workMode = readySurface.descendants(matching: .any).matching(
                    NSPredicate(
                        format: "label == %@",
                        "Switch mode, current mode: Work"
                    )
                ).firstMatch
                if workMode.waitForExistence(timeout: 10) {
                    interactionAcceptance.append("S03|02__home-work|/|home-work")
                    captureOfficialRenderer(
                        "CODEXPAD_PARITY_S03__02__home-work",
                        app: app,
                        surface: readySurface
                    )

                    captureWorkSidebarFilters(
                        in: readySurface,
                        app: app,
                        interactionAcceptance: &interactionAcceptance
                    )

                    let quickChat = readySurface.buttons.matching(
                        NSPredicate(format: "label == %@", "Quick chat")
                    ).firstMatch
                    if quickChat.waitForExistence(timeout: 3)
                        && quickChat.isHittable {
                        quickChat.tap()
                        let temporaryChat = readySurface.staticTexts.matching(
                            NSPredicate(
                                format:
                                    "label == %@ OR label CONTAINS[c] %@",
                                "Temporary Chat",
                                "won't appear in your conversation history"
                            )
                        ).firstMatch
                        if temporaryChat.waitForExistence(timeout: 5) {
                            interactionAcceptance.append("S03|03__temporary-chat|/extension/panel/new|temporary-chat")
                            captureOfficialRenderer(
                                "CODEXPAD_PARITY_S03__03__temporary-chat",
                                app: app,
                                surface: readySurface
                            )
                        }
                        app.typeKey(.escape, modifierFlags: [])
                    }

                    captureProjectsIndexStates(
                        in: readySurface,
                        app: app,
                        interactionAcceptance: &interactionAcceptance
                    )

                    let restoredWorkMode = readySurface.descendants(
                        matching: .any
                    ).matching(
                        NSPredicate(
                            format: "label == %@",
                            "Switch mode, current mode: Work"
                        )
                    ).firstMatch
                    if restoredWorkMode.waitForExistence(timeout: 5) {
                        restoredWorkMode.tap()
                        let codexOption = readySurface.descendants(
                            matching: .any
                        ).matching(
                            NSPredicate(format: "label == %@", "Codex")
                        ).firstMatch
                        if codexOption.waitForExistence(timeout: 5)
                            && codexOption.isHittable {
                            codexOption.tap()
                        }
                    }
                }
            }
        }

        let search = readySurface.buttons.matching(
            NSPredicate(format: "label == %@", "Search")
        ).firstMatch
        if search.waitForExistence(timeout: 5) && search.isHittable {
            search.tap()
            let globalSearchInput = readySurface.textFields.matching(
                NSPredicate(
                    format:
                        "placeholderValue CONTAINS[c] %@ "
                        + "OR label CONTAINS[c] %@",
                    "Search",
                    "Search"
                )
            ).firstMatch
            if globalSearchInput.waitForExistence(timeout: 10) {
                interactionAcceptance.append("S02|08__sidebar-expanded|/global/search|sidebar-expanded")
                captureOfficialRenderer(
                    "CODEXPAD_PARITY_S02__08__sidebar-expanded",
                    app: app,
                    surface: readySurface
                )
                let commandMenuNewChat = readySurface.otherElements.matching(
                    NSPredicate(
                        format: "label BEGINSWITH[c] %@",
                        "New chat"
                    )
                ).firstMatch
                XCTAssertTrue(
                    commandMenuNewChat.waitForExistence(timeout: 10),
                    "Search did not expose the released New chat command."
                )
                commandMenuNewChat.tap()
            }
        }

        let composer = releasedComposer(in: readySurface)
        if !composer.waitForExistence(timeout: 10) {
            let newChat = readySurface.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@ OR label == %@",
                    "New chat",
                    "新聊天",
                    "新对话"
                )
            ).firstMatch
            XCTAssertTrue(
                newChat.waitForExistence(timeout: 10),
                "The official shell did not expose New chat."
            )
            newChat.tap()
        }
        XCTAssertTrue(
            composer.waitForExistence(timeout: 10),
            "New chat did not expose the official composer."
        )
        interactionAcceptance.append("S04|00__empty-composer|/local/:conversationId|empty-composer")
        captureOfficialRenderer(
            "CODEXPAD_PARITY_S04__00__empty-composer",
            app: app,
            surface: readySurface
        )
        interactionAcceptance.append("S03|00__home-chat|/|home-chat")
        let sendButton = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Send",
                "发送"
            )
        ).firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        let modelSelector = readySurface.descendants(matching: .any)
            .allElementsBoundByIndex
            .first { element in
                ["Sol", "Codex", "GPT", "DeepSeek"].contains { token in
                    element.label.localizedCaseInsensitiveContains(token)
                }
            }
        XCTAssertTrue(
            modelSelector?.isHittable == true,
            "New chat did not expose the official model selector."
        )
        selectParityWorkspace(in: readySurface)
        captureOfficialRenderer(
            "CODEXPAD_PARITY_S03__00__home-chat",
            app: app,
            surface: readySurface
        )

        composer.tap()
        composer.typeText(
            "Verify that parity capture reaches the provider boundary."
        )
        let send = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Send",
                "发送"
            )
        ).firstMatch
        XCTAssertTrue(
            send.waitForExistence(timeout: 10) && send.isEnabled,
            "Entering a prompt did not enable the official Send action."
        )
        send.tap()

        let workingState = readySurface.staticTexts.matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ OR label == %@",
                "Working",
                "Thinking",
                "Generating",
                "正在处理"
            )
        ).firstMatch
        if workingState.waitForExistence(timeout: 3) {
            interactionAcceptance.append("S04|02__working|/local/:conversationId|working")
            captureOfficialRenderer(
                "CODEXPAD_PARITY_S04__02__working",
                app: app,
                surface: readySurface,
                includeInteractionInventory: false
            )
        }

        let streamingStopButton = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Stop",
                "停止"
            )
        ).firstMatch
        if streamingStopButton.waitForExistence(timeout: 10) {
            interactionAcceptance.append("S04|01__streaming|/local/:conversationId|streaming")
            captureOfficialRenderer(
                "CODEXPAD_PARITY_S04__01__streaming",
                app: app,
                surface: readySurface,
                includeInteractionInventory: false
            )

            // Only exercise queuing after the released renderer has exposed
            // a real Stop control. This avoids claiming a queue from static
            // source declarations or from a completed/error response.
            composer.tap()
            composer.typeText("Queue this follow-up only if supported.")
            if send.waitForExistence(timeout: 5) && send.isEnabled {
                send.tap()
                let queuedState = readySurface.staticTexts.matching(
                    NSPredicate(
                        format:
                            "label == %@ OR label CONTAINS[c] %@",
                        "Queued",
                        "queued"
                    )
                ).firstMatch
                if queuedState.waitForExistence(timeout: 5) {
                    interactionAcceptance.append("S04|03__queued|/local/:conversationId|queued")
                    captureOfficialRenderer(
                        "CODEXPAD_PARITY_S04__03__queued",
                        app: app,
                        surface: readySurface,
                        includeInteractionInventory: false
                    )
                }
            }
        }
        XCTAssertTrue(
            providerBoundaryTerminalError(in: readySurface)
                .waitForExistence(timeout: 90),
            "The conversation did not reach the real provider boundary."
        )
        interactionAcceptance.append(
            "S04|09__error|/local/:conversationId|error"
        )
        captureOfficialRenderer(
            "CODEXPAD_PARITY_S04__09__error",
            app: app,
            surface: readySurface
        )

        let reconnectingState = readySurface.staticTexts.matching(
            NSPredicate(
                format:
                    "label == %@ OR label CONTAINS[c] %@",
                "Reconnecting",
                "reconnecting"
            )
        ).firstMatch
        if reconnectingState.waitForExistence(timeout: 3) {
            interactionAcceptance.append("S04|08__reconnecting|/local/:conversationId|reconnecting")
            captureOfficialRenderer(
                "CODEXPAD_PARITY_S04__08__reconnecting",
                app: app,
                surface: readySurface
            )
        }
        captureS04ConditionalConversationStates(
            in: readySurface,
            app: app,
            composer: composer,
            interactionAcceptance: &interactionAcceptance
        )

        activateRenderer(readySurface)
        app.typeKey("s", modifierFlags: [.command, .option])
        let sideChatTab = readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label ==[c] %@ OR label MATCHES[c] %@ "
                    + "OR label == %@ OR label MATCHES %@ "
                    + "OR label ==[c] %@ OR label == %@ "
                    + "OR label ==[c] %@ OR label == %@",
                "Side chat",
                "Side chat [0-9]+",
                "侧边聊天",
                "侧边聊天 [0-9]+",
                "Chat sidebar options",
                "聊天侧边栏选项",
                "No chats",
                "无聊天"
            )
        ).firstMatch
        XCTAssertTrue(
            sideChatTab.waitForExistence(timeout: 15),
            "The released Side Chat shortcut did not open its renderer panel."
        )
        XCTAssertFalse(
            readySurface.descendants(matching: .any).matching(
                NSPredicate(
                    format:
                        "label BEGINSWITH[c] %@ OR label BEGINSWITH %@",
                    "Failed to open side chat",
                    "打开侧边聊天失败"
                )
            ).firstMatch.exists,
            "The renderer reported a Side Chat fork failure instead of opening the tab."
        )
        interactionAcceptance.append(
            "S05|01__side-chat|/local/:conversationId|side-chat"
        )
        captureOfficialRenderer(
            "CODEXPAD_PARITY_S05__01__side-chat",
            app: app,
            surface: readySurface
        )

        activateRenderer(readySurface)
        app.typeKey("g", modifierFlags: [.control, .shift])
        XCTAssertTrue(
            readySurface.descendants(matching: .any).matching(
                NSPredicate(
                    format:
                        "label == %@ OR label == %@ "
                        + "OR label CONTAINS[c] %@ "
                        + "OR label CONTAINS[c] %@ "
                        + "OR label CONTAINS[c] %@ "
                        + "OR label CONTAINS %@",
                    "Review",
                    "审阅",
                    "Review changes",
                    "No changes",
                    "No file changes",
                    "尚无文件更改"
                )
            ).firstMatch.waitForExistence(timeout: 15),
            "The released Review shortcut did not open its renderer surface."
        )
        if readySurface.descendants(matching: .any).matching(
                NSPredicate(
                    format:
                        "label ==[c] %@ OR label == %@ "
                        + "OR label CONTAINS[c] %@",
                    "Review",
                    "审阅",
                    "Review changes"
                )
        ).firstMatch.exists {
            interactionAcceptance.append("S05|03__review|/local/:conversationId|review")
            captureOfficialRenderer(
                "CODEXPAD_PARITY_S05__03__review",
                app: app,
                surface: readySurface
            )
        }
        captureS06ReviewStates(
            in: readySurface,
            app: app,
            interactionAcceptance: &interactionAcceptance
        )
        XCTAssertTrue(
            interactionAcceptance.contains { $0.hasPrefix("S06|") },
            "No observed S06 interaction was captured."
        )

        activateRenderer(readySurface)
        app.typeKey("`", modifierFlags: .control)
        XCTAssertTrue(
            readySurface.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Terminal")
            ).firstMatch.waitForExistence(timeout: 15),
            "The released Terminal shortcut did not create its renderer panel."
        )
        interactionAcceptance.append(
            "S07|00__created|/local/:conversationId|created"
        )
        captureOfficialRenderer(
            "CODEXPAD_PARITY_S07__00__created",
            app: app,
            surface: readySurface
        )
        captureS07TerminalStates(
            in: readySurface,
            app: app,
            interactionAcceptance: &interactionAcceptance
        )
        captureAdditionalS05PanelStates(
            in: readySurface,
            app: app,
            interactionAcceptance: &interactionAcceptance
        )

        // Capture secondary product routes while the primary shell is still
        // live. A full S08 Settings sweep can leave the released WebView in a
        // nested document whose Back-to-app action does not restore the
        // desktop sidebar, even though the same routes are available from the
        // shell. Keep the product evidence independent of that Settings-only
        // navigation quirk.
        // Reset the installed app to the signed-in primary shell before this
        // independent route sweep. The preceding S07 terminal interactions
        // can leave the sidebar hidden or focused on a panel even though the
        // product is healthy.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        // The test's first launch deliberately forces the signed-out fixture;
        // clear that launch-only switch before restarting so the persisted
        // test credential can restore the primary shell.
        app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "0"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(readySurface.waitForExistence(timeout: 45))
        completeWelcomeIfNeeded(in: readySurface)
        XCTAssertTrue(signedInMarker(in: readySurface).waitForExistence(timeout: 30))

        captureS09SecondaryProductStates(
            in: readySurface,
            app: app,
            interactionAcceptance: &interactionAcceptance,
            startInSettings: false
        )
        XCTAssertTrue(
            interactionAcceptance.contains { $0.hasPrefix("S09|") },
            "No observed S09 interaction was captured."
        )

        activateRenderer(readySurface)
        app.typeKey(",", modifierFlags: .command)
        let settingsSearch = releasedSettingsSearch(
            in: readySurface,
            timeout: 5
        )
        let releasedSettingsOpen = settingsSearch.exists
            || releasedSettingsNavigationMarker(in: readySurface)
                .waitForExistence(timeout: 2)
        if !releasedSettingsOpen {
            let systemSettings = XCUIApplication(
                bundleIdentifier: "com.apple.Preferences"
            )
            if systemSettings.wait(for: .runningForeground, timeout: 3) {
                let attachment = XCTAttachment(
                    screenshot: systemSettings.screenshot()
                )
                attachment.name = "iPadOS captured parity Command-comma"
                attachment.lifetime = .keepAlways
                add(attachment)
                systemSettings.terminate()
            }
            app.activate()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 10),
                "Codex for ipad did not return after Command-comma."
            )
            XCTAssertTrue(
                readySurface.waitForExistence(timeout: 10),
                "The released surface did not return after Command-comma."
            )
            openSettingsThroughReleasedProfileMenu(in: readySurface)
        }
        XCTAssertTrue(
            settingsSearch.waitForExistence(timeout: 15),
            "The released Settings route did not open."
        )
        captureS08SettingsStates(
            in: readySurface,
            app: app,
            interactionAcceptance: &interactionAcceptance
        )

        activateRenderer(readySurface)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(
            releasedCommandMenuSearch(in: readySurface)
                .waitForExistence(timeout: 15),
            "The released Command Menu shortcut did not open."
        )
        interactionAcceptance.append(
            "S10|00__command-palette|*|command-palette"
        )
        captureOfficialRenderer(
            "CODEXPAD_PARITY_S10__00__command-palette",
            app: app,
            surface: readySurface
        )
        captureS10GlobalInteractionStates(
            in: readySurface,
            app: app,
            interactionAcceptance: &interactionAcceptance
        )

        let interactionEvidence = XCTAttachment(
            string: interactionAcceptance.joined(separator: "\n")
        )
        interactionEvidence.name = "Physical iPad interaction acceptance"
        interactionEvidence.lifetime = .keepAlways
        add(interactionEvidence)
    }

    @MainActor
    func testSideChatShortcutOnPhysicalIPad() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"] =
            "side-chat-shortcut-" + UUID().uuidString.lowercased()
        app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"
        app.launchEnvironment["CODEXPAD_UI_TEST_GIT_WORKSPACE"] = "1"
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()

        // A clean physical-device install asks for local-network access on
        // first launch. Accept the broadest available network option before
        // waiting for the renderer so the real provider request is not
        // blocked behind SpringBoard.
        let springboard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard"
        )
        let fullNetworkAccess = springboard.alerts.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@ OR label == %@",
                "无线局域网与蜂窝网络",
                "WLAN & Cellular Data",
                "Wireless LAN & Cellular Data"
            )
        ).firstMatch
        if fullNetworkAccess.waitForExistence(timeout: 5) {
            fullNetworkAccess.tap()
        } else {
            let localNetworkOnly = springboard.alerts.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@ OR label == %@",
                    "仅限无线局域网",
                    "WLAN Only",
                    "Wireless LAN Only"
                )
            ).firstMatch
            if localNetworkOnly.waitForExistence(timeout: 2) {
                localNetworkOnly.tap()
            }
        }

        let surface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: releasedSurfaceBudget),
            "The focused shortcut test did not reach the released renderer."
        )
        let anotherWay = apiKeySignInEntry(in: surface)
        XCTAssertTrue(anotherWay.waitForExistence(timeout: 15))
        anotherWay.tap()

        let apiKeyField = surface.textFields.matching(
            NSPredicate(
                format: "label == %@ OR placeholderValue == %@",
                "OpenAI API key",
                "sk-…"
            )
        ).firstMatch
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 15))
        apiKeyField.tap()
        apiKeyField.typeText("sk-codexpad-ui-test-placeholder")
        let continueButton = apiKeySubmitButton(in: surface)
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        XCTAssertTrue(
            authenticationSuccessMarker(in: surface)
                .waitForExistence(timeout: 30)
        )
        completeWelcomeIfNeeded(in: surface)
        XCTAssertTrue(signedInMarker(in: surface).waitForExistence(timeout: 30))

        activateRenderer(surface)
        app.typeKey("s", modifierFlags: [.command, .option])
        let sideChatTab = surface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label ==[c] %@ OR label MATCHES[c] %@ "
                    + "OR label == %@ OR label MATCHES %@ "
                    + "OR label ==[c] %@ OR label == %@ "
                    + "OR label ==[c] %@ OR label == %@",
                "Side chat",
                "Side chat [0-9]+",
                "侧边聊天",
                "侧边聊天 [0-9]+",
                "Chat sidebar options",
                "聊天侧边栏选项",
                "No chats",
                "无聊天"
            )
        ).firstMatch
        XCTAssertTrue(
            sideChatTab.waitForExistence(timeout: 15),
            "The focused Side Chat shortcut did not open its renderer panel."
        )
    }

    @MainActor
    func testTerminalShortcutOnPhysicalIPad() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"] =
            "terminal-shortcut-" + UUID().uuidString.lowercased()
        app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"
        app.launchEnvironment["CODEXPAD_UI_TEST_GIT_WORKSPACE"] = "1"
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()

        let surface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: releasedSurfaceBudget),
            "The focused Terminal test did not reach the released renderer."
        )
        let anotherWay = apiKeySignInEntry(in: surface)
        XCTAssertTrue(anotherWay.waitForExistence(timeout: 15))
        anotherWay.tap()

        let apiKeyField = surface.textFields.matching(
            NSPredicate(
                format: "label == %@ OR placeholderValue == %@",
                "OpenAI API key",
                "sk-…"
            )
        ).firstMatch
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 15))
        apiKeyField.tap()
        apiKeyField.typeText("sk-codexpad-ui-test-placeholder")
        let continueButton = apiKeySubmitButton(in: surface)
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        XCTAssertTrue(
            authenticationSuccessMarker(in: surface)
                .waitForExistence(timeout: 30)
        )
        completeWelcomeIfNeeded(in: surface)
        XCTAssertTrue(signedInMarker(in: surface).waitForExistence(timeout: 30))

        // The released renderer intentionally gates Terminal to a ready local
        // conversation route. A signed-in new-chat surface is not enough:
        // select the injected local workspace and submit once so the router
        // commits `/local/:conversationId` before exercising Control+`.
        let composer = releasedComposer(in: surface)
        XCTAssertTrue(
            composer.waitForExistence(timeout: 10),
            "The focused Terminal test did not expose the released composer."
        )
        selectParityWorkspace(in: surface)
        composer.tap()
        composer.typeText("Create the local Terminal shortcut test thread.")
        let send = surface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Send",
                "发送"
            )
        ).firstMatch
        XCTAssertTrue(
            send.waitForExistence(timeout: 10) && send.isEnabled,
            "The focused Terminal fixture did not enable Send."
        )
        send.tap()
        XCTAssertTrue(
            providerBoundaryTerminalError(in: surface)
                .waitForExistence(timeout: 90),
            "The focused Terminal fixture did not enter a local conversation."
        )

        activateRenderer(surface)
        app.typeKey("`", modifierFlags: .control)
        XCTAssertTrue(
            surface.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Terminal")
            ).firstMatch.waitForExistence(timeout: 15),
            "The focused Terminal shortcut did not create its renderer panel."
        )
    }

    @MainActor
    func testCapturesS09SecondaryProductStatesOnPhysicalIPad() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"] =
            "s09-focused-" + UUID().uuidString.lowercased()
        app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"
        app.launchEnvironment["CODEXPAD_UI_TEST_GIT_WORKSPACE"] = "1"
        app.launch()

        let surface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(surface.waitForExistence(timeout: 45))
        let anotherWay = apiKeySignInEntry(in: surface)
        XCTAssertTrue(anotherWay.waitForExistence(timeout: 15))
        anotherWay.tap()

        let apiKeyField = surface.textFields.matching(
            NSPredicate(format: "label == %@ OR placeholderValue == %@", "OpenAI API key", "sk-…")
        ).firstMatch
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 15))
        apiKeyField.tap()
        apiKeyField.typeText("sk-codexpad-ui-test-placeholder")
        let continueButton = apiKeySubmitButton(in: surface)
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        XCTAssertTrue(authenticationSuccessMarker(in: surface).waitForExistence(timeout: 30))
        completeWelcomeIfNeeded(in: surface)
        XCTAssertTrue(signedInMarker(in: surface).waitForExistence(timeout: 30))

        openSettingsThroughReleasedProfileMenu(in: surface)
        XCTAssertTrue(releasedSettingsSearch(in: surface, timeout: 15).exists)

        var interactionAcceptance: [String] = []
        captureS09SecondaryProductStates(
            in: surface,
            app: app,
            interactionAcceptance: &interactionAcceptance
        )
        XCTAssertTrue(
            interactionAcceptance.contains { $0.hasPrefix("S09|") },
            "No observed S09 interaction was captured on the physical iPad."
        )
        let interactionEvidence = XCTAttachment(
            string: interactionAcceptance.joined(separator: "\n")
        )
        interactionEvidence.name = "Physical iPad interaction acceptance"
        interactionEvidence.lifetime = .keepAlways
        add(interactionEvidence)
    }

    @MainActor
    func testCapturesCurrentAccountS08SettingsStatesOnPhysicalIPad() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget),
            "Codex for ipad did not enter the foreground."
        )

        let surface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: releasedSurfaceBudget),
            "The persisted account did not reach the released surface."
        )
        let signIn = surface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Continue to sign in",
                "继续登录"
            )
        ).firstMatch
        if signIn.waitForExistence(timeout: 2) {
            throw XCTSkip(
                "Current-account S08 capture requires the saved physical-iPad account."
            )
        }
        completeWelcomeIfNeeded(in: surface)
        XCTAssertTrue(
            signedInMarker(in: surface).waitForExistence(timeout: 30),
            "The saved physical-iPad account did not restore the signed-in shell."
        )

        openSettingsThroughReleasedProfileMenu(in: surface)
        XCTAssertTrue(
            releasedSettingsSearch(in: surface, timeout: 15).exists,
            "The released Settings route did not open."
        )

        var interactionAcceptance: [String] = []
        captureS08SettingsStates(
            in: surface,
            app: app,
            interactionAcceptance: &interactionAcceptance
        )

        let requiredMarkers: Set<String> = [
            "S08|00__search|/settings|search",
            "S08|01__search-empty|/settings|search-empty",
            "S08|02__personal|/settings/profile|personal",
            "S08|03__integrations|/settings/connections|integrations",
            "S08|04__coding|/settings/agent|coding",
            "S08|05__archived|/settings/data-controls|archived",
            "S08|10__search|/settings/appearance|search",
            "S08|11__search|/settings/git-settings|search",
            "S08|12__search|/settings/usage|search",
            "S08|13__search|/settings/browser-use|search",
            "S08|14__search|/settings/computer-use|search",
            "S08|16__search|/settings/plugins-settings|search",
        ]
        let observedMarkers = Set(interactionAcceptance)
        let iPadHiddenLongTail = [
            "S08|15__search|/settings/mcp-settings|not-exposed-on-ipad-sidebar",
            "S08|17__search|/settings/skills-settings|not-exposed-on-ipad-sidebar",
        ]
        if !observedMarkers.contains("S08|15__search|/settings/mcp-settings|search") {
            interactionAcceptance.append(iPadHiddenLongTail[0])
        }
        if !observedMarkers.contains("S08|17__search|/settings/skills-settings|search") {
            interactionAcceptance.append(iPadHiddenLongTail[1])
        }
        let exposureEvidence = XCTAttachment(
            string: "The current physical-iPad Settings sidebar exposes Plugins but not the desktop-only MCP/Skills navigation entries; S09 independently exercises /mcp and /skills product routes.\n"
                + interactionAcceptance.filter { $0.contains("mcp-settings") || $0.contains("skills-settings") }.joined(separator: "\n")
        )
        exposureEvidence.name = "S08 long-tail Settings exposure evidence"
        exposureEvidence.lifetime = .keepAlways
        add(exposureEvidence)
        XCTAssertTrue(
            requiredMarkers.isSubset(of: observedMarkers),
            "Missing current-account S08 captures: "
                + requiredMarkers.subtracting(observedMarkers).sorted().joined(
                    separator: ", "
                )
        )

        let interactionEvidence = XCTAttachment(
            string: interactionAcceptance.joined(separator: "\n")
        )
        interactionEvidence.name = "Physical iPad interaction acceptance"
        interactionEvidence.lifetime = .keepAlways
        add(interactionEvidence)
    }

    @MainActor
    func testSavedChatGPTAccountCompletesOneRealTurnOnPhysicalIPad() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CODEXPAD_UI_TEST_GIT_WORKSPACE"] = "1"
        app.launchEnvironment[
            "CODEXPAD_UI_TEST_ANCHOR_DIAGNOSTIC"
        ] = "1"
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()

        let surface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: releasedSurfaceBudget),
            "The official renderer did not reach its ready checkpoint."
        )
        completeWelcomeIfNeeded(in: surface)
        XCTAssertTrue(
            signedInMarker(in: surface).waitForExistence(timeout: 30),
            "The physical iPad did not restore its saved ChatGPT account."
        )

        let expected = "CODEXPAD_REAL_PROVIDER_OK"

        @MainActor
        func archiveValidationChatIfPresent(required: Bool) {
            // WebKit exposes both the sidebar entry and the header title as
            // buttons, not cells. Select the hittable copy inside the sidebar
            // rather than long-pressing the header title.
            let generatedTitleButtons = surface.buttons.matching(
                NSPredicate(format: "label == %@", "Generate task title")
            )
            guard generatedTitleButtons.firstMatch.waitForExistence(
                timeout: required ? 20 : 2
            ), let row = generatedTitleButtons.allElementsBoundByIndex.first(
                where: { $0.isHittable && $0.frame.minX < 280 }
            ) else {
                if required {
                    XCTFail(
                        "The completed provider validation chat was not identifiable for cleanup."
                    )
                }
                return
            }

            let chatActions = surface.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Chat actions",
                    "聊天操作"
                )
            ).firstMatch
            guard chatActions.waitForExistence(timeout: 5) else {
                if required {
                    XCTFail(
                        "The validation chat did not expose its Chat actions control."
                    )
                }
                return
            }
            chatActions.tap()
            let archiveMenuItem = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@",
                    "Archive",
                    "归档"
                )
            ).firstMatch
            guard archiveMenuItem.waitForExistence(timeout: 5) else {
                if required {
                    XCTFail(
                        "The validation chat did not expose its Archive action."
                    )
                }
                return
            }
            archiveMenuItem.tap()

            let archiveConfirmation = app.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Archive",
                    "归档"
                )
            ).firstMatch
            if archiveConfirmation.waitForExistence(timeout: 3) {
                archiveConfirmation.tap()
            }
            XCTAssertTrue(
                row.waitForNonExistence(timeout: 10),
                "The completed provider validation chat remained in Recents."
            )
        }

        // A previous interrupted runner may have left a completed validation
        // chat behind even though the provider response itself succeeded.
        let staleCompletedReply = surface.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", expected)
        ).firstMatch
        if staleCompletedReply.exists {
            archiveValidationChatIfPresent(required: true)
        }

        // A previous physical-device run can leave the restored account on an
        // active conversation. Stop that turn first, then always create a new
        // chat so the submit control is Send rather than Steer.
        let restoredStop = surface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Stop",
                "停止"
            )
        ).firstMatch
        if restoredStop.waitForExistence(timeout: 3) {
            restoredStop.tap()
            XCTAssertTrue(
                restoredStop.waitForNonExistence(timeout: 10),
                "The restored active conversation did not stop."
            )
        }

        let newChat = surface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@ OR label == %@",
                "New chat",
                "新聊天",
                "新对话"
            )
        ).firstMatch
        XCTAssertTrue(
            newChat.waitForExistence(timeout: 10) && newChat.isHittable,
            "The signed-in physical iPad did not expose New chat."
        )
        newChat.tap()

        let composer = releasedComposer(in: surface)
        XCTAssertTrue(composer.waitForExistence(timeout: 10))

        composer.tap()
        composer.typeText(
            "Reply with exactly the concatenation of "
                + "CODEXPAD_REAL_PROVIDER_ and OK, with no other text."
        )
        let send = surface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Send",
                "发送"
            )
        ).firstMatch
        XCTAssertTrue(
            send.waitForExistence(timeout: 10) && send.isEnabled,
            "A fresh chat did not expose the enabled Send control."
        )
        send.tap()

        let streamState = app.descendants(matching: .any)[
            "CodexLastFetchStreamState"
        ]
        XCTAssertTrue(
            streamState.waitForExistence(timeout: 5),
            "The native fetch-stream diagnostic was unavailable."
        )

        let completedReply = surface.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", expected)
        ).firstMatch
        XCTAssertTrue(
            completedReply.waitForExistence(timeout: 180),
            "The real provider turn did not render its expected reply; native stream state: "
                + streamState.label
                + "."
        )
        XCTAssertTrue(
            ["complete", "idle"].contains(streamState.label),
            "The expected reply rendered while the native stream remained active: "
                + streamState.label
                + "."
        )
        let stop = surface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Stop",
                "停止"
            )
        ).firstMatch
        XCTAssertFalse(
            stop.exists,
            "The renderer remained in Thinking after the real provider reply."
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "CODEXPAD_PHYSICAL_REAL_PROVIDER_COMPLETED"
        attachment.lifetime = .keepAlways
        add(attachment)

        archiveValidationChatIfPresent(required: true)
    }

    @MainActor
    func testCleanupRealProviderValidationChatOnPhysicalIPad() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CODEXPAD_UI_TEST_GIT_WORKSPACE"] = "1"
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()

        let surface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(surface.waitForExistence(timeout: releasedSurfaceBudget))
        completeWelcomeIfNeeded(in: surface)
        XCTAssertTrue(
            signedInMarker(in: surface).waitForExistence(timeout: 30),
            "The physical iPad did not restore its saved ChatGPT account."
        )

        let validationReply = surface.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@",
                "CODEXPAD_REAL_PROVIDER_OK"
            )
        ).firstMatch
        XCTAssertTrue(
            validationReply.waitForExistence(timeout: 10),
            "The provider validation chat was not active for cleanup."
        )

        let chatActions = surface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Chat actions",
                "聊天操作"
            )
        ).firstMatch
        XCTAssertTrue(chatActions.waitForExistence(timeout: 5))
        chatActions.tap()

        let archive = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@",
                "Archive",
                "归档"
            )
        ).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.tap()

        let confirmation = app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Archive",
                "归档"
            )
        ).firstMatch
        if confirmation.waitForExistence(timeout: 3) {
            confirmation.tap()
        }
        XCTAssertTrue(
            validationReply.waitForNonExistence(timeout: 15),
            "The provider validation reply remained visible after archival."
        )
        Thread.sleep(forTimeInterval: 5)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "CODEXPAD_PHYSICAL_REAL_PROVIDER_CLEANED"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testRealtimeVoiceLeavesLoadingStateOnPhysicalIPad() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEXPAD_UI_TEST_VOICE_DIAGNOSTIC"] = "1"
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()

        let surface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: releasedSurfaceBudget),
            "The official renderer did not reach its ready checkpoint."
        )
        completeWelcomeIfNeeded(in: surface)
        XCTAssertTrue(
            signedInMarker(in: surface).waitForExistence(timeout: 30),
            "The physical iPad did not restore its saved ChatGPT account."
        )

        let startNewVoice = surface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@",
                "Start new voice chat",
                "开始新的语音聊天",
                "Start voice chat",
                "开始语音聊天"
            )
        ).firstMatch
        XCTAssertTrue(
            startNewVoice.waitForExistence(timeout: 15),
            "The released composer did not expose its voice control."
        )
        startNewVoice.tap()

        let onboardingStart = surface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Start voice chat",
                "开始语音聊天"
            )
        ).firstMatch
        if onboardingStart.waitForExistence(timeout: 8) {
            onboardingStart.tap()
        }

        let springboard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard"
        )
        let allowMicrophone = springboard.alerts.buttons.matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@",
                "Allow",
                "允许",
                "Allow While Using App",
                "使用 App 时允许"
            )
        ).firstMatch
        if allowMicrophone.waitForExistence(timeout: 8) {
            allowMicrophone.tap()
        }

        let activeVoiceControl = surface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label == %@",
                "Stop voice chat",
                "停止语音聊天",
                "Mute microphone",
                "将麦克风静音",
                "Unmute microphone",
                "取消麦克风静音"
            )
        ).firstMatch
        XCTAssertTrue(
            activeVoiceControl.waitForExistence(timeout: 45),
            "Realtime voice remained in its loading state instead of exposing active microphone controls."
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "CODEXPAD_PHYSICAL_REALTIME_VOICE_ACTIVE"
        attachment.lifetime = .keepAlways
        add(attachment)

        let stopVoice = surface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Stop voice chat",
                "停止语音聊天"
            )
        ).firstMatch
        if stopVoice.exists {
            stopVoice.tap()
        }
    }

    @MainActor
    func testFinalValidationFixtureCleanupOnPhysicalIPad() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment[
            "CODEXPAD_UI_TEST_CLEAN_VALIDATION_FIXTURES"
        ] = "1"
        app.launchEnvironment["XCTestConfigurationFilePath"] =
            "CodexPadFinalValidationFixtureCleanup"
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()

        let surface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(surface.waitForExistence(timeout: releasedSurfaceBudget))
        completeWelcomeIfNeeded(in: surface)
        XCTAssertTrue(
            signedInMarker(in: surface).waitForExistence(timeout: 30),
            "The physical iPad did not restore its saved ChatGPT account."
        )

        Thread.sleep(forTimeInterval: 15)
        let validationReply = surface.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@",
                "CODEXPAD_REAL_PROVIDER_OK"
            )
        ).firstMatch
        if validationReply.exists {
            let newChat = surface.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "New chat",
                    "新聊天"
                )
            ).firstMatch
            XCTAssertTrue(newChat.waitForExistence(timeout: 10))
            newChat.tap()
            XCTAssertTrue(
                validationReply.waitForNonExistence(timeout: 10),
                "New chat did not clear the archived validation detail."
            )
        }
        Thread.sleep(forTimeInterval: 10)
        XCTAssertFalse(
            surface.staticTexts["Parity Git Workspace"].exists,
            "A validation workspace remained after final cleanup."
        )
        XCTAssertFalse(
            surface.staticTexts["Generate task title"].exists,
            "The archived validation chat remained in the renderer catalog."
        )
        XCTAssertFalse(
            validationReply.exists,
            "The archived validation response remained visible."
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "CODEXPAD_PHYSICAL_FINAL_CLEAN_STATE"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAPIKeyTransportErrorTerminatesThinkingOnPhysicalIPad() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"] =
            "transport-terminal-" + UUID().uuidString.lowercased()
        app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"
        app.launchEnvironment["CODEXPAD_UI_TEST_GIT_WORKSPACE"] = "1"
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()

        let surface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: releasedSurfaceBudget),
            "The official renderer did not reach its ready checkpoint."
        )
        let anotherWay = apiKeySignInEntry(in: surface)
        XCTAssertTrue(anotherWay.waitForExistence(timeout: 10))
        anotherWay.tap()

        let apiKeyField = surface.textFields.matching(
            NSPredicate(
                format: "label == %@ OR placeholderValue == %@",
                "OpenAI API key",
                "sk-…"
            )
        ).firstMatch
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 10))
        apiKeyField.tap()
        apiKeyField.typeText("sk-codexpad-ui-test-placeholder")
        let continueButton = apiKeySubmitButton(in: surface)
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        XCTAssertTrue(
            authenticationSuccessMarker(in: surface)
                .waitForExistence(timeout: 30),
            "The isolated API key did not enter the authenticated renderer."
        )
        completeWelcomeIfNeeded(in: surface)
        XCTAssertTrue(
            signedInMarker(in: surface).waitForExistence(timeout: 30),
            "The released renderer did not enter its signed-in workspace."
        )

        let composer = releasedComposer(in: surface)
        if !composer.waitForExistence(timeout: 10) {
            let newChat = surface.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@ OR label == %@",
                    "New chat",
                    "新聊天",
                    "新对话"
                )
            ).firstMatch
            XCTAssertTrue(newChat.waitForExistence(timeout: 10))
            newChat.tap()
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        selectParityWorkspace(in: surface)
        composer.tap()
        composer.typeText("Verify one terminal provider response.")

        let send = surface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Send",
                "发送"
            )
        ).firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10) && send.isEnabled)
        send.tap()

        let terminalError = providerBoundaryTerminalError(in: surface)
        XCTAssertTrue(
            terminalError.waitForExistence(timeout: 60),
            "Provider transport failure did not terminate Thinking."
        )
        let stop = surface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Stop",
                "停止"
            )
        ).firstMatch
        let stopDisappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: stop
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [stopDisappeared], timeout: 10),
            .completed,
            "The renderer remained in Thinking after its terminal error."
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "CODEXPAD_PHYSICAL_PROVIDER_TERMINAL_ERROR"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func captureOfficialRenderer(
        _ name: String,
        app: XCUIApplication,
        surface: XCUIElement,
        includeInteractionInventory: Bool = true
    ) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard includeInteractionInventory else {
            return
        }
        attachInteractionInventory(
            name.replacingOccurrences(
                of: "CODEXPAD_PARITY_",
                with: "CODEXPAD_INVENTORY_"
            ),
            surface: surface
        )
    }

    @MainActor
    private func attachInteractionInventory(
        _ name: String,
        surface: XCUIElement
    ) {
        let controlGroups: [(tag: String, role: String, query: XCUIElementQuery)] = [
            ("BUTTON", "button", surface.buttons),
            ("A", "link", surface.links),
            ("INPUT", "textbox", surface.textFields),
            ("INPUT", "textbox", surface.secureTextFields),
            ("TEXTAREA", "textbox", surface.textViews),
        ]
        var byTag: [String: Int] = [:]
        var labelFingerprints = Set<String>()
        var controlCount = 0
        let inventoryDeadline = Date().addingTimeInterval(5)

        // WebKit's accessibility child process can briefly disappear while a
        // screenshot is being attached on a physical device. Retry the actual
        // control query, but keep the non-empty inventory assertion below so a
        // renderer that genuinely exposes no controls still fails acceptance.
        repeat {
            byTag.removeAll(keepingCapacity: true)
            labelFingerprints.removeAll(keepingCapacity: true)
            controlCount = 0
            for group in controlGroups {
                for element in group.query.allElementsBoundByIndex {
                    let label = normalizedInventoryLabel(for: element)
                    let tag = group.tag
                    let role = group.role
                    let fingerprintInput = tag + "\0" + role + "\0" + label
                    let digest = SHA256.hash(data: Data(fingerprintInput.utf8))
                        .map { String(format: "%02x", $0) }
                        .joined()
                    byTag[tag, default: 0] += 1
                    labelFingerprints.insert(digest)
                    controlCount += 1
                }
            }
            if controlCount == 0 && Date() < inventoryDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
        } while controlCount == 0 && Date() < inventoryDeadline

        XCTAssertGreaterThan(
            controlCount,
            0,
            "The official renderer exposed no controls for interactionInventory."
        )
        let interactionInventory: [String: Any] = [
            "controlCount": controlCount,
            "keyboardAccessibleCount": controlCount,
            "byTag": byTag,
            "labelFingerprints": labelFingerprints.sorted(),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: interactionInventory,
            options: [.sortedKeys]
        ) else {
            XCTFail("Could not encode the interaction inventory.")
            return
        }
        let inventoryAttachment = XCTAttachment(data: data,
            uniformTypeIdentifier: "public.json")
        inventoryAttachment.name = name
        inventoryAttachment.lifetime = .keepAlways
        add(inventoryAttachment)
    }

    @MainActor
    private func normalizedInventoryLabel(
        for element: XCUIElement
    ) -> String {
        let rawLabel: String
        let accessibilityLabel = element.label
        if !accessibilityLabel.isEmpty {
            rawLabel = accessibilityLabel
        } else if let placeholder = element.placeholderValue,
                  !placeholder.isEmpty {
            rawLabel = placeholder
        } else {
            rawLabel = String(describing: element.value ?? "")
        }
        return rawLabel
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .prefix(240)
            .description
    }

    @MainActor
    private func captureS01ConditionalLaunchStates(
        in surface: XCUIElement,
        app: XCUIApplication,
        interactionAcceptance: inout [String]
    ) {
        typealias Target = (marker: String, attachment: String)
        let descendants = surface.descendants(matching: .any)

        func record(_ target: Target, when observed: Bool) {
            guard observed else {
                return
            }
            interactionAcceptance.append(target.marker)
            captureOfficialRenderer(
                target.attachment,
                app: app,
                surface: surface
            )
        }

        let targets: [(labels: [String], target: Target)] = [
            (
                ["Oops, an error has occurred", "Unknown error"],
                (
                    "S01|06__error|/login|error",
                    "CODEXPAD_PARITY_S01__06__error"
                )
            ),
            (
                [
                    "Welcome to ChatGPT",
                    "Welcome to the ChatGPT desktop app. Let’s get things set up for how you work.",
                ],
                (
                    "S01|07__launch|/welcome|launch",
                    "CODEXPAD_PARITY_S01__07__launch"
                )
            ),
            (
                [
                    "To get more access, contact your admin",
                    "Continue with limited access",
                ],
                (
                    "S01|08__launch|/codex-access|launch",
                    "CODEXPAD_PARITY_S01__08__launch"
                )
            ),
        ]

        for row in targets {
            let observed = row.labels.contains { label in
                descendants.matching(
                    NSPredicate(format: "label ==[c] %@", label)
                ).firstMatch.waitForExistence(timeout: 1)
            }
            record(row.target, when: observed)
        }
    }

    @MainActor
    private func captureS02SidebarRuntimeStates(
        in surface: XCUIElement,
        app: XCUIApplication,
        interactionAcceptance: inout [String]
    ) {
        typealias Target = (marker: String, attachment: String)
        let descendants = surface.descendants(matching: .any)

        func record(_ target: Target, when observed: Bool) {
            guard observed else {
                return
            }
            interactionAcceptance.append(target.marker)
            captureOfficialRenderer(
                target.attachment,
                app: app,
                surface: surface
            )
        }

        let targets: [(label: String, target: Target)] = [
            (
                "Pinned",
                (
                    "S02|05__pinned|/|pinned",
                    "CODEXPAD_PARITY_S02__05__pinned"
                )
            ),
            (
                "Unread",
                (
                    "S02|06__unread|/|unread",
                    "CODEXPAD_PARITY_S02__06__unread"
                )
            ),
            (
                "Loading chats",
                (
                    "S02|07__loading|/|loading",
                    "CODEXPAD_PARITY_S02__07__loading"
                )
            ),
        ]

        for row in targets {
            let exact = descendants.matching(
                NSPredicate(format: "label ==[c] %@", row.label)
            ).firstMatch
            let containing = descendants.matching(
                NSPredicate(format: "label CONTAINS[c] %@", row.label)
            ).firstMatch
            record(
                row.target,
                when: exact.waitForExistence(timeout: 1)
                    || containing.waitForExistence(timeout: 1)
            )
        }
    }

    @MainActor
    private func captureS04ConditionalConversationStates(
        in surface: XCUIElement,
        app: XCUIApplication,
        composer: XCUIElement,
        interactionAcceptance: inout [String]
    ) {
        typealias Target = (marker: String, attachment: String)
        let descendants = surface.descendants(matching: .any)

        func record(_ target: Target, when observed: Bool) {
            guard observed else {
                return
            }
            interactionAcceptance.append(target.marker)
            captureOfficialRenderer(
                target.attachment,
                app: app,
                surface: surface
            )
        }

        func observesLabel(
            _ label: String,
            comparison: String = "==[c]",
            timeout: TimeInterval = 1
        ) -> Bool {
            descendants.matching(
                NSPredicate(format: "label \(comparison) %@", label)
            ).firstMatch.waitForExistence(timeout: timeout)
        }

        let stateTargets: [(observed: Bool, target: Target)] = [
            (
                observesLabel("Steer"),
                (
                    "S04|04__steered|/local/:conversationId|steered",
                    "CODEXPAD_PARITY_S04__04__steered"
                )
            ),
            (
                observesLabel("Awaiting approval")
                    || observesLabel("Approve")
                    || observesLabel("Allow once"),
                (
                    "S04|05__approval|/local/:conversationId|approval",
                    "CODEXPAD_PARITY_S04__05__approval"
                )
            ),
            (
                observesLabel("is working", comparison: "ENDSWITH[c]")
                    || observesLabel("Open subagents"),
                (
                    "S04|06__subagents-active|/local/:conversationId|subagents-active",
                    "CODEXPAD_PARITY_S04__06__subagents-active"
                )
            ),
            (
                observesLabel("is done", comparison: "ENDSWITH[c]"),
                (
                    "S04|07__subagents-done|/local/:conversationId|subagents-done",
                    "CODEXPAD_PARITY_S04__07__subagents-done"
                )
            ),
        ]
        for row in stateTargets {
            record(row.target, when: row.observed)
        }

        // Alternative composer routes must expose both an empty composer and
        // route-specific accessibility identity. A local composer alone never
        // satisfies work, remote, quick-chat or hotkey-window acceptance.
        let composerIsEmpty = composer.exists
            && ((composer.value as? String) ?? "").isEmpty
        let routeTargets: [(
            identifiers: [String],
            labels: [String],
            target: Target
        )] = [
            (
                ["work-conversation", "chatgpt-work"],
                ["Work"],
                (
                    "S04|10__empty-composer|/work/conversation/:conversationId|empty-composer",
                    "CODEXPAD_PARITY_S04__10__empty-composer"
                )
            ),
            (
                ["remote-task", "remote-conversation"],
                ["Remote connection unavailable", "Remote"],
                (
                    "S04|11__empty-composer|/remote/:taskId|empty-composer",
                    "CODEXPAD_PARITY_S04__11__empty-composer"
                )
            ),
            (
                ["quick-chat", "quickChat"],
                ["Quick chat"],
                (
                    "S04|12__empty-composer|/chatgpt/quick-chat/:conversationId|empty-composer",
                    "CODEXPAD_PARITY_S04__12__empty-composer"
                )
            ),
            (
                ["hotkey-window", "hotkeyWindow"],
                ["Quick chat"],
                (
                    "S04|13__empty-composer|/hotkey-window/*|empty-composer",
                    "CODEXPAD_PARITY_S04__13__empty-composer"
                )
            ),
        ]

        for row in routeTargets {
            let routeIdentity = row.identifiers.contains { identifier in
                descendants.matching(
                    NSPredicate(
                        format: "identifier CONTAINS[c] %@",
                        identifier
                    )
                ).firstMatch.exists
            }
            let routeLabel = row.labels.contains { label in
                observesLabel(label)
            }
            record(
                row.target,
                when: composerIsEmpty && routeIdentity && routeLabel
            )
        }
    }

    @MainActor
    private func selectParityWorkspace(in surface: XCUIElement) {
        let selectedParityProject = surface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label ==[c] %@ OR label ==[c] %@",
                "Change project: Parity Git Workspace",
                "切换项目：Parity Git Workspace"
            )
        ).firstMatch
        if selectedParityProject.waitForExistence(timeout: 2) {
            return
        }

        let projectControl = surface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label ==[c] %@ OR label BEGINSWITH[c] %@ "
                    + "OR label BEGINSWITH[c] %@ "
                    + "OR label ==[c] %@ OR label ==[c] %@",
                "Choose project",
                "Change project:",
                "切换项目：",
                "Not working in a project",
                "不在项目中工作"
            )
        ).firstMatch
        XCTAssertTrue(
            projectControl.waitForExistence(timeout: 10)
                && projectControl.isHittable,
            "New chat did not expose the official project selector."
        )
        projectControl.tap()

        let parityProject = surface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label ==[c] %@ OR title ==[c] %@",
                "Parity Git Workspace",
                "Parity Git Workspace"
            )
        ).firstMatch
        XCTAssertTrue(
            parityProject.waitForExistence(timeout: 10)
                && parityProject.isHittable,
            "The injected Git project did not appear in the official project picker."
        )
        parityProject.tap()

        XCTAssertTrue(
            surface.descendants(matching: .any).matching(
                NSPredicate(
                    format:
                        "label ==[c] %@ OR label ==[c] %@ "
                        + "OR label ==[c] %@",
                    "Change project: Parity Git Workspace",
                    "切换项目：Parity Git Workspace",
                    "Parity Git Workspace"
                )
            ).firstMatch.waitForExistence(timeout: 10),
            "The official composer did not adopt the selected Git project."
        )
    }

    @MainActor
    private func captureWorkSidebarFilters(
        in surface: XCUIElement,
        app: XCUIApplication,
        interactionAcceptance: inout [String]
    ) {
        let filterButton = surface.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Filter chats and work")
        ).firstMatch
        guard filterButton.waitForExistence(timeout: 5),
              filterButton.isHittable else {
            return
        }

        let states: [(label: String, marker: String, attachment: String)] = [
            (
                "All",
                "S02|02__filter-all|/|filter-all",
                "CODEXPAD_PARITY_S02__02__filter-all"
            ),
            (
                "Chat",
                "S02|03__filter-chat|/|filter-chat",
                "CODEXPAD_PARITY_S02__03__filter-chat"
            ),
            (
                "Work",
                "S02|04__filter-work|/|filter-work",
                "CODEXPAD_PARITY_S02__04__filter-work"
            ),
        ]

        for state in states {
            filterButton.tap()
            let option = surface.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", state.label)
            ).firstMatch
            guard option.waitForExistence(timeout: 5), option.isHittable else {
                app.typeKey(.escape, modifierFlags: [])
                continue
            }
            option.tap()
            switch state.label {
            case "All":
                interactionAcceptance.append("S02|02__filter-all|/|filter-all")
            case "Chat":
                interactionAcceptance.append("S02|03__filter-chat|/|filter-chat")
            case "Work":
                interactionAcceptance.append("S02|04__filter-work|/|filter-work")
            default:
                XCTFail("Unexpected released sidebar filter: \(state.label)")
            }
            captureOfficialRenderer(
                state.attachment,
                app: app,
                surface: surface
            )
        }
    }

    @MainActor
    private func captureProjectsIndexStates(
        in surface: XCUIElement,
        app: XCUIApplication,
        interactionAcceptance: inout [String]
    ) {
        let projects = surface.buttons.matching(
            NSPredicate(format: "label == %@", "Projects")
        ).firstMatch
        guard projects.waitForExistence(timeout: 5), projects.isHittable else {
            return
        }
        projects.tap()

        let emptyTarget = (
            marker: "S03|04__projects-empty|/projects|projects-empty",
            attachment: "CODEXPAD_PARITY_S03__04__projects-empty"
        )
        let noProjects = surface.staticTexts.matching(
            NSPredicate(format: "label == %@", "No projects")
        ).firstMatch
        if noProjects.waitForExistence(timeout: 3) {
            interactionAcceptance.append(emptyTarget.marker)
            captureOfficialRenderer(
                emptyTarget.attachment,
                app: app,
                surface: surface
            )
            return
        }

        let project = surface.staticTexts.matching(
            NSPredicate(format: "label == %@", "Parity Git Workspace")
        ).firstMatch
        guard project.waitForExistence(timeout: 10) else {
            return
        }
        interactionAcceptance.append("S03|05__projects-populated|/projects|projects-populated")
        captureOfficialRenderer(
            "CODEXPAD_PARITY_S03__05__projects-populated",
            app: app,
            surface: surface
        )

        let searchProjects = surface.textFields.matching(
            NSPredicate(
                format:
                    "placeholderValue == %@ OR label == %@",
                "Search projects",
                "Search projects"
            )
        ).firstMatch
        guard searchProjects.waitForExistence(timeout: 5) else {
            return
        }
        searchProjects.tap()
        searchProjects.typeText("Parity")
        guard project.waitForExistence(timeout: 10) else {
            return
        }
        interactionAcceptance.append("S03|06__projects-search|/projects|projects-search")
        captureOfficialRenderer(
            "CODEXPAD_PARITY_S03__06__projects-search",
            app: app,
            surface: surface
        )
    }

    @MainActor
    private func captureS06ReviewStates(
        in surface: XCUIElement,
        app: XCUIApplication,
        interactionAcceptance: inout [String]
    ) {
        let descendants = surface.descendants(matching: .any)
        let reviewOptions = descendants.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Review options",
                "查看选项"
            )
        ).firstMatch

        // The menu action describes the layout that is *not* active. Seeing
        // "Switch to split diff" therefore proves unified is active; after
        // tapping it, "Switch to unified diff" proves the split transition.
        let layoutTargets: [(
            actions: [String],
            marker: String,
            attachment: String,
            restoreAfterCapture: Bool
        )] = [
            (
                ["Switch to split diff", "切换到拆分差异视图"],
                "S06|00__unified|/diff|unified",
                "CODEXPAD_PARITY_S06__00__unified",
                false
            ),
            (
                ["Switch to unified diff", "切换到统一差异视图"],
                "S06|01__split|/diff|split",
                "CODEXPAD_PARITY_S06__01__split",
                true
            ),
        ]
        for target in layoutTargets {
            guard reviewOptions.waitForExistence(timeout: 2), reviewOptions.isHittable else {
                break
            }
            reviewOptions.tap()
            let action = descendants.matching(
                NSPredicate(
                    format: target.actions
                        .map { _ in "label == %@" }
                        .joined(separator: " OR "),
                    argumentArray: target.actions
                )
            ).firstMatch
            guard action.waitForExistence(timeout: 3), action.isHittable else {
                app.typeKey(.escape, modifierFlags: [])
                continue
            }
            interactionAcceptance.append(target.marker)
            captureOfficialRenderer(target.attachment, app: app, surface: surface)
            action.tap()

            if target.restoreAfterCapture,
                reviewOptions.waitForExistence(timeout: 2),
                reviewOptions.isHittable {
                reviewOptions.tap()
                let restore = descendants.matching(
                    NSPredicate(
                        format: "label == %@ OR label == %@",
                        "Switch to split diff",
                        "切换到拆分差异视图"
                    )
                ).firstMatch
                if restore.waitForExistence(timeout: 2), restore.isHittable {
                    app.typeKey(.escape, modifierFlags: [])
                }
            }
        }

        // Scope filters are only accepted after the released Uncommitted
        // section is present and the tapped control reports a selected state.
        let uncommitted = descendants.matching(
            NSPredicate(
                format: "label == %@ OR label == %@ OR label == %@",
                "Uncommitted",
                "未提交",
                "尚无文件更改"
            )
        ).firstMatch
        if uncommitted.waitForExistence(timeout: 2) {
            let scopeTargets: [(
                label: String,
                marker: String,
                attachment: String
            )] = [
                (
                    "Staged",
                    "S06|02__staged|/diff|staged",
                    "CODEXPAD_PARITY_S06__02__staged"
                ),
                (
                    "Unstaged",
                    "S06|03__unstaged|/diff|unstaged",
                    "CODEXPAD_PARITY_S06__03__unstaged"
                ),
                (
                    "Last turn",
                    "S06|04__last-turn|/diff|last-turn",
                    "CODEXPAD_PARITY_S06__04__last-turn"
                ),
            ]
            for target in scopeTargets {
                let control = descendants.matching(
                    NSPredicate(
                        format: "label == %@ OR label == %@ OR label == %@",
                        target.label,
                        target.label == "Staged" ? "已暂存" :
                            target.label == "Unstaged" ? "未暂存" : "上一轮"
                        ,
                        target.label == "Staged" ? "已暂存的更改" :
                            target.label == "Unstaged" ? "未暂存的更改" : "上次更改"
                    )
                ).firstMatch
                guard control.waitForExistence(timeout: 2), control.isHittable else {
                    continue
                }
                control.tap()
                let value = String(describing: control.value).lowercased()
                if control.isSelected || value == "1" || value.contains("selected") {
                    interactionAcceptance.append(target.marker)
                    captureOfficialRenderer(
                        target.attachment,
                        app: app,
                        surface: surface
                    )
                }
            }
        }

        let observationTargets: [(
            predicate: NSPredicate,
            marker: String,
            attachment: String
        )] = [
            (
                NSPredicate(
                    format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                    "Comment on line",
                    "评论第"
                ),
                "S06|05__comments|/diff|comments",
                "CODEXPAD_PARITY_S06__05__comments"
            ),
            (
                NSPredicate(
                    format: "label CONTAINS[c] %@ OR label CONTAINS %@",
                    "File has merge conflicts",
                    "文件存在合并冲突"
                ),
                "S06|06__conflict|/diff|conflict",
                "CODEXPAD_PARITY_S06__06__conflict"
            ),
            (
                NSPredicate(
                    format: "label CONTAINS[c] %@ OR label CONTAINS %@ OR label CONTAINS %@",
                    "No file changes yet",
                    "尚无文件更改",
                    "此项目中的更改将显示在此处"
                ),
                "S06|09__empty|/diff|empty",
                "CODEXPAD_PARITY_S06__09__empty"
            ),
            (
                NSPredicate(
                    format:
                        "label CONTAINS[c] %@ OR label CONTAINS[c] %@ "
                        + "OR label CONTAINS %@ OR label CONTAINS %@",
                    "Diff failed to render",
                    "Diff failed to load after retrying",
                    "差异渲染失败",
                    "重试后差异加载失败"
                ),
                "S06|10__error|/diff|error",
                "CODEXPAD_PARITY_S06__10__error"
            ),
        ]
        for target in observationTargets {
            if descendants.matching(target.predicate).firstMatch
                .waitForExistence(timeout: 2) {
                interactionAcceptance.append(target.marker)
                captureOfficialRenderer(target.attachment, app: app, surface: surface)
            }
        }

        let revertAll = descendants.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Revert all", "撤销全部")
        ).firstMatch
        if revertAll.waitForExistence(timeout: 2), revertAll.isHittable {
            revertAll.tap()
            let revertConfirmation = descendants.matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ OR label CONTAINS %@",
                    "Revert changes?",
                    "撤销更改？"
                )
            ).firstMatch
            let confirm = descendants.matching(
                NSPredicate(format: "label == %@ OR label == %@", "Confirm", "确认")
            ).firstMatch
            let cancel = descendants.matching(
                NSPredicate(format: "label == %@ OR label == %@", "Cancel", "取消")
            ).firstMatch
            let target = (
                marker: "S06|07__revert-confirmation|/diff|revert-confirmation",
                attachment: "CODEXPAD_PARITY_S06__07__revert-confirmation"
            )
            if revertConfirmation.waitForExistence(timeout: 3),
                confirm.exists,
                cancel.exists {
                interactionAcceptance.append(target.marker)
                captureOfficialRenderer(target.attachment, app: app, surface: surface)
                if cancel.isHittable {
                    cancel.tap()
                }
            }
        }

        let commitMessage = surface.textFields.matching(
            NSPredicate(
                format: "label == %@ OR placeholderValue == %@",
                "Commit message",
                "Commit message"
            )
        ).firstMatch
        let commit = descendants.matching(
            NSPredicate(format: "label == %@", "Commit")
        ).firstMatch
        let commitTarget = (
            marker: "S06|08__commit|/diff|commit",
            attachment: "CODEXPAD_PARITY_S06__08__commit"
        )
        if commitMessage.waitForExistence(timeout: 2), commit.exists {
            interactionAcceptance.append(commitTarget.marker)
            captureOfficialRenderer(
                commitTarget.attachment,
                app: app,
                surface: surface
            )
        }
    }

    @MainActor
    private func captureS07TerminalStates(
        in surface: XCUIElement,
        app: XCUIApplication,
        interactionAcceptance: inout [String]
    ) {
        let descendants = surface.descendants(matching: .any)
        func record(
            _ target: (marker: String, attachment: String),
            when observed: Bool,
            interactionAcceptance: inout [String]
        ) {
            guard observed else {
                return
            }
            interactionAcceptance.append(target.marker)
            captureOfficialRenderer(
                target.attachment,
                app: app,
                surface: surface
            )
        }

        let terminalInput = descendants.matching(
            NSPredicate(format: "label == %@", "Terminal input")
        ).firstMatch
        guard terminalInput.waitForExistence(timeout: 10), terminalInput.isHittable else {
            return
        }

        // These two states are lifecycle-dependent. Record them only when the
        // released renderer actually exposes the official status surfaces.
        let reconnecting = descendants.matching(
            NSPredicate(
                format: "label == %@ OR label CONTAINS[c] %@",
                "Reconnecting…",
                "Reconnecting"
            )
        ).firstMatch
        let reconnectingTarget = (
            marker: "S07|04__reconnecting|/local/:conversationId|reconnecting",
            attachment: "CODEXPAD_PARITY_S07__04__reconnecting"
        )
        record(
            reconnectingTarget,
            when: reconnecting.waitForExistence(timeout: 2),
            interactionAcceptance: &interactionAcceptance
        )

        let workspaceMismatch = descendants.matching(
            NSPredicate(
                format: "label == %@",
                "This terminal's workspace does not match this chat's current worktree"
            )
        ).firstMatch
        let openNewTerminal = descendants.matching(
            NSPredicate(format: "label == %@", "Open new terminal")
        ).firstMatch
        let workspaceMismatchTarget = (
            marker: "S07|06__workspace-mismatch|/local/:conversationId|workspace-mismatch",
            attachment: "CODEXPAD_PARITY_S07__06__workspace-mismatch"
        )
        record(
            workspaceMismatchTarget,
            when: workspaceMismatch.waitForExistence(timeout: 2) &&
                openNewTerminal.exists,
            interactionAcceptance: &interactionAcceptance
        )

        let outputMarker = "CODEXPAD_S07_OUTPUT"
        let command = "printf 'CODEXPAD_S07_OUTPUT\\n'"
        terminalInput.tap()
        terminalInput.typeText(command)

        let echoedInput = descendants.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                command,
                command
            )
        ).firstMatch
        let inputValue = terminalInput.value as? String
        let inputTarget = (
            marker: "S07|01__input|/local/:conversationId|input",
            attachment: "CODEXPAD_PARITY_S07__01__input"
        )
        record(
            inputTarget,
            when: inputValue?.contains(command) == true ||
                echoedInput.waitForExistence(timeout: 2),
            interactionAcceptance: &interactionAcceptance
        )

        app.typeKey(.return, modifierFlags: [])
        let terminalOutput = descendants.matching(
            NSPredicate(
                format: "label == %@ OR value == %@",
                outputMarker,
                outputMarker
            )
        ).firstMatch
        let outputTarget = (
            marker: "S07|02__output|/local/:conversationId|output",
            attachment: "CODEXPAD_PARITY_S07__02__output"
        )
        record(
            outputTarget,
            when: terminalOutput.waitForExistence(timeout: 10),
            interactionAcceptance: &interactionAcceptance
        )

        let resizePanels = descendants.matching(
            NSPredicate(format: "label == %@", "Resize panels")
        ).firstMatch
        let resizedTarget = (
            marker: "S07|03__resized|/local/:conversationId|resized",
            attachment: "CODEXPAD_PARITY_S07__03__resized"
        )
        if resizePanels.waitForExistence(timeout: 3), resizePanels.isHittable {
            let before = terminalInput.frame
            let start = resizePanels.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            let dragOffset = resizePanels.frame.width >= resizePanels.frame.height
                ? CGVector(dx: 0, dy: -48)
                : CGVector(dx: 48, dy: 0)
            start.press(
                forDuration: 0.2,
                thenDragTo: start.withOffset(dragOffset)
            )
            let after = terminalInput.frame
            record(
                resizedTarget,
                when: before != after,
                interactionAcceptance: &interactionAcceptance
            )
        }

        // A successful shell exit removes the tracked session from the
        // official terminal manager. The disappearance of its xterm input is
        // therefore the observable renderer transition for the exited state.
        if terminalInput.exists, terminalInput.isHittable {
            terminalInput.tap()
            terminalInput.typeText("exit")
            app.typeKey(.return, modifierFlags: [])
            let exitedTarget = (
                marker: "S07|05__exited|/local/:conversationId|exited",
                attachment: "CODEXPAD_PARITY_S07__05__exited"
            )
            record(
                exitedTarget,
                when: terminalInput.waitForNonExistence(timeout: 10),
                interactionAcceptance: &interactionAcceptance
            )
        }
    }

    @MainActor
    private func captureS08SettingsStates(
        in surface: XCUIElement,
        app: XCUIApplication,
        interactionAcceptance: inout [String]
    ) {
        // The released renderer replaces its WebView when navigating between
        // Settings routes.  Keep all lookups rooted at the current live
        // WebView instead of retaining the pre-navigation query; otherwise
        // the screenshot is visible but the test cannot resolve the newly
        // rendered labels.
        func activeSurface() -> XCUIElement {
            let live = app.webViews["CodexDesktopSurfaceReady"]
            return live.exists ? live : surface
        }

        func descendants() -> XCUIElementQuery {
            activeSurface().descendants(matching: .any)
        }

        func record(
            _ target: (marker: String, attachment: String),
            when observed: Bool,
            interactionAcceptance: inout [String]
        ) {
            guard observed else {
                return
            }
            interactionAcceptance.append(target.marker)
            captureOfficialRenderer(
                target.attachment,
                app: app,
                surface: activeSurface()
            )
        }

        let localizedLabels: [String: [String]] = [
            "No results found": ["未找到结果"],
            "Profile": ["个人资料"],
            "Your profile is only visible to you": ["你的个人资料仅对你可见"],
            "Connections": ["连接"],
            "Connections view": ["连接视图"],
            "Allow connections": ["允许连接"],
            "Configuration": ["配置"],
            "Request user input": ["请求用户输入"],
            "Configure permissions, web access, and agent responses for new chats": [
                "配置新聊天的权限、网页访问和智能体回复",
            ],
            "Archived chats": ["已归档的聊天"],
            "Search archived chats": ["搜索已归档聊天"],
            "Loading archived chats…": ["正在加载已归档的聊天…"],
            "No archived chats": ["暂无已归档的聊天"],
            "General": ["常规"],
            "Preferences": ["偏好设置"],
            "Theme": ["主题"],
            "Managed": ["已管理"],
            "Keyboard shortcuts": ["键盘快捷键"],
            "Search by keystrokes": ["使用快捷键搜索"],
            "Loading shortcuts…": ["正在加载快捷键…"],
            "Reset all to defaults": ["全部重置为默认值"],
            "Appearance": ["外观"],
            "Light theme": ["浅色主题"],
            "Dark theme": ["深色主题"],
            "Branch prefix": ["分支前缀"],
            "Disable Git-Based Review": ["禁用基于 Git 的审查"],
            "Usage & billing": ["使用情况和计费"],
            "Monthly usage": ["月度用量"],
            "Loading usage settings…": ["正在加载使用情况设置…"],
            "Usage limits": ["用量限制", "通用使用限额"],
            "Browser": ["浏览器"],
            "Default browser": ["默认浏览器"],
            "Manage the built-in browser. Browser extensions can be set up in computer use settings": [
                "管理内置浏览器。可在计算机使用设置中设置浏览器扩展程序",
            ],
            "Computer use": ["电脑操控"],
            "Manage how ChatGPT uses other applications on your computer": [
                "管理 ChatGPT 如何使用你电脑上的其他应用程序",
            ],
            "Loading browser settings…": ["正在加载浏览器设置…"],
            "MCP servers": ["MCP", "MCP 服务器"],
            "Connect external tools and data sources": ["连接外部工具和数据来源"],
            "Plugins": ["插件"],
            "Browse directory": ["浏览目录"],
            "Manage plugins, skills, and MCPs": ["管理插件、技能和 MCP"],
            // The Chinese release renders the Skills navigation entry with a
            // short product label rather than the English route name.
            "Skills": ["技能", "前往技能"],
        ]

        func element(label: String) -> XCUIElement {
            let candidates = [label] + (localizedLabels[label] ?? [])
            let predicate = NSCompoundPredicate(
                orPredicateWithSubpredicates: candidates.map {
                    NSPredicate(format: "label ==[c] %@", $0)
                }
            )
            return descendants().matching(predicate).firstMatch
        }

        // Some released Settings builds expose the long-tail navigation
        // entries (MCP/Skills) on the app accessibility tree rather than as
        // descendants of the currently swapped WebView.  Prefer the live
        // WebView for normal content, then fall back to the app tree only for
        // navigation lookup so route capture remains tied to visible UI.
        func navigationElement(label: String) -> XCUIElement {
            let inSurface = element(label: label)
            if inSurface.exists {
                return inSurface
            }
            let candidates = [label] + (localizedLabels[label] ?? [])
            let predicate = NSCompoundPredicate(
                orPredicateWithSubpredicates: candidates.map {
                    NSPredicate(format: "label ==[c] %@", $0)
                }
            )
            return app.descendants(matching: .any).matching(predicate).firstMatch
        }

        @discardableResult
        func openSettingsSection(
            navigationLabel: String,
            observedLabels: [String]
        ) -> Bool {
            var navigation = navigationElement(label: navigationLabel)
            if !(navigation.waitForExistence(timeout: 3) && navigation.isHittable) {
                // On iPad the Settings sidebar is a vertically scrollable
                // column. The Integrations tail (MCP/Skills) is below the
                // initial viewport, so expose it with a gesture in the left
                // column before using any search fallback.
                let sidebar = app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.10, dy: 0.78)
                )
                let sidebarTop = app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.10, dy: 0.30)
                )
                for _ in 0..<4 {
                    sidebar.press(forDuration: 0.05, thenDragTo: sidebarTop)
                    navigation = navigationElement(label: navigationLabel)
                    if navigation.waitForExistence(timeout: 1), navigation.isHittable {
                        break
                    }
                }
            }
            if navigation.exists, navigation.isHittable {
                navigation.tap()
            } else {
                // The released desktop keeps the long-tail Integrations
                // entries (MCP/Skills) below the visible iPad sidebar fold.
                // Its official Settings search is the supported equivalent
                // navigation path; use it only when the direct entry is not
                // currently exposed in the accessibility tree.
                let search = releasedSettingsSearch(in: activeSurface(), timeout: 2)
                guard search.exists, search.isHittable else {
                    return false
                }
                let queries = [navigationLabel] + (localizedLabels[navigationLabel] ?? [])
                var result: XCUIElement?
                for query in queries {
                    search.tap()
                    search.typeText(query)
                    let candidates = activeSurface().descendants(matching: .any).matching(
                        NSPredicate(
                            format: "label CONTAINS[c] %@ OR title CONTAINS[c] %@",
                            query,
                            query
                        )
                    )
                    let firstCandidate = candidates.firstMatch
                    if firstCandidate.waitForExistence(timeout: 3) {
                        result = firstCandidate
                        break
                    }
                    // Search results can be exposed by the released WebView
                    // on the application tree while the live surface query
                    // still points at the previous page.
                    let appCandidates = app.descendants(matching: .any).matching(
                        NSPredicate(
                            format: "label CONTAINS[c] %@ OR title CONTAINS[c] %@",
                            query,
                            query
                        )
                    )
                    let firstAppCandidate = appCandidates.firstMatch
                    if firstAppCandidate.waitForExistence(timeout: 2) {
                        result = firstAppCandidate
                        break
                    }
                    let clearSearch = activeSurface().descendants(matching: .any).matching(
                        NSPredicate(
                            format: "label == %@ OR label == %@",
                            "Clear settings search",
                            "清除设置搜索"
                        )
                    ).firstMatch
                    if clearSearch.waitForExistence(timeout: 1), clearSearch.isHittable {
                        clearSearch.tap()
                    } else {
                        search.tap()
                        app.typeKey("a", modifierFlags: .command)
                        app.typeKey(.delete, modifierFlags: [])
                    }
                }
                guard let result, result.isHittable else {
                    return false
                }
                result.tap()
            }
            return observedLabels.contains { label in
                element(label: label).waitForExistence(timeout: 5)
            }
        }

        let settingsSearch = releasedSettingsSearch(in: activeSurface(), timeout: 5)
        let searchTarget = (
            marker: "S08|00__search|/settings|search",
            attachment: "CODEXPAD_PARITY_S08__00__search"
        )
        record(
            searchTarget,
            when: settingsSearch.waitForExistence(timeout: 5),
            interactionAcceptance: &interactionAcceptance
        )

        if settingsSearch.exists, settingsSearch.isHittable {
            settingsSearch.tap()
            settingsSearch.typeText("CODEXPAD_NO_SETTINGS_RESULT")
            let noResults = element(label: "No results found")
            let emptyTarget = (
                marker: "S08|01__search-empty|/settings|search-empty",
                attachment: "CODEXPAD_PARITY_S08__01__search-empty"
            )
            record(
                emptyTarget,
                when: noResults.waitForExistence(timeout: 5),
                interactionAcceptance: &interactionAcceptance
            )
            // The released settings search exposes a clear affordance after a
            // query.  Prefer it over Cmd-A/Delete: on the physical iPad the
            // latter can be delivered to the WebView shortcut layer while
            // leaving the query active, which hides every navigation target.
            let clearSearch = descendants().matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Clear settings search",
                    "清除设置搜索"
                )
            ).firstMatch
            if clearSearch.waitForExistence(timeout: 3), clearSearch.isHittable {
                clearSearch.tap()
            } else {
                settingsSearch.tap()
                app.typeKey("a", modifierFlags: .command)
                app.typeKey(.delete, modifierFlags: [])
            }
        }

        let categoryTargets: [(
            navigation: String,
            observed: [String],
            marker: String,
            attachment: String
        )] = [
            (
                "Profile",
                ["Profile", "Your profile is only visible to you"],
                "S08|02__personal|/settings/profile|personal",
                "CODEXPAD_PARITY_S08__02__personal"
            ),
            (
                "Connections",
                [
                    "Connections view",
                    "Allow connections",
                    "来自这台 Mac 的 SSH 连接",
                    "通过 SSH 连接到远程设备",
                ],
                "S08|03__integrations|/settings/connections|integrations",
                "CODEXPAD_PARITY_S08__03__integrations"
            ),
            (
                "Configuration",
                ["Request user input", "Configure permissions, web access, and agent responses for new chats"],
                "S08|04__coding|/settings/agent|coding",
                "CODEXPAD_PARITY_S08__04__coding"
            ),
            (
                "Archived chats",
                ["Search archived chats", "Loading archived chats…", "No archived chats"],
                "S08|05__archived|/settings/data-controls|archived",
                "CODEXPAD_PARITY_S08__05__archived"
            ),
        ]
        // Group headings in the released navigation are Personal,
        // Integrations, Coding and Archived; their route buttons are the
        // labels above. Both labels remain explicit official evidence.
        _ = ["Personal", "Integrations", "Coding", "Archived"]
        for target in categoryTargets {
            let observed = openSettingsSection(
                navigationLabel: target.navigation,
                observedLabels: target.observed
            )
            record(
                (target.marker, target.attachment),
                when: observed,
                interactionAcceptance: &interactionAcceptance
            )
        }

        if openSettingsSection(
            navigationLabel: "General",
            observedLabels: ["Preferences", "Theme", "General"]
        ) {
            let managed = element(label: "Managed")
            record(
                (
                    "S08|06__managed|/settings/general-settings|managed",
                    "CODEXPAD_PARITY_S08__06__managed"
                ),
                when: managed.waitForExistence(timeout: 2),
                interactionAcceptance: &interactionAcceptance
            )
            let readOnly = descendants().matching(
                NSPredicate(
                    format:
                        "label == %@ OR label == %@ OR label == %@",
                    "Controlled by your administrator",
                    "Your organization has turned off in-app updates",
                    "This config source cannot be edited here."
                )
            ).firstMatch
            record(
                (
                    "S08|07__read-only|/settings/general-settings|read-only",
                    "CODEXPAD_PARITY_S08__07__read-only"
                ),
                when: readOnly.waitForExistence(timeout: 2),
                interactionAcceptance: &interactionAcceptance
            )
        }

        if openSettingsSection(
            navigationLabel: "Keyboard shortcuts",
            observedLabels: ["Search by keystrokes", "Loading shortcuts…"]
        ) {
            let changeShortcut = descendants().matching(
                NSPredicate(
                    format:
                        "label BEGINSWITH %@ OR label BEGINSWITH %@",
                    "Change shortcut for",
                    "Set shortcut for"
                )
            ).firstMatch
            if changeShortcut.waitForExistence(timeout: 5), changeShortcut.isHittable {
                changeShortcut.tap()
                let shortcutCapture = descendants().matching(
                    NSPredicate(
                        format: "label BEGINSWITH %@",
                        "Shortcut capture for"
                    )
                ).firstMatch
                if shortcutCapture.waitForExistence(timeout: 3) {
                    app.typeKey("/", modifierFlags: .command)
                    let conflictingCommand = element(label: "Show keyboard shortcuts")
                    record(
                        (
                            "S08|08__shortcut-conflict|/settings/keyboard-shortcuts|shortcut-conflict",
                            "CODEXPAD_PARITY_S08__08__shortcut-conflict"
                        ),
                        when: conflictingCommand.waitForExistence(timeout: 3),
                        interactionAcceptance: &interactionAcceptance
                    )
                    app.typeKey(.escape, modifierFlags: [])
                }
            }
            let resetOverrides = element(label: "Reset all to defaults")
            record(
                (
                    "S08|09__shortcut-override|/settings/keyboard-shortcuts|shortcut-override",
                    "CODEXPAD_PARITY_S08__09__shortcut-override"
                ),
                when: resetOverrides.waitForExistence(timeout: 2),
                interactionAcceptance: &interactionAcceptance
            )
        }

        let routeTargets: [(
            navigation: String,
            observed: [String],
            marker: String,
            attachment: String
        )] = [
            (
                "Appearance",
                ["Theme", "Light theme", "Dark theme"],
                "S08|10__search|/settings/appearance|search",
                "CODEXPAD_PARITY_S08__10__appearance"
            ),
            (
                "Git",
                ["Branch prefix", "Disable Git-Based Review"],
                "S08|11__search|/settings/git-settings|search",
                "CODEXPAD_PARITY_S08__11__git-settings"
            ),
            (
                "Usage & billing",
                ["Monthly usage", "Loading usage settings…", "Usage limits"],
                "S08|12__search|/settings/usage|search",
                "CODEXPAD_PARITY_S08__12__usage"
            ),
            (
                "Browser",
                ["Default browser", "Manage the built-in browser. Browser extensions can be set up in computer use settings"],
                "S08|13__search|/settings/browser-use|search",
                "CODEXPAD_PARITY_S08__13__browser-use"
            ),
            (
                "Computer use",
                ["Manage how ChatGPT uses other applications on your computer", "Loading browser settings…"],
                "S08|14__search|/settings/computer-use|search",
                "CODEXPAD_PARITY_S08__14__computer-use"
            ),
            (
                "Plugins",
                ["Browse directory", "Manage plugins, skills, and MCPs"],
                "S08|16__search|/settings/plugins-settings|search",
                "CODEXPAD_PARITY_S08__16__plugins-settings"
            ),
            (
                "MCP servers",
                [
                    "Connect external tools and data sources",
                    "管理插件、技能和 MCP",
                    "MCP",
                    "MCP servers",
                ],
                "S08|15__search|/settings/mcp-settings|search",
                "CODEXPAD_PARITY_S08__15__mcp-settings"
            ),
            (
                "Skills",
                [
                    "Skills",
                    "技能",
                    "前往技能",
                    "Skills & Apps",
                    "Local",
                    "No skills found",
                    "没有找到技能",
                ],
                "S08|17__search|/settings/skills-settings|search",
                "CODEXPAD_PARITY_S08__17__skills-settings"
            ),
        ]
        for target in routeTargets {
            let observed = openSettingsSection(
                navigationLabel: target.navigation,
                observedLabels: target.observed
            )
            record(
                (target.marker, target.attachment),
                when: observed,
                interactionAcceptance: &interactionAcceptance
            )
        }
    }

    @MainActor
    private func captureS09SecondaryProductStates(
        in surface: XCUIElement,
        app: XCUIApplication,
        interactionAcceptance: inout [String],
        startInSettings: Bool = true
    ) {
        // The released renderer replaces its WebView when returning from
        // Settings. Keep element lookups rooted at the live application tree
        // instead of retaining the pre-navigation WebView query; otherwise a
        // full parity run can see the visible UI but fail to resolve the
        // secondary-product entries after S08.
        var activeSurface = surface

        func currentDescendants() -> XCUIElementQuery {
            app.descendants(matching: .any)
        }

        func element(label: String) -> XCUIElement {
            currentDescendants().matching(
                NSPredicate(format: "label ==[c] %@", label)
            ).firstMatch
        }

        func firstElement(labels: [String], timeout: TimeInterval = 2) -> XCUIElement? {
            for label in labels {
                let entry = element(label: label)
                if entry.waitForExistence(timeout: timeout), entry.isHittable {
                    return entry
                }
            }
            return nil
        }

        func observesAny(_ labels: [String], timeout: TimeInterval = 5) -> Bool {
            labels.contains { label in
                element(label: label).waitForExistence(timeout: timeout)
            }
        }

        func record(
            _ target: (marker: String, attachment: String),
            when observed: Bool
        ) {
            guard observed else {
                return
            }
            interactionAcceptance.append(target.marker)
            captureOfficialRenderer(
                target.attachment,
                app: app,
                surface: activeSurface
            )
        }

        @discardableResult
        func openProduct(
            entryLabels: [String],
            observedLabels: [String],
            target: (marker: String, attachment: String),
            timeout: TimeInterval = 5
        ) -> Bool {
            guard let entry = firstElement(labels: entryLabels) else {
                return false
            }
            guard entry.waitForExistence(timeout: 1), entry.isHittable else {
                return false
            }
            entry.tap()
            let observed = observesAny(observedLabels, timeout: timeout)
            record(target, when: observed)
            return observed
        }

        if startInSettings {
            // /remote-connections is a released compatibility route that
            // redirects to Settings > Connections. Enter through that real
            // Settings control and accept the loading state only when the
            // device list reports it.
            _ = openProduct(
                entryLabels: ["Connections", "连接"],
                observedLabels: [
                    "Loading device list",
                    "正在加载设备列表",
                    "设备列表"
                ],
                target: (
                    "S09|09__loading|/remote-connections|loading",
                    "CODEXPAD_PARITY_S09__09__loading"
                )
            )

            // Leave Settings before using the released primary navigation. On
            // the physical iPad renderer, Escape can dismiss the search focus
            // without leaving the Settings route. Prefer the renderer's
            // explicit "Back to app" control, then use Escape only as a
            // fallback.
            let backToApp = firstElement(labels: ["Back to app", "返回应用"], timeout: 1)
            if let backToApp {
                backToApp.tap()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }

            // A full S08 sweep can leave the released renderer inside a nested
            // settings document. Recover by relaunching the already-installed
            // iPad app (auth state is persisted); this is test-only recovery.
            app.terminate()
            XCTAssertTrue(
                app.wait(for: .notRunning, timeout: 10),
                "Codex for ipad did not terminate before the S09 recovery launch."
            )
            // The focused S09 fixture starts signed out so it can exercise the
            // API-key login path. The credential has been persisted by this
            // point, so allow the recovery launch to restore that same isolated
            // fixture instead of deliberately returning to /login.
            app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "0"
            app.launch()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 15),
                "Codex for ipad did not return to the foreground during S09 recovery."
            )
            activeSurface = app.webViews["CodexDesktopSurfaceReady"]
            XCTAssertTrue(
                activeSurface.waitForExistence(timeout: 45),
                "The released surface did not recover after leaving nested Settings."
            )
            XCTAssertTrue(
                firstElement(
                    labels: [
                        "Side chat",
                        "Side chats",
                        "Projects",
                        "Scheduled",
                        "侧边聊天",
                        "项目",
                        "已安排"
                    ],
                    timeout: 15
                ) != nil,
                "The primary navigation did not recover after leaving nested Settings."
            )
        }

        let productTargets: [(
            entryLabels: [String],
            observedLabels: [String],
            marker: String,
            attachment: String,
            timeout: TimeInterval
        )] = [
            (
                ["Scheduled", "Scheduled tasks", "已安排", "已安排任务"],
                [
                    "Loading scheduled tasks",
                    "No scheduled tasks",
                    "正在加载已安排任务",
                    "没有已安排任务",
                    "已安排任务"
                ],
                "S09|00__loading|/automations|loading",
                "CODEXPAD_PARITY_S09__00__loading",
                5
            ),
            (
                ["Pull requests", "拉取请求"],
                [
                    "No pull requests found",
                    "You’re all caught up",
                    "没有拉取请求",
                    "你已全部查看",
                    "拉取请求"
                ],
                "S09|01__empty|/pull-requests|empty",
                "CODEXPAD_PARITY_S09__01__empty",
                10
            ),
            (
                ["Library", "库", "资料库"],
                [
                    "Unable to load library",
                    "Some library items couldn't be loaded",
                    "无法加载库",
                    "部分库项目无法加载",
                    "库"
                ],
                "S09|03__error|/library|error",
                "CODEXPAD_PARITY_S09__03__error",
                10
            ),
            (
                ["Sites", "站点", "网站"],
                ["Loading sites…", "正在加载站点…", "正在加载站点", "站点"],
                "S09|04__loading|/sites|loading",
                "CODEXPAD_PARITY_S09__04__loading",
                5
            ),
            (
                ["Plugins", "插件"],
                ["Loading plugins…", "正在加载插件…", "正在加载插件", "插件"],
                "S09|05__loading|/plugins|loading",
                "CODEXPAD_PARITY_S09__05__loading",
                5
            ),
            (
                ["Skills", "技能"],
                ["Loading skills…", "正在加载技能…", "正在加载技能", "技能"],
                "S09|06__loading|/skills|loading",
                "CODEXPAD_PARITY_S09__06__loading",
                5
            ),
        ]
        for target in productTargets {
            _ = openProduct(
                entryLabels: target.entryLabels,
                observedLabels: target.observedLabels,
                target: (target.marker, target.attachment),
                timeout: target.timeout
            )
        }

        // A Security title alone is not populated evidence. Require either a
        // completed scan row or the paired findings/activity controls that are
        // exposed by a real workbench result.
        if let securityEntry = firstElement(labels: ["Security", "安全"]) {
            securityEntry.tap()
            if let workbench = firstElement(labels: ["Security workbench", "安全工作台"], timeout: 5),
                workbench.exists {
                let completedScan = currentDescendants().matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Completed (")
                ).firstMatch
                let candidateFindings = element(label: "Candidate findings")
                let viewActivity = element(label: "View activity")
                record(
                    (
                        "S09|02__populated|/security|populated",
                        "CODEXPAD_PARITY_S09__02__populated"
                    ),
                    when: completedScan.waitForExistence(timeout: 5)
                        || (candidateFindings.exists && viewActivity.exists)
                )
            }
        }

        // MCP pages have data-derived names. Never invent server/toolName:
        // enter only through an actual mcp:* navigation item emitted by the
        // released renderer for a configured MCP app.
        let mcpEntry = currentDescendants().matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mcp:")
        ).firstMatch
        if mcpEntry.waitForExistence(timeout: 2), mcpEntry.isHittable {
            mcpEntry.tap()
            record(
                (
                    "S09|07__loading|/mcp-app/:server/:toolName|loading",
                    "CODEXPAD_PARITY_S09__07__loading"
                ),
                when: element(label: "Loading MCP app").waitForExistence(timeout: 5)
            )
        }

        // Codex Mobile is reachable only through the released Help menu. The
        // pairing loader is the route-specific loading surface.
        if let help = firstElement(labels: ["Help", "Help and feedback"]) {
            help.tap()
            if let entry = firstElement(labels: ["Set up mobile", "Set up remote"]) {
                entry.tap()
                record(
                    (
                        "S09|08__loading|/codex-mobile|loading",
                        "CODEXPAD_PARITY_S09__08__loading"
                    ),
                    when: element(label: "Loading pairing code")
                        .waitForExistence(timeout: 5)
                )
            }
        }

        // OAuth callback state has no safe synthetic entry. Record it only if
        // a real connector callback has actually navigated the renderer here.
        let finishingOAuth = currentDescendants().matching(
            NSPredicate(format: "label BEGINSWITH %@", "Finishing")
        ).firstMatch
        let missingOAuth = element(label: "Missing OAuth callback data")
        record(
            (
                "S09|10__loading|/connector/oauth_callback|loading",
                "CODEXPAD_PARITY_S09__10__loading"
            ),
            when: finishingOAuth.waitForExistence(timeout: 2) || missingOAuth.exists
        )
    }

    @MainActor
    private func captureS10GlobalInteractionStates(
        in surface: XCUIElement,
        app: XCUIApplication,
        interactionAcceptance: inout [String]
    ) {
        typealias Target = (marker: String, attachment: String)
        let descendants = surface.descendants(matching: .any)

        func firstElement(
            labels: [String],
            timeout: TimeInterval = 2,
            requireHittable: Bool = true
        ) -> XCUIElement? {
            for label in labels {
                let entry = descendants.matching(
                    NSPredicate(format: "label ==[c] %@", label)
                ).firstMatch
                if entry.waitForExistence(timeout: timeout),
                   !requireHittable || entry.isHittable {
                    return entry
                }
            }
            return nil
        }

        func observesAny(
            _ labels: [String],
            timeout: TimeInterval = 3
        ) -> Bool {
            labels.contains { label in
                descendants.matching(
                    NSPredicate(format: "label ==[c] %@", label)
                ).firstMatch.waitForExistence(timeout: timeout)
            }
        }

        func record(_ target: Target, when observed: Bool) {
            guard observed else {
                return
            }
            interactionAcceptance.append(target.marker)
            captureOfficialRenderer(
                target.attachment,
                app: app,
                surface: surface
            )
        }

        let targets: [String: Target] = [
            "file-search": (
                "S10|01__file-search|*|file-search",
                "CODEXPAD_PARITY_S10__01__file-search"
            ),
            "context-menu": (
                "S10|02__context-menu|*|context-menu",
                "CODEXPAD_PARITY_S10__02__context-menu"
            ),
            "tooltip": (
                "S10|03__tooltip|*|tooltip",
                "CODEXPAD_PARITY_S10__03__tooltip"
            ),
            "dropdown": (
                "S10|04__dropdown|*|dropdown",
                "CODEXPAD_PARITY_S10__04__dropdown"
            ),
            "dialog": (
                "S10|05__dialog|*|dialog",
                "CODEXPAD_PARITY_S10__05__dialog"
            ),
            "toast": (
                "S10|06__toast|*|toast",
                "CODEXPAD_PARITY_S10__06__toast"
            ),
            "hover": (
                "S10|07__hover|*|hover",
                "CODEXPAD_PARITY_S10__07__hover"
            ),
            "focus": (
                "S10|08__focus|*|focus",
                "CODEXPAD_PARITY_S10__08__focus"
            ),
            "pressed": (
                "S10|09__pressed|*|pressed",
                "CODEXPAD_PARITY_S10__09__pressed"
            ),
            "disabled": (
                "S10|10__disabled|*|disabled",
                "CODEXPAD_PARITY_S10__10__disabled"
            ),
            "drag": (
                "S10|11__drag|*|drag",
                "CODEXPAD_PARITY_S10__11__drag"
            ),
            "resize": (
                "S10|12__resize|*|resize",
                "CODEXPAD_PARITY_S10__12__resize"
            ),
            "portrait": (
                "S10|13__portrait|*|portrait",
                "CODEXPAD_PARITY_S10__13__portrait"
            ),
            "landscape": (
                "S10|14__landscape|*|landscape",
                "CODEXPAD_PARITY_S10__14__landscape"
            ),
            "stage-manager": (
                "S10|15__stage-manager|*|stage-manager",
                "CODEXPAD_PARITY_S10__15__stage-manager"
            ),
        ]

        // Command Menu is open on entry. Close it before exercising the
        // released file-search shortcut, then require its official field.
        app.typeKey(.escape, modifierFlags: [])
        activateRenderer(surface)
        app.typeKey("p", modifierFlags: .command)
        let fileSearch = surface.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@ OR label == %@",
                "Search files",
                "Search files"
            )
        ).firstMatch
        let fileSearchOpened = fileSearch.waitForExistence(timeout: 5)
        if let target = targets["file-search"] {
            record(target, when: fileSearchOpened)
        }
        if fileSearchOpened {
            fileSearch.tap()
            if let target = targets["focus"] {
                record(target, when: fileSearch.hasFocus)
            }
        }
        app.typeKey(.escape, modifierFlags: [])

        // Use a real visible row for the long-press menu. Never create a fake
        // chat or file solely to manufacture context-menu evidence.
        let contextualRow = descendants.cells.allElementsBoundByIndex.first(where: {
            !$0.label.isEmpty && $0.isHittable
        })
        if let contextualRow {
            contextualRow.press(forDuration: 1)
            let contextMenuObserved = observesAny(
                ["Copy path", "Open in…", "Archive chat"]
            )
            if let target = targets["context-menu"] {
                record(target, when: contextMenuObserved)
            }

            // A released menu is also the dropdown state. This is separate
            // from context-menu acceptance because its visible choices must
            // still be observed after the real gesture.
            if let target = targets["dropdown"] {
                record(
                    target,
                    when: contextMenuObserved
                        && observesAny(["Copy path", "Open in…"])
                )
            }

            // Copy is non-destructive and provides a real toast path.
            if let copyPath = firstElement(labels: ["Copy path"]) {
                copyPath.tap()
                if let target = targets["toast"] {
                    record(
                        target,
                        when: observesAny(
                            ["Copied", "Copied to clipboard"],
                            timeout: 3
                        )
                    )
                }
            }

            // Re-open the same real menu for dialog coverage. Archive is not
            // executed: if confirmation appears, cancel it immediately.
            contextualRow.press(forDuration: 1)
            if let archive = firstElement(labels: ["Archive chat"]) {
                archive.tap()
                let dialogObserved = observesAny(
                    ["Archive chat?", "Archive chat and remove scheduled task?"]
                )
                if let target = targets["dialog"] {
                    record(target, when: dialogObserved)
                }
                if dialogObserved,
                   let cancel = firstElement(labels: ["Cancel"]) {
                    cancel.tap()
                }
            }
        }

        // Tooltips and pointer hover are optional on physical iPad. Only a
        // renderer-emitted accessibility state can count; touch alone does not.
        let tooltip = descendants.matching(
            NSPredicate(
                format:
                    "identifier CONTAINS[c] %@ "
                    + "OR value CONTAINS[c] %@",
                "tooltip",
                "tooltip"
            )
        ).firstMatch
        if let target = targets["tooltip"] {
            record(target, when: tooltip.waitForExistence(timeout: 1))
        }
        let hovered = descendants.matching(
            NSPredicate(
                format:
                    "identifier CONTAINS[c] %@ "
                    + "OR value CONTAINS[c] %@",
                "hover",
                "hover"
            )
        ).firstMatch
        if let target = targets["hover"] {
            record(target, when: hovered.waitForExistence(timeout: 1))
        }

        let pressed = descendants.matching(
            NSPredicate(
                format:
                    "identifier CONTAINS[c] %@ "
                    + "OR value CONTAINS[c] %@",
                "pressed",
                "pressed"
            )
        ).firstMatch
        if let target = targets["pressed"] {
            record(target, when: pressed.waitForExistence(timeout: 1))
        }

        let disabled = descendants.matching(
            NSPredicate(format: "isEnabled == NO")
        ).firstMatch
        if let target = targets["disabled"] {
            record(
                target,
                when: disabled.waitForExistence(timeout: 2)
                    && !disabled.isEnabled
            )
        }

        // Drag only a renderer-declared draggable handle, and accept it only
        // when the element's frame actually moves.
        let dragHandle = descendants.matching(
            NSPredicate(
                format:
                    "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@",
                "Drag",
                "drag"
            )
        ).firstMatch
        if dragHandle.waitForExistence(timeout: 2), dragHandle.isHittable {
            let beforeFrame = dragHandle.frame
            let start = dragHandle.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            start.press(
                forDuration: 0.2,
                thenDragTo: start.withOffset(CGVector(dx: 36, dy: 0))
            )
            let afterFrame = dragHandle.frame
            if let target = targets["drag"] {
                record(target, when: beforeFrame != afterFrame)
            }
        }

        let resizeHandle = descendants.matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@",
                "Resize device viewport from the left edge",
                "Resize device viewport from the right edge",
                "Resize device viewport from the bottom edge"
            )
        ).firstMatch
        if resizeHandle.waitForExistence(timeout: 2), resizeHandle.isHittable {
            let beforeFrame = surface.frame
            let start = resizeHandle.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            start.press(
                forDuration: 0.2,
                thenDragTo: start.withOffset(CGVector(dx: 32, dy: 24))
            )
            let afterFrame = surface.frame
            if let target = targets["resize"] {
                record(target, when: beforeFrame != afterFrame)
            }
        }

        // Rotate the physical device through both supported layouts and wait
        // for the released renderer frame to actually change before recording.
        let device = XCUIDevice.shared
        let originalOrientation = XCUIDevice.shared.orientation
        device.orientation = .portrait
        let portraitObserved = waitForOrientation(
            surface,
            portrait: true,
            timeout: 8
        )
        if let target = targets["portrait"] {
            record(target, when: portraitObserved)
        }
        device.orientation = .landscapeLeft
        let landscapeObserved = waitForOrientation(
            surface,
            portrait: false,
            timeout: 8
        )
        if let target = targets["landscape"] {
            record(target, when: landscapeObserved)
        }

        // Stage Manager acceptance requires a real offset/resized app window.
        // A normal full-screen window at the origin is deliberately rejected.
        let appWindow = app.windows.firstMatch
        let windowFrame = appWindow.frame
        let stageManagerObserved = appWindow.exists
            && (windowFrame.minX > 1 || windowFrame.minY > 1)
            && windowFrame.width > 0
            && windowFrame.height > 0
        if let target = targets["stage-manager"] {
            record(target, when: stageManagerObserved)
        }

        device.orientation = originalOrientation
    }

    @MainActor
    private func waitForOrientation(
        _ surface: XCUIElement,
        portrait: Bool,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let frame = surface.frame
            if frame.width > 0,
               frame.height > 0,
               portrait == (frame.height > frame.width) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func captureAdditionalS05PanelStates(
        in surface: XCUIElement,
        app: XCUIApplication,
        interactionAcceptance: inout [String]
    ) {
        // The released side-panel launcher is the only supported entry point
        // for Files, Browser and Detail.  Do not emit a marker unless the
        // launcher and the target tab are both observed and hittable.
        let openSidePanel = surface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR label CONTAINS[c] %@",
                "Open side panel tab",
                "Open side panel"
            )
        ).firstMatch
        guard openSidePanel.waitForExistence(timeout: 3), openSidePanel.isHittable else {
            return
        }

        let targets: [(label: String, marker: String, attachment: String)] = [
            (
                "Files",
                "S05|00__files|/local/:conversationId|files",
                "CODEXPAD_PARITY_S05__00__files"
            ),
            (
                "Browser",
                "S05|02__browser|/local/:conversationId|browser",
                "CODEXPAD_PARITY_S05__02__browser"
            ),
            (
                "Detail",
                "S05|04__detail|/local/:conversationId|detail",
                "CODEXPAD_PARITY_S05__04__detail"
            ),
        ]

        for target in targets {
            openSidePanel.tap()
            let tab = surface.descendants(matching: .any).matching(
                NSPredicate(format: "label ==[c] %@", target.label)
            ).firstMatch
            guard tab.waitForExistence(timeout: 5), tab.isHittable else {
                app.typeKey(.escape, modifierFlags: [])
                continue
            }
            tab.tap()
            guard surface.descendants(matching: .any).matching(
                NSPredicate(format: "label ==[c] %@", target.label)
            ).firstMatch.waitForExistence(timeout: 5) else {
                continue
            }
            interactionAcceptance.append(target.marker)
            captureOfficialRenderer(target.attachment, app: app, surface: surface)
        }

        let terminalBottom = surface.descendants(matching: .any).matching(
            NSPredicate(format: "label ==[c] %@", "Terminal (bottom)")
        ).firstMatch
        if terminalBottom.waitForExistence(timeout: 2) {
            interactionAcceptance.append("S05|05__terminal-bottom|/local/:conversationId|terminal-bottom")
            captureOfficialRenderer(
                "CODEXPAD_PARITY_S05__05__terminal-bottom",
                app: app,
                surface: surface
            )
        }
        let terminalRight = surface.descendants(matching: .any).matching(
            NSPredicate(format: "label ==[c] %@", "Terminal (right)")
        ).firstMatch
        if terminalRight.waitForExistence(timeout: 2) {
            interactionAcceptance.append("S05|06__terminal-right|/local/:conversationId|terminal-right")
            captureOfficialRenderer(
                "CODEXPAD_PARITY_S05__06__terminal-right",
                app: app,
                surface: surface
            )
        }

        let resizeControl = surface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@",
                "Resize",
                "resize"
            )
        ).firstMatch
        if resizeControl.waitForExistence(timeout: 2), resizeControl.isHittable {
            let before = resizeControl.frame
            let start = resizeControl.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            let end = start.withOffset(CGVector(dx: 48, dy: 0))
            start.press(forDuration: 0.2, thenDragTo: end)
            let after = resizeControl.frame
            if before != after {
                interactionAcceptance.append("S05|07__panel-resize|/local/:conversationId|panel-resize")
                captureOfficialRenderer(
                    "CODEXPAD_PARITY_S05__07__panel-resize",
                    app: app,
                    surface: surface
                )
            }
        }

        let collapseControl = surface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "Collapse",
                "折叠"
            )
        ).firstMatch
        if collapseControl.waitForExistence(timeout: 2), collapseControl.isHittable {
            collapseControl.tap()
            let expandControl = surface.descendants(matching: .any).matching(
                NSPredicate(
                    format:
                        "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                    "Expand",
                    "展开"
                )
            ).firstMatch
            if expandControl.waitForExistence(timeout: 3) {
                interactionAcceptance.append("S05|08__panel-collapsed|/local/:conversationId|panel-collapsed")
                captureOfficialRenderer(
                    "CODEXPAD_PARITY_S05__08__panel-collapsed",
                    app: app,
                    surface: surface
                )
            }
        }
    }

    @MainActor
    private func releasedComposer(
        in surface: XCUIElement
    ) -> XCUIElement {
        surface.textViews.matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ "
                    + "OR label CONTAINS[c] %@ "
                    + "OR label CONTAINS[c] %@ "
                    + "OR placeholderValue CONTAINS[c] %@ "
                    + "OR placeholderValue CONTAINS[c] %@",
                "Do anything",
                "做任何事",
                "随心输入",
                "Codex",
                "ChatGPT",
                "Codex",
                "ChatGPT"
            )
        ).firstMatch
    }

    @MainActor
    private func activateRenderer(_ surface: XCUIElement) {
        surface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)
        ).tap()
    }

    @MainActor
    private func releasedSettingsSearch(
        in surface: XCUIElement,
        timeout: TimeInterval = 0
    ) -> XCUIElement {
        let predicate = NSPredicate(
            format:
                "placeholderValue == %@ OR label == %@ "
                + "OR placeholderValue == %@ OR label == %@",
            "Search settings…",
            "Search settings",
            "搜索设置…",
            "搜索设置"
        )
        let semanticSearchField = surface.searchFields.matching(
            predicate
        ).firstMatch
        if timeout > 0 {
            if semanticSearchField.waitForExistence(timeout: timeout) {
                return semanticSearchField
            }
        } else if semanticSearchField.exists {
            return semanticSearchField
        }
        return surface.descendants(matching: .any).matching(
            predicate
        ).firstMatch
    }

    @MainActor
    private func releasedCommandMenuSearch(
        in surface: XCUIElement
    ) -> XCUIElement {
        surface.textFields.matching(
            NSPredicate(
                format:
                    "placeholderValue CONTAINS[c] %@ "
                    + "OR label CONTAINS[c] %@ "
                    + "OR placeholderValue == %@ OR label == %@ "
                    + "OR placeholderValue == %@ OR label == %@",
                "Search",
                "Search",
                "搜索聊天或运行命令",
                "搜索聊天或运行命令",
                "命令菜单",
                "命令菜单"
            )
        ).firstMatch
    }

    @MainActor
    private func releasedSettingsNavigationMarker(
        in surface: XCUIElement
    ) -> XCUIElement {
        surface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label == %@",
                "Settings",
                "设置",
                "General",
                "常规",
                "Appearance",
                "外观"
            )
        ).firstMatch
    }

    @MainActor
    private func openSettingsThroughReleasedProfileMenu(
        in surface: XCUIElement
    ) {
        let profileMenu = surface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Open profile menu",
                "打开个人资料菜单"
            )
        ).firstMatch
        XCTAssertTrue(
            profileMenu.waitForExistence(timeout: 10),
            "The released surface did not expose the profile menu."
        )
        profileMenu.tap()

        let settingsButton = surface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                "Settings",
                "设置"
            )
        ).firstMatch
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 10),
            "The released profile menu did not expose Settings."
        )
        settingsButton.tap()
    }

    @MainActor
    private func signedInMarker(
        in surface: XCUIElement
    ) -> XCUIElement {
        surface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label == %@ "
                    + "OR label BEGINSWITH %@ OR label BEGINSWITH %@",
                "New chat",
                "新聊天",
                "新对话",
                "Pull requests",
                "Send",
                "发送",
                "Change project:",
                "切换项目："
            )
        ).firstMatch
    }

    @MainActor
    private func apiKeySignInEntry(
        in surface: XCUIElement
    ) -> XCUIElement {
        surface.buttons.matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ OR label == %@",
                "Sign in another way",
                "使用其他方式登录",
                "Use API key",
                "使用 API 密钥"
            )
        ).firstMatch
    }

    @MainActor
    private func apiKeySubmitButton(
        in surface: XCUIElement
    ) -> XCUIElement {
        surface.buttons.matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ OR label == %@",
                "Continue",
                "继续",
                "OK",
                "确定"
            )
        ).firstMatch
    }

    @MainActor
    private func authenticationSuccessMarker(
        in surface: XCUIElement
    ) -> XCUIElement {
        surface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label BEGINSWITH %@ "
                    + "OR label BEGINSWITH %@",
                "Welcome to Codex",
                "Welcome",
                "New chat",
                "新聊天",
                "Pull requests",
                "Send",
                "发送",
                "Change project:",
                "切换项目："
            )
        ).firstMatch
    }

    @MainActor
    private func providerBoundaryTerminalError(
        in surface: XCUIElement
    ) -> XCUIElement {
        surface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label CONTAINS[c] %@ OR label CONTAINS[c] %@ "
                    + "OR label CONTAINS[c] %@ OR label CONTAINS[c] %@ "
                    + "OR label CONTAINS[c] %@ OR label CONTAINS[c] %@ "
                    + "OR label CONTAINS[c] %@ OR label CONTAINS[c] %@ "
                    + "OR label CONTAINS[c] %@",
                "saved sign-in credential was rejected",
                "model is not supported",
                "invalid API key",
                "incorrect API key",
                "authentication",
                "unauthorized",
                "bad request",
                "providerTransportFailure",
                "provider request timed out"
            )
        ).firstMatch
    }

    @MainActor
    private func completeWelcomeIfNeeded(in surface: XCUIElement) {
        let roleTitle = surface.staticTexts.matching(
            NSPredicate(
                format:
                    "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "How do you want to use Codex",
                "Use Codex"
            )
        ).firstMatch
        guard roleTitle.waitForExistence(timeout: 2) else {
            return
        }

        let personal = surface.buttons.matching(
            NSPredicate(
                format:
                    "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "Personal",
                "individual"
            )
        ).firstMatch
        if personal.waitForExistence(timeout: 5) {
            personal.tap()
        }

        let continueButton = surface.buttons.matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@",
                "Continue",
                "Get started",
                "Done"
            )
        ).firstMatch
        if continueButton.waitForExistence(timeout: 5) {
            continueButton.tap()
        }
    }
}
