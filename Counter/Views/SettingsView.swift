import SwiftUI
import CounterCore

/// User-tunable sources and appearance. Anthropic doesn't expose plan limits locally
/// (see CLAUDE.md), so the dashboard's gauges no longer compare against a user-set
/// budget either — there's nothing to configure here for them anymore.
struct SettingsView: View {
    let store: DataStore
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .auto
    @AppStorage("displayNameOverride") private var displayNameOverride = ""
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
                Text("Counter reads each tool's local session logs and folds them into every chart and total, including Session Usage and This Week — except the Claude Block Reset countdown, which is Claude Code only since it's the one gauge tied to Anthropic's own rate-limit window. Sources marked 'not detected' have no session directory on this Mac (OpenCode's newer database-only format isn't read yet).")
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
