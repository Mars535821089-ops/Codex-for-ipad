#if SWIFT_PACKAGE
import CodexPadProtocolBridge
#endif

public enum CodexDesktopAppServerNotificationProjector {
    public static func messages(
        _ notifications: [CodexAppServerNotification],
        hostID: String
    ) -> [CodexDesktopHostMessage] {
        notifications.map {
            .mcpNotification(
                hostID: hostID,
                method: $0.method,
                params: $0.params,
                metadata: [:]
            )
        }
    }
}
