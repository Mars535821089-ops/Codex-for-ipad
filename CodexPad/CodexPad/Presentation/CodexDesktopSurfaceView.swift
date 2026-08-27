#if os(iOS) && canImport(UIKit) && canImport(WebKit)
    import SwiftUI
    import UniformTypeIdentifiers
    import WebKit

    struct CodexDesktopSurfaceView: View {
        @Bindable var controller: CodexDesktopSurfaceController
        let onOpenNativeRecovery: () -> Void

        var body: some View {
            ZStack {
                if let host = controller.host {
                    CodexDesktopWebView(
                        webView: host.webView,
                        controller: controller
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                }

                if controller.isAvatarOverlayPresented,
                   let overlayHost = controller.avatarOverlayHost
                {
                    CodexDesktopWebView(
                        webView: overlayHost.webView,
                        controller: controller
                    )
                    .frame(width: 420, height: 620)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottomTrailing
                    )
                    .accessibilityIdentifier(
                        "CodexDesktopAvatarOverlay"
                    )
                }

                if case let .failed(reason) =
                    controller.surfaceState
                {
                    failureView(reason: reason)
                }

                if ProcessInfo.processInfo.environment[
                    "CODEXPAD_UI_TEST_ANCHOR_DIAGNOSTIC"
                ] == "1" {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier(
                            "CodexLastActiveThreadAnchor"
                        )
                        .accessibilityLabel(
                            controller.lastActiveLocalThreadAnchorState
                        )

                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier(
                            "CodexLastFetchStreamState"
                        )
                        .accessibilityLabel(
                            controller.lastFetchStreamState
                        )
                }
            }
            .background(Color.black)
            .onAppear {
                controller.startIfNeeded()
            }
            .fileImporter(
                isPresented: Binding(
                    get: {
                        controller.isWorkspacePickerPresented
                    },
                    set: {
                        controller.isWorkspacePickerPresented = $0
                    }
                ),
                allowedContentTypes: [.folder],
                allowsMultipleSelection:
                    controller
                        .workspacePickerAllowsMultipleSelection,
                onCompletion:
                    controller.completeWorkspacePicker(_:)
            )
            .fileImporter(
                isPresented: Binding(
                    get: {
                        controller
                            .isDesktopFilePickerPresented
                    },
                    set: {
                        controller
                            .isDesktopFilePickerPresented = $0
                    }
                ),
                allowedContentTypes:
                    desktopFilePickerContentTypes,
                allowsMultipleSelection:
                    controller
                        .desktopFilePickerAllowsMultipleSelection,
                onCompletion:
                    controller.completeDesktopFilePicker(_:)
            )
            .fileExporter(
                isPresented: Binding(
                    get: {
                        controller
                            .isDesktopFileExporterPresented
                    },
                    set: {
                        controller
                            .isDesktopFileExporterPresented = $0
                    }
                ),
                document: CodexDesktopExportDocument(
                    contents:
                        controller.desktopFileExportContents
                ),
                contentType: desktopFileExportContentType,
                defaultFilename:
                    controller
                        .desktopFileExportSuggestedFilename,
                onCompletion:
                    controller.completeDesktopFileExporter(_:)
            )
        }

        private var desktopFilePickerContentTypes: [UTType] {
            if controller.desktopFilePickerImagesOnly {
                return [.image]
            }
            if controller
                .desktopFilePickerAllowsMultipleSelection
            {
                return [.item, .folder]
            }
            return [.item]
        }

        private var desktopFileExportContentType: UTType {
            let filename = controller
                .desktopFileExportSuggestedFilename
            let pathExtension = (filename as NSString)
                .pathExtension
            guard !pathExtension.isEmpty,
                  let type = UTType(
                    filenameExtension: pathExtension
                  )
            else {
                return .data
            }
            return type
        }

        private func failureView(
            reason: String
        ) -> some View {
            VStack(spacing: 16) {
                Text("Codex renderer failed to start")
                    .font(.headline)
                Text(reason)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    Button("Retry") {
                        controller.retry()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open native recovery") {
                        onOpenNativeRecovery()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .background(.regularMaterial)
            .clipShape(
                RoundedRectangle(cornerRadius: 16)
            )
            .padding()
        }
    }

    private struct CodexDesktopExportDocument: FileDocument {
        static var readableContentTypes: [UTType] {
            [.data]
        }

        let contents: Data

        init(contents: Data) {
            self.contents = contents
        }

        init(configuration: ReadConfiguration)
            throws
        {
            contents =
                configuration.file
                    .regularFileContents ?? Data()
        }

        func fileWrapper(
            configuration _: WriteConfiguration
        ) throws -> FileWrapper {
            FileWrapper(regularFileWithContents: contents)
        }
    }

    private struct CodexDesktopWebView: UIViewControllerRepresentable {
        let webView: WKWebView
        let controller: CodexDesktopSurfaceController

        func makeUIViewController(
            context _: Context
        ) -> CodexDesktopHardwareShortcutViewController {
            CodexDesktopHardwareShortcutViewController(
                webView: webView,
                onHardwareShortcut: { shortcut in
                    controller.performNativeShortcut(shortcut)
                },
                onNativeGeometry: { [weak controller] snapshot in
                    controller?.recordNativeGeometry(snapshot)
                }
            )
        }

        func updateUIViewController(
            _ viewController: CodexDesktopHardwareShortcutViewController,
            context _: Context
        ) {
            viewController.onHardwareShortcut = { shortcut in
                controller.performNativeShortcut(shortcut)
            }
            viewController.onNativeGeometry = { [weak controller] snapshot in
                controller?.recordNativeGeometry(snapshot)
            }
        }
    }

    /// Hosts the released renderer and installs its accelerator table on the
    /// WKWebView's direct parent in the responder chain. WKContentView remains
    /// first responder while editing, so the parent view is the nearest native
    /// responder that can claim desktop shortcuts before iPadOS consumes them.
    @MainActor
    private final class CodexDesktopHardwareShortcutViewController:
        UIViewController
    {
        let webView: WKWebView
        var onHardwareShortcut: (CodexDesktopNativeShortcut) -> Void {
            didSet {
                (viewIfLoaded as? CodexDesktopHardwareShortcutContainerView)?
                    .onHardwareShortcut = onHardwareShortcut
            }
        }
        var onNativeGeometry:
            (CodexDesktopNativeGeometrySnapshot) -> Void
        private var lastNativeGeometrySnapshot:
            CodexDesktopNativeGeometrySnapshot?

        init(
            webView: WKWebView,
            onHardwareShortcut: @escaping (
                CodexDesktopNativeShortcut
            ) -> Void,
            onNativeGeometry: @escaping (
                CodexDesktopNativeGeometrySnapshot
            ) -> Void
        ) {
            self.webView = webView
            self.onHardwareShortcut = onHardwareShortcut
            self.onNativeGeometry = onNativeGeometry
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let rootView = CodexDesktopHardwareShortcutContainerView(
                onHardwareShortcut: onHardwareShortcut
            )
            rootView.backgroundColor = .black
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(
                    equalTo: rootView.leadingAnchor
                ),
                webView.trailingAnchor.constraint(
                    equalTo: rootView.trailingAnchor
                ),
                webView.topAnchor.constraint(
                    equalTo: rootView.topAnchor
                ),
                webView.bottomAnchor.constraint(
                    equalTo: rootView.bottomAnchor
                ),
            ])
            view = rootView
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            #if DEBUG && !targetEnvironment(simulator)
                captureNativeGeometry()
            #endif
        }

        #if DEBUG && !targetEnvironment(simulator)
            private func captureNativeGeometry() {
                guard let container = viewIfLoaded,
                      let window = container.window
                else {
                    return
                }
                let snapshot = CodexDesktopNativeGeometrySnapshot(
                    window: geometryNode(window),
                    windowScene: window.windowScene.map {
                        scene in
                        CodexDesktopNativeGeometryNode(
                            frame: geometryRect(
                                scene.coordinateSpace.bounds
                            ),
                            bounds: geometryRect(
                                scene.coordinateSpace.bounds
                            ),
                            safeAreaInsets: nil
                        )
                    },
                    rootViewController: window.rootViewController?
                        .viewIfLoaded
                        .map(geometryNode),
                    container: geometryNode(container),
                    webView: geometryNode(webView)
                )
                guard snapshot != lastNativeGeometrySnapshot else {
                    return
                }
                lastNativeGeometrySnapshot = snapshot
                onNativeGeometry(snapshot)
            }

            private func geometryNode(
                _ view: UIView
            ) -> CodexDesktopNativeGeometryNode {
                CodexDesktopNativeGeometryNode(
                    frame: geometryRect(view.frame),
                    bounds: geometryRect(view.bounds),
                    safeAreaInsets: CodexDesktopNativeGeometryInsets(
                        top: Double(view.safeAreaInsets.top),
                        left: Double(view.safeAreaInsets.left),
                        bottom: Double(view.safeAreaInsets.bottom),
                        right: Double(view.safeAreaInsets.right)
                    )
                )
            }

            private func geometryRect(
                _ rect: CGRect
            ) -> CodexDesktopNativeGeometryRect {
                CodexDesktopNativeGeometryRect(
                    x: Double(rect.origin.x),
                    y: Double(rect.origin.y),
                    width: Double(rect.size.width),
                    height: Double(rect.size.height)
                )
            }
        #endif

        override var keyCommands: [UIKeyCommand]? {
            Self.shortcutCommands
        }

        override func pressesBegan(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            let handled = dispatchHardwareShortcut(from: presses)
            if !handled {
                super.pressesBegan(presses, with: event)
            }
        }

        @objc
        private func performDesktopShortcut(
            _ command: UIKeyCommand
        ) {
            guard let input = command.input else {
                recordHardwareShortcutDiagnostic(
                    path: "controller-key-command",
                    input: "missing",
                    handled: false
                )
                return
            }
            let shortcut = Self.resolve(
                input: input,
                flags: command.modifierFlags
            )
            recordHardwareShortcutDiagnostic(
                path: "controller-key-command",
                input: input,
                handled: shortcut != nil
            )
            guard let shortcut else { return }
            onHardwareShortcut(shortcut)
        }

        private func dispatchHardwareShortcut(
            from presses: Set<UIPress>
        ) -> Bool {
            for press in presses {
                guard let key = press.key else { continue }
                let input = key.charactersIgnoringModifiers
                let shortcut = Self.resolve(
                    input: input,
                    flags: key.modifierFlags
                )
                recordHardwareShortcutDiagnostic(
                    path: "controller-presses-began",
                    input: input,
                    handled: shortcut != nil
                )
                guard let shortcut else { continue }
                onHardwareShortcut(shortcut)
                return true
            }
            return false
        }

        private func recordHardwareShortcutDiagnostic(
            path: String,
            input: String,
            handled: Bool
        ) {
            UserDefaults.standard.set(
                "path=\(path) input=\(input) handled=\(handled)",
                forKey: "codex.desktop.last-hardware-shortcut-diagnostic"
            )
        }

        private static func resolve(
            input: String,
            flags: UIKeyModifierFlags
        ) -> CodexDesktopNativeShortcut? {
            CodexDesktopNativeShortcut.resolve(
                key: input,
                command: flags.contains(.command),
                shift: flags.contains(.shift),
                option: flags.contains(.alternate),
                control: flags.contains(.control)
            )
        }

        private static let shortcutCommands: [UIKeyCommand] = {
            CodexDesktopNativeShortcutBinding.released.map { binding in
                var modifiers: UIKeyModifierFlags = []
                if binding.command { modifiers.insert(.command) }
                if binding.shift { modifiers.insert(.shift) }
                if binding.option { modifiers.insert(.alternate) }
                if binding.control { modifiers.insert(.control) }
                let command = UIKeyCommand(
                    title: binding.title,
                    action: #selector(performDesktopShortcut(_:)),
                    input: binding.key,
                    modifierFlags: modifiers
                )
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }()
    }

    @MainActor
    private final class CodexDesktopHardwareShortcutContainerView: UIView {
        var onHardwareShortcut: (CodexDesktopNativeShortcut) -> Void

        init(
            onHardwareShortcut: @escaping (
                CodexDesktopNativeShortcut
            ) -> Void
        ) {
            self.onHardwareShortcut = onHardwareShortcut
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var keyCommands: [UIKeyCommand]? {
            Self.shortcutCommands
        }

        override func pressesBegan(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            let handled = dispatchHardwareShortcut(from: presses)
            if !handled {
                super.pressesBegan(presses, with: event)
            }
        }

        @objc
        private func performDesktopShortcut(
            _ command: UIKeyCommand
        ) {
            guard let input = command.input else {
                return
            }
            let flags = command.modifierFlags
            guard let shortcut = CodexDesktopNativeShortcut.resolve(
                key: input,
                command: flags.contains(.command),
                shift: flags.contains(.shift),
                option: flags.contains(.alternate),
                control: flags.contains(.control)
            ) else {
                return
            }
            onHardwareShortcut(shortcut)
        }

        private func dispatchHardwareShortcut(
            from presses: Set<UIPress>
        ) -> Bool {
            for press in presses {
                guard let key = press.key else { continue }
                let flags = key.modifierFlags
                let input = key.charactersIgnoringModifiers
                let shortcut = CodexDesktopNativeShortcut.resolve(
                    key: input,
                    command: flags.contains(.command),
                    shift: flags.contains(.shift),
                    option: flags.contains(.alternate),
                    control: flags.contains(.control),
                    physicalKeyCode: UInt16(key.keyCode.rawValue)
                )
                UserDefaults.standard.set(
                    "path=container-presses-began input=\(input) flags=\(flags.rawValue) handled=\(shortcut != nil)",
                    forKey: "codex.desktop.last-hardware-shortcut-diagnostic"
                )
                guard let shortcut else { continue }
                onHardwareShortcut(shortcut)
                return true
            }
            return false
        }

        private static let shortcutCommands: [UIKeyCommand] = {
            CodexDesktopNativeShortcutBinding.released.map { binding in
                var modifiers: UIKeyModifierFlags = []
                if binding.command { modifiers.insert(.command) }
                if binding.shift { modifiers.insert(.shift) }
                if binding.option { modifiers.insert(.alternate) }
                if binding.control { modifiers.insert(.control) }
                let command = UIKeyCommand(
                    title: binding.title,
                    action: #selector(performDesktopShortcut(_:)),
                    input: binding.key,
                    modifierFlags: modifiers
                )
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }()
    }
#endif
