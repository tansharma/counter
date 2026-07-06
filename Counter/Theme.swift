import SwiftUI

/// The "Tachometer" palette — single source of truth for every colour in the app.
/// Each token carries a light and a dark variant; views never hard-code colors.
enum Theme {

    // Backgrounds & surfaces
    static let background = adaptive(light: 0xF7F5F0, dark: 0x101418)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1A2027)
    static let surfaceRaised = adaptive(light: 0xEFEBE2, dark: 0x232B34)

    // Brand & signals
    static let accent = adaptive(light: 0xE84A22, dark: 0xFF5C39)   // signal orange
    static let positive = adaptive(light: 0x1B9E92, dark: 0x2EC4B6) // teal
    static let warning = adaptive(light: 0xD98E00, dark: 0xFFB020)  // amber
    static let danger = adaptive(light: 0xC7362B, dark: 0xF25C4D)

    // Text
    static let textPrimary = adaptive(light: 0x1B2026, dark: 0xF2F0EA)
    static let textSecondary = adaptive(light: 0x5C6670, dark: 0x9AA6B2)

    // Chart series (model breakdown etc.)
    static let series: [Color] = [
        accent, positive, warning,
        adaptive(light: 0x5B6ABF, dark: 0x8B9AE8),
        adaptive(light: 0xB05BA6, dark: 0xD98BD0),
    ]

    // Type scale — a deliberate display face for the big numbers.
    static func displayFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }

    static func numberFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Self.rgb(isDark ? dark : light))
        })
        #else
        Color(uiColor: UIColor { traits in
            UIColor(Self.rgb(traits.userInterfaceStyle == .dark ? dark : light))
        })
        #endif
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// Appearance preference persisted in Settings; Auto follows the system.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
