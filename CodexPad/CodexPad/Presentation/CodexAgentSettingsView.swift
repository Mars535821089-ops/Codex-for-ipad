import SwiftUI

struct CodexAgentSettingsView: View {
    @Binding var approvalPolicyRaw: String
    @Binding var sandboxModeRaw: String
    @Binding var modelID: String
    @Binding var reasoningEffortRaw: String
    let modelCatalog: CodexModelCatalogViewState
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var visibleModels: [CodexModelConfiguration] {
        modelCatalog.models.filter { !$0.hidden }
    }

    private var selectedModel: CodexModelConfiguration? {
        modelCatalog.model(selectionID: modelID)
    }

    private var selectedEffortOption:
        CodexModelReasoningEffortOption?
    {
        selectedModel?.reasoningEffortOptions.first {
            $0.reasoningEffort.rawValue == reasoningEffortRaw
        }
    }

    private var canSave: Bool {
        modelCatalog.canRunModelOperations
            && selectedModel != nil
            && selectedEffortOption != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Model", selection: $modelID) {
                        if selectedModel == nil, !modelID.isEmpty {
                            Text("\(modelID) — Unavailable")
                                .tag(modelID)
                        }
                        ForEach(visibleModels) { model in
                            Text(model.displayName)
                                .tag(pickerSelectionID(for: model))
                        }
                    }
                    .disabled(visibleModels.isEmpty)

                    if let selectedModel {
                        Text(selectedModel.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !modelID.isEmpty {
                        Text(
                            "This saved model is not present in the current server catalog."
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    Picker("Reasoning effort", selection: $reasoningEffortRaw) {
                        if selectedEffortOption == nil,
                           !reasoningEffortRaw.isEmpty {
                            Text("\(reasoningEffortRaw) — Unavailable")
                                .tag(reasoningEffortRaw)
                        }
                        if let selectedModel {
                            ForEach(
                                selectedModel.reasoningEffortOptions,
                                id: \.reasoningEffort.rawValue
                            ) { option in
                                Text(option.reasoningEffort.displayName)
                                    .tag(option.reasoningEffort.rawValue)
                            }
                        }
                    }
                    .disabled(selectedModel == nil)

                    if let selectedEffortOption {
                        Text(selectedEffortOption.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(modelCatalogFooter)
                }

                Section("Provider capabilities") {
                    capabilityRow(
                        "Namespace tools",
                        capability: .namespaceTools
                    )
                    capabilityRow(
                        "Image generation",
                        capability: .imageGeneration
                    )
                    capabilityRow(
                        "Web search",
                        capability: .webSearch
                    )
                }

                Section {
                    Picker(
                        "Approval policy",
                        selection: $approvalPolicyRaw
                    ) {
                        ForEach(CodexApprovalPolicy.allCases, id: \.rawValue) {
                            Text($0.displayName).tag($0.rawValue)
                        }
                    }
                } footer: {
                    Text("Choose when Codex asks before changing the project.")
                }

                Section {
                    Picker("Sandbox settings", selection: $sandboxModeRaw) {
                        ForEach(CodexSandboxMode.allCases, id: \.rawValue) {
                            Text($0.displayName).tag($0.rawValue)
                        }
                    }
                } footer: {
                    Text("Controls which workspace operations Codex may run.")
                }
            }
            .onChange(of: modelID) {
                guard let selectedModel,
                      !selectedModel.supportedReasoningEfforts.contains(
                        where: {
                            $0.rawValue == reasoningEffortRaw
                        }
                      )
                else {
                    return
                }
                reasoningEffortRaw =
                    selectedModel.defaultReasoningEffort.rawValue
            }
            .navigationTitle("Agent configuration")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pickerSelectionID(
        for model: CodexModelConfiguration
    ) -> String {
        if model.id == modelID, model.model != modelID {
            return modelID
        }
        return model.model
    }

    private var modelCatalogFooter: String {
        let provider = modelCatalog.requestedSource?.modelProvider
            ?? modelCatalog.source?.modelProvider
            ?? "current provider"
        if modelCatalog.isStale {
            return
                "Showing the last successful \(provider) catalog while the current catalog is unavailable."
        }
        switch modelCatalog.phase {
        case .loading:
            return "Loading models and effort descriptions from \(provider)."
        case .loaded where visibleModels.isEmpty:
            return "\(provider) returned an empty model catalog."
        case .loaded:
            return
                "Models and effort descriptions are supplied by \(provider)."
        case .failed:
            return modelCatalog.problem?.message
                ?? "The current model catalog did not load."
        }
    }

    @ViewBuilder
    private func capabilityRow(
        _ title: String,
        capability: CodexModelProviderCapability
    ) -> some View {
        let isEnabled = modelCatalog.capabilityGate(capability)
        LabeledContent(title) {
            Label(
                isEnabled ? "Available" : "Unavailable",
                systemImage: isEnabled
                    ? "checkmark.circle.fill"
                    : "xmark.circle"
            )
            .foregroundStyle(isEnabled ? .green : .secondary)
        }
    }
}
