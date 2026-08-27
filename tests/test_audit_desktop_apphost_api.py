from __future__ import annotations

import tempfile
from pathlib import Path
import unittest

from scripts.audit_desktop_apphost_api import (
    audit_apphost_api,
    class_public_methods,
)


class AuditDesktopAppHostAPITests(unittest.TestCase):
    def test_extracts_only_top_level_class_methods(self) -> None:
        source = """
        var Service=class extends Base {
          cache=new Map;
          callback=()=>nestedCallback();
          constructor(owner){super();this.owner=owner}
          static create(){return new Service()}
          async importBrowserProfile(request){
            nestedCall(request);
          }
          getSnapshot(){return this.cache}
          [Symbol.dispose](){this.cache.clear()}
        };
        """

        self.assertEqual(
            class_public_methods(source, "Service"),
            (
                "create",
                "getSnapshot",
                "importBrowserProfile",
            ),
        )
        self.assertEqual(
            class_public_methods(
                "Alias=class e extends Base{static create(){} run(){}}",
                "Alias",
            ),
            ("create", "run"),
        )

    def test_audits_methods_exposed_only_by_registered_service_objects(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            main = root / "main.js"
            renderer = root / "renderer.js"
            router = root / "Router.swift"
            main.write_text(
                """
                var Hotkeys=class extends Base {
                  open() {}
                  toggle() {}
                };
                var Remote=class extends Base {
                  renameIfDefault(request) {}
                };
                class Host {
                  constructor() {
                    this.remoteService = new Remote();
                  }
                  createAppHost(view) {
                    let hotkeys = new Hotkeys(view);
                    return new AppHost({
                      hotkeyWindowCommands: hotkeys,
                      remoteControlEnvironments: this.remoteService,
                    });
                  }
                }
                """,
                encoding="utf-8",
            )
            renderer.write_text("", encoding="utf-8")
            router.write_text(
                """
                static let serviceNames = [
                    "hotkeyWindowCommands",
                    "remoteControlEnvironments",
                ]
                switch method {
                case "open": return .undefined
                case "renameIfDefault": return .undefined
                default: return .undefined
                }
                """,
                encoding="utf-8",
            )

            result = audit_apphost_api(main, renderer, router)

            self.assertEqual(
                result["resolvedOfficialServiceMethods"],
                [
                    {
                        "className": "Hotkeys",
                        "method": "open",
                        "service": "hotkeyWindowCommands",
                    },
                    {
                        "className": "Hotkeys",
                        "method": "toggle",
                        "service": "hotkeyWindowCommands",
                    },
                    {
                        "className": "Remote",
                        "method": "renameIfDefault",
                        "service": "remoteControlEnvironments",
                    },
                ],
            )
            self.assertEqual(
                result["missingResolvedOfficialServiceMethods"],
                ["hotkeyWindowCommands.toggle"],
            )
            self.assertEqual(result["status"], "incomplete")

    def test_resolves_conditionally_constructed_local_service_alias(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            main = root / "main.js"
            renderer = root / "renderer.js"
            router = root / "Router.swift"
            main.write_text(
                """
                var Wrong=class extends Base { list() {} };
                var Right=class extends Base { showTask() {} };
                let s=new Wrong();
                class Host {
                  createAppHost(view) {
                    let s=this.controller==null?void 0:new Right(view);
                    return new AppHost({remoteHostedPIP:s});
                  }
                }
                """,
                encoding="utf-8",
            )
            renderer.write_text("", encoding="utf-8")
            router.write_text(
                """
                static let serviceNames = ["remoteHostedPIP"]
                case ("remoteHostedPIP", "showTask"):
                    return .undefined
                """,
                encoding="utf-8",
            )

            result = audit_apphost_api(main, renderer, router)

        self.assertEqual(
            result["resolvedOfficialServiceMethods"],
            [
                {
                    "className": "Right",
                    "method": "showTask",
                    "service": "remoteHostedPIP",
                }
            ],
        )
        self.assertEqual(result["missingResolvedOfficialServiceMethods"], [])
        self.assertEqual(result["status"], "complete")

    def test_reports_service_and_direct_renderer_call_gaps(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            main = root / "main.js"
            renderer = root / "renderer.js"
            router = root / "Router.swift"
            main.write_text(
                """
                class Host {
                  createAppHost(view) {
                    return new AppHost({
                      appInfo: new AppInfo(),
                      localProjects: new LocalProjects(view),
                    });
                  }
                }
                """,
                encoding="utf-8",
            )
            renderer.write_text(
                """
                await kp.appInfo.get();
                await kp?.localProjects?.create({name: "P"});
                """,
                encoding="utf-8",
            )
            router.write_text(
                """
                public static let serviceNames = ["appInfo"]
                switch (service, method) {
                case ("appInfo", "get"): return .object([:])
                default: return .undefined
                }
                """,
                encoding="utf-8",
            )

            result = audit_apphost_api(main, renderer, router)

            self.assertEqual(result["status"], "incomplete")
            self.assertEqual(result["officialServiceCount"], 2)
            self.assertEqual(
                result["missingOfficialServices"],
                ["localProjects"],
            )
            self.assertEqual(
                result["missingDirectRendererServices"],
                ["localProjects"],
            )
            self.assertEqual(result["missingDirectRendererMethods"], [])

    def test_accepts_a_complete_direct_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            main = root / "main.js"
            renderer = root / "renderer.js"
            router = root / "Router.swift"
            main.write_text(
                """
                createAppHost(e) {
                  return new Host({appInfo: service});
                }
                """,
                encoding="utf-8",
            )
            renderer.write_text(
                "void kp?.appInfo?.get();\n",
                encoding="utf-8",
            )
            router.write_text(
                """
                static let serviceNames = ["appInfo"]
                case ("appInfo", "get"): return .object([:])
                """,
                encoding="utf-8",
            )

            result = audit_apphost_api(main, renderer, router)

            self.assertEqual(result["status"], "complete")
            self.assertEqual(result["missingOfficialServices"], [])
            self.assertEqual(result["missingDirectRendererMethods"], [])

    def test_excludes_literal_undefined_apphost_properties(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            main = root / "main.js"
            renderer = root / "renderer.js"
            router = root / "Router.swift"
            main.write_text(
                """
                createAppHost(e) {
                  return new Host({
                    appInfo: service,
                    customRuntime: void 0,
                  });
                }
                """,
                encoding="utf-8",
            )
            renderer.write_text("", encoding="utf-8")
            router.write_text(
                'static let serviceNames = ["appInfo"]',
                encoding="utf-8",
            )

            result = audit_apphost_api(main, renderer, router)

            self.assertEqual(result["status"], "complete")
            self.assertEqual(result["officialServices"], ["appInfo"])
            self.assertEqual(
                result["officialUndefinedServices"],
                ["customRuntime"],
            )
            self.assertEqual(result["missingOfficialServices"], [])

    def test_tracks_literal_root_values_without_allocating_rpc_targets(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            main = root / "main.js"
            renderer = root / "renderer.js"
            router = root / "Router.swift"
            main.write_text(
                """
                createAppHost(e) {
                  return new Host({
                    appInfo: service,
                    notificationPermissionsSupported: true,
                    customRuntime: void 0,
                  });
                }
                """,
                encoding="utf-8",
            )
            renderer.write_text("", encoding="utf-8")
            router.write_text(
                """
                static let serviceNames = ["appInfo"]
                values["notificationPermissionsSupported"] = .bool(true)
                """,
                encoding="utf-8",
            )

            result = audit_apphost_api(main, renderer, router)

            self.assertEqual(result["status"], "complete")
            self.assertEqual(result["officialServices"], ["appInfo"])
            self.assertEqual(
                result["officialRootValues"],
                ["notificationPermissionsSupported"],
            )
            self.assertEqual(result["missingOfficialRootValues"], [])

    def test_detects_current_minified_renderer_alias(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            main = root / "main.js"
            renderer = root / "renderer.js"
            router = root / "Router.swift"
            main.write_text(
                """
                createAppHost(e) {
                  return new Host({appInfo: service});
                }
                """,
                encoding="utf-8",
            )
            renderer.write_text(
                """
                var z8e, Bm;
                async function connect() { Bm = await z8e.services; }
                void Bm.appInfo.get();
                """,
                encoding="utf-8",
            )
            router.write_text(
                """
                static let serviceNames = ["appInfo"]
                """,
                encoding="utf-8",
            )

            result = audit_apphost_api(main, renderer, router)

            self.assertEqual(
                result["directRendererCalls"],
                [{"service": "appInfo", "method": "get"}],
            )
            self.assertEqual(
                result["missingDirectRendererMethods"],
                ["appInfo.get"],
            )

    def test_ignores_non_apphost_objects_with_official_service_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            main = root / "main.js"
            renderer = root / "renderer.js"
            router = root / "Router.swift"
            main.write_text(
                """
                createAppHost(e) {
                  return new Host({
                    appInfo: appInfoService,
                    clipboard: clipboardService,
                    downloads: downloadsService,
                    fileAttachments: fileAttachmentsService,
                  });
                }
                """,
                encoding="utf-8",
            )
            renderer.write_text(
                """
                var z8e, Bm;
                async function connect() { Bm = await z8e.services; }
                void Bm.appInfo.get();
                void navigator.clipboard.write([item]);
                void state.downloads.filter(Boolean);
                void context.fileAttachments.some(Boolean);
                """,
                encoding="utf-8",
            )
            router.write_text(
                """
                static let serviceNames = [
                    "appInfo", "clipboard", "downloads", "fileAttachments"
                ]
                """,
                encoding="utf-8",
            )

            result = audit_apphost_api(main, renderer, router)

            self.assertEqual(
                result["directRendererCalls"],
                [{"service": "appInfo", "method": "get"}],
            )

    def test_ignores_collection_map_on_shadowed_apphost_alias(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            main = root / "main.js"
            renderer = root / "renderer.js"
            router = root / "Router.swift"
            main.write_text(
                """
                createAppHost(e) {
                  return new Host({downloads: downloadsService});
                }
                """,
                encoding="utf-8",
            )
            renderer.write_text(
                """
                var bridge, host;
                async function connect() { host = await bridge.services; }
                void host.downloads.getSnapshot();
                function render(host) {
                  return host.downloads.map((download) => download.id);
                }
                """,
                encoding="utf-8",
            )
            router.write_text(
                """
                static let serviceNames = ["downloads"]
                case "getSnapshot": return .object([:])
                """,
                encoding="utf-8",
            )

            result = audit_apphost_api(main, renderer, router)

            self.assertEqual(
                result["directRendererCalls"],
                [{"service": "downloads", "method": "getSnapshot"}],
            )

    def test_reads_delegated_ipad_methods_from_a_swift_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            main = root / "main.js"
            renderer = root / "renderer.js"
            ipad = root / "Application"
            ipad.mkdir()
            main.write_text(
                """
                createAppHost(e) {
                  return new Host({visualizations: service});
                }
                """,
                encoding="utf-8",
            )
            renderer.write_text(
                """
                var z8e, Bm;
                async function connect() { Bm = await z8e.services; }
                void Bm.visualizations.getTemporaryRoots();
                void Bm.visualizations.showTask();
                void Bm.visualizations.hideTask();
                """,
                encoding="utf-8",
            )
            (ipad / "Router.swift").write_text(
                'static let serviceNames = ["visualizations"]',
                encoding="utf-8",
            )
            (ipad / "VisualizationsService.swift").write_text(
                """
                case "getTemporaryRoots": return .array([])
                case "showTask", "hideTask": return .undefined
                """,
                encoding="utf-8",
            )

            result = audit_apphost_api(main, renderer, ipad)

            self.assertEqual(result["status"], "complete")
            self.assertEqual(result["missingDirectRendererMethods"], [])

    def test_reads_guarded_and_set_dispatched_ipad_methods(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            main = root / "main.js"
            renderer = root / "renderer.js"
            ipad = root / "Application"
            ipad.mkdir()
            main.write_text(
                """
                var Avatar=class { setInputShape() {} };
                var Debug=class { exportLogs() {} getMemoryStatus() {} };
                createAppHost(e) {
                  return new Host({
                    avatarOverlay: new Avatar(),
                    debug: new Debug(),
                  });
                }
                """,
                encoding="utf-8",
            )
            renderer.write_text("", encoding="utf-8")
            (ipad / "Router.swift").write_text(
                'static let serviceNames = ["avatarOverlay", "debug"]',
                encoding="utf-8",
            )
            (ipad / "OptionalService.swift").write_text(
                """
                if method == "setInputShape" { return .undefined }
                let methods: Set<String> = [
                    "exportLogs",
                    "getMemoryStatus",
                ]
                guard methods.contains(method) else { return .undefined }
                """,
                encoding="utf-8",
            )

            result = audit_apphost_api(main, renderer, ipad)

            self.assertEqual(result["status"], "complete")
            self.assertEqual(
                result["missingResolvedOfficialServiceMethods"],
                [],
            )

    def test_records_methods_that_are_unavailable_in_official_host(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            main = root / "main.js"
            renderer = root / "renderer.js"
            router = root / "Router.swift"
            main.write_text(
                """
                var Debug=class extends Base {
                  async getMemoryDiagnosticsStatus(){
                    throw Error(`Memory diagnostics are unavailable`)
                  }
                  async exportLogs(){ return true }
                };
                createAppHost(e) {
                  return new Host({debug: new Debug()});
                }
                """,
                encoding="utf-8",
            )
            renderer.write_text("", encoding="utf-8")
            router.write_text(
                """
                static let serviceNames = ["debug"]
                let methods: Set<String> = [
                    "getMemoryDiagnosticsStatus",
                    "exportLogs",
                ]
                """,
                encoding="utf-8",
            )

            result = audit_apphost_api(main, renderer, router)

            self.assertEqual(
                result["officialExplicitlyUnavailableMethods"],
                ["debug.getMemoryDiagnosticsStatus"],
            )


if __name__ == "__main__":
    unittest.main()
