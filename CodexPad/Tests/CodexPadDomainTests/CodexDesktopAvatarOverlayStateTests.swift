import CodexPadDomain
import Testing

@testable import CodexPadApplication

@Test
func desktopAvatarOverlayInputRegionsDecodeReleasedRectangles() throws {
    let regions = try CodexDesktopAvatarOverlayInputRegion.decode(
        .array([
            .object([
                "left": .number(12),
                "top": .number(18),
                "width": .number(112),
                "height": .number(90),
            ])
        ])
    )

    #expect(regions == [
        .init(left: 12, top: 18, width: 112, height: 90)
    ])
    #expect(regions[0].contains(x: 12, y: 18))
    #expect(regions[0].contains(x: 123.9, y: 107.9))
    #expect(!regions[0].contains(x: 124, y: 108))
}

@Test
func desktopAvatarOverlayInputRegionsRejectMalformedShapes() {
    #expect(throws: CodexDesktopAvatarOverlayInputRegion.Error.self) {
        try CodexDesktopAvatarOverlayInputRegion.decode(
            .array([
                .object([
                    "left": .number(0),
                    "top": .number(0),
                    "width": .number(0),
                    "height": .number(10),
                ])
            ])
        )
    }
}

@Test
func desktopAppHostSurfaceTargetRoutesScopedOverlayPorts() {
    #expect(
        CodexDesktopAppHostSurfaceTarget.resolve(portID: "app-host-1")
            == .primary
    )
    #expect(
        CodexDesktopAppHostSurfaceTarget.resolve(
            portID: "avatar-overlay-app-host-1"
        ) == .avatarOverlay
    )
}

@Test
func desktopAvatarOverlayMirrorsReleasedOpenStateRoundTrip() {
    var state = CodexDesktopAvatarOverlayState()

    #expect(
        state.handle(type: "avatar-overlay-open-state-request")
            == .reportOpenState(false)
    )
    #expect(
        state.handle(type: "avatar-overlay-open")
            == .presentationChanged(true)
    )
    #expect(state.isOpen)
    #expect(
        state.handle(type: "avatar-overlay-open-state-request")
            == .reportOpenState(true)
    )
    #expect(
        state.handle(type: "avatar-overlay-open")
            == .presentationChanged(false)
    )
    #expect(!state.isOpen)
}

@Test
func desktopAvatarOverlayCloseAndHideDismissTheInAppSurface() {
    var state = CodexDesktopAvatarOverlayState(isOpen: true)

    #expect(
        state.handle(type: "avatar-overlay-hide")
            == .presentationChanged(false)
    )
    #expect(!state.isOpen)

    state = CodexDesktopAvatarOverlayState(isOpen: true)
    #expect(
        state.handle(type: "avatar-overlay-close")
            == .presentationChanged(false)
    )
    #expect(!state.isOpen)
}

@Test
func desktopAvatarOverlayConsumesReleasedInteractionEvents() {
    var state = CodexDesktopAvatarOverlayState(isOpen: true)
    let interactionTypes = [
        "avatar-overlay-drag-start",
        "avatar-overlay-drag-move",
        "avatar-overlay-drag-end",
        "avatar-overlay-drag-release",
        "avatar-overlay-mascot-resize-start",
        "avatar-overlay-mascot-resize-move",
        "avatar-overlay-mascot-resize-end",
        "avatar-overlay-element-size-changed",
        "avatar-overlay-composition-changed",
        "avatar-overlay-composition-surface-action",
        "avatar-overlay-pointer-interaction-changed",
        "avatar-overlay-keyboard-interaction-changed",
    ]

    for type in interactionTypes {
        #expect(state.handle(type: type) == .handled)
        #expect(state.isOpen)
    }
    #expect(state.handle(type: "unrelated-event") == .ignored)
}
