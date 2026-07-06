import SwiftUI

@main
struct CounterApp: App {
    @State private var store = DataStore()
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .auto

    var body: some Scene {
        // A single unique window (not a WindowGroup) so the menu bar's "Open Counter"
        // focuses the one dashboard rather than spawning duplicates.
        Window("Counter", id: "dashboard") {
            DashboardView(store: store)
                .preferredColorScheme(appearanceMode.colorScheme)
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContentView(store: store)
                .preferredColorScheme(appearanceMode.colorScheme)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }
}
