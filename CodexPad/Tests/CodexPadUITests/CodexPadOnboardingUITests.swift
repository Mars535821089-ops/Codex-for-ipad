import XCTest

final class CodexPadOnboardingUITests: XCTestCase {
    private let releasedSurfaceBudget: TimeInterval = 45

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testColdLaunchShowsOfficialLoginAndKeepsAuthenticationInsideApp() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"] =
            "signed-out-browser-" + UUID().uuidString.lowercased()
        app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"
        // The released surface performs a complete, content-addressed
        // resource verification before navigation.  Wait for that explicit
        // native checkpoint instead of racing the WebView's splash screen.
        let startupBudget = releasedSurfaceBudget
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]

        if app.state != .notRunning {
            app.terminate()
        }

        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: startupBudget),
            "Codex for ipad did not enter the foreground."
        )

        let readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: startupBudget),
            "The released surface did not reach its native ready checkpoint."
        )

        let continueButton = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Continue to sign in",
                "继续登录"
            )
        ).firstMatch
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: startupBudget),
            "The official signed-out surface did not expose its sign-in action after the ready checkpoint."
        )
        continueButton.tap()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 5),
            "Starting ChatGPT authentication moved Codex out of the foreground."
        )
        acceptAuthenticationServicesFirstUsePromptIfNeeded()
        let authenticationBrowser =
            app.otherElements["CodexAuthenticationBrowser"]
        XCTAssertTrue(
            authenticationBrowser.waitForExistence(timeout: 15),
            "The AuthenticationServices browser was not presented inside Codex."
        )
        let closeAuthentication =
            authenticationBrowser.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Close",
                    "关闭"
                )
            ).firstMatch
        XCTAssertTrue(
            closeAuthentication.waitForExistence(timeout: 15),
            "The AuthenticationServices browser did not expose its released close control."
        )
        closeAuthentication.tap()
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: 10),
            "Canceling authentication did not return to the released Codex surface."
        )
    }

    @MainActor
    func testColdLaunchExpandsOfficialAPIKeySignInWithoutSubmittingCredentials() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"] =
            "signed-out-api-key-" + UUID().uuidString.lowercased()
        app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        XCTAssertTrue(
            app.wait(
                for: .runningForeground,
                timeout: releasedSurfaceBudget
            )
        )

        let readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(
                timeout: releasedSurfaceBudget
            )
        )

        let anotherWayButton = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Sign in another way",
                "使用其他方式登录"
            )
        ).firstMatch
        XCTAssertTrue(
            anotherWayButton.waitForExistence(timeout: 5)
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
            apiKeyField.waitForExistence(timeout: 5),
            "The released API-key form did not expose its credential field."
        )
    }

    @MainActor
    func testAPIKeyLoginCommitsToKeychainSurvivesColdRelaunchAndMatchesDesktopLogoutVisibility() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"] =
            "api-key-login-" + UUID().uuidString.lowercased()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        // Show the signed-out surface without deleting any persisted revision.
        // The submission below must replace it through the production
        // account/login/start bridge and system Keychain implementation.
        app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )

        var readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: releasedSurfaceBudget),
            "The forced signed-out run did not reach the released surface."
        )

        let anotherWayButton = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Sign in another way",
                "使用其他方式登录"
            )
        ).firstMatch
        XCTAssertTrue(
            anotherWayButton.waitForExistence(timeout: 10),
            "The released surface did not expose API-key sign-in."
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
            "The released API-key form did not expose its credential field."
        )
        apiKeyField.tap()
        apiKeyField.typeText("test-key-codexpad-placeholder")

        let continueButton = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Continue",
                "继续"
            )
        ).firstMatch
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 10),
            "The released API-key form did not expose its submit action."
        )
        continueButton.tap()

        XCTAssertTrue(
            releasedAuthenticationSuccessMarker(in: readySurface)
                .waitForExistence(
                timeout: 30
            ),
            "Submitting an API key did not enter the released authenticated flow."
        )
        XCTAssertFalse(
            apiKeyPersistenceFailure(in: readySurface).exists,
            "API-key submission still reported a Keychain persistence failure."
        )

        completeReleasedWelcomeIfNeeded(in: readySurface)
        XCTAssertTrue(
            releasedSignedInMarker(in: readySurface).waitForExistence(
                timeout: 30
            ),
            "Completing the released API-key welcome flow did not enter the workspace."
        )

        let committedScreenshot = XCTAttachment(screenshot: app.screenshot())
        committedScreenshot.name =
            "API key committed through the released surface"
        committedScreenshot.lifetime = .keepAlways
        add(committedScreenshot)

        app.terminate()
        app.launchEnvironment.removeValue(
            forKey: "CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"
        )
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )
        readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: releasedSurfaceBudget),
            "Cold relaunch did not return to the released surface."
        )
        XCTAssertTrue(
            releasedSignedInMarker(in: readySurface).waitForExistence(
                timeout: 30
            ),
            "Cold relaunch did not restore the API key from Keychain."
        )
        XCTAssertFalse(
            readySurface.buttons["Continue to sign in"].exists,
            "Cold relaunch returned to signed-out state after API-key login."
        )

        // XCUI's synthesized hardware keys are dispatched through the current
        // WebKit responder. A cold process launch does not select one until the
        // restored surface receives an interaction, unlike a physical iPad
        // keyboard event delivered to the active scene. Activate the released
        // surface before asserting its native accelerator bridge.
        readySurface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()

        // Desktop 26.814.41407 registers `logOut` only while `requiresAuth`
        // is true. API-key profiles report requiresAuth=false, so both the
        // profile popup and command menu intentionally omit Log out. Preserve
        // that released behavior instead of inventing an iPad-only exit flow.
        app.typeKey("k", modifierFlags: .command)

        let commandSearch = readySurface.textFields.matching(
            NSPredicate(
                format:
                    "placeholderValue CONTAINS[c] %@ OR label CONTAINS[c] %@ "
                    + "OR placeholderValue == %@ OR label == %@",
                "Search",
                "Search",
                "搜索聊天或运行命令",
                "命令菜单"
            )
        ).firstMatch
        XCTAssertTrue(
            commandSearch.waitForExistence(timeout: 10),
            "The released ⌘K shortcut did not open the command menu."
        )
        commandSearch.tap()
        commandSearch.typeText("Log out")

        let noMatchingItems = readySurface.otherElements.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "No matching items",
                "无匹配项"
            )
        ).firstMatch
        XCTAssertTrue(
            noMatchingItems.waitForExistence(timeout: 10),
            "The API-key command menu diverged from desktop logout visibility."
        )

        // The hidden command must not mutate the durable API-key revision.
        app.terminate()
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )
        readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: releasedSurfaceBudget)
        )
        XCTAssertTrue(
            releasedSignedInMarker(in: readySurface).waitForExistence(
                timeout: 30
            ),
            "Searching the unavailable Log out command removed the API key."
        )
    }

    @MainActor
    func testSignedOutSurfaceExposesTheReleasedLoginButtonInventory() {
        let app = XCUIApplication()
        app.launchEnvironment["CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"] =
            "signed-out-inventory-" + UUID().uuidString.lowercased()
        app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )

        let surface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: releasedSurfaceBudget)
        )
        let buttons = surface.buttons
        let primarySignIn = buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Continue to sign in",
                "继续登录"
            )
        ).firstMatch
        XCTAssertTrue(
            primarySignIn.waitForExistence(timeout: 10),
            "The released primary sign-in button is missing."
        )
        XCTAssertTrue(
            buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Sign in another way",
                    "使用其他方式登录"
                )
            ).firstMatch.waitForExistence(timeout: 10),
            "The released secondary sign-in button is missing."
        )

        let visibleLabels = Set(
            buttons.allElementsBoundByIndex
                .filter(\.isHittable)
                .map(\.label)
                .filter { !$0.isEmpty }
        )
        let releasedSignedOutLabelGroups: [[String]] = [
            ["Continue to sign in", "继续登录"],
            ["Sign in another way", "使用其他方式登录"],
            ["Sign up", "注册"],
            ["Play Snake", "玩贪吃蛇"],
        ]
        XCTAssertTrue(
            releasedSignedOutLabelGroups.allSatisfy { labels in
                !Set(labels).isDisjoint(with: visibleLabels)
            } && visibleLabels.count == releasedSignedOutLabelGroups.count,
            "The signed-out button inventory diverged from the released surface."
        )
    }

    @MainActor
    func testAuthenticatedReleasedSurfaceCapturesVisibleButtonInventory() {
        let app = XCUIApplication()
        let readySurface = signIntoReleasedSurfaceWithPlaceholder(in: app)

        let visibleButtons = readySurface.buttons.allElementsBoundByIndex
            .filter(\.isHittable)
            .map(\.label)
            .filter { !$0.isEmpty }
        let visibleLabels = Array(Set(visibleButtons)).sorted()
        let releasedStaticLabelGroups: [[String]] = [
            ["Add files and more", "添加文件等内容"],
            ["Add new project", "添加新项目"],
            ["Back", "返回"],
            ["Build a new feature, app, or tool", "构建新功能、应用或工具"],
            ["Explore and understand code", "探索并理解代码"],
            ["Fix issues and failures", "修复问题和失败"],
            ["Forward", "前进"],
            ["Hide sidebar", "隐藏边栏"],
            ["New chat", "New Chat", "新聊天", "新对话"],
            ["Plugins", "插件"],
            ["Projects", "项目"],
            ["Recents", "最近"],
            ["Review code and suggest changes", "审查代码并提出修改建议"],
            ["Scheduled", "已安排"],
            ["Search", "搜索"],
            ["Send", "发送"],
        ]
        let visibleLabelSet = Set(visibleLabels)

        XCTAssertTrue(
            releasedStaticLabelGroups.allSatisfy { labels in
                !Set(labels).isDisjoint(with: visibleLabelSet)
            },
            "The authenticated surface omitted released desktop 26.803.41515 controls."
        )
        print(
            "CODEXPAD_AUTHENTICATED_BUTTON_INVENTORY="
                + visibleLabels.joined(separator: " | ")
        )

        let inventory = XCTAttachment(
            string: visibleLabels.joined(separator: "\n")
        )
        inventory.name = "Authenticated released button inventory"
        inventory.lifetime = .keepAlways
        add(inventory)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Authenticated released surface button inventory"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testAuthenticatedReleasedPrimaryNavigationButtonsOpenTheirDesktopSurfaces() {
        let app = XCUIApplication()
        let readySurface = signIntoReleasedSurfaceWithPlaceholder(in: app)

        let destinations: [
            (button: String, localizedButton: String,
             marker: String, localizedMarker: String)
        ] = [
            // The released desktop surface labels this page's heading
            // "Scheduled tasks" (the sidebar control remains "Scheduled").
            ("Scheduled", "已安排", "Scheduled tasks", "已安排"),
            ("Plugins", "插件", "Plugins", "插件"),
        ]
        for destination in destinations {
            let button = readySurface.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    destination.button,
                    destination.localizedButton
                )
            ).firstMatch
            XCTAssertTrue(
                button.waitForExistence(timeout: 10),
                "The released sidebar omitted \(destination.button)."
            )
            button.tap()

            let heading = readySurface.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    destination.marker,
                    destination.localizedMarker
                )
            ).firstMatch
            XCTAssertTrue(
                heading.waitForExistence(timeout: 10),
                "Tapping \(destination.button) did not open its desktop surface."
            )
        }

        let hideSidebar = readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Hide sidebar",
                "隐藏边栏"
            )
        ).firstMatch
        XCTAssertTrue(hideSidebar.waitForExistence(timeout: 10))
        hideSidebar.tap()
        let showSidebar = readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Show sidebar",
                "显示边栏"
            )
        ).firstMatch
        XCTAssertTrue(
            showSidebar.waitForExistence(timeout: 10),
            "Hide sidebar did not expose the reciprocal Show sidebar action."
        )
        showSidebar.tap()
        XCTAssertTrue(
            readySurface.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Hide sidebar",
                    "隐藏边栏"
                )
            ).firstMatch.waitForExistence(timeout: 10),
            "Show sidebar did not restore the released sidebar."
        )

        let newChat = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@ OR label == %@",
                "New chat",
                "新聊天",
                "新对话"
            )
        ).firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.tap()
        XCTAssertTrue(
            readySurface.textViews.matching(
                NSPredicate(
                    format:
                        "label == %@ OR label == %@ OR label == %@ "
                        + "OR label CONTAINS[c] %@ "
                        + "OR placeholderValue CONTAINS[c] %@ "
                        + "OR label CONTAINS[c] %@ "
                        + "OR placeholderValue CONTAINS[c] %@",
                    "Do anything",
                    "做任何事",
                    "随心输入",
                    "Codex",
                    "Codex",
                    "ChatGPT",
                    "ChatGPT"
                )
            ).firstMatch.waitForExistence(timeout: 10),
            "New chat did not expose the released composer."
        )

        // Search opens a modal command menu in the released desktop surface.
        // Keep it as the final interaction in this test: on iPad Simulator,
        // the software keyboard consumes Escape and the menu intentionally
        // remains open until the user chooses a command or taps its controls.
        let search = readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Search",
                "搜索"
            )
        ).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let searchField = readySurface.textFields.matching(
            NSPredicate(
                format:
                    "placeholderValue CONTAINS[c] %@ OR label CONTAINS[c] %@ "
                    + "OR placeholderValue == %@ OR label == %@",
                "Search",
                "Search",
                "搜索聊天或运行命令",
                "命令菜单"
            )
        ).firstMatch
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 10),
            "Tapping Search did not open the released search surface."
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Authenticated primary navigation button acceptance"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// The first ASWebAuthenticationSession for a domain is gated by a
    /// SpringBoard-owned consent alert. Its localized action labels follow the
    /// simulator language rather than the app's `-AppleLanguages` launch
    /// argument, so select the affirmative trailing action by position.
    @MainActor
    private func acceptAuthenticationServicesFirstUsePromptIfNeeded() {
        let springboard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard"
        )
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else {
            return
        }

        let actions = alert.buttons
        XCTAssertGreaterThanOrEqual(
            actions.count,
            2,
            "The AuthenticationServices consent alert did not expose its expected actions."
        )
        actions.element(boundBy: actions.count - 1).tap()
    }

    @MainActor
    private func signIntoReleasedSurfaceWithPlaceholder(
        in app: XCUIApplication
    ) -> XCUIElement {
        if app.launchEnvironment[
            "CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"
        ] == nil {
            app.launchEnvironment[
                "CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"
            ] = "placeholder-login-" + UUID().uuidString.lowercased()
        }
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )

        let readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: releasedSurfaceBudget),
            "The forced signed-out run did not reach the released surface."
        )

        let anotherWayButton = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Sign in another way",
                "使用其他方式登录"
            )
        ).firstMatch
        XCTAssertTrue(
            anotherWayButton.waitForExistence(timeout: 10),
            "The released surface did not expose API-key sign-in."
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
            "The released API-key form did not expose its credential field."
        )
        apiKeyField.tap()
        apiKeyField.typeText("test-key-codexpad-placeholder")

        let continueButton = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Continue",
                "继续"
            )
        ).firstMatch
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 10),
            "The released API-key form did not expose its submit action."
        )
        continueButton.tap()

        XCTAssertTrue(
            releasedAuthenticationSuccessMarker(in: readySurface)
                .waitForExistence(timeout: 30),
            "Submitting an API key did not enter the released authenticated flow."
        )
        completeReleasedWelcomeIfNeeded(in: readySurface)
        XCTAssertTrue(
            releasedSignedInMarker(in: readySurface).waitForExistence(
                timeout: 30
            ),
            "Completing the released welcome flow did not enter the workspace."
        )
        return readySurface
    }

    @MainActor
    func testPlaceholderCredentialCreatesThreadBeforeProviderRejectsTurn() {
        let app = XCUIApplication()
        let readySurface = signIntoReleasedSurfaceWithPlaceholder(in: app)

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
            "The authenticated released surface did not expose New chat."
        )
        newChat.tap()

        let composer = readySurface.textViews.matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ "
                    + "OR label CONTAINS[c] %@ "
                    + "OR placeholderValue CONTAINS[c] %@",
                "Do anything",
                "做任何事",
                "随心输入",
                "给 ChatGPT 发消息",
                "Codex",
                "Codex"
            )
        ).firstMatch
        XCTAssertTrue(
            composer.waitForExistence(timeout: 10),
            "New chat did not expose the released composer."
        )
        composer.tap()
        composer.typeText(
            "Verify that thread creation reaches the provider boundary."
        )

        let send = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Send",
                "发送"
            )
        ).firstMatch
        XCTAssertTrue(
            send.waitForExistence(timeout: 10),
            "Entering a prompt did not expose the released send action."
        )
        XCTAssertTrue(
            send.isEnabled,
            "Entering a prompt did not enable the released send action."
        )
        send.tap()

        let providerRejection = releasedProviderBoundaryTerminalError(
            in: readySurface
        )
        XCTAssertTrue(
            providerRejection.waitForExistence(timeout: 90),
            "The placeholder turn did not reach the provider boundary."
        )

        let threadCreationFailure = readySurface.staticTexts.matching(
            NSPredicate(
                format:
                    "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "Error creating chat",
                "Thread session starting failed"
            )
        ).firstMatch
        XCTAssertFalse(
            threadCreationFailure.exists,
            "The renderer failed before the provider request was attempted."
        )
    }

    @MainActor
    func testRuntimeSurfaceProbeKeepsTheActualCurrentUI() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15)
        )
    }

    @MainActor
    func testCurrentAccountFeatureGatedPrimaryNavigation() throws {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )

        let readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: 90),
            "The persisted account did not return to the released surface."
        )
        try skipCurrentAccountFlowWhenSignedOut(readySurface)

        // Pull Requests is supplied by the official renderer only for accounts
        // whose capability set enables it. API-key sessions legitimately omit
        // this control, while a capable persisted ChatGPT account must navigate
        // to the matching released surface when the control is present.
        let pullRequests = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Pull requests",
                "拉取请求"
            )
        ).firstMatch
        if pullRequests.exists {
            pullRequests.tap()
            let heading = readySurface.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Pull Request",
                    "拉取请求"
                )
            ).firstMatch
            XCTAssertTrue(
                heading.waitForExistence(timeout: 10),
                "The enabled Pull Requests control did not open its released surface."
            )
        }

        let capabilityEvidence = XCTAttachment(
            string: pullRequests.exists
                ? "Pull Requests enabled and navigable"
                : "Pull Requests omitted by current account capability set"
        )
        capabilityEvidence.name = "Current account primary navigation capability"
        capabilityEvidence.lifetime = .keepAlways
        add(capabilityEvidence)
    }

    @MainActor
    func testCurrentAccountStateSupportsRealNavigationWithoutResettingData() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )

        let readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: releasedSurfaceBudget),
            "The persisted account did not return to the released surface."
        )
        try skipCurrentAccountFlowWhenSignedOut(readySurface)

        let profileMenu = readySurface.descendants(
            matching: .any
        ).matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Open profile menu",
                "打开个人资料菜单"
            )
        ).firstMatch
        XCTAssertTrue(
            profileMenu.waitForExistence(timeout: 10),
            "The persisted main surface did not expose the profile menu."
        )
        profileMenu.tap()

        let settingsButton = readySurface.descendants(
            matching: .any
        ).matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                "Settings",
                "设置"
            )
        ).firstMatch
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 10),
            "The persisted main surface did not expose Settings."
        )
        settingsButton.tap()

        let appearanceItem = readySurface.descendants(
            matching: .any
        ).matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Appearance",
                "外观"
            )
        ).firstMatch
        XCTAssertTrue(
            appearanceItem.waitForExistence(timeout: 10),
            "Opening Settings did not expose the desktop Appearance section."
        )
        appearanceItem.tap()

        let themeControl = readySurface.descendants(
            matching: .any
        ).matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@",
                "Theme",
                "主题",
                "Use system theme",
                "System theme",
                "Light theme",
                "Dark theme",
                "System",
                "Light",
                "Dark",
                "使用系统主题",
                "系统主题",
                "浅色主题",
                "深色主题",
                "系统",
                "浅色",
                "深色"
            )
        ).firstMatch
        let appearanceInventory = XCTAttachment(
            string: readySurface.debugDescription
        )
        appearanceInventory.name =
            "Settings Appearance accessibility inventory"
        appearanceInventory.lifetime = .keepAlways
        add(appearanceInventory)
        let appearanceBeforeAssertion = XCTAttachment(
            screenshot: app.screenshot()
        )
        appearanceBeforeAssertion.name =
            "Settings Appearance before assertion"
        appearanceBeforeAssertion.lifetime = .keepAlways
        add(appearanceBeforeAssertion)
        XCTAssertTrue(
            themeControl.waitForExistence(timeout: 10),
            "Opening Appearance did not expose a desktop Theme option."
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "S02 Settings Appearance on physical iPad"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testCurrentAccountDesktopSettingsShortcuts() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )
        let readySurface = app.webViews["CodexDesktopSurfaceReady"]
        if !readySurface.waitForExistence(timeout: releasedSurfaceBudget) {
            let signIn = app.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Continue to sign in",
                    "继续登录"
                )
            ).firstMatch
            if signIn.waitForExistence(timeout: 2) {
                throw XCTSkip(
                    "Current-account flow requires persisted simulator authentication."
                )
            }
            XCTFail("The persisted account did not reach the released surface.")
            return
        }
        try skipCurrentAccountFlowWhenSignedOut(readySurface)

        // XCUI's synthesized hardware shortcut is delivered through the
        // current WebKit responder. Activate the released renderer before
        // sending it, matching the already-proven ⌘K physical-iPad path.
        readySurface.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()

        app.typeKey("k", modifierFlags: .command)
        let commandSearch = readySurface.textFields.matching(
            NSPredicate(
                format:
                    "placeholderValue CONTAINS[c] %@ OR label CONTAINS[c] %@ "
                    + "OR placeholderValue == %@ OR label == %@",
                "Search",
                "Search",
                "搜索聊天或运行命令",
                "命令菜单"
            )
        ).firstMatch
        XCTAssertTrue(
            commandSearch.waitForExistence(timeout: 10),
            "The released ⌘K shortcut did not open the command menu."
        )
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("/", modifierFlags: .command)
        let shortcutSearch = readySurface.textFields.matching(
            NSPredicate(
                format:
                    "placeholderValue == %@ OR placeholderValue == %@",
                "Search shortcuts",
                "搜索快捷键"
            )
        ).firstMatch
        XCTAssertTrue(
            shortcutSearch.waitForExistence(timeout: 10),
            "The released ⌘/ shortcut did not open Keyboard shortcuts."
        )
        let backToApp = readySurface.links.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Back to app",
                "返回应用"
            )
        ).firstMatch
        XCTAssertTrue(
            backToApp.waitForExistence(timeout: 10),
            "Keyboard shortcuts did not expose the desktop Back to app link."
        )
        backToApp.tap()

        app.typeKey(",", modifierFlags: .command)
        let inAppSettings = readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label == %@",
                "Appearance",
                "外观",
                "General",
                "常规",
                "Settings",
                "设置"
            )
        ).firstMatch
        if inAppSettings.waitForExistence(timeout: 5) {
            return
        }

        let systemSettings = XCUIApplication(
            bundleIdentifier: "com.apple.Preferences"
        )
        if systemSettings.wait(for: .runningForeground, timeout: 5) {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name =
                "iPadOS captured XCTest synthesized Command-comma"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            throw XCTSkip(
                "XCTest synthesized ⌘, was routed to iPadOS Settings before "
                    + "the Codex responder chain. ⌘K and ⌘/ reached Codex; "
                    + "the remaining ⌘, acceptance gate requires a real "
                    + "hardware-keyboard event."
            )
        }

        XCTFail(
            "The released ⌘, shortcut neither opened Codex Settings nor "
                + "produced the observed iPadOS Settings capture."
        )

    }

    @MainActor
    func testCurrentAccountDesktopFileSearchShortcut() throws {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )
        let readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: releasedSurfaceBudget)
        )
        try skipCurrentAccountFlowWhenSignedOut(readySurface)

        app.typeKey("p", modifierFlags: .command)
        let fileSearch = readySurface.textFields.matching(
            NSPredicate(
                format:
                    "placeholderValue == %@ OR placeholderValue == %@",
                "Search files",
                "搜索文件"
            )
        ).firstMatch
        XCTAssertTrue(
            fileSearch.waitForExistence(timeout: 10),
            "The released ⌘P shortcut did not open file search."
        )
    }

    @MainActor
    func testCurrentAccountThreadSidebarAndNewChatComposerAreNavigable() throws {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )

        let readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: releasedSurfaceBudget),
            "The persisted account did not return to the released surface."
        )
        try skipCurrentAccountFlowWhenSignedOut(readySurface)

        // The released 26.814.41407 renderer exposes Recents as a sidebar
        // section heading, not as a button.  Query the rendered accessibility
        // tree without assuming a control role; the actual thread rows below
        // the heading remain buttons.
        let recents = readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR label == %@ OR label == %@",
                "Recents",
                "最近",
                "最近会话"
            )
        ).firstMatch
        XCTAssertTrue(
            recents.waitForExistence(timeout: 10),
            "The persisted main surface did not expose Recents."
        )

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
            "The current account did not expose New Chat."
        )
        newChat.tap()

        let composer = readySurface.textViews.matching(
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
        XCTAssertTrue(
            composer.waitForExistence(timeout: 10),
            "Starting a new chat did not expose the released composer."
        )

        let sendButton = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Send",
                "发送"
            )
        ).firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))

        // The released iPad WebKit tree places the model selector beside the
        // composer and Send control, not inside the editor-toolbar subtree.
        // WebKit has exposed this renderer control as different XCUI element
        // types across iPadOS releases. Match its released label across the
        // complete accessibility tree instead of assuming `otherElements`.
        let modelSelector = readySurface.descendants(matching: .any)
            .allElementsBoundByIndex
            .first { element in
                ["Sol", "Codex", "GPT", "DeepSeek"].contains { token in
                    element.label.localizedCaseInsensitiveContains(token)
                }
            }
        XCTAssertNotNil(
            modelSelector,
            "Starting a new chat did not expose the released model selector."
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "S03 Thread sidebar and new chat composer on physical iPad"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testCurrentAccountCanSendReceiveAndRestoreARealThread() throws {
        let app = XCUIApplication()
        app.launchEnvironment[
            "CODEXPAD_UI_TEST_ANCHOR_DIAGNOSTIC"
        ] = "1"
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )

        var readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: releasedSurfaceBudget),
            "The persisted account did not return to the released surface."
        )
        try skipCurrentAccountFlowWhenSignedOut(readySurface)

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
            "The current account did not expose New Chat."
        )
        newChat.tap()

        let webComposer = readySurface.textViews.matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ "
                    + "OR label CONTAINS[c] %@ "
                    + "OR placeholderValue CONTAINS[c] %@",
                "Do anything",
                "做任何事",
                "随心输入",
                "给 ChatGPT 发消息",
                "Codex",
                "Codex"
            )
        ).firstMatch
        let nativeComposer = app.textFields["codex.composer.input"]
        let composerAvailable = webComposer.waitForExistence(timeout: 10)
            || nativeComposer.waitForExistence(timeout: 10)
        XCTAssertTrue(
            composerAvailable,
            "Starting a new chat did not expose the released composer."
        )

        let responseMarker = "S04_DEVICE_RESPONSE_OK"
        let composer = webComposer.exists ? webComposer : nativeComposer
        composer.tap()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        composer.typeText("Reply with \(responseMarker) only.")

        let webSend = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Send",
                "发送"
            )
        ).firstMatch
        let nativeSend = app.buttons["Send message"]
        let send = webSend.exists ? webSend : nativeSend
        XCTAssertTrue(
            send.waitForExistence(timeout: 10),
            "Entering a prompt did not expose the released send action."
        )
        XCTAssertTrue(
            send.isEnabled,
            "Entering a prompt did not enable the released send action."
        )
        send.tap()

        let streamState = app.descendants(matching: .any)[
            "CodexLastFetchStreamState"
        ]
        XCTAssertTrue(
            streamState.waitForExistence(timeout: 5),
            "The native fetch-stream diagnostic was unavailable."
        )

        let streamDeadline = Date().addingTimeInterval(180)
        var terminalStreamState: String?
        while Date() < streamDeadline {
            let state = streamState.label
            if state == "error" || state == "cancelled" {
                terminalStreamState = state
                break
            }
            if state == "complete" {
                terminalStreamState = state
                break
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(0.25)
            )
        }
        guard terminalStreamState == "complete" else {
            XCTFail(
                "The physical iPad stream ended in state "
                    + (terminalStreamState ?? streamState.label)
                    + "."
            )
            return
        }

        let response = readySurface.staticTexts.matching(
            NSPredicate(
                format: "label == %@",
                responseMarker
            )
        ).firstMatch
        XCTAssertTrue(
            response.exists,
            "The completed physical iPad stream did not render the expected model response."
        )

        let responseScreenshot = XCTAttachment(screenshot: app.screenshot())
        responseScreenshot.name = "S04 Real response on physical iPad"
        responseScreenshot.lifetime = .keepAlways
        add(responseScreenshot)

        let anchorDiagnostic =
            app.descendants(matching: .any)[
                "CodexLastActiveThreadAnchor"
            ]
        XCTAssertTrue(
            anchorDiagnostic.waitForExistence(timeout: 5),
            "The pre-termination thread-anchor diagnostic was unavailable."
        )
        XCTAssertEqual(
            anchorDiagnostic.label,
            "present",
            "The completed thread anchor was already missing before termination."
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )
        readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: releasedSurfaceBudget),
            "Relaunching after a completed response did not restore the released surface."
        )

        let restoredResponse = readySurface.staticTexts.matching(
            NSPredicate(
                format: "label == %@",
                responseMarker
            )
        ).firstMatch
        XCTAssertTrue(
            restoredResponse.waitForExistence(timeout: 30),
            "Relaunching did not restore the completed thread response."
        )

        let restoredScreenshot = XCTAttachment(screenshot: app.screenshot())
        restoredScreenshot.name = "S04 Restored response after relaunch"
        restoredScreenshot.lifetime = .keepAlways
        add(restoredScreenshot)
    }

    @MainActor
    func testFreshOAuthLoginCommitsCredentialsAndSurvivesColdRelaunch()
        throws
    {
        #if CODEXPAD_FRESH_OAUTH_UI_TEST
        let freshOAuthEnabled = true
        #else
        let freshOAuthEnabled =
            ProcessInfo.processInfo.environment[
                "CODEXPAD_RUN_FRESH_OAUTH_UI_TEST"
            ] == "1"
        #endif
        guard freshOAuthEnabled else {
            throw XCTSkip(
                "Fresh OAuth is a manual physical-device gate; set "
                    + "CODEXPAD_RUN_FRESH_OAUTH_UI_TEST=1 to run it."
            )
        }
        let app = XCUIApplication()
        // Present the signed-out surface without deleting the previous
        // Keychain revision. A failed browser run is therefore non-destructive,
        // while a successful run must replace it through the real OAuth path.
        app.launchEnvironment["CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"] = "1"
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )

        var readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: releasedSurfaceBudget),
            "The forced signed-out run did not reach the released surface."
        )
        let signIn = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Continue to sign in",
                "继续登录"
            )
        ).firstMatch
        XCTAssertTrue(
            signIn.waitForExistence(timeout: 10),
            "The forced signed-out run did not expose browser login."
        )
        signIn.tap()
        acceptAuthenticationServicesFirstUsePromptIfNeeded()

        let signedInDeadline = Date().addingTimeInterval(150)
        var signedIn = false
        var lastBrowserState = FreshOAuthBrowserState.browserOpen
        var lastAutomaticAction: FreshOAuthBrowserState?
        while Date() < signedInDeadline {
            if releasedSignedInMarker(in: readySurface).exists {
                signedIn = true
                break
            }
            let browserState = freshOAuthBrowserState(in: app)
            lastBrowserState = browserState
            if lastBrowserState.requiresManualCredentialInput {
                throw XCTSkip(
                    "Fresh OAuth requires manual credential input on this device."
                )
            }
            if browserState != lastAutomaticAction,
               advanceFreshOAuthBrowserIfSafe(
                   browserState,
                   in: app
               )
            {
                lastAutomaticAction = browserState
            } else if !browserState.permitsAutomaticContinuation {
                lastAutomaticAction = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        if !signedIn {
            // Do not attach the full hierarchy here. The system keyboard can
            // expose account suggestions in it. A compact state is sufficient
            // to distinguish a callback failure from a page that still needs
            // user input without persisting credentials or account details.
            let diagnostic = XCTAttachment(
                string: """
                browserState=\(lastBrowserState.rawValue)
                signedInMarker=false
                keychainPersistenceError=\(
                    app.staticTexts[
                        "Credentials could not be saved"
                    ].exists
                )
                """
            )
            diagnostic.name = "Fresh OAuth redacted browser state"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
        }
        XCTAssertTrue(
            signedIn,
            "Fresh OAuth did not return to the signed-in Codex surface."
        )
        XCTAssertFalse(
            app.staticTexts["Credentials could not be saved"].exists,
            "Fresh OAuth still reported a Keychain persistence failure."
        )

        let loginScreenshot = XCTAttachment(screenshot: app.screenshot())
        loginScreenshot.name = "Fresh OAuth committed on physical iPad"
        loginScreenshot.lifetime = .keepAlways
        add(loginScreenshot)

        app.terminate()
        app.launchEnvironment.removeValue(
            forKey: "CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"
        )
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget)
        )
        readySurface = app.webViews["CodexDesktopSurfaceReady"]
        XCTAssertTrue(
            readySurface.waitForExistence(timeout: releasedSurfaceBudget),
            "Cold relaunch did not return to the released surface."
        )
        XCTAssertTrue(
            releasedSignedInMarker(in: readySurface).waitForExistence(
                timeout: 30
            ),
            "Cold relaunch did not restore the newly committed OAuth revision."
        )
        XCTAssertFalse(
            readySurface.buttons["Continue to sign in"].exists,
            "Cold relaunch returned to signed-out state after fresh OAuth."
        )
    }

    @MainActor
    private func releasedSignedInMarker(
        in readySurface: XCUIElement
    ) -> XCUIElement {
        readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label == %@ "
                    + "OR label BEGINSWITH %@ OR label BEGINSWITH %@",
                "Open profile menu",
                "打开个人资料菜单",
                "New Chat",
                "新聊天",
                "新对话",
                "Send",
                "发送",
                "Change project:",
                "切换项目："
            )
        ).firstMatch
    }

    @MainActor
    private func releasedAuthenticationSuccessMarker(
        in readySurface: XCUIElement
    ) -> XCUIElement {
        readySurface.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label BEGINSWITH %@ "
                    + "OR label BEGINSWITH %@",
                "Open profile menu",
                "打开个人资料菜单",
                "New Chat",
                "新聊天",
                "新对话",
                "What type of work do you do?",
                "你是做什么工作的？",
                "Send",
                "发送",
                "Change project:",
                "切换项目："
            )
        ).firstMatch
    }

    @MainActor
    private func completeReleasedWelcomeIfNeeded(
        in readySurface: XCUIElement
    ) {
        let roleTitle = readySurface.staticTexts.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "What type of work do you do?",
                "你是做什么工作的？"
            )
        ).firstMatch
        guard roleTitle.exists else { return }

        // The released renderer exposes its role pills as ARIA switches,
        // rather than buttons. Query the semantic control emitted by the
        // desktop bundle so this assertion follows the actual surface.
        let engineering = readySurface.switches.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Engineering",
                "工程"
            )
        ).firstMatch
        XCTAssertTrue(
            engineering.waitForExistence(timeout: 10),
            "The released welcome flow did not expose the Engineering role."
        )
        engineering.tap()

        let continueButton = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Continue",
                "继续"
            )
        ).firstMatch
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 10),
            "The released welcome flow did not enable Continue after role selection."
        )
        let continueEnabled = NSPredicate(format: "enabled == true")
        let enablement = XCTNSPredicateExpectation(
            predicate: continueEnabled,
            object: continueButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enablement], timeout: 10),
            .completed,
            "The released welcome flow kept Continue disabled after role selection."
        )
        continueButton.tap()
    }

    @MainActor
    private func tapReleasedRendererItem(_ item: XCUIElement) {
        if item.isHittable {
            item.tap()
            return
        }

        // iOS 27 WebKit can expose a rendered menu item's visible text while
        // marking the text node itself non-hittable. It can also report a
        // desktop popover row with the correct origin but an erroneous
        // ~1,200 pt accessibility height. Tap inside the reported element
        // instead of substituting a native shortcut; this still exercises the
        // released renderer action.
        let normalizedY = item.frame.height > 100 ? 0.005 : 0.5
        item.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: normalizedY)
        ).tap()
    }

    @MainActor
    private func apiKeyPersistenceFailure(
        in readySurface: XCUIElement
    ) -> XCUIElement {
        readySurface.staticTexts.matching(
            NSPredicate(
                format:
                    "label CONTAINS[c] %@ OR label CONTAINS[c] %@ "
                    + "OR label CONTAINS[c] %@",
                "Failed to save API key",
                "API key could not be saved",
                "Keychain"
            )
        ).firstMatch
    }

    @MainActor
    private func releasedProviderBoundaryTerminalError(
        in readySurface: XCUIElement
    ) -> XCUIElement {
        readySurface.descendants(matching: .any).matching(
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
    func testCurrentSurfacePublishesOneNativeAccessibilityState() {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: releasedSurfaceBudget),
            "Codex for ipad did not enter the foreground."
        )

        let loading = app.webViews["CodexDesktopSurfaceLoading"]
        let ready = app.webViews["CodexDesktopSurfaceReady"]
        let failed = app.webViews["CodexDesktopSurfaceFailed"]
        let didReachReady = ready.waitForExistence(
            timeout: releasedSurfaceBudget
        )

        let publishedStates = [
            "loading": loading.exists,
            "ready": ready.exists,
            "failed": failed.exists,
        ].filter(\.value).map(\.key).sorted()
        print(
            "codexpad-native-surface-ready=\(didReachReady) "
                + "final-state=\(publishedStates)"
        )
        XCTAssertTrue(
            didReachReady,
            "The physical iPad did not reach CodexDesktopSurfaceReady "
                + "within \(releasedSurfaceBudget) seconds; "
                + "final native state was \(publishedStates)."
        )
        XCTAssertEqual(
            publishedStates,
            ["ready"],
            "The physical app must finish with only the ready surface."
        )
    }

    private enum FreshOAuthBrowserState: String {
        case emailInputRequired
        case emailReady
        case passwordInputRequired
        case passwordReady
        case verificationInputRequired
        case verificationReady
        case passkeyInteractionRequired
        case accountSelectionRequired
        case accountSelectionReady
        case authorizationReady
        case browserOpen

        var permitsAutomaticContinuation: Bool {
            switch self {
            case .emailReady,
                 .passwordReady,
                 .verificationReady,
                 .accountSelectionReady,
                 .authorizationReady:
                true
            default:
                false
            }
        }

        var requiresManualCredentialInput: Bool {
            switch self {
            case .emailInputRequired,
                 .passwordInputRequired,
                 .verificationInputRequired,
                 .passkeyInteractionRequired:
                true
            default:
                false
            }
        }
    }

    @MainActor
    private func freshOAuthBrowserState(
        in app: XCUIApplication
    ) -> FreshOAuthBrowserState {
        let emailField = app.textFields.matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ "
                    + "OR placeholderValue == %@ "
                    + "OR placeholderValue == %@",
                "Email address",
                "电子邮件地址",
                "Email address",
                "电子邮件地址"
            )
        ).firstMatch
        if emailField.exists {
            return fieldContainsUserInput(emailField)
                ? .emailReady
                : .emailInputRequired
        }

        let passwordField = app.secureTextFields.matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ "
                    + "OR placeholderValue == %@ "
                    + "OR placeholderValue == %@",
                "Password",
                "密码",
                "Password",
                "密码"
            )
        ).firstMatch
        if passwordField.exists {
            return fieldContainsUserInput(passwordField)
                ? .passwordReady
                : .passwordInputRequired
        }

        let verificationField = app.textFields.matching(
            NSPredicate(
                format:
                    "label CONTAINS[c] %@ OR label CONTAINS %@ "
                    + "OR placeholderValue CONTAINS[c] %@ "
                    + "OR placeholderValue CONTAINS %@",
                "verification code",
                "验证码",
                "verification code",
                "验证码"
            )
        ).firstMatch
        if verificationField.exists {
            return fieldContainsUserInput(verificationField)
                ? .verificationReady
                : .verificationInputRequired
        }

        let passkeyMarker = app.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label CONTAINS[c] %@ OR label CONTAINS %@ "
                    + "OR label CONTAINS %@",
                "passkey",
                "通行密钥",
                "面容 ID"
            )
        ).firstMatch
        if passkeyMarker.exists {
            return .passkeyInteractionRequired
        }

        let accountSelection = app.buttons.matching(
            NSPredicate(
                format:
                    "label BEGINSWITH[c] %@ OR label BEGINSWITH %@",
                "Continue as ",
                "以此账户继续"
            )
        ).firstMatch
        if accountSelection.exists {
            return accountSelection.isHittable
                ? .accountSelectionReady
                : .accountSelectionRequired
        }

        if browserAuthorizationButton(in: app).exists {
            return .authorizationReady
        }

        return .browserOpen
    }

    @MainActor
    private func advanceFreshOAuthBrowserIfSafe(
        _ state: FreshOAuthBrowserState,
        in app: XCUIApplication
    ) -> Bool {
        let button: XCUIElement
        switch state {
        case .emailReady, .passwordReady, .verificationReady:
            button = browserFormContinueButton(in: app)
        case .accountSelectionReady:
            button = app.buttons.matching(
                NSPredicate(
                    format:
                        "label BEGINSWITH[c] %@ OR label BEGINSWITH %@",
                    "Continue as ",
                    "以此账户继续"
                )
            ).firstMatch
        case .authorizationReady:
            button = browserAuthorizationButton(in: app)
        default:
            return false
        }
        guard button.exists, button.isHittable else {
            return false
        }
        button.tap()
        return true
    }

    @MainActor
    private func browserFormContinueButton(
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Continue",
                "继续"
            )
        ).firstMatch
    }

    @MainActor
    private func browserAuthorizationButton(
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format:
                    "label == %@ OR label == %@ OR label == %@ "
                    + "OR label == %@ OR label == %@ OR label == %@",
                "Allow",
                "Authorize",
                "Yes, continue",
                "Continue with ChatGPT",
                "允许",
                "授权"
            )
        ).firstMatch
    }

    @MainActor
    private func fieldContainsUserInput(
        _ field: XCUIElement
    ) -> Bool {
        guard let rawValue = field.value as? String else {
            return false
        }
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else {
            return false
        }
        let placeholder = field.placeholderValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value != placeholder && value != field.label
    }

    @MainActor
    private func skipCurrentAccountFlowWhenSignedOut(
        _ readySurface: XCUIElement
    ) throws {
        let signIn = readySurface.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Continue to sign in",
                "继续登录"
            )
        ).firstMatch
        if signIn.waitForExistence(timeout: 2) {
            throw XCTSkip(
                "Current-account flow requires persisted simulator authentication."
            )
        }
    }
}
