import AppKit
import Foundation
import Observation
import SSHConfigSync

enum GistSyncStoreError: LocalizedError {
    case notConfigured
    case passphraseRequired
    case noManifestFile

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "GitHub sync isn't configured for this build."
        case .passphraseRequired: return "A passphrase is required to continue."
        case .noManifestFile: return "This gist doesn't contain a config sync file this app recognizes."
        }
    }
}

@MainActor
@Observable
final class GistSyncStore {
    static let shared = GistSyncStore()

    enum Connection: Equatable {
        case disconnected
        case connecting(userCode: String, uri: String)
        case connected(login: String)
    }

    struct PendingConflict {
        enum Resolution { case keepLocal, takeRemote, cancel }
        let resolve: (Resolution) -> Void
    }

    private(set) var connection: Connection = .disconnected
    var lastSyncedAt: Date? {
        settings.gistLastSyncedAt > 0 ? Date(timeIntervalSince1970: settings.gistLastSyncedAt) : nil
    }
    var pendingPush: Bool { settings.gistPendingPush }
    private(set) var lastError: String?
    var conflict: PendingConflict?

    private let settings: AppSettings
    private let secretStore: GistSecretStoring
    private let configStore: ConfigStore
    private let clientID: String
    private let deviceFlowClient: () -> GitHubDeviceFlowClient
    private let apiClient: (String) -> GistAPIClient

    init(
        settings: AppSettings = .shared,
        secretStore: GistSecretStoring = KeychainGistStore(),
        configStore: ConfigStore = .shared,
        clientID: String = BuildEnvironment.gitHubGistClientID ?? "",
        deviceFlowClient: (() -> GitHubDeviceFlowClient)? = nil,
        apiClient: @escaping (String) -> GistAPIClient = { GistAPIClient(token: $0) }
    ) {
        self.settings = settings
        self.secretStore = secretStore
        self.configStore = configStore
        self.clientID = clientID
        self.deviceFlowClient = deviceFlowClient ?? { GitHubDeviceFlowClient(clientID: clientID) }
        self.apiClient = apiClient
        configStore.onConfigSaved = { [weak self] in
            Task { @MainActor in await self?.autoSyncIfNeeded() }
        }
        if let token = secretStore.token(), !token.isEmpty {
            Task { await verifyStoredToken(token) }
        }
    }

    private func verifyStoredToken(_ token: String) async {
        do {
            let login = try await apiClient(token).authenticatedLogin()
            connection = .connected(login: login)
        } catch GistError.unauthorized {
            secretStore.removeToken()
            connection = .disconnected
        } catch {
            connection = .disconnected
        }
    }

    func connect() async {
        guard !clientID.isEmpty else {
            lastError = GistSyncStoreError.notConfigured.localizedDescription
            return
        }
        let flow = deviceFlowClient()
        do {
            let code = try await flow.requestCode()
            connection = .connecting(userCode: code.userCode, uri: code.verificationURI)
            var interval = max(code.interval, 1)
            let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
            while Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                switch try await flow.poll(deviceCode: code.deviceCode) {
                case .token(let token):
                    try secretStore.saveToken(token)
                    let login = try await apiClient(token).authenticatedLogin()
                    connection = .connected(login: login)
                    lastError = nil
                    return
                case .pending:
                    continue
                case .slowDown(let newInterval):
                    interval = max(newInterval, 1)
                case .denied:
                    connection = .disconnected
                    lastError = "GitHub sign-in was denied."
                    return
                case .expired:
                    connection = .disconnected
                    lastError = "The GitHub sign-in code expired. Try again."
                    return
                }
            }
            connection = .disconnected
            lastError = "The GitHub sign-in code expired. Try again."
        } catch {
            connection = .disconnected
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        secretStore.removeToken()
        secretStore.removePassphrase()
        forgetRemoteGist()
        settings.gistPendingPush = false
        settings.gistLastSyncedAt = 0
        connection = .disconnected
        lastError = nil
        recreatedAfterRemoteDeletion = false
    }

    private(set) var recreatedAfterRemoteDeletion = false

    func forgetRemoteGist() {
        settings.gistID = ""
        settings.gistLastSyncedVersion = ""
        settings.gistLastSyncedLocalHash = ""
    }

    func pushNow() async {
        guard case .connected = connection, let token = secretStore.token() else { return }
        do {
            try await push(using: apiClient(token), recreatingIfDeleted: true)
        } catch {
            handleSyncFailure(error, wasPush: true)
        }
    }

    private func push(using client: GistAPIClient, recreatingIfDeleted: Bool) async throws {
        let manifest = currentManifest()
        let files = try encodedFiles(for: manifest)
        let gist: GistAPIClient.Gist
        if settings.gistID.isEmpty {
            gist = try await client.create(files: files, description: "SSH Config Manager sync")
        } else {
            do {
                let present = Set(try await client.get(id: settings.gistID).files.keys)
                var patch: [String: String?] = files.mapValues { $0 }
                for stale in GistFileNames.superseded(byWriting: Set(files.keys)) where present.contains(stale) {
                    patch[stale] = String?.none
                }
                gist = try await client.update(id: settings.gistID, files: patch)
            } catch GistError.notFound where recreatingIfDeleted {
                forgetRemoteGist()
                recreatedAfterRemoteDeletion = true
                try await push(using: client, recreatingIfDeleted: false)
                return
            }
        }
        settings.gistID = gist.id
        settings.gistLastSyncedVersion = gist.version
        settings.gistLastSyncedLocalHash = manifest.contentHash()
        settings.gistLastSyncedAt = Date().timeIntervalSince1970
        settings.gistPendingPush = false
        lastError = nil
    }

    func pullNow() async {
        guard case .connected = connection, let token = secretStore.token(), !settings.gistID.isEmpty else { return }
        do {
            let gist = try await apiClient(token).get(id: settings.gistID)
            let manifest = try decodeManifest(from: gist.files)
            try configStore.applyRemoteSnapshot(manifest.toFiles())
            settings.gistLastSyncedVersion = gist.version
            settings.gistLastSyncedLocalHash = manifest.contentHash()
            settings.gistLastSyncedAt = Date().timeIntervalSince1970
            lastError = nil
        } catch GistError.notFound {
            forgetRemoteGist()
            lastError = "That gist no longer exists on GitHub. Push to back up your config to a new one."
        } catch {
            handleSyncFailure(error, wasPush: false)
        }
    }

    func autoSyncIfNeeded() async {
        guard settings.gistSyncEnabled, case .connected = connection, let token = secretStore.token() else { return }
        guard !settings.gistID.isEmpty else {
            await pushNow()
            return
        }
        do {
            let remote: GistAPIClient.Gist
            do {
                remote = try await apiClient(token).get(id: settings.gistID)
            } catch GistError.notFound {
                forgetRemoteGist()
                recreatedAfterRemoteDeletion = true
                await pushNow()
                return
            }
            let localHash = currentManifest().contentHash()
            let lastVersion = settings.gistLastSyncedVersion.isEmpty ? nil : settings.gistLastSyncedVersion
            let lastHash = settings.gistLastSyncedLocalHash.isEmpty ? nil : settings.gistLastSyncedLocalHash
            switch GistSyncDecision.decide(
                remoteVersion: remote.version, localHash: localHash, lastVersion: lastVersion, lastHash: lastHash)
            {
            case .noop:
                break
            case .push:
                await pushNow()
            case .pull:
                await pullNow()
            case .conflict:
                conflict = PendingConflict { [weak self] resolution in
                    Task { @MainActor in
                        guard let self else { return }
                        switch resolution {
                        case .keepLocal: await self.pushNow()
                        case .takeRemote: await self.pullNow()
                        case .cancel: break
                        }
                        self.conflict = nil
                    }
                }
            }
        } catch {
            handleSyncFailure(error, wasPush: nil)
        }
    }

    private func currentManifest() -> GistSyncManifest {
        GistSyncManifest.from(
            files: configStore.trackedFilesSnapshot(),
            generator: "sshconfigmanager/\(DeviceInfo.appVersion ?? "unknown")", now: Date())
    }

    private func encodedFiles(for manifest: GistSyncManifest) throws -> [String: String] {
        if settings.gistEncryptionEnabled {
            let passphrase = try passphraseForEncryption()
            let envelope = try GistCrypto.encrypt(manifest, passphrase: passphrase)
            let data = try JSONEncoder().encode(envelope)
            return [
                GistFileNames.encryptedManifest: String(decoding: data, as: UTF8.self),
                GistFileNames.notice: GistFileNames.noticeText,
            ]
        }
        let data = try JSONEncoder().encode(manifest)
        return [
            GistFileNames.plaintextManifest: String(decoding: data, as: UTF8.self),
            GistFileNames.notice: GistFileNames.noticeText,
        ]
    }

    private func decodeManifest(from files: [String: String]) throws -> GistSyncManifest {
        if let encContent = GistFileNames.encryptedManifestContent(in: files) {
            let envelope = try JSONDecoder().decode(GistCrypto.Envelope.self, from: Data(encContent.utf8))
            let passphrase = try passphraseForDecryption()
            let manifest = try GistCrypto.decrypt(envelope, passphrase: passphrase)
            try? secretStore.savePassphrase(passphrase)
            return manifest
        }
        if let jsonContent = GistFileNames.plaintextManifestContent(in: files) {
            return try JSONDecoder().decode(GistSyncManifest.self, from: Data(jsonContent.utf8))
        }
        throw GistSyncStoreError.noManifestFile
    }

    private func passphraseForEncryption() throws -> String {
        if let existing = secretStore.passphrase() { return existing }
        guard
            let entered = Self.promptForPassphrase(
                title: "Set a Sync Passphrase",
                message:
                    "This encrypts your SSH config before it leaves this Mac. You'll need it to restore on another machine."
            )
        else { throw GistSyncStoreError.passphraseRequired }
        try secretStore.savePassphrase(entered)
        return entered
    }

    private func passphraseForDecryption() throws -> String {
        if let existing = secretStore.passphrase() { return existing }
        guard
            let entered = Self.promptForPassphrase(
                title: "Enter Sync Passphrase",
                message: "This gist is encrypted. Enter the passphrase you set when you enabled sync.")
        else { throw GistSyncStoreError.passphraseRequired }
        return entered
    }

    private static func promptForPassphrase(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.isEmpty ? nil : field.stringValue
    }

    private func handleSyncFailure(_ error: Error, wasPush: Bool?) {
        if case GistError.unauthorized = error {
            secretStore.removeToken()
            connection = .disconnected
            lastError = "GitHub sign-in expired. Reconnect your account."
            return
        }
        lastError = error.localizedDescription
        if wasPush == true, GistSyncDecision.isTransient(error) {
            settings.gistPendingPush = true
        }
    }
}
