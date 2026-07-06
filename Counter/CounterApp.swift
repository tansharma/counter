import SwiftUI

@main
struct CounterApp: App {
    @State private var store = DataStore()
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .auto

    var body: some Scene {
        WindowGroup {
            DashboardView(store: store)
                .preferredColorScheme(appearanceMode.colorScheme)
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }
}
