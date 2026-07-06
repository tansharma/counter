import SwiftUI
import CounterCore
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Icon

/// A miniature tachometer arc for the menu bar, sharing the big gauge's 150°/240°
/// geometry. Fills with the current block's usage vs budget; goes redline past 80%.
/// Drawn with alpha-distinct track/fill so it still reads if the system renders the
/// menu-bar label as a monochrome template.
struct MenuBarGaugeIcon: View {
    let fraction: Double
    var size: CGFloat = 18

    private let startAngle = 150.0
    private let sweep = 240.0
    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        Canvas { context, canvasSize in
            let inset = size * 0.14
            let rect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: inset, dy: inset)
            let lineWidth = max(2, size * 0.14)
            let track = StrokeStyle(lineWidth: lineWidth, lineCap: .round)

            context.stroke(
                arc(in: rect, from: 0, to: 1),
                with: .color(Theme.textSecondary.opacity(0.35)),
                style: track
            )
            context.stroke(
                arc(in: rect, from: 0, to: clamped),
                with: .color(clamped >= 0.8 ? Theme.danger : Theme.accent),
                style: track
            )
        }
        .frame(width: size, height: size)
    }

    private func arc(in rect: CGRect, from: Double, to: Double) -> Path {
        Path { path in
            path.addArc(
                center: CGPoint(x: rect.midX, y: rect.midY),
                radius: min(rect.width, rect.height) / 2,
                startAngle: .degrees(startAngle + sweep * from),
                endAngle: .degrees(startAngle + sweep * to),
                clockwise: false
            )
        }
    }
}

// MARK: - Label (status-bar item)

/// The always-present menu-bar item. Because the label lives for the app's lifetime,
/// it also hosts the refresh loop so the gauge stays live even when the main window is
/// closed (the dashboard's own loop only runs while its window is open).
struct MenuBarLabel: View {
    let store: DataStore
    @AppStorage("blockBudgetMTok") private var blockBudgetMTok = 25.0
    @Environment(\.displayScale) private var displayScale

    private var fraction: Double {
        Double(store.currentBlock?.totalTokens ?? 0) / max(blockBudgetMTok * 1_000_000, 1)
    }

    var body: some View {
        iconLabel
            .task {
                await store.refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    await store.refresh()
                }
            }
    }

    // A Canvas view renders blank inside a MenuBarExtra label (the status bar rasterises
    // the label), so draw the gauge to an NSImage and hand that over instead.
    @ViewBuilder
    private var iconLabel: some View {
        #if os(macOS)
        if let image = renderedIcon {
            Image(nsImage: image)
        } else {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        }
        #else
        MenuBarGaugeIcon(fraction: fraction)
        #endif
    }

    #if os(macOS)
    private var renderedIcon: NSImage? {
        let renderer = ImageRenderer(
            content: MenuBarGaugeIcon(fraction: fraction, size: 18).frame(width: 18, height: 18)
        )
        renderer.scale = displayScale
        guard let image = renderer.nsImage else { return nil }
        // Non-template so the accent/redline colour survives in the menu bar.
        image.isTemplate = false
        return image
    }
    #endif
}

// MARK: - Dropdown

/// The menu-bar dropdown: block usage, live reset countdown, today's total and cost,
/// and a button to bring up the dashboard. Read-only over the shared DataStore.
struct MenuBarContentView: View {
    let store: DataStore
    @AppStorage("blockBudgetMTok") private var blockBudgetMTok = 25.0
    @Environment(\.openWindow) private var openWindow

    private var blockTokens: Int { store.currentBlock?.totalTokens ?? 0 }
    private var fraction: Double {
        Double(blockTokens) / max(blockBudgetMTok * 1_000_000, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            blockRow
            todayRow
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Counter")
                .font(Theme.displayFont(16))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let refreshed = store.lastRefreshed {
                Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var blockRow: some View {
        HStack(spacing: 12) {
            MenuBarGaugeIcon(fraction: fraction, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("This block")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Text(Format.tokens(blockTokens))
                    .font(Theme.numberFont(18))
                    .foregroundStyle(Theme.textPrimary)
                Text("of \(Int(blockBudgetMTok))M budget")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            resetCountdown
        }
    }

    private var resetCountdown: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("Resets in")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            // Live tick while the dropdown is open.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(store.currentBlock.map { Format.countdown(to: $0.end, from: context.date) } ?? "—")
                    .font(Theme.numberFont(18))
                    .foregroundStyle(Theme.positive)
            }
            Text(store.currentBlock == nil ? "no active block" : "h:mm")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var todayRow: some View {
        HStack {
            Text("Today")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("\(Format.tokens(store.today?.totalTokens ?? 0)) · est. \(Format.usd(store.today?.estimatedCostUSD ?? 0))")
                .font(Theme.numberFont(13))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Counter") { openDashboard() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            Spacer()
            Button("Quit") { quit() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
    }

    private func openDashboard() {
        openWindow(id: "dashboard")
        #if canImport(AppKit)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }

    private func quit() {
        #if canImport(AppKit)
        NSApplication.shared.terminate(nil)
        #endif
    }
}
