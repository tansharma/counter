import SwiftUI
import CounterCore

/// User-tunable sources and appearance. Anthropic doesn't expose plan limits locally
/// (see CLAUDE.md), so the dashboard's gauges no longer compare against a user-set
/// budget either — there's nothing to configure here for them anymore.
struct SettingsView: View {
    let store: DataStore
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .auto
    @AppStorage("displayNameOverride") private var displayNameOverride = ""

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Display name override", text: $displayNameOverride,
                          prompt: Text("Leave blank to use your Claude account name"))
            }

            Section("Sources") {
                ForEach(AgentSource.allCases) { agent in
                    AgentToggleRow(
                        agent: agent,
                        isDetected: store.detectedAgents.contains(agent),
                        store: store
                    )
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
    }
}

/// One source's enable toggle, backed directly by its own `@AppStorage` key (rather
/// than a hand-declared var per agent in `SettingsView`) so a new `AgentSource` case
/// gets a working toggle — persisted, labeled, refresh-triggering — the moment it's
/// added to `allCases`, with no edit here.
private struct AgentToggleRow: View {
    let agent: AgentSource
    let isDetected: Bool
    let store: DataStore
    @AppStorage private var enabled: Bool

    init(agent: AgentSource, isDetected: Bool, store: DataStore) {
        self.agent = agent
        self.isDetected = isDetected
        self.store = store
        _enabled = AppStorage(wrappedValue: true, DataStore.settingsKey(for: agent))
    }

    var body: some View {
        Toggle(isOn: $enabled) {
            HStack(spacing: 8) {
                Text(agent.displayName)
                if !isDetected {
                    Text("not detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: enabled) {
            Task { await store.refresh() }
        }
    }
}
