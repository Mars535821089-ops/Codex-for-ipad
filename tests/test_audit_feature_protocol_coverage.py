from __future__ import annotations

import importlib
import json
from pathlib import Path
import tempfile
import unittest


def load_auditor():
    try:
        return importlib.import_module(
            "scripts.audit_feature_protocol_coverage"
        )
    except ModuleNotFoundError as error:
        raise AssertionError(
            "feature protocol coverage auditor is not implemented"
        ) from error


class AuditFeatureProtocolCoverageTests(unittest.TestCase):
    def test_maps_official_types_to_wire_methods(self) -> None:
        auditor = load_auditor()
        source = """
        client_request_definitions! {
            AppsList => "app/list" {
                params: v2::AppsListParams,
                serialization: None,
                response: v2::AppsListResponse,
            },
            ConfigBatchWrite => "config/batchWrite" {
                params: v2::ConfigBatchWriteParams,
                response: v2::ConfigWriteResponse,
            },
            ConfigValueWrite => "config/value/write" {
                params: v2::ConfigValueWriteParams,
                response: v2::ConfigWriteResponse,
            },
        }
        server_notification_definitions! {
            EnvironmentConnected => "thread/environment/connected"
                (v2::EnvironmentConnectionNotification),
            EnvironmentDisconnected => "thread/environment/disconnected"
                (v2::EnvironmentConnectionNotification),

            #[serde(rename = "account/login/completed")]
            #[ts(rename = "account/login/completed")]
            AccountLoginCompleted(v2::AccountLoginCompletedNotification),
        }
        """

        mapping = auditor.protocol_type_methods(source)

        self.assertEqual(
            mapping["AppsListParams"],
            (("app/list", "params"),),
        )
        self.assertEqual(
            mapping["AppsListResponse"],
            (("app/list", "response"),),
        )
        self.assertEqual(
            mapping["ConfigWriteResponse"],
            (
                ("config/batchWrite", "response"),
                ("config/value/write", "response"),
            ),
        )
        self.assertEqual(
            mapping["EnvironmentConnectionNotification"],
            (
                ("thread/environment/connected", "notification"),
                ("thread/environment/disconnected", "notification"),
            ),
        )
        self.assertEqual(
            mapping["AccountLoginCompletedNotification"],
            (("account/login/completed", "notification"),),
        )

    def test_classifies_complete_partial_missing_and_unmapped_features(
        self,
    ) -> None:
        auditor = load_auditor()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            protocol = root / "common.rs"
            inventory = root / "feature-inventory.json"
            production = root / "production"
            tests = root / "tests"
            production.mkdir()
            tests.mkdir()
            (production / "Resources").mkdir()
            protocol.write_text(
                """
                client_request_definitions! {
                    AppsList => "app/list" {
                        params: v2::AppsListParams,
                        response: v2::AppsListResponse,
                    },
                    PluginList => "plugin/list" {
                        params: v2::PluginListParams,
                        response: v2::PluginListResponse,
                    },
                    ModelList => "model/list" {
                        params: v2::ModelListParams,
                        response: v2::ModelListResponse,
                    },
                }
                server_notification_definitions! {
                    EnvironmentConnected =>
                        "thread/environment/connected"
                        (v2::EnvironmentConnectionNotification),
                    EnvironmentDisconnected =>
                        "thread/environment/disconnected"
                        (v2::EnvironmentConnectionNotification),
                    ThreadArchived => "thread/archived"
                        (v2::ThreadArchivedNotification),

                    #[serde(rename = "account/login/completed")]
                    AccountLoginCompleted(
                        v2::AccountLoginCompletedNotification
                    ),
                }
                """,
                encoding="utf-8",
            )
            names = (
                "AccountLoginCompletedNotification",
                "AppsListParams",
                "AppsListResponse",
                "ConfigBogusParams",
                "EnvironmentConnectionNotification",
                "ModelListParams",
                "ModelListResponse",
                "PluginListParams",
                "PluginListResponse",
                "ThreadArchivedNotification",
            )
            inventory.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "version": "fixture",
                        "featureCount": len(names),
                        "features": [
                            {
                                "id": f"fixture.{name}",
                                "name": name,
                                "category": "fixture",
                                "status": (
                                    "matched"
                                    if name == "ThreadArchivedNotification"
                                    else "unknown"
                                ),
                                "automatedTests": (
                                    ["FixtureTests.threadArchive"]
                                    if name == "ThreadArchivedNotification"
                                    else []
                                ),
                            }
                            for name in names
                        ],
                    }
                ),
                encoding="utf-8",
            )
            (production / "Router.swift").write_text(
                """
                let complete = "app/list"
                let untested = "plugin/list"
                let partial = "thread/environment/connected"
                let special = "account/login/completed"
                """,
                encoding="utf-8",
            )
            (production / "Resources" / "Vendored.swift").write_text(
                'let bundledDependencyMethod = "model/list"\n',
                encoding="utf-8",
            )
            (tests / "RouterTests.swift").write_text(
                """
                #expect(route("app/list"))
                #expect(notification("thread/environment/connected"))
                #expect(notification("account/login/completed"))
                """,
                encoding="utf-8",
            )

            result = auditor.audit_feature_protocol_coverage(
                protocol_path=protocol,
                inventory_path=inventory,
                production_roots=(production,),
                test_roots=(tests,),
            )

        rows = {row["name"]: row for row in result["features"]}
        self.assertEqual(
            rows["AppsListParams"]["classification"],
            "implemented-and-test-referenced",
        )
        self.assertEqual(
            rows["AppsListResponse"]["classification"],
            "implemented-and-test-referenced",
        )
        self.assertEqual(
            rows["PluginListParams"]["classification"],
            "implemented-without-test-reference",
        )
        self.assertEqual(
            rows["PluginListResponse"]["classification"],
            "implemented-without-test-reference",
        )
        self.assertEqual(
            rows["EnvironmentConnectionNotification"]["classification"],
            "partially-implemented",
        )
        self.assertEqual(
            rows["ModelListParams"]["classification"],
            "not-implemented",
        )
        self.assertEqual(
            rows["ConfigBogusParams"]["classification"],
            "protocol-unmapped",
        )
        self.assertEqual(
            rows["AccountLoginCompletedNotification"]["protocolMethods"],
            ["account/login/completed"],
        )
        self.assertEqual(
            rows["ThreadArchivedNotification"]["classification"],
            "inventory-matched",
        )
        self.assertEqual(
            result["classificationCounts"],
            {
                "implemented-and-test-referenced": 3,
                "implemented-without-test-reference": 2,
                "inventory-matched": 1,
                "not-implemented": 2,
                "partially-implemented": 1,
                "protocol-unmapped": 1,
            },
        )
        app_method = rows["AppsListParams"]["methodCoverage"][0]
        self.assertEqual(app_method["method"], "app/list")
        self.assertEqual(
            app_method["productionReferences"],
            [{"file": "Router.swift", "line": 2}],
        )
        self.assertEqual(
            app_method["testReferences"],
            [{"file": "RouterTests.swift", "line": 2}],
        )


if __name__ == "__main__":
    unittest.main()
