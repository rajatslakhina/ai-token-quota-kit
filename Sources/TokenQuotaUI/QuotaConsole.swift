#if canImport(SwiftUI)
import SwiftUI
import TokenQuota

/// View model: runs a scenario through the real gateway and client and publishes the report.
@MainActor
public final class QuotaConsoleModel: ObservableObject {
    @Published public var scenario: Scenario
    @Published public private(set) var report: ScenarioReport?
    @Published public private(set) var isRunning = false
    public let onDevice: OnDeviceCapability
    private var runToken = 0

    public init(scenario: Scenario = .runawayAgent, onDevice: OnDeviceCapability = ScenarioRunner.standardDevice) {
        self.scenario = scenario
        self.onDevice = onDevice
    }

    public func run() async {
        runToken += 1
        let token = runToken
        let chosen = scenario
        isRunning = true
        let result = await ScenarioRunner.run(chosen, onDevice: onDevice)
        // A newer run started while this one was suspended: drop the stale result.
        guard token == runToken else { return }
        report = result
        isRunning = false
    }
}

public struct QuotaConsole: View {
    @StateObject private var model: QuotaConsoleModel
    private let autorun: Bool

    public init(scenario: Scenario = .runawayAgent,
                onDevice: OnDeviceCapability = ScenarioRunner.standardDevice,
                autorun: Bool = true) {
        _model = StateObject(wrappedValue: QuotaConsoleModel(scenario: scenario, onDevice: onDevice))
        self.autorun = autorun
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Scenario", selection: $model.scenario) {
                        ForEach(Scenario.allCases) { Text($0.title).tag($0) }
                    }
                    Button {
                        Task { await model.run() }
                    } label: {
                        Label(model.isRunning ? "Running…" : "Run scenario", systemImage: "play.fill")
                    }
                    .disabled(model.isRunning)
                }

                if let report = model.report {
                    Section("Result") {
                        Text(report.headline).font(.headline)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(report.metrics) { metric in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(metric.value).font(.title3.monospacedDigit().bold())
                                    Text(metric.label).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }

                    if !report.findings.isEmpty {
                        Section("Reconciliation") {
                            ForEach(Array(report.findings.enumerated()), id: \.offset) { _, finding in
                                FindingRow(finding: finding)
                            }
                        }
                    }

                    Section("Timeline") {
                        if report.events.isEmpty {
                            Text("No events.").foregroundStyle(.secondary)
                        }
                        ForEach(report.events) { event in
                            EventRow(event: event)
                        }
                    }
                } else {
                    Section { Text("Pick a scenario and run it.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Token Quota")
            .onChange(of: model.scenario) { _, _ in
                Task { await model.run() }
            }
            .task {
                if autorun, model.report == nil { await model.run() }
            }
        }
    }
}

struct EventRow: View {
    let event: ScenarioEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.text).font(.callout)
                Text(ScenarioRunner.formatSeconds(event.atMs)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var symbol: String {
        switch event.kind {
        case .grant: return "checkmark.circle.fill"
        case .deny: return "hand.raised.fill"
        case .local: return "iphone"
        case .settle: return "arrow.triangle.2.circlepath"
        case .info: return "info.circle"
        case .alert: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .grant: return .green
        case .deny: return .orange
        case .local: return .blue
        case .settle: return .teal
        case .info: return .secondary
        case .alert: return .red
        }
    }
}

struct FindingRow: View {
    let finding: DriftFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(finding.apiKey) · day \(finding.dayIndex)").font(.callout.monospaced())
                Spacer()
                Text(ScenarioRunner.describe(finding.status))
                    .font(.caption.bold())
                    .foregroundStyle(finding.status.needsAttention ? .red : .secondary)
                    .multilineTextAlignment(.trailing)
            }
            Text("ledger \(ScenarioRunner.formatTokens(finding.ledgerTokens)) · analytics \(finding.reportedTokens.map(ScenarioRunner.formatTokens) ?? "—")\(finding.isFinal ? " · final" : "")")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
#endif
