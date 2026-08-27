import tempfile
import unittest
from pathlib import Path

from scripts.build_recovered_source_index import index_source_tree


class BuildRecoveredSourceIndexTests(unittest.TestCase):
    def test_indexes_dependencies_routes_messages_and_categories(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "thread-settings.js"
            source.write_text(
                """
                import value from "./dependency.js";
                const lazy = import("./lazy.js");
                const route = "/settings/general-settings";
                const message = {
                  id: "settings.general.title",
                  defaultMessage: "General"
                };
                """,
                encoding="utf-8",
            )

            index = index_source_tree(root)

            self.assertEqual(index["moduleCount"], 1)
            self.assertEqual(index["dependencyEdgeCount"], 2)
            self.assertEqual(
                index["uiRouteCandidates"],
                ["/settings/general-settings"],
            )
            self.assertEqual(index["messageCount"], 1)
            self.assertEqual(
                index["modules"][0]["categories"],
                ["conversation-thread", "settings"],
            )

    def test_output_is_deterministic_by_path_and_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "z.js").write_text(
                '({id:"z",defaultMessage:"Zulu"})',
                encoding="utf-8",
            )
            (root / "a.js").write_text(
                '({id:"a",defaultMessage:"Alpha"})',
                encoding="utf-8",
            )

            index = index_source_tree(root)

            self.assertEqual(
                [module["path"] for module in index["modules"]],
                ["a.js", "z.js"],
            )
            self.assertEqual(
                [message["id"] for message in index["messages"]],
                ["a", "z"],
            )


if __name__ == "__main__":
    unittest.main()
