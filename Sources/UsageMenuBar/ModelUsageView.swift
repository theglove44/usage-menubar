import SwiftUI

struct ModelUsageView: View {
    let provider: MenuBarProvider
    let back: () -> Void
    @StateObject private var store: ModelUsageStore
    @State private var period = UsagePeriod.week

    init(provider: MenuBarProvider, scanner: ModelUsageScanner, back: @escaping () -> Void) {
        self.provider = provider
        self.back = back
        _store = StateObject(wrappedValue: ModelUsageStore(scanner: scanner))
    }

    private var rows: [ModelUsageRow] {
        guard let report = store.report else { return [] }
        return report.rows(since: period.start(now: report.capturedAt), until: report.capturedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }
                Spacer()
                Text("\(provider.displayName) model usage").font(.headline)
                Spacer()
                Button {
                    Task { await store.refresh(provider: provider) }
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh local usage")
                .accessibilityLabel("Refresh local usage")
                .disabled(store.loading)
            }
            Picker("Time period", selection: $period) {
                ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)

            if store.loading {
                HStack { ProgressView().controlSize(.small); Text("Reading local usage…").font(.caption) }
            }
            if let report = store.report {
                if rows.isEmpty {
                    Text(report.sourceAvailable ? "No recorded token usage in this period." : "No local usage files found for \(provider.displayName).")
                        .font(.subheadline).padding(.vertical, 12)
                } else {
                    summary
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(rows) { row in modelRow(row) }
                        }
                    }
                    .frame(maxHeight: 300)
                }
                Text("This Mac only · \(report.filesRead) local files · updated \(report.capturedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
                if report.incompleteFiles > 0 {
                    Text("Partial coverage: \(report.incompleteFiles) files or folders could not be fully read.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("API-equivalent estimate · USD").font(.caption.bold())
                Text("Standard short-context rates, checked \(ModelPricing.checkedDate). Includes recorded cache reads/writes. Excludes long-context and speed premiums, tool fees and tax. This is not your subscription bill.")
                Text("Local records may omit web, cloud, other devices and older unsupported log formats. Unpriced models remain in token totals.")
                if provider == .grok {
                    Text("Grok Build variants use the public Grok 4.6 rate for comparison.")
                }
                Link("View official API pricing", destination: pricingURL)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .task { await store.refresh(provider: provider) }
    }

    private var summary: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(rows.reduce(Int64(0)) { $0 + $1.tokens.total }.formatted()).font(.title2.bold().monospacedDigit())
                Text("tokens recorded").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if rows.contains(where: { $0.cost != nil }) {
                    Text(money(rows.compactMap(\.cost).reduce(0, +))).font(.title2.bold().monospacedDigit())
                    Text(rows.contains(where: { $0.cost == nil }) ? "priced models only" : "API equivalent")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Price unavailable").font(.subheadline.bold())
                }
            }
        }
    }

    private func modelRow(_ row: ModelUsageRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.model).font(.subheadline.bold()).textSelection(.enabled)
                Spacer()
                Text(row.cost.map(money) ?? "Price unavailable").font(.subheadline.monospacedDigit())
            }
            Text("\(row.tokens.total.formatted()) tokens").font(.caption.bold())
            HStack(alignment: .top) {
                tokenColumn("Input", row.tokens.input)
                tokenColumn("Cached read", row.tokens.cachedInput)
                tokenColumn("Cache write", row.tokens.cacheWrite + row.tokens.cacheWriteHour)
                tokenColumn("Output", row.tokens.output)
            }
            if let rate = ModelPricing.rate(for: row.model) {
                Text("$/1M: input \(rate.input.formatted()) · cached \(rate.cached.formatted()) · output \(rate.output.formatted())")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tokenColumn(_ title: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            Text(value.formatted()).monospacedDigit()
        }.font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }

    private var pricingURL: URL {
        switch provider {
        case .codex: return ModelPricing.openAIURL
        case .claude: return ModelPricing.claudeURL
        case .grok: return ModelPricing.grokURL
        }
    }
}
