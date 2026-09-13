import Foundation
import SSHConfigSync
import Testing

@testable import SSHConfigMacUI

private nonisolated final class FakeGistSecretStore: GistSecretStoring, @unchecked Sendable {
    var storedToken: String?
    var storedPassphrase: String?

    func saveToken(_ token: String) throws { storedToken = token }
    func token() -> String? { storedToken }
    func removeToken() { storedToken = nil }
    func savePassphrase(_ passphrase: String) throws { storedPassphrase = passphrase }
    func passphrase() -> String? { storedPassphrase }
    func removePassphrase() { storedPassphrase = nil }
}

@MainActor
struct GistSyncStoreTests {
    private func isolatedSettings() -> AppSettings {
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        return settings
    }

    private func makeStore(settings: AppSettings, secretStore: FakeGistSecretStore) -> GistSyncStore {
        GistSyncStore(
            settings: settings, secretStore: secretStore, configStore: ConfigStore(),
            deviceFlowClient: { GitHubDeviceFlowClient(clientID: "unused") },
            apiClient: { GistAPIClient(token: $0) })
    }

    @Test func startsDisconnectedWithNoStoredToken() async throws {
        let settings = isolatedSettings()
        let secretStore = FakeGistSecretStore()
        let sync = makeStore(settings: settings, secretStore: secretStore)
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(sync.connection == .disconnected)
    }

    @Test func restoresPendingPushAndLastSyncedAtFromSettings() {
        let settings = isolatedSettings()
        settings.gistPendingPush = true
        settings.gistLastSyncedAt = 1_700_000_000
        let sync = makeStore(settings: settings, secretStore: FakeGistSecretStore())
        #expect(sync.pendingPush == true)
        #expect(sync.lastSyncedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func reflectsSettingsThatArriveAfterTheStoreIsBuilt() {
        let settings = isolatedSettings()
        let sync = makeStore(settings: settings, secretStore: FakeGistSecretStore())
        #expect(sync.lastSyncedAt == nil)
        #expect(sync.pendingPush == false)

        settings.gistLastSyncedAt = 1_700_000_000
        settings.gistPendingPush = true

        #expect(sync.lastSyncedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(sync.pendingPush == true)
    }

    @Test func disconnectClearsTokenPassphraseAndSettings() {
        let settings = isolatedSettings()
        settings.gistID = "abc123"
        settings.gistLastSyncedVersion = "v1"
        settings.gistLastSyncedLocalHash = "hash"
        settings.gistPendingPush = true
        settings.gistLastSyncedAt = 1_700_000_000
        let secretStore = FakeGistSecretStore()
        secretStore.storedToken = "gho_abc"
        secretStore.storedPassphrase = "shh"

        let sync = makeStore(settings: settings, secretStore: secretStore)
        sync.disconnect()

        #expect(sync.connection == .disconnected)
        #expect(sync.pendingPush == false)
        #expect(sync.lastSyncedAt == nil)
        #expect(sync.lastError == nil)
        #expect(secretStore.storedToken == nil)
        #expect(secretStore.storedPassphrase == nil)
        #expect(settings.gistID.isEmpty)
        #expect(settings.gistLastSyncedVersion.isEmpty)
        #expect(settings.gistLastSyncedLocalHash.isEmpty)
        #expect(settings.gistPendingPush == false)
        #expect(settings.gistLastSyncedAt == 0)
    }

    @Test func autoSyncNoOpsWhenDisabled() async {
        let settings = isolatedSettings()
        settings.gistSyncEnabled = false
        let sync = makeStore(settings: settings, secretStore: FakeGistSecretStore())
        await sync.autoSyncIfNeeded()
        #expect(sync.connection == .disconnected)
        #expect(sync.lastError == nil)
    }

    @Test func autoSyncNoOpsWhenNotConnected() async {
        let settings = isolatedSettings()
        settings.gistSyncEnabled = true
        let sync = makeStore(settings: settings, secretStore: FakeGistSecretStore())
        await sync.autoSyncIfNeeded()
        #expect(sync.connection == .disconnected)
    }
}
