import Foundation
import Testing

@testable import CodexPadApplication

@MainActor
private final class FakeAuthenticationBrowserSession:
    CodexDesktopAuthenticationBrowserSession
{
    var acceptsPresentation = true
    private(set) var presentationCount = 0
    private(set) var dismissalCount = 0
    private var didFinish: (@MainActor () -> Void)?
    private var dismissalCompletion: (@MainActor () -> Void)?

    func present(
        onFinish: @escaping @MainActor () -> Void
    ) -> Bool {
        presentationCount += 1
        didFinish = onFinish
        return acceptsPresentation
    }

    func dismiss(
        completion: @escaping @MainActor () -> Void
    ) {
        dismissalCount += 1
        dismissalCompletion = completion
    }

    func finishFromBrowser() {
        didFinish?()
    }

    func finishDismissal() {
        let completion = dismissalCompletion
        dismissalCompletion = nil
        completion?()
    }
}

@MainActor
@Test
func authenticationBrowserPresenterReusesAndReplacesSessions() {
    let firstURL = URL(
        string: "https://auth.openai.com/oauth/authorize?state=first"
    )!
    let secondURL = URL(
        string: "https://auth.openai.com/oauth/authorize?state=second"
    )!
    var madeURLs: [URL] = []
    var sessions: [FakeAuthenticationBrowserSession] = []
    let presenter = CodexDesktopAuthenticationBrowserPresenter {
        url in
        madeURLs.append(url)
        let session = FakeAuthenticationBrowserSession()
        sessions.append(session)
        return session
    }

    #expect(presenter.presentAuthentication(at: firstURL))
    #expect(presenter.presentAuthentication(at: firstURL))
    #expect(madeURLs == [firstURL])
    #expect(sessions[0].presentationCount == 1)

    #expect(presenter.presentAuthentication(at: secondURL))
    #expect(sessions[0].dismissalCount == 1)
    #expect(madeURLs == [firstURL])

    sessions[0].finishDismissal()

    #expect(madeURLs == [firstURL, secondURL])
    #expect(sessions[1].presentationCount == 1)
}

@MainActor
@Test
func authenticationBrowserPresenterCoalescesReplacementToLatestURL() {
    let firstURL = URL(
        string: "https://auth.openai.com/oauth/authorize?state=first"
    )!
    let skippedURL = URL(
        string: "https://auth.openai.com/oauth/authorize?state=skipped"
    )!
    let latestURL = URL(
        string: "https://auth.openai.com/oauth/authorize?state=latest"
    )!
    var madeURLs: [URL] = []
    var sessions: [FakeAuthenticationBrowserSession] = []
    let presenter = CodexDesktopAuthenticationBrowserPresenter {
        url in
        madeURLs.append(url)
        let session = FakeAuthenticationBrowserSession()
        sessions.append(session)
        return session
    }

    #expect(presenter.presentAuthentication(at: firstURL))
    #expect(presenter.presentAuthentication(at: skippedURL))
    #expect(presenter.presentAuthentication(at: latestURL))
    #expect(sessions[0].dismissalCount == 1)

    sessions[0].finishDismissal()

    #expect(madeURLs == [firstURL, latestURL])
}

@MainActor
@Test
func authenticationBrowserPresenterRecoversAfterUserDismissal() {
    let firstURL = URL(
        string: "https://auth.openai.com/oauth/authorize?state=first"
    )!
    let secondURL = URL(
        string: "https://auth.openai.com/oauth/authorize?state=second"
    )!
    var sessions: [FakeAuthenticationBrowserSession] = []
    let presenter = CodexDesktopAuthenticationBrowserPresenter {
        _ in
        let session = FakeAuthenticationBrowserSession()
        sessions.append(session)
        return session
    }

    #expect(presenter.presentAuthentication(at: firstURL))
    sessions[0].finishFromBrowser()
    #expect(presenter.presentAuthentication(at: secondURL))

    #expect(sessions.count == 2)
    #expect(sessions[1].presentationCount == 1)
}

@MainActor
@Test
func authenticationBrowserPresenterRejectsMissingPresentationAnchor() {
    let url = URL(
        string: "https://auth.openai.com/oauth/authorize?state=first"
    )!
    let presenter = CodexDesktopAuthenticationBrowserPresenter {
        _ in nil
    }

    #expect(!presenter.presentAuthentication(at: url))
}

@MainActor
@Test
func authenticationBrowserPresenterCanRetryAfterPresentationRace() {
    let url = URL(
        string: "https://auth.openai.com/oauth/authorize?state=first"
    )!
    var sessions: [FakeAuthenticationBrowserSession] = []
    let presenter = CodexDesktopAuthenticationBrowserPresenter {
        _ in
        let session = FakeAuthenticationBrowserSession()
        session.acceptsPresentation = !sessions.isEmpty
        sessions.append(session)
        return session
    }

    #expect(!presenter.presentAuthentication(at: url))
    #expect(presenter.presentAuthentication(at: url))

    #expect(sessions.count == 2)
    #expect(sessions[0].presentationCount == 1)
    #expect(sessions[1].presentationCount == 1)
}

@MainActor
@Test
func authenticationBrowserPresenterDismissesCompletedLogin() {
    let firstURL = URL(
        string: "https://auth.openai.com/oauth/authorize?state=first"
    )!
    let secondURL = URL(
        string: "https://auth.openai.com/oauth/authorize?state=second"
    )!
    var sessions: [FakeAuthenticationBrowserSession] = []
    let presenter = CodexDesktopAuthenticationBrowserPresenter {
        _ in
        let session = FakeAuthenticationBrowserSession()
        sessions.append(session)
        return session
    }

    #expect(presenter.presentAuthentication(at: firstURL))
    presenter.dismissAuthentication()
    presenter.dismissAuthentication()

    #expect(sessions[0].dismissalCount == 1)

    sessions[0].finishDismissal()
    #expect(presenter.presentAuthentication(at: secondURL))
    #expect(sessions.count == 2)
}

@MainActor
@Test
func authenticationBrowserPresenterCompletionDropsPendingReplacement() {
    let firstURL = URL(
        string: "https://auth.openai.com/oauth/authorize?state=first"
    )!
    let pendingURL = URL(
        string: "https://auth.openai.com/oauth/authorize?state=pending"
    )!
    var madeURLs: [URL] = []
    var sessions: [FakeAuthenticationBrowserSession] = []
    let presenter = CodexDesktopAuthenticationBrowserPresenter {
        url in
        madeURLs.append(url)
        let session = FakeAuthenticationBrowserSession()
        sessions.append(session)
        return session
    }

    #expect(presenter.presentAuthentication(at: firstURL))
    #expect(presenter.presentAuthentication(at: pendingURL))
    presenter.dismissAuthentication()
    sessions[0].finishDismissal()

    #expect(madeURLs == [firstURL])
}
