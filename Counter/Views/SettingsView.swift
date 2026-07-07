import SwiftUI
import CounterCore

/// User-tunable sources, budgets, and appearance. Limits are budgets the user sets,
/// not values fetched from Anthropic — plan limits aren't exposed locally (see
/// CLAUDE.md).
struct SettingsView: View {
    let store: DataStore
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .auto
    @AppStorage("displayNameOverride") private var displayNameOverride = ""
    @AppStorage("blockBudgetMTok") private var blockBudgetMTok = 25.0
    @AppStorage("weeklyBudgetMTok") private var weeklyBudgetMTok = 300.0
    // One toggle per agent source; keys come from DataStore.settingsKey(for:).
    @AppStorage("source_claude_enabled") private var claudeEnabled = true
    @AppStorage("source_codex_enabled") private var codexEnabled = true
    @AppStorage("source_gemini_enabled") private var geminiEnabled = true
    @AppStorage("source_opencode_enabled") private var opencodeEnabled = true

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Display name override", text: $displayNameOverride,
                          prompt: Text("Leave blank to use your Claude account name"))
            }

            Section("Sources") {
                ForEach(AgentSource.allCases) { agent in
                    Toggle(isOn: binding(for: agent)) {
                        HStack(spacing: 8) {
                            Text(agent.displayName)
                            if !store.detectedAgents.contains(agent) {
                                Text("not detected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Counter reads each tool's local session logs and folds them into every chart, gauge, and total. Sources marked 'not detected' have no session directory on this Mac (OpenCode's newer database-only format isn't read yet).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Budgets") {
                LabeledContent("5-hour block budget") {
                    HStack {
                        Slider(value: $blockBudgetMTok, in: 1...200, step: 1)
                        Text("\(Int(blockBudgetMTok))M tokens")
                            .monospacedDigit()
                            .frame(width: 100, alignment: .trailing)
                    }
                }
                LabeledContent("Weekly budget") {
                    HStack {
                        Slider(value: $weeklyBudgetMTok, in: 10...2000, step: 10)
                        Text("\(Int(weeklyBudgetMTok))M tokens")
                            .monospacedDigit()
                            .frame(width: 100, alignment: .trailing)
                    }
                }
                Text("Anthropic doesn't publish per-plan token limits locally, so gauges compare against these budgets. With multiple sources enabled the gauges aggregate all of them — tune budgets accordingly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Mode", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .navigationTitle("Counter Settings")
        .onChange(of: [claudeEnabled, codexEnabled, geminiEnabled, opencodeEnabled]) {
            Task { await store.refresh() }
        }
    }

    private func binding(for agent: AgentSource) -> Binding<Bool> {
        switch agent {
        case .claude: $claudeEnabled
        case .codex: $codexEnabled
        case .gemini: $geminiEnabled
        case .opencode: $opencodeEnabled
        }
    }
}
