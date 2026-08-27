#if SWIFT_PACKAGE
    import CodexPadProtocolBridge
#endif
import Foundation

#if os(iOS) && canImport(UIKit)
    import UIKit
#endif

@MainActor
public protocol CodexDesktopExternalURLOpening: AnyObject {
    @discardableResult
    func open(
        _ request: CodexDesktopOpenInBrowserRequest
    ) -> Bool

    func dismissAuthentication()
}

public extension CodexDesktopExternalURLOpening {
    func dismissAuthentication() {}
}

public enum AuthenticationPresentationPolicy: Sendable {
    case systemFallback
    case inAppOnly
    /// The platform login driver already owns the active authentication
    /// session.  Renderer `open_in_browser` frames are acknowledged without
    /// presenting a second browser over that session.
    case sessionDriverOwned
}

@MainActor
public final class CodexDesktopExternalURLOpener:
    CodexDesktopExternalURLOpening
{
    public typealias OpenURL = @MainActor (URL) -> Void

    private let authenticationBrowser:
        (any CodexDesktopAuthenticationBrowserPresenting)?
    private let authenticationPresentationPolicy:
        AuthenticationPresentationPolicy
    private let openURL: OpenURL

    public init(_ openURL: @escaping OpenURL) {
        authenticationBrowser = nil
        authenticationPresentationPolicy = .systemFallback
        self.openURL = openURL
    }

    public init(
        authenticationBrowser:
            (any CodexDesktopAuthenticationBrowserPresenting)?,
        authenticationPresentationPolicy:
            AuthenticationPresentationPolicy = .systemFallback,
        openURL: @escaping OpenURL
    ) {
        self.authenticationBrowser = authenticationBrowser
        self.authenticationPresentationPolicy =
            authenticationPresentationPolicy
        self.openURL = openURL
    }

    #if os(iOS) && canImport(UIKit)
        public convenience init(
            authenticationPresentationPolicy:
                AuthenticationPresentationPolicy = .systemFallback
        ) {
            self.init(
                authenticationBrowser:
                    CodexDesktopAuthenticationBrowserPresenter(),
                authenticationPresentationPolicy:
                    authenticationPresentationPolicy,
                openURL: { url in
                    UIApplication.shared.open(url)
                }
            )
        }
    #endif

    @discardableResult
    public func open(
        _ request: CodexDesktopOpenInBrowserRequest
    ) -> Bool {
        guard let url = URL(string: request.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return false
        }

        if Self.isReleasedAuthenticationRequest(
            request,
            url: url
        ) {
            if case .sessionDriverOwned =
                authenticationPresentationPolicy
            {
                return true
            }
            if authenticationBrowser?.presentAuthentication(at: url)
                == true
            {
                return true
            }
            if case .inAppOnly = authenticationPresentationPolicy {
                return false
            }
        }

        var externalURL = url
        if scheme == "https",
           url.host?.lowercased() == "chatgpt.com",
           var components = URLComponents(
               url: url,
               resolvingAgainstBaseURL: false
           )
        {
            var queryItems = components.queryItems ?? []
            let universalLinkOptOut = URLQueryItem(
                name: "no_universal_links",
                value: "1"
            )
            if let existingIndex = queryItems.firstIndex(
                where: {
                    $0.name == universalLinkOptOut.name
                }
            ) {
                queryItems[existingIndex] = universalLinkOptOut
                queryItems = queryItems.enumerated().compactMap {
                    index,
                    item in
                    if index != existingIndex,
                       item.name == universalLinkOptOut.name
                    {
                        return nil
                    }
                    return item
                }
            } else {
                queryItems.append(universalLinkOptOut)
            }
            components.queryItems = queryItems
            externalURL = components.url ?? url
        }
        openURL(externalURL)
        return true
    }

    public func dismissAuthentication() {
        authenticationBrowser?.dismissAuthentication()
    }

    private static func isReleasedAuthenticationRequest(
        _ request: CodexDesktopOpenInBrowserRequest,
        url: URL
    ) -> Bool {
        guard request.openTarget == "external-browser" else {
            return false
        }

        return isReleasedOAuthAuthorizeURL(url)
            || isReleasedDesktopAuthenticationWrapperURL(url)
    }

    private static func isReleasedOAuthAuthorizeURL(
        _ url: URL
    ) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "auth.openai.com"
            && url.port == nil
            && url.user == nil
            && url.password == nil
            && url.path == "/oauth/authorize"
    }

    private static func isReleasedDesktopAuthenticationWrapperURL(
        _ url: URL
    ) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "chatgpt.com",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.path == "/codex/desktop-auth",
              url.fragment == nil,
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              let queryItems = components.queryItems,
              Self.isReleasedDesktopAuthenticationWrapperQuery(
                  queryItems
              ),
              let authorizeURLString = queryItems.first(
                  where: { $0.name == "authorize_url" }
              )?.value,
              let authorizeURL = URL(string: authorizeURLString)
        else {
            return false
        }

        return isReleasedOAuthAuthorizeURL(authorizeURL)
    }

    private static func isReleasedDesktopAuthenticationWrapperQuery(
        _ queryItems: [URLQueryItem]
    ) -> Bool {
        let authorizeURLItems = queryItems.filter {
            $0.name == "authorize_url"
        }
        let streamlinedLoginItems = queryItems.filter {
            $0.name == "codex_streamlined_login"
        }
        return authorizeURLItems.count == 1
            && streamlinedLoginItems.count <= 1
            && queryItems.count
                == authorizeURLItems.count
                    + streamlinedLoginItems.count
            && streamlinedLoginItems.allSatisfy {
                $0.value == "true"
            }
    }
}
