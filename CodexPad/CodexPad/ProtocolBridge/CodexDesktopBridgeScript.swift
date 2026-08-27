#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public struct CodexDesktopBridgeBootstrap:
    Codable,
    Equatable,
    Sendable
{
    /// The released desktop main process enables the Owl application shell
    /// unless `CODEX_USE_OWL_APP_SHELL` is explicitly set to `"0"`.
    public static let releasedUsesOwlAppShell = true

    public let preloadStartedAtMs: Double
    public let systemThemeVariant: String
    public let initialSidebarBootstrap: CodexJSONValue
    public let sharedObjectSnapshot: [String: CodexJSONValue]
    public let sentryInitOptions: CodexJSONValue
    public let buildFlavor: String
    public let appSessionID: String
    public let usesOwlAppShell: Bool
    public let appHostPortIDPrefix: String

    public init(
        preloadStartedAtMs: Double,
        systemThemeVariant: String,
        initialSidebarBootstrap: CodexJSONValue,
        sharedObjectSnapshot: [String: CodexJSONValue],
        sentryInitOptions: CodexJSONValue,
        buildFlavor: String,
        appSessionID: String,
        usesOwlAppShell: Bool,
        appHostPortIDPrefix: String = "app-host"
    ) {
        self.preloadStartedAtMs = preloadStartedAtMs
        self.systemThemeVariant = systemThemeVariant
        self.initialSidebarBootstrap = initialSidebarBootstrap
        self.sharedObjectSnapshot = sharedObjectSnapshot
        self.sentryInitOptions = sentryInitOptions
        self.buildFlavor = buildFlavor
        self.appSessionID = appSessionID
        self.usesOwlAppShell = usesOwlAppShell
        self.appHostPortIDPrefix = appHostPortIDPrefix
    }

    public func scopedToAppHostPortIDPrefix(
        _ prefix: String
    ) -> CodexDesktopBridgeBootstrap {
        CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: preloadStartedAtMs,
            systemThemeVariant: systemThemeVariant,
            initialSidebarBootstrap: initialSidebarBootstrap,
            sharedObjectSnapshot: sharedObjectSnapshot,
            sentryInitOptions: sentryInitOptions,
            buildFlavor: buildFlavor,
            appSessionID: appSessionID,
            usesOwlAppShell: usesOwlAppShell,
            appHostPortIDPrefix: prefix
        )
    }

    public static func releasedSentryInitOptions(
        appSessionID: String,
        appVersion: String,
        buildNumber: String,
        buildFlavor: String = "prod",
        desktopTraceSampleRate: Double = 0
    ) -> CodexJSONValue {
        .object([
            "appVersion": .string(appVersion),
            "buildFlavor": .string(buildFlavor),
            "buildNumber": .string(buildNumber),
            "codexAppSessionId": .string(appSessionID),
            "desktopTraceSampleRate":
                .number(desktopTraceSampleRate),
        ])
    }
}

public enum CodexDesktopBridgeScript {
    public static func make(
        bootstrap: CodexDesktopBridgeBootstrap
    ) throws -> String {
        guard ["dark", "light"].contains(bootstrap.systemThemeVariant) else {
            throw CodexDesktopBridgeError.invalidSystemThemeVariant
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(bootstrap)
        guard let bootstrapJSON = String(data: data, encoding: .utf8) else {
            throw CodexDesktopBridgeError.invalidPayload
        }
        return source.replacingOccurrences(
            of: "__CODEX_BOOTSTRAP_JSON__",
            with: bootstrapJSON
        )
    }

    private static let source = #"""
    (() => {
      "use strict";
      const bootstrap = __CODEX_BOOTSTRAP_JSON__;
      const sharedObjects = {...bootstrap.sharedObjectSnapshot};
      const themeSubscribers = new Set();
      const workerSubscribers = new Map();
      const appHostPorts = new Map();
      const mcpAppSandboxGuestMessageChannel =
        "codex_desktop:mcp-app-sandbox-guest-message";
      const mcpAppSandboxHostMessageChannel =
        "codex_desktop:mcp-app-sandbox-host-message";
      const nativeHandler =
        window.webkit?.messageHandlers?.codexDesktopBridge ?? null;
      let themeVariant = bootstrap.systemThemeVariant;
      let nextAppHostPortID = 1;

      // WKWebView serializes a file URL's origin as "null". The released
      // renderer passes window.location.origin back into postMessage while
      // transferring its app-host MessagePort; WebKit requires "*" for this
      // opaque-origin case. Keep all other postMessage calls byte-for-byte
      // equivalent to the browser implementation.
      if (window.location.origin === "null") {
        const browserPostMessage = window.postMessage.bind(window);
        window.postMessage = (message, targetOrigin, transfer) =>
          browserPostMessage(
            message,
            targetOrigin === "null" ? "*" : targetOrigin,
            transfer
          );
      }

      const nativePost = (channel, payload) => {
        if (nativeHandler === null) {
          return Promise.reject(new Error("Codex iPad host bridge is unavailable"));
        }
        return Promise.resolve(nativeHandler.postMessage({channel, payload}));
      };

      const makeWebMCPModelContext = (onToolsChanged) => {
        const tools = new Map();
        const makeRegistrationID = () => {
          const words = crypto.getRandomValues(new Uint32Array(4));
          return `${words[0]}-${words[1]}-${words[2]}-${words[3]}`;
        };
        const normalizeToolName = (name) => {
          if (typeof name !== "string" || name.trim().length === 0) {
            throw new Error("WebMCP tools must have a non-empty name.");
          }
          return name.trim();
        };
        const notifyToolsChanged = () => {
          try {
            onToolsChanged?.();
          } catch {}
        };
        const publicTool = (tool) => ({
          name: tool.name,
          inputSchema: tool.inputSchema ?? null,
          ...(tool.title == null ? {} : {title: tool.title}),
          ...(tool.description == null
            ? {}
            : {description: tool.description}),
          ...(tool.annotations == null
            ? {}
            : {annotations: {...tool.annotations}}),
          ...(location.origin == null ? {} : {origin: location.origin}),
          ...(location.href == null ? {} : {pageUrl: location.href}),
        });
        const execute = async (reference, inputJSON, validateRegistration) => {
          let input;
          try {
            input = JSON.parse(inputJSON);
          } catch {
            throw new Error(
              "WebMCP executeTool requires a JSON-stringified input."
            );
          }
          const name = normalizeToolName(reference?.name);
          const tool = tools.get(name);
          if (tool == null) {
            throw new Error(
              validateRegistration
                ? `WebMCP tool ${JSON.stringify(name)} is stale. Call fetchTools() again.`
                : `WebMCP tool not found: ${name}`
            );
          }
          if (
            validateRegistration &&
            tool.registrationId !== reference?.registrationId
          ) {
            throw new Error(
              `WebMCP tool ${JSON.stringify(name)} is stale. Call fetchTools() again.`
            );
          }
          const client = {
            async requestUserInteraction() {
              throw new Error(
                "requestUserInteraction is not supported by the Codex WebMCP shim."
              );
            },
          };
          const result = await tool.execute(input, client);
          const normalizedResult = result === undefined ? null : result;
          try {
            const resultJSON = JSON.stringify(normalizedResult);
            if (resultJSON === undefined) {
              throw new Error();
            }
            return resultJSON;
          } catch {
            throw new Error(
              "WebMCP tool result is not JSON-serializable."
            );
          }
        };

        return Object.freeze({
          codexExecuteTool: (reference, inputJSON) =>
            execute(reference, inputJSON, true),
          codexGetTools: () =>
            Array.from(tools.values(), (tool) => ({
              ...publicTool(tool),
              registrationId: tool.registrationId,
            })),
          executeTool: (reference, inputJSON) =>
            execute(reference, inputJSON, false),
          getTools: () =>
            Array.from(tools.values(), (tool) => publicTool(tool)),
          registerTool: (definition, options) => {
            const name = normalizeToolName(definition?.name);
            const executeCallback = definition?.execute;
            if (typeof executeCallback !== "function") {
              throw new Error(
                `WebMCP tool ${name} is missing an execute callback.`
              );
            }
            let inputSchema;
            if (definition.inputSchema !== undefined) {
              inputSchema = JSON.stringify(definition.inputSchema);
              if (inputSchema === undefined) {
                throw new Error(
                  "WebMCP tool inputSchema must be JSON-serializable."
                );
              }
            }
            const registered = {
              name,
              registrationId: makeRegistrationID(),
              execute: executeCallback,
              ...(definition.title == null
                ? {}
                : {title: definition.title}),
              ...(definition.description == null
                ? {}
                : {description: definition.description}),
              ...(inputSchema === undefined ? {} : {inputSchema}),
              ...(definition.annotations == null
                ? {}
                : {annotations: {...definition.annotations}}),
            };
            const signal = options?.signal;
            if (signal?.aborted) {
              return;
            }
            if (typeof signal?.addEventListener === "function") {
              signal.addEventListener(
                "abort",
                () => {
                  if (tools.get(name) === registered) {
                    tools.delete(name);
                    notifyToolsChanged();
                  }
                },
                {once: true}
              );
            }
            tools.set(name, registered);
            notifyToolsChanged();
          },
          unregisterTool: (name) => {
            if (tools.delete(normalizeToolName(name))) {
              notifyToolsChanged();
            }
          },
        });
      };

      const webMCPModelContext = makeWebMCPModelContext(() => {
        void nativePost("view-message", {
          type: "webmcp_changed",
          version: 1,
        }).catch(() => {});
      });

      Object.defineProperty(window, "__codexWebMcpModelContext", {
        configurable: false,
        enumerable: false,
        value: webMCPModelContext,
        writable: false,
      });
      for (const modelContextOwner of [document, navigator]) {
        Object.defineProperty(modelContextOwner, "modelContext", {
          configurable: false,
          enumerable: false,
          value: webMCPModelContext,
          writable: false,
        });
      }

      const describeDiagnosticValue = (value) => {
        if (value instanceof Error) {
          return {
            name: value.name,
            message: value.message,
            stack: value.stack ?? null,
          };
        }
        if (value !== null && typeof value === "object") {
          try {
            return JSON.parse(JSON.stringify(value));
          } catch {
            return String(value);
          }
        }
        return String(value);
      };

      const normalizeDiagnosticValue = (value, seen = new WeakSet()) => {
        if (
          value === null ||
          typeof value === "string" ||
          typeof value === "number" ||
          typeof value === "boolean"
        ) {
          return value;
        }
        if (typeof value !== "object") {
          return String(value);
        }
        if (seen.has(value)) {
          return "[Circular]";
        }
        seen.add(value);

        if (value instanceof Error) {
          const normalizedError = {
            name: value.name,
            message: value.message,
            stack: value.stack ?? null,
          };
          if (value.cause !== undefined) {
            normalizedError.cause = normalizeDiagnosticValue(
              value.cause,
              seen
            );
          }
          for (const [key, entry] of Object.entries(value)) {
            if (key !== "cause") {
              normalizedError[key] = normalizeDiagnosticValue(entry, seen);
            }
          }
          return normalizedError;
        }
        if (Array.isArray(value)) {
          return value.map((entry) =>
            normalizeDiagnosticValue(entry, seen)
          );
        }

        const normalizedObject = {};
        for (const [key, entry] of Object.entries(value)) {
          normalizedObject[key] = normalizeDiagnosticValue(entry, seen);
        }
        return normalizedObject;
      };

      const reportRendererDiagnostic = (kind, details = {}) => {
        void nativePost("renderer-diagnostic", {
          kind,
          readyState: document.readyState,
          href: window.location.href,
          ...details,
        }).catch(() => {});
      };

      window.addEventListener("error", (event) => {
        reportRendererDiagnostic("window-error", {
          message: event.message,
          filename: event.filename,
          line: event.lineno,
          column: event.colno,
          error: describeDiagnosticValue(event.error),
        });
      });
      window.addEventListener("unhandledrejection", (event) => {
        reportRendererDiagnostic("unhandled-rejection", {
          reason: describeDiagnosticValue(event.reason),
        });
      });
      window.addEventListener(
        "DOMContentLoaded",
        () => reportRendererDiagnostic("dom-content-loaded"),
        {once: true}
      );
      window.addEventListener(
        "load",
        () => {
          reportRendererDiagnostic("window-loaded", {
            scriptCount: document.scripts.length,
            rootChildCount:
              document.getElementById("root")?.childElementCount ?? null,
          });
          window.setTimeout(() => {
            reportRendererDiagnostic("post-load-checkpoint", {
              bridgeInstalled: window.electronBridge === bridge,
              scriptCount: document.scripts.length,
              rootChildCount:
                document.getElementById("root")?.childElementCount ?? null,
            });
          }, 2_000);
        },
        {once: true}
      );

      const normalizeViewMessageForNative = (message) => {
        if (message === null || typeof message !== "object") {
          return message;
        }
        if (message.type === "log-message") {
          const normalized = {...message};
          normalized.tags = normalizeDiagnosticValue(message.tags);
          return normalized;
        }
        if (
          message.type !== "shared-object-set" &&
          message.type !== "persisted-atom-update"
        ) {
          return message;
        }
        if (message.value !== undefined) {
          return message;
        }

        const normalized = {...message};
        if (message.type === "persisted-atom-update") {
          normalized.value = null;
          normalized.deleted = true;
        } else {
          delete normalized.value;
        }
        return normalized;
      };

      const applyThemeClass = () => {
        const root = document.documentElement;
        if (root === null) {
          return;
        }
        root.classList.remove("electron-dark", "electron-light");
        root.classList.add(
          themeVariant === "dark" ? "electron-dark" : "electron-light"
        );
      };

      if (document.documentElement !== null) {
        applyThemeClass();
      } else {
        const observer = new MutationObserver(() => {
          if (document.documentElement !== null) {
            applyThemeClass();
            observer.disconnect();
          }
        });
        observer.observe(document, {childList: true});
      }

      window.addEventListener("message", (event) => {
        const message = event.data;
        if (message?.type !== "connect-app-host") {
          return;
        }
        const port = message.port ?? event.ports?.[0];
        if (port === null || port === undefined) {
          return;
        }

        const portID = `${bootstrap.appHostPortIDPrefix}-${nextAppHostPortID}`;
        nextAppHostPortID += 1;
        appHostPorts.set(portID, port);

        const forwardFrame = (portEvent) => {
          const frame = portEvent.data;
          if (typeof frame !== "string") {
            return;
          }
          void nativePost("app-host-message", {portID, frame}).then(
            (responseFrame) => {
              if (typeof responseFrame === "string") {
                port.postMessage(responseFrame);
              }
            }
          );
        };
        if (typeof port.addEventListener === "function") {
          port.addEventListener("message", forwardFrame);
        } else {
          port.onmessage = forwardFrame;
        }
        if (typeof port.start === "function") {
          port.start();
        }
        void nativePost("app-host-connected", {portID});
      });

      const bridge = {
        windowType: "electron",
        acknowledgeChunkedMessage: (transferID, sequence) => {
          void nativePost("chunked-message-ack", {
            transferID,
            sequence,
          }).catch(() => {});
        },
        getPreloadStartedAtMs: () => bootstrap.preloadStartedAtMs,
        sendMessageFromView: async (message) => {
          if (message?.type === "shared-object-set") {
            if (message.value === undefined) {
              delete sharedObjects[message.key];
            } else {
              sharedObjects[message.key] = message.value;
            }
          }
          await nativePost(
            "view-message",
            normalizeViewMessageForNative(message)
          );
        },
        getPathForFile: (file) =>
          typeof file?.__codexNativePath === "string"
            ? file.__codexNativePath
            : null,
        startFileDrag: (payload) => {
          const dataTransfer = window.event?.dataTransfer ?? null;
          if (
            dataTransfer === null ||
            typeof dataTransfer.setData !== "function" ||
            typeof payload?.path !== "string" ||
            payload.path.length === 0
          ) {
            return false;
          }

          const path = payload.path;
          let fileURL;
          try {
            fileURL = new URL(`file://${path}`).href;
          } catch {
            return false;
          }
          dataTransfer.setData("text/plain", path);
          dataTransfer.setData("text/uri-list", fileURL);
          dataTransfer.effectAllowed = "copy";
          void nativePost("start-file-drag", payload).catch(() => {});
          return true;
        },
        sendWorkerMessageFromView: async (workerID, message) => {
          await nativePost("worker-message", {workerID, message});
        },
        subscribeToWorkerMessages: (workerID, callback) => {
          let callbacks = workerSubscribers.get(workerID);
          if (callbacks === undefined) {
            callbacks = new Set();
            workerSubscribers.set(workerID, callbacks);
          }
          callbacks.add(callback);
          return () => {
            callbacks.delete(callback);
            if (callbacks.size === 0) {
              workerSubscribers.delete(workerID);
            }
          };
        },
        // The released renderer owns the full touch/keyboard accessible menu
        // implementation and selects it when the native preload hook is null.
        showContextMenu: null,
        getFastModeRolloutMetrics: async (payload) =>
          nativePost("fast-mode-rollout-metrics", payload),
        getSharedObjectSnapshotValue: (key) => sharedObjects[key],
        getInitialSidebarBootstrap: () =>
          bootstrap.initialSidebarBootstrap,
        getSystemThemeVariant: () => themeVariant,
        subscribeToSystemThemeVariant: (callback) => {
          themeSubscribers.add(callback);
          return () => themeSubscribers.delete(callback);
        },
        triggerSentryTestError: async () =>
          nativePost("trigger-sentry-test-error", {}),
        getSentryInitOptions: () => bootstrap.sentryInitOptions,
        getDesktopUserAgent: () =>
          `Codex Desktop/${bootstrap.sentryInitOptions.appVersion}`
            + " (iPadOS; arm64)",
        getAppSessionId: () => bootstrap.appSessionID,
        getBuildFlavor: () => bootstrap.buildFlavor,
        isDeviceCheckSupported: () => true,
        isIntelMacBuild: () => false,
        usesOwlAppShell: () => bootstrap.usesOwlAppShell,
      };

      // A physical shortcut can reach the released renderer through both the
      // DOM fallback and UIKit's responder chain. Terminal is a toggle, so
      // replaying that single press would open and immediately close it.
      // Coalesce only near-simultaneous terminal deliveries at the one ingress
      // shared by both paths; deliberate later presses remain independent.
      const terminalToggleDuplicateIntervalMs = 100;
      let lastTerminalToggleReceivedAt = Number.NEGATIVE_INFINITY;
      const receive = (message) => {
        if (message?.type === "toggle-terminal") {
          const now = performance.now();
          if (
            now - lastTerminalToggleReceivedAt
              <= terminalToggleDuplicateIntervalMs
          ) {
            return;
          }
          lastTerminalToggleReceivedAt = now;
        }
        if (message?.type === mcpAppSandboxHostMessageChannel) {
          if (
            message.appSessionID !== bootstrap.appSessionID ||
            message.targetOrigin !== window.location.origin
          ) {
            return;
          }
          const envelope = message.payload;
          if (
            envelope?.type !== "init" ||
            typeof envelope.origin !== "string" ||
            typeof envelope.initId !== "string" ||
            typeof envelope.sandboxId !== "string" ||
            !Array.isArray(envelope.portNames)
          ) {
            return;
          }
          const ports = Array.isArray(message.ports) ? message.ports : [];
          if (ports.length !== envelope.portNames.length + 1) {
            return;
          }
          window.postMessage(envelope, window.location.origin, ports);
          return;
        }
        if (message?.type === "app-host-message") {
          const port = appHostPorts.get(message.portID);
          if (port !== undefined && typeof message.frame === "string") {
            port.postMessage(message.frame);
          }
          return;
        }
        if (message?.type === "shared-object-updated") {
          if (message.value === undefined) {
            delete sharedObjects[message.key];
          } else {
            sharedObjects[message.key] = message.value;
          }
        }
        if (message?.type === "system-theme-variant-updated") {
          themeVariant = message.value;
          applyThemeClass();
          for (const callback of themeSubscribers) {
            callback();
          }
        }
        if (message?.type === "worker-message") {
          const callbacks = workerSubscribers.get(message.workerID);
          if (callbacks !== undefined) {
            for (const callback of callbacks) {
              callback(message.message);
            }
          }
          return;
        }
        window.dispatchEvent(new MessageEvent("message", {data: message}));
      };

      window.codexWindowType = "electron";
      window.electronBridge = bridge;
      window.__codexDesktopHost = Object.freeze({
        mcpAppSandboxGuestMessageChannel,
        mcpAppSandboxHostMessageChannel,
        receive,
      });
    })();
    """#
}
