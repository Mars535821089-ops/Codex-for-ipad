from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).parents[1]


class TurnDiffUIContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root_view = (
            ROOT
            / "CodexPad"
            / "CodexPad"
            / "Presentation"
            / "CodexRootView.swift"
        ).read_text(encoding="utf-8")
        self.persisted_view = (
            ROOT
            / "CodexPad"
            / "CodexPad"
            / "Presentation"
            / "PersistedThreadDetailView.swift"
        ).read_text(encoding="utf-8")
        self.thread_view = (
            ROOT
            / "CodexPad"
            / "CodexPad"
            / "Presentation"
            / "ThreadDetailView.swift"
        ).read_text(encoding="utf-8")

    def test_root_forwards_the_current_resumed_turn_diff(self) -> None:
        self.assertIn(
            "latestDiff: store.resumedTurnState.latestDiff",
            self.root_view,
        )

    def test_root_routes_notifications_through_the_captured_selection(
        self,
    ) -> None:
        selection = self.root_view.index(
            "store.selectResumedTurnThread(storedThreadID)"
        )
        capture = self.root_view.index(
            "let turnSelectionGeneration = "
            "store.resumedTurnState.selectionGeneration"
        )
        callback = self.root_view.index("onTurnNotification: { notification in")
        receive = self.root_view.index(
            "store.receiveTurnNotification("
            "\n                        notification,"
        )

        self.assertLess(selection, capture)
        self.assertLess(capture, callback)
        self.assertLess(callback, receive)
        self.assertIn(
            "selectionGeneration: turnSelectionGeneration",
            self.root_view,
        )

    def test_persisted_thread_has_an_expandable_latest_changes_panel(
        self,
    ) -> None:
        self.assertIn("let latestDiff: String?", self.persisted_view)
        self.assertIn(
            'DisclosureGroup("Changes", isExpanded: $changesExpanded)',
            self.persisted_view,
        )
        self.assertIn(
            "UnifiedDiffView(diff: latestDiff)",
            self.persisted_view,
        )
        self.assertIn(
            '"codex.persisted-thread.latest-diff"',
            self.persisted_view,
        )

    def test_unified_diff_renderer_is_shared_by_live_and_persisted_views(
        self,
    ) -> None:
        self.assertIn("struct UnifiedDiffView: View", self.thread_view)
        self.assertNotIn(
            "private struct UnifiedDiffView: View",
            self.thread_view,
        )


if __name__ == "__main__":
    unittest.main()
