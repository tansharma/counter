import SwiftUI

/// User-tunable budgets and appearance. Limits are budgets the user sets, not values
/// fetched from Anthropic — plan limits aren't exposed locally (see CLAUDE.md).
struct SettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .auto
    @AppStorage("displayNameOverride") private var displayNameOverride = ""
    @AppStorage("blockBudgetMTok") private var blockBudgetMTok = 25.0
    @AppStorage("weeklyBudgetMTok") private var weeklyBudgetMTok = 300.0

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Display name override", text: $displayNameOverride,
                          prompt: Text("Leave blank to use your Claude account name"))
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
                Text("Anthropic doesn't publish per-plan token limits locally, so gauges compare against these budgets. Tune them to where you typically hit your plan's limits.")
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
