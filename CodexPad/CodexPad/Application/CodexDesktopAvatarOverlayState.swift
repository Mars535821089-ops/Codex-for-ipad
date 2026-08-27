import Foundation

public struct CodexDesktopAvatarOverlayInputRegion:
    Equatable,
    Sendable
{
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidShape
        case invalidRectangle(index: Int)
    }

    public let left: Double
    public let top: Double
    public let width: Double
    public let height: Double

    public init(
        left: Double,
        top: Double,
        width: Double,
        height: Double
    ) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }

    public func contains(x: Double, y: Double) -> Bool {
        x >= left
            && y >= top
            && x < left + width
            && y < top + height
    }

    public static func decode(
        _ value: CodexDesktopAppHostRPC.Value
    ) throws -> [Self] {
        guard case let .array(values) = value else {
            throw Error.invalidShape
        }
        return try values.enumerated().map { index, value in
            guard case let .object(fields) = value,
                  case let .number(left)? = fields["left"],
                  case let .number(top)? = fields["top"],
                  case let .number(width)? = fields["width"],
                  case let .number(height)? = fields["height"],
                  left.isFinite,
                  top.isFinite,
                  width.isFinite,
                  height.isFinite,
                  width > 0,
                  height > 0
            else {
                throw Error.invalidRectangle(index: index)
            }
            return Self(
                left: left,
                top: top,
                width: width,
                height: height
            )
        }
    }
}

public enum CodexDesktopAppHostSurfaceTarget: Equatable, Sendable {
    case primary
    case avatarOverlay

    public static func resolve(portID: String) -> Self {
        portID.hasPrefix("avatar-overlay-app-host-")
            ? .avatarOverlay
            : .primary
    }
}

/// iPad counterpart of the released Electron AvatarOverlayManager's
/// presentation contract. Window-only movement and composition messages are
/// consumed by the in-app surface while open/close state remains observable
/// by the main released renderer.
public struct CodexDesktopAvatarOverlayState: Equatable, Sendable {
    public enum Effect: Equatable, Sendable {
        case ignored
        case handled
        case reportOpenState(Bool)
        case presentationChanged(Bool)
    }

    public private(set) var isOpen: Bool

    public init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    public mutating func handle(type: String) -> Effect {
        switch type {
        case "avatar-overlay-open-state-request":
            return .reportOpenState(isOpen)
        case "avatar-overlay-open":
            isOpen.toggle()
            return .presentationChanged(isOpen)
        case "avatar-overlay-close", "avatar-overlay-hide":
            isOpen = false
            return .presentationChanged(false)
        case "avatar-overlay-drag-start",
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
             "avatar-overlay-keyboard-interaction-changed":
            return .handled
        default:
            return .ignored
        }
    }
}
