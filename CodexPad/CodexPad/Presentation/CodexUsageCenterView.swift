import SwiftUI

struct CodexUsageCenterView: View {
    @Bindable var accountStore: CodexAccountStore
    let threadID: String?
    @State private var payload: CodexJSONValue?
    @State private var model: CodexUsageCenterModel?
    @State private var summary: CodexUsageSummary?
    @State private var isLoading = false
    @State private var problem: String?

    var body: some View {
        Group {
            if isLoading && payload == nil {
                ProgressView("Loading usage…")
            } else if let problem {
                ContentUnavailableView("Usage unavailable", systemImage: "chart.bar.xaxis", description: Text(problem))
            } else if let model {
                threadUsage(model)
            } else if let summary {
                accountUsage(summary)
            } else {
                ContentUnavailableView("No usage data", systemImage: "chart.bar.xaxis", description: Text("Usage will appear after the account service returns data."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .navigationTitle("Usage")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(isLoading)
            }
        }
        .task(id: threadID) { await load() }
        .accessibilityIdentifier("codex.usage.center")
    }

    @ViewBuilder
    private func threadUsage(_ model: CodexUsageCenterModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thread usage").font(.title2.weight(.semibold))
                    Text(model.threadID).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    metricCard("Credits", value: Self.credits(model.creditsMicros), systemImage: "circle.grid.2x2")
                    metricCard("USD", value: model.usdMicros.map(Self.usd) ?? "Unavailable", systemImage: "dollarsign.circle")
                }
                breakdownSection("By model", rows: model.breakdown(for: .model))
                breakdownSection("By reasoning effort", rows: model.breakdown(for: .reasoningEffort))
                breakdownSection("By speed", rows: model.breakdown(for: .speed))
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    @ViewBuilder
    private func accountUsage(_ summary: CodexUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Account usage").font(.title2.weight(.semibold))
            HStack(spacing: 12) {
                metricCard("Lifetime tokens", value: summary.lifetimeTokens.map(Self.integer) ?? "Unavailable", systemImage: "number")
                metricCard("Peak daily tokens", value: summary.peakDailyTokens.map(Self.integer) ?? "Unavailable", systemImage: "chart.line.uptrend.xyaxis")
            }
            Text("Open a conversation’s Usage panel to see model, reasoning effort, and speed breakdowns.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    @ViewBuilder
    private func breakdownSection(_ title: String, rows: [CodexUsageCenterModel.BreakdownRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if rows.isEmpty {
                Text("No breakdown data").foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack {
                        Text(row.label)
                        Spacer()
                        Text(Self.credits(row.micros)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(row.micros), total: Double(max(1, rows.map(\.micros).max() ?? 1)))
                        .tint(CodexTheme.accent)
                }
            }
        }
        .padding(14)
        .background(CodexTheme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metricCard(_ title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(CodexTheme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @MainActor
    private func load() async {
        guard accountStore.isChatGPTSignedIn else {
            problem = "Sign in with ChatGPT to load usage."
            return
        }
        isLoading = true
        problem = nil
        defer { isLoading = false }
        do {
            let value = try await CodexAccountRateLimitsClient(accountStore: accountStore).readAccountUsage(threadID: threadID)
            payload = value
            model = threadID == nil ? nil : CodexUsageCenterModel(payload: value)
            summary = threadID == nil ? CodexUsageSummary(payload: value) : nil
            if model == nil && summary == nil { problem = "The account service returned an unsupported usage shape." }
        } catch {
            model = nil
            summary = nil
            problem = "Unable to load usage right now."
        }
    }

    private static func credits(_ micros: Int64) -> String { String(format: "%.2f", Double(micros) / 1_000_000) }
    private static func usd(_ micros: Int64) -> String { String(format: "$%.2f", Double(micros) / 1_000_000) }
    private static func integer(_ value: Int64) -> String { value.formatted() }
}

private struct CodexUsageSummary: Sendable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?

    init?(payload: CodexJSONValue) {
        guard case let .object(root) = payload,
              case let .object(summary)? = root["summary"]
        else { return nil }
        lifetimeTokens = Self.integer(summary["lifetimeTokens"])
        peakDailyTokens = Self.integer(summary["peakDailyTokens"])
    }

    private static func integer(_ value: CodexJSONValue?) -> Int64? {
        guard case let .integer(number)? = value else { return nil }
        return number
    }
}
