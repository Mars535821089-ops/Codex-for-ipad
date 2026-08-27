from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile

from scripts.audit_ipad_interaction_coverage import audit


def test_cli_require_complete_rejects_missing_or_unexpected_markers() -> None:
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory() as temporary:
        temporary_root = Path(temporary)
        inventory = temporary_root / "inventory.json"
        plan = temporary_root / "plan.json"
        ui_test = temporary_root / "ParityUITests.swift"
        output = temporary_root / "report.json"
        inventory.write_text(
            json.dumps({
                "desktopVersion": "26.810.52044",
                "desktopBuild": "6662",
                "sourceIdentity": {"desktopSurfaceTreeSha256": "abc"},
                "surfaces": [{"interactionCount": 1}],
            }),
            encoding="utf-8",
        )
        plan.write_text(
            json.dumps({
                "schemaVersion": 1,
                "captures": [{
                    "surfaceId": "S01",
                    "captureKey": "00__launch",
                    "route": "/login",
                    "state": "launch",
                }],
            }),
            encoding="utf-8",
        )
        ui_test.write_text(
            'interactionAcceptance.append("S01|99__wrong|/login|wrong")',
            encoding="utf-8",
        )

        result = subprocess.run(
            [
                sys.executable,
                str(root / "scripts/audit_ipad_interaction_coverage.py"),
                "--inventory", str(inventory),
                "--capture-plan", str(plan),
                "--ui-test", str(ui_test),
                "--output", str(output),
                "--require-complete",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        assert result.returncode == 1
        assert "static interaction coverage is incomplete" in result.stderr
        report = json.loads(output.read_text(encoding="utf-8"))
        assert report["missingCaptureCount"] == 1
        assert report["unexpectedMarkerCount"] == 1


def test_audit_is_conservative_and_reports_missing_physical_states() -> None:
    inventory = {
        "desktopVersion": "26.810.52044",
        "desktopBuild": "6662",
        "sourceIdentity": {"desktopSurfaceTreeSha256": "abc"},
        "surfaces": [{"interactionCount": 4553}],
    }
    plan = {
        "schemaVersion": 1,
        "captures": [
            {
                "surfaceId": "S01",
                "captureKey": "00__launch",
                "route": "/login",
                "state": "launch",
            },
            {
                "surfaceId": "S01",
                "captureKey": "01__signed-out",
                "route": "/login",
                "state": "signed-out",
            },
        ],
    }

    report = audit(
        inventory,
        plan,
        'interactionAcceptance.append("S01|00__launch|/login|launch")',
    )

    assert report["staticEvidenceOnly"] is True
    assert report["interactionCount"] == 4553
    assert report["requiredCaptureCount"] == 2
    assert report["coveredCaptureCount"] == 1
    assert report["missingCaptureCount"] == 1
    assert report["coveragePercent"] == 50.0
    assert report["missing"] == ["S01|01__signed-out|/login|signed-out"]


def test_audit_allows_explicit_iPad_acceptance_only_markers() -> None:
    marker = "S08|15__search|/settings/mcp-settings|not-exposed-on-ipad-sidebar"
    report = audit(
        {
            "desktopVersion": "26.814.41957",
            "desktopBuild": "6744",
            "sourceIdentity": {},
            "surfaces": [],
        },
        {
            "schemaVersion": 1,
            "captures": [],
            "acceptedNonCaptureMarkers": [marker],
        },
        f'interactionAcceptance.append("{marker}")',
    )

    assert report["unexpectedMarkerCount"] == 0
    assert report["acceptedNonCaptureMarkerCount"] == 1
    assert report["acceptedNonCaptureMarkers"] == [marker]


def test_checked_in_coverage_report_matches_current_sources() -> None:
    root = Path(__file__).resolve().parents[1]
    report = json.loads(
        (root / "artifacts/ipad-interaction-coverage-26.810.52044.json")
        .read_text(encoding="utf-8")
    )
    assert report["desktopVersion"] == "26.810.52044"
    assert report["desktopBuild"] == "6662"
    assert report["staticEvidenceOnly"] is True
    assert report["requiredCaptureCount"] == 111
    assert report["coveredCaptureCount"] == 111
    assert report["missingCaptureCount"] == 0
    assert report["coveragePercent"] == 100.0
    assert report["unexpectedMarkerCount"] == 0


def test_primary_search_capture_uses_visible_command_menu_new_chat_action() -> None:
    root = Path(__file__).resolve().parents[1]
    ui_test = (
        root
        / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
    ).read_text(encoding="utf-8")

    search_start = ui_test.index("let search = readySurface.buttons.matching(")
    new_chat_start = ui_test.index(
        "let newChat = readySurface.buttons.matching(",
        search_start,
    )
    search_flow = ui_test[search_start:new_chat_start]

    assert 'captureOfficialRenderer(\n                    "CODEXPAD_PARITY_S02__08__sidebar-expanded"' in search_flow
    assert 'format: "label BEGINSWITH[c] %@"' in search_flow
    assert '"New chat"' in search_flow
    assert "commandMenuNewChat.tap()" in search_flow


def test_new_chat_flow_does_not_create_a_second_chat_after_command_menu_success() -> None:
    root = Path(__file__).resolve().parents[1]
    ui_test = (
        root
        / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
    ).read_text(encoding="utf-8")

    command_tap = ui_test.index("commandMenuNewChat.tap()")
    workspace_selection = ui_test.index(
        "selectParityWorkspace(in: readySurface)",
        command_tap,
    )
    new_chat_flow = ui_test[command_tap:workspace_selection]

    assert "if !composer.waitForExistence(timeout: 10)" in new_chat_flow
    fallback_start = new_chat_flow.index(
        "if !composer.waitForExistence(timeout: 10)"
    )
    assert new_chat_flow.index("newChat.tap()") > fallback_start


def test_project_selector_accepts_both_official_unselected_and_selected_labels() -> None:
    root = Path(__file__).resolve().parents[1]
    ui_test = (
        root
        / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
    ).read_text(encoding="utf-8")

    selector_start = ui_test.index(
        "private func selectParityWorkspace(in surface: XCUIElement)"
    )
    selector_end = ui_test.index("private func", selector_start + 20)
    selector_flow = ui_test[selector_start:selector_end]

    assert '"Choose project"' in selector_flow
    assert '"Change project:"' in selector_flow
    assert "projectControl.tap()" in selector_flow
    assert '"Parity Git Workspace"' in selector_flow


def test_sidebar_and_home_acceptance_paths_cover_real_released_controls() -> None:
    root = Path(__file__).resolve().parents[1]
    ui_test = (
        root
        / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
    ).read_text(encoding="utf-8")

    required_markers = {
        "S02|02__filter-all|/|filter-all",
        "S02|03__filter-chat|/|filter-chat",
        "S02|04__filter-work|/|filter-work",
        "S02|08__sidebar-expanded|/global/search|sidebar-expanded",
        "S03|01__home-codex|/|home-codex",
        "S03|02__home-work|/|home-work",
        "S03|03__temporary-chat|/extension/panel/new|temporary-chat",
        "S03|05__projects-populated|/projects|projects-populated",
        "S03|06__projects-search|/projects|projects-search",
    }

    for marker in required_markers:
        assert f'interactionAcceptance.append("{marker}")' in ui_test

    assert '"Filter chats and work"' in ui_test
    assert '"Switch mode, current mode: Codex"' in ui_test
    assert '"Switch mode, current mode: Work"' in ui_test
    assert '"Search projects"' in ui_test


def test_conversation_acceptance_paths_cover_observed_runtime_states() -> None:
    root = Path(__file__).resolve().parents[1]
    ui_test = (
        root
        / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
    ).read_text(encoding="utf-8")

    required_markers = {
        "S04|00__empty-composer|/local/:conversationId|empty-composer",
        "S04|01__streaming|/local/:conversationId|streaming",
        "S04|02__working|/local/:conversationId|working",
        "S04|03__queued|/local/:conversationId|queued",
        "S04|08__reconnecting|/local/:conversationId|reconnecting",
    }

    for marker in required_markers:
        assert f'interactionAcceptance.append("{marker}")' in ui_test

    assert '"Stop"' in ui_test
    assert '"Queued"' in ui_test
    assert '"Reconnecting"' in ui_test


def test_panel_acceptance_paths_require_observed_renderer_states() -> None:
    root = Path(__file__).resolve().parents[1]
    ui_test = (
        root
        / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
    ).read_text(encoding="utf-8")

    required_markers = {
        "S05|00__files|/local/:conversationId|files",
        "S05|01__side-chat|/local/:conversationId|side-chat",
        "S05|02__browser|/local/:conversationId|browser",
        "S05|03__review|/local/:conversationId|review",
        "S05|04__detail|/local/:conversationId|detail",
        "S05|05__terminal-bottom|/local/:conversationId|terminal-bottom",
        "S05|06__terminal-right|/local/:conversationId|terminal-right",
        "S05|07__panel-resize|/local/:conversationId|panel-resize",
        "S05|08__panel-collapsed|/local/:conversationId|panel-collapsed",
    }

    for marker in required_markers:
        assert marker in ui_test

    assert "interactionAcceptance.append(target.marker)" in ui_test


def test_review_diff_acceptance_paths_require_observed_official_states() -> None:
    root = Path(__file__).resolve().parents[1]
    ui_test = (
        root
        / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
    ).read_text(encoding="utf-8")

    required_markers = {
        "S06|00__unified|/diff|unified",
        "S06|01__split|/diff|split",
        "S06|02__staged|/diff|staged",
        "S06|03__unstaged|/diff|unstaged",
        "S06|04__last-turn|/diff|last-turn",
        "S06|05__comments|/diff|comments",
        "S06|06__conflict|/diff|conflict",
        "S06|07__revert-confirmation|/diff|revert-confirmation",
        "S06|08__commit|/diff|commit",
        "S06|09__empty|/diff|empty",
        "S06|10__error|/diff|error",
    }
    official_labels = {
        "Review options",
        "Switch to split diff",
        "Switch to unified diff",
        "Uncommitted",
        "Unstaged",
        "Staged",
        "Last turn",
        "Comment on line",
        "File has merge conflicts",
        "Revert all",
        "Revert changes?",
        "Confirm",
        "Cancel",
        "Commit",
        "Commit message",
        "No file changes yet",
        "Diff failed to render",
        "Diff failed to load after retrying",
    }

    assert "captureS06ReviewStates(" in ui_test
    helper_start = ui_test.index("private func captureS06ReviewStates(")
    helper_end = ui_test.index("\n    @MainActor", helper_start + 1)
    helper = ui_test[helper_start:helper_end]

    for marker in required_markers:
        assert marker in helper
    for label in official_labels:
        assert f'"{label}"' in helper

    # S06 evidence must be emitted through observed targets, never by an
    # unconditional append that can turn static source text into fake parity.
    assert "interactionAcceptance.append(target.marker)" in helper
    assert 'interactionAcceptance.append("S06|' not in helper


def test_terminal_acceptance_paths_require_observed_official_states() -> None:
    root = Path(__file__).resolve().parents[1]
    ui_test = (
        root
        / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
    ).read_text(encoding="utf-8")

    required_markers = {
        "S07|01__input|/local/:conversationId|input",
        "S07|02__output|/local/:conversationId|output",
        "S07|03__resized|/local/:conversationId|resized",
        "S07|04__reconnecting|/local/:conversationId|reconnecting",
        "S07|05__exited|/local/:conversationId|exited",
        "S07|06__workspace-mismatch|/local/:conversationId|workspace-mismatch",
    }
    official_labels = {
        "Terminal input",
        "Resize panels",
        "Reconnecting…",
        "This terminal's workspace does not match this chat's current worktree",
        "Open new terminal",
    }

    assert "captureS07TerminalStates(" in ui_test
    helper_start = ui_test.index("private func captureS07TerminalStates(")
    helper_end = ui_test.index("\n    @MainActor", helper_start + 1)
    helper = ui_test[helper_start:helper_end]

    for marker in required_markers:
        assert marker in helper
    for label in official_labels:
        assert f'"{label}"' in helper

    # S07 evidence is emitted only after the released renderer exposes or
    # transitions through the target state. Static marker text alone is not
    # physical-device parity evidence.
    assert "interactionAcceptance.append(target.marker)" in helper
    assert 'interactionAcceptance.append("S07|' not in helper


def test_settings_acceptance_paths_require_observed_official_states() -> None:
    root = Path(__file__).resolve().parents[1]
    ui_test = (
        root
        / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
    ).read_text(encoding="utf-8")

    required_markers = {
        "S08|00__search|/settings|search",
        "S08|01__search-empty|/settings|search-empty",
        "S08|02__personal|/settings/profile|personal",
        "S08|03__integrations|/settings/connections|integrations",
        "S08|04__coding|/settings/agent|coding",
        "S08|05__archived|/settings/data-controls|archived",
        "S08|06__managed|/settings/general-settings|managed",
        "S08|07__read-only|/settings/general-settings|read-only",
        "S08|08__shortcut-conflict|/settings/keyboard-shortcuts|shortcut-conflict",
        "S08|09__shortcut-override|/settings/keyboard-shortcuts|shortcut-override",
        "S08|10__search|/settings/appearance|search",
        "S08|11__search|/settings/git-settings|search",
        "S08|12__search|/settings/usage|search",
        "S08|13__search|/settings/browser-use|search",
        "S08|14__search|/settings/computer-use|search",
        "S08|15__search|/settings/mcp-settings|search",
        "S08|16__search|/settings/plugins-settings|search",
        "S08|17__search|/settings/skills-settings|search",
    }
    official_labels = {
        "Search settings…",
        "No results found",
        "Personal",
        "Profile",
        "Integrations",
        "Connections",
        "Coding",
        "Configuration",
        "Archived",
        "Archived chats",
        "General",
        "Managed",
        "Controlled by your administrator",
        "Keyboard shortcuts",
        "Search by keystrokes",
        "Shortcut capture for",
        "Appearance",
        "Git",
        "Usage & billing",
        "Browser",
        "Computer use",
        "MCP servers",
        "Plugins",
        "Skills",
    }

    assert 'app.typeKey(",", modifierFlags: .command)' in ui_test
    assert "captureS08SettingsStates(" in ui_test
    helper_start = ui_test.index("private func captureS08SettingsStates(")
    helper_end = ui_test.index("\n    @MainActor", helper_start + 1)
    helper = ui_test[helper_start:helper_end]

    for marker in required_markers:
        assert marker in helper
    for label in official_labels:
        assert f'"{label}"' in helper

    # S08 route/state evidence is emitted only after its released control or
    # state is observed. Merely embedding a marker must never count as parity.
    assert "interactionAcceptance.append(target.marker)" in helper
    assert 'interactionAcceptance.append("S08|' not in helper


def test_secondary_product_acceptance_requires_real_entries_and_states() -> None:
    root = Path(__file__).resolve().parents[1]
    ui_test = (
        root
        / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
    ).read_text(encoding="utf-8")

    required_markers = {
        "S09|00__loading|/automations|loading",
        "S09|01__empty|/pull-requests|empty",
        "S09|02__populated|/security|populated",
        "S09|03__error|/library|error",
        "S09|04__loading|/sites|loading",
        "S09|05__loading|/plugins|loading",
        "S09|06__loading|/skills|loading",
        "S09|07__loading|/mcp-app/:server/:toolName|loading",
        "S09|08__loading|/codex-mobile|loading",
        "S09|09__loading|/remote-connections|loading",
        "S09|10__loading|/connector/oauth_callback|loading",
    }
    official_labels = {
        "Scheduled tasks",
        "Loading scheduled tasks",
        "Pull requests",
        "No pull requests found",
        "You’re all caught up",
        "Security",
        "Security workbench",
        "Candidate findings",
        "View activity",
        "Library",
        "Unable to load library",
        "Some library items couldn't be loaded",
        "Sites",
        "Loading sites…",
        "Plugins",
        "Loading plugins…",
        "Skills",
        "Loading skills…",
        "Loading MCP app",
        "Set up mobile",
        "Set up remote",
        "Loading device list",
        "Finishing",
        "Missing OAuth callback data",
    }

    assert "captureS09SecondaryProductStates(" in ui_test
    helper_start = ui_test.index("private func captureS09SecondaryProductStates(")
    helper_end = ui_test.index("\n    @MainActor", helper_start + 1)
    helper = ui_test[helper_start:helper_end]

    for marker in required_markers:
        assert marker in helper
    for label in official_labels:
        assert f'"{label}"' in helper

    # Navigation must use released, hittable controls. Dynamic MCP apps are
    # allowed only when the renderer exposes a real mcp:* navigation item.
    assert "entry.waitForExistence" in helper
    assert "entry.isHittable" in helper
    assert 'identifier BEGINSWITH %@", "mcp:"' in helper

    # Acceptance is conditional on a released state label; embedding an S09
    # marker or tapping the Settings Plugins row must not count as parity.
    assert "interactionAcceptance.append(target.marker)" in helper
    assert 'interactionAcceptance.append("S09|' not in helper
    main_flow = ui_test[:helper_start]
    assert 'interactionAcceptance.append("S09|' not in main_flow
    assert 'let plugins = readySurface.buttons["Plugins"]' not in main_flow


def test_global_interaction_acceptance_requires_observed_physical_ipad_states() -> None:
    root = Path(__file__).resolve().parents[1]
    ui_test = (
        root
        / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
    ).read_text(encoding="utf-8")

    required_markers = {
        "S10|01__file-search|*|file-search",
        "S10|02__context-menu|*|context-menu",
        "S10|03__tooltip|*|tooltip",
        "S10|04__dropdown|*|dropdown",
        "S10|05__dialog|*|dialog",
        "S10|06__toast|*|toast",
        "S10|07__hover|*|hover",
        "S10|08__focus|*|focus",
        "S10|09__pressed|*|pressed",
        "S10|10__disabled|*|disabled",
        "S10|11__drag|*|drag",
        "S10|12__resize|*|resize",
        "S10|13__portrait|*|portrait",
        "S10|14__landscape|*|landscape",
        "S10|15__stage-manager|*|stage-manager",
    }
    official_labels = {
        "Search files",
        "Copy path",
        "Open in…",
        "Archive chat",
        "Archive chat?",
        "Cancel",
        "Copied",
        "Copied to clipboard",
        "Resize device viewport from the left edge",
        "Resize device viewport from the right edge",
        "Resize device viewport from the bottom edge",
    }

    assert "captureS10GlobalInteractionStates(" in ui_test
    helper_start = ui_test.index("private func captureS10GlobalInteractionStates(")
    helper_end = ui_test.index("\n    @MainActor", helper_start + 1)
    helper = ui_test[helper_start:helper_end]

    for marker in required_markers:
        assert marker in helper
    for label in official_labels:
        assert f'"{label}"' in helper

    # Static marker coverage must remain conditional. Physical-device evidence
    # is emitted only through record(... when:) after observing the real state.
    assert "interactionAcceptance.append(target.marker)" in helper
    assert "guard observed else" in helper
    assert 'interactionAcceptance.append("S10|' not in helper

    # Destructive menu actions may open a confirmation dialog, but the helper
    # must cancel instead of confirming archive/delete behavior.
    assert "cancel.tap()" in helper
    assert "archive.tap()" in helper
    assert "confirm.tap()" not in helper

    # Orientation and resize evidence must be based on an observed frame/state
    # transition rather than an unconditional device rotation or marker.
    assert "XCUIDevice.shared.orientation" in helper
    assert "beforeFrame" in helper
    assert "afterFrame" in helper
    assert "beforeFrame != afterFrame" in helper


def test_remaining_launch_sidebar_project_and_conversation_states_are_conditional() -> None:
    root = Path(__file__).resolve().parents[1]
    ui_test = (
        root
        / "CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift"
    ).read_text(encoding="utf-8")

    helper_markers = {
        "captureS01ConditionalLaunchStates": {
            "S01|06__error|/login|error",
            "S01|07__launch|/welcome|launch",
            "S01|08__launch|/codex-access|launch",
        },
        "captureS02SidebarRuntimeStates": {
            "S02|05__pinned|/|pinned",
            "S02|06__unread|/|unread",
            "S02|07__loading|/|loading",
        },
        "captureS04ConditionalConversationStates": {
            "S04|04__steered|/local/:conversationId|steered",
            "S04|05__approval|/local/:conversationId|approval",
            "S04|06__subagents-active|/local/:conversationId|subagents-active",
            "S04|07__subagents-done|/local/:conversationId|subagents-done",
            "S04|10__empty-composer|/work/conversation/:conversationId|empty-composer",
            "S04|11__empty-composer|/remote/:taskId|empty-composer",
            "S04|12__empty-composer|/chatgpt/quick-chat/:conversationId|empty-composer",
            "S04|13__empty-composer|/hotkey-window/*|empty-composer",
        },
    }
    official_labels = {
        "Oops, an error has occurred",
        "Welcome to ChatGPT",
        "To get more access, contact your admin",
        "Pinned",
        "Unread",
        "Loading chats",
        "No projects",
        "Steer",
        "Awaiting approval",
        "Open subagents",
        "is working",
        "is done",
        "Quick chat",
        "Remote connection unavailable",
    }

    for helper_name, markers in helper_markers.items():
        helper_start = ui_test.index(f"private func {helper_name}(")
        helper_end = ui_test.index("\n    @MainActor", helper_start + 1)
        helper = ui_test[helper_start:helper_end]
        for marker in markers:
            assert marker in helper
        assert "interactionAcceptance.append(target.marker)" in helper
        assert "guard observed else" in helper
        for surface in {marker.split("|", 1)[0] for marker in markers}:
            assert f'interactionAcceptance.append("{surface}|' not in helper

    for label in official_labels:
        assert f'"{label}"' in ui_test

    projects_start = ui_test.index("private func captureProjectsIndexStates(")
    projects_end = ui_test.index("\n    @MainActor", projects_start + 1)
    projects_helper = ui_test[projects_start:projects_end]
    assert "S03|04__projects-empty|/projects|projects-empty" in projects_helper
    assert '"No projects"' in projects_helper
    assert "interactionAcceptance.append(emptyTarget.marker)" in projects_helper
