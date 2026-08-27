import SwiftUI

struct CodexAccountView: View {
    @Bindable var accountStore: CodexAccountStore
    let threadID: String?

    init(accountStore: CodexAccountStore, threadID: String? = nil) {
        self.accountStore = accountStore
        self.threadID = threadID
    }
    @Environment(\.openURL) private var openURL
    @State private var apiKeyDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                if accountStore.isSignedIn {
                    Section(
                        accountStore.authMode == .apiKey
                            ? "OpenAI API key"
                            : "ChatGPT"
                    ) {
                        Label(
                            accountStore.authMode == .apiKey
                                ? "API key saved"
                                : "Signed in",
                            systemImage: "checkmark.circle.fill"
                        )
                            .foregroundStyle(.green)
                        if let accountID = accountStore.accountID {
                            LabeledContent("Account", value: accountID)
                                .textSelection(.enabled)
                        }
                        Button("Sign Out", role: .destructive) {
                            accountStore.signOut()
                        }
                        NavigationLink {
                            CodexUsageCenterView(accountStore: accountStore, threadID: threadID)
                        } label: {
                            Label("Usage", systemImage: "chart.bar.xaxis")
                        }
                        .accessibilityIdentifier("codex.account.usage")
                    }
                } else if let code = accountStore.deviceCode {
                    Section("Connect Codex") {
                        Text("Enter this one-time code in the ChatGPT sign-in page.")
                            .foregroundStyle(.secondary)
                        Text(code.userCode)
                            .font(.system(.title, design: .monospaced))
                            .fontWeight(.semibold)
                            .textSelection(.enabled)
                            .accessibilityLabel("Device code \(code.userCode)")
                        Button("Open ChatGPT Sign In") {
                            openURL(code.verificationURL)
                        }
                        if accountStore.isWorking {
                            HStack {
                                ProgressView()
                                Text("Waiting for sign-in…")
                            }
                        }
                    }
                    .task(id: code.userCode) {
                        await accountStore.completeDeviceCodeLogin()
                    }
                } else {
                    Section("ChatGPT") {
                        Text("Use the same ChatGPT account as Codex. Credentials stay in this iPad’s Keychain.")
                            .foregroundStyle(.secondary)
                        Button("Sign in with ChatGPT") {
                            Task {
                                await accountStore.requestDeviceCode()
                            }
                        }
                        .disabled(accountStore.isWorking)
                    }
                }

                Section("OpenAI API key") {
                    SecureField("sk-…", text: $apiKeyDraft)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("codex.account.apiKey")
                    Button("Save API key") {
                        let value = apiKeyDraft
                        do {
                            try accountStore.acceptAPIKey(value)
                            apiKeyDraft = ""
                        } catch {
                            // `acceptAPIKey` publishes a user-safe problem on
                            // the account store's next render; keep the draft
                            // intact so a transient Keychain failure does not
                            // erase the user's input.
                            _ = error
                        }
                    }
                    .disabled(
                        apiKeyDraft.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
                    .accessibilityIdentifier("codex.account.saveAPIKey")
                    Text(
                        "Use an API key for the OpenAI API when ChatGPT sign-in is unavailable."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let problem = accountStore.problem {
                    Section {
                        Text(problem)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Codex Account")
        }
        .presentationDetents([.medium, .large])
    }
}
