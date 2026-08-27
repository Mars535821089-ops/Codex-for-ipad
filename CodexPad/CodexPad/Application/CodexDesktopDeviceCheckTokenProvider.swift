#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation
#if os(iOS) && canImport(DeviceCheck)
import DeviceCheck
#endif

/// Supplies the attestation token normally injected by Electron's native
/// devicecheck module before a ChatGPT conversation stream is sent.
public protocol CodexDesktopDeviceCheckTokenProviding: Sendable {
    func token() async -> String?
}

public struct CodexDesktopPlatformDeviceCheckTokenProvider:
    CodexDesktopDeviceCheckTokenProviding,
    Sendable
{
    public init() {}

    public func token() async -> String? {
#if os(iOS) && canImport(DeviceCheck)
        guard DCDevice.current.isSupported else { return nil }
        return await withCheckedContinuation { continuation in
            DCDevice.current.generateToken { token, _ in
                continuation.resume(
                    returning: token?.base64EncodedString()
                )
            }
        }
#else
        return nil
#endif
    }
}
