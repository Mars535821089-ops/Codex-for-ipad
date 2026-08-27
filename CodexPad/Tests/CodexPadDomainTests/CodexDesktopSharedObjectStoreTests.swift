import CodexPadDomain
import Testing

@testable import CodexPadApplication

@Test
func sharedObjectStoreSeedsTheReleasedDesktopSnapshot() {
    let snapshot =
        CodexDesktopSharedObjectStore.releasedInitialSnapshot(
            installationID: "installation-1"
        )

    #expect(
        snapshot["host_config"]
            == .object([
                "id": .string("local"),
                "display_name": .string("Local"),
                "kind": .string("local"),
            ])
    )
    #expect(snapshot["remote_ssh_connections"] == .array([]))
    #expect(
        snapshot["remote_control_connections_state"]
            == .object([
                "available": .bool(false),
                "accessRequired": .bool(false),
                "authRequired": .bool(false),
                "clientAuthorized": .bool(false),
            ])
    )
    #expect(snapshot["local_remote_control_client_id"] == .null)
    #expect(
        snapshot["local_remote_control_installation_id"]
            == .string("installation-1")
    )
    #expect(snapshot["local_remote_control_environment_id"] == nil)
    #expect(snapshot["local_remote_control_enabled"] == nil)
}

@Test
func sharedObjectStoreDistinguishesMissingFromExplicitNull() {
    let store = CodexDesktopSharedObjectStore(
        initialValues: ["present": .null]
    )

    #expect(store.lookup("missing") == .missing)
    #expect(store.lookup("present") == .value(.null))
    #expect(store.set(.null, for: "next") == .value(.null))
    #expect(store.set(nil, for: "present") == .missing)
    #expect(store.lookup("present") == .missing)
}

@Test
func sharedObjectStoreReferenceCountsSubscriptions() {
    let store = CodexDesktopSharedObjectStore(
        initialValues: ["selected-project": .string("one")]
    )

    #expect(
        store.subscribe("selected-project")
            == .value(.string("one"))
    )
    #expect(
        store.subscribe("selected-project")
            == .value(.string("one"))
    )
    #expect(store.subscriptionCount(for: "selected-project") == 2)
    #expect(store.unsubscribe("selected-project") == 1)
    #expect(store.isSubscribed(to: "selected-project"))
    #expect(store.unsubscribe("selected-project") == 0)
    #expect(!store.isSubscribed(to: "selected-project"))
    #expect(store.unsubscribe("selected-project") == 0)
}

@Test
func sharedObjectStoreResetKeepsValuesAndClearsSubscribers() {
    let store = CodexDesktopSharedObjectStore(initialValues: [:])
    _ = store.set(.string("two"), for: "selected-project")
    _ = store.subscribe("selected-project")

    store.resetSubscriptions()

    #expect(!store.isSubscribed(to: "selected-project"))
    #expect(
        store.lookup("selected-project")
            == .value(.string("two"))
    )
}

@Test
func sharedObjectStoreIgnoresEmptySubscriptionAndSetKeys() {
    let store = CodexDesktopSharedObjectStore(initialValues: [:])

    #expect(store.subscribe("") == .missing)
    #expect(store.set(.string("ignored"), for: "") == .missing)
    #expect(store.subscriptionCount(for: "") == 0)
    #expect(store.snapshot.isEmpty)
}
