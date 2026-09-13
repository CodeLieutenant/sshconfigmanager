//
//  GenerateKeySheet.swift
//  sshconfigmanager
//
//  Guided "Generate key…" sheet: pick an algorithm, name, comment and optional
//  passphrase, generate the pair in-process (see SSHKeyGenerator), write it into the
//  granted ~/.ssh, and optionally wire it into a host as an IdentityFile.
//

import SSHConfigCore
import SSHConfigServices
import SwiftUI

struct GenerateKeySheet: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Called with the freshly created key so the caller can select it in the table.
    let onCreated: (SSHPublicKey) -> Void

    /// Defaults to the user's preferred algorithm (`AppSettings.defaultKeyAlgorithm`,
    /// Ed25519 out of the box). The "Generate Replacement" deep-link passes the weak
    /// key's comment so the new key keeps it.
    @MainActor
    init(
        initialAlgorithm: KeyAlgorithm? = nil,
        initialComment: String = "",
        initialFileName: String? = nil,
        onCreated: @escaping (SSHPublicKey) -> Void
    ) {
        // `nil` → the user's preferred default. Resolved here (not as a default
        // argument) because `AppSettings.shared` is main-actor isolated.
        let algorithm = initialAlgorithm ?? AppSettings.shared.defaultKeyAlgorithm
        self.onCreated = onCreated
        _algorithm = State(initialValue: algorithm)
        _fileName = State(initialValue: initialFileName ?? algorithm.defaultFileName)
        _comment = State(initialValue: initialComment)
    }

    @State private var algorithm: KeyAlgorithm
    @State private var fileName: String
    @State private var comment: String
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var attachHostID: HostBlock.ID?
    @State private var errorMessage: String?
    @State private var isGenerating = false

    /// Selectable hosts for the optional IdentityFile wiring (skip wildcards).
    private var hosts: [HostBlock] { store.allHostBlocks.filter { !$0.isWildcard } }

    private var trimmedName: String {
        fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A validation message for the name field, or nil when it's good.
    private var nameError: String? {
        guard !trimmedName.isEmpty else { return nil } // empty: just disable, no error text
        guard ConfigStore.isValidKeyFileName(trimmedName) else {
            return "Use a single file name with no “/”."
        }
        let existing = store.existingFileNames
        if existing.contains(trimmedName) || existing.contains(trimmedName + ".pub") {
            return "“\(trimmedName)” already exists — pick another name."
        }
        return nil
    }

    private var passphraseMismatch: Bool {
        !confirmPassphrase.isEmpty && passphrase != confirmPassphrase
    }

    private var canGenerate: Bool {
        !trimmedName.isEmpty && nameError == nil && passphrase == confirmPassphrase && !isGenerating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Generate SSH Key")
                .font(.headline)
                .padding([.top, .horizontal])

            Form {
                Section {
                    Picker("Algorithm", selection: $algorithm) {
                        ForEach(KeyAlgorithm.allCases) { algo in
                            Text(algo.displayName).tag(algo)
                        }
                    }
                    .onChange(of: algorithm) { oldValue, newValue in
                        // Track the conventional default unless the user customized it.
                        if trimmedName == oldValue.defaultFileName {
                            fileName = newValue.defaultFileName
                        }
                    }

                    TextField("File name", text: $fileName, prompt: Text(algorithm.defaultFileName))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("key-filename-field")
                    if let nameError {
                        Label(nameError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    TextField("Comment", text: $comment, prompt: Text("user@host"))
                        .autocorrectionDisabled()
                }

                Section("Passphrase") {
                    SecureField("Passphrase", text: $passphrase)
                    SecureField("Confirm", text: $confirmPassphrase)
                    if passphraseMismatch {
                        Label("Passphrases don't match.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if passphrase.isEmpty {
                        Label(
                            "Leave empty for no passphrase — not recommended.",
                            systemImage: "lock.open"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if !hosts.isEmpty {
                    Section("Use for a host (optional)") {
                        Picker("Add as IdentityFile to", selection: $attachHostID) {
                            Text("None").tag(HostBlock.ID?.none)
                            ForEach(hosts) { host in
                                Text(host.title).tag(HostBlock.ID?.some(host.id))
                            }
                        }
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Generate") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canGenerate)
                    .accessibilityIdentifier("generate-key-confirm-button")
            }
            .padding()
        }
        .frame(width: 460)
        .onAppear { if comment.isEmpty { comment = Self.defaultComment() } }
    }

    private func generate() {
        errorMessage = nil
        isGenerating = true
        defer { isGenerating = false }
        do {
            let key = try store.createKey(
                algorithm: algorithm, fileName: trimmedName, comment: comment,
                passphrase: passphrase.isEmpty ? nil : passphrase)
            if let hostID = attachHostID {
                store.attachIdentity(fileName: trimmedName, toHost: hostID)
            }
            onCreated(key)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `user@host`, matching what `ssh-keygen` writes by default.
    private static func defaultComment() -> String {
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
        return "\(NSUserName())@\(host)"
    }
}
