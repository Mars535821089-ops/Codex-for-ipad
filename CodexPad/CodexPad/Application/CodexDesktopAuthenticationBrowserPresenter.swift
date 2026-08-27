import Foundation

@MainActor
public protocol CodexDesktopAuthenticationBrowserPresenting: AnyObject {
    @discardableResult
    func presentAuthentication(at url: URL) -> Bool

    func dismissAuthentication()
}

@MainActor
protocol CodexDesktopAuthenticationBrowserSession: AnyObject {
    @discardableResult
    func present(
        onFinish: @escaping @MainActor () -> Void
    ) -> Bool

    func dismiss(
        completion: @escaping @MainActor () -> Void
    )
}

@MainActor
public final class CodexDesktopAuthenticationBrowserPresenter:
    CodexDesktopAuthenticationBrowserPresenting
{
    typealias SessionFactory =
        @MainActor (URL) ->
        (any CodexDesktopAuthenticationBrowserSession)?

    private struct ActiveSession {
        let identifier: UUID
        let url: URL
        let session: any CodexDesktopAuthenticationBrowserSession
    }

    private let makeSession: SessionFactory
    private var activeSession: ActiveSession?
    private var pendingURL: URL?
    private var dismissingSessionIdentifier: UUID?

    init(
        makeSession: @escaping SessionFactory
    ) {
        self.makeSession = makeSession
    }

    @discardableResult
    public func presentAuthentication(at url: URL) -> Bool {
        if let activeSession,
           activeSession.url == url,
           dismissingSessionIdentifier == nil,
           pendingURL == nil
        {
            return true
        }

        if dismissingSessionIdentifier != nil {
            pendingURL = url
            return true
        }

        guard let activeSession else {
            return beginSession(at: url)
        }

        pendingURL = url
        dismissingSessionIdentifier = activeSession.identifier
        activeSession.session.dismiss { [weak self] in
            self?.completeDismissal(
                of: activeSession.identifier
            )
        }
        return true
    }

    public func dismissAuthentication() {
        pendingURL = nil

        guard dismissingSessionIdentifier == nil,
              let activeSession
        else {
            return
        }

        dismissingSessionIdentifier = activeSession.identifier
        activeSession.session.dismiss { [weak self] in
            self?.completeDismissal(
                of: activeSession.identifier
            )
        }
    }

    @discardableResult
    private func beginSession(at url: URL) -> Bool {
        guard let session = makeSession(url) else {
            return false
        }

        let identifier = UUID()
        activeSession = ActiveSession(
            identifier: identifier,
            url: url,
            session: session
        )
        let presented = session.present { [weak self] in
            self?.sessionDidFinish(identifier: identifier)
        }
        guard presented else {
            if activeSession?.identifier == identifier {
                activeSession = nil
            }
            return false
        }
        return true
    }

    private func completeDismissal(of identifier: UUID) {
        guard dismissingSessionIdentifier == identifier else {
            return
        }
        if activeSession?.identifier == identifier {
            activeSession = nil
        }
        dismissingSessionIdentifier = nil
        beginPendingSessionIfPossible()
    }

    private func sessionDidFinish(identifier: UUID) {
        guard activeSession?.identifier == identifier else {
            return
        }
        activeSession = nil
        if dismissingSessionIdentifier != identifier {
            beginPendingSessionIfPossible()
        }
    }

    private func beginPendingSessionIfPossible() {
        guard dismissingSessionIdentifier == nil,
              activeSession == nil,
              let pendingURL
        else {
            return
        }
        self.pendingURL = nil
        _ = beginSession(at: pendingURL)
    }
}

#if os(iOS) && canImport(UIKit) && canImport(SafariServices)
    import SafariServices
    import UIKit

    @MainActor
    private final class CodexDesktopSafariAuthenticationSession:
        NSObject,
        CodexDesktopAuthenticationBrowserSession,
        SFSafariViewControllerDelegate
    {
        private let url: URL
        private weak var presentingViewController: UIViewController?
        private var safariViewController: SFSafariViewController?
        private var onFinish: (@MainActor () -> Void)?

        init(
            url: URL,
            presentingViewController: UIViewController
        ) {
            self.url = url
            self.presentingViewController = presentingViewController
        }

        @discardableResult
        func present(
            onFinish: @escaping @MainActor () -> Void
        ) -> Bool {
            guard safariViewController == nil,
                  let presentingViewController,
                  presentingViewController.viewIfLoaded?.window != nil,
                  presentingViewController.presentedViewController == nil
            else {
                return false
            }

            let safariViewController = SFSafariViewController(url: url)
            safariViewController.delegate = self
            safariViewController.view.accessibilityIdentifier =
                "CodexAuthenticationBrowser"
            self.onFinish = onFinish
            self.safariViewController = safariViewController
            presentingViewController.present(
                safariViewController,
                animated: true
            )
            return true
        }

        func dismiss(
            completion: @escaping @MainActor () -> Void
        ) {
            onFinish = nil
            guard let safariViewController else {
                completion()
                return
            }
            guard safariViewController.presentingViewController != nil else {
                self.safariViewController = nil
                completion()
                return
            }
            safariViewController.dismiss(animated: true) {
                self.safariViewController = nil
                completion()
            }
        }

        nonisolated func safariViewControllerDidFinish(
            _ controller: SFSafariViewController
        ) {
            Task { @MainActor [weak self] in
                self?.finishFromSafari()
            }
        }

        private func finishFromSafari() {
            safariViewController = nil
            let finish = onFinish
            onFinish = nil
            finish?()
        }
    }

    extension CodexDesktopAuthenticationBrowserPresenter {
        public convenience init() {
            self.init(
                rootViewControllerProvider: {
                    Self.activeRootViewController()
                }
            )
        }

        public convenience init(
            rootViewControllerProvider:
                @escaping @MainActor () -> UIViewController?
        ) {
            self.init { url in
                guard let rootViewController =
                    rootViewControllerProvider(),
                    let presentingViewController =
                        Self.topPresentationViewController(
                            from: rootViewController
                        ),
                    presentingViewController.viewIfLoaded?.window != nil
                else {
                    return nil
                }
                return CodexDesktopSafariAuthenticationSession(
                    url: url,
                    presentingViewController: presentingViewController
                )
            }
        }

        private static func activeRootViewController()
            -> UIViewController?
        {
            let foregroundScenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
            let visibleWindows = foregroundScenes
                .flatMap(\.windows)
                .filter {
                    !$0.isHidden && $0.alpha > 0 && $0.windowLevel == .normal
                }
            return (
                visibleWindows.first(where: \.isKeyWindow)
                    ?? visibleWindows.first
            )?.rootViewController
        }

        private static func topPresentationViewController(
            from rootViewController: UIViewController
        ) -> UIViewController? {
            var current: UIViewController? = rootViewController
            var visited = Set<ObjectIdentifier>()

            while let candidate = current {
                let identifier = ObjectIdentifier(candidate)
                guard visited.insert(identifier).inserted else {
                    return nil
                }

                if let presented = candidate.presentedViewController,
                   !presented.isBeingDismissed
                {
                    current = presented
                } else if let navigation =
                    candidate as? UINavigationController
                {
                    current =
                        navigation.visibleViewController
                        ?? navigation.topViewController
                        ?? navigation
                    if current === navigation {
                        return navigation
                    }
                } else if let tab =
                    candidate as? UITabBarController,
                    let selected = tab.selectedViewController
                {
                    current = selected
                } else if let split =
                    candidate as? UISplitViewController,
                    let visible = split.viewControllers.reversed()
                        .first(where: {
                            $0.viewIfLoaded?.window != nil
                        })
                        ?? split.viewControllers.last
                {
                    current = visible
                } else {
                    return candidate
                }
            }
            return nil
        }
    }
#endif
