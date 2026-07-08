import SwiftUI

/// A tachometer-style gauge: a 240° arc with tick marks. `value` is 0...1; progress is
/// shown by recoloring the tick marks (no needle) as it fills.
///
/// When `innerValue` is set, the fill arc — and the ticks — split into two segments:
/// `innerAccent` from 0 to `innerValue`, `accent` from `innerValue` to `value`. Two
/// different callers use this:
/// - Composition gauges (e.g. new vs. reused tokens) pass `value: 1` — the ring is
///   always fully drawn, split purely by the two segments' share of the whole.
/// - The reset countdown passes a fixed `innerValue` threshold and a growing `value`
///   (elapsed fraction) — the first segment fills and then freezes at the threshold,
///   and the second segment takes over and keeps growing past it, so a two-phase
///   countdown ("elapsed, then imminent") reads correctly with no needle to point at
///   a single position.
/// A small legend with the actual numbers renders under the title when `showsLegend`
/// is true, its height reserved (via `.opacity(0)` otherwise) so every gauge in a row
/// stays the same height regardless of whether it has legend content.
struct SpeedometerView: View {
    let title: String
    let value: Double          // 0...1 (clamped)
    let centerLabel: String    // big number in the middle
    let subLabel: String       // small line under it
    var accent: Color = Theme.accent
    var innerValue: Double? = nil
    var innerAccent: Color = Theme.accent
    var showsLegend: Bool = false
    var innerLegendLabel: String = "new"
    var innerLegendValue: String = ""
    var outerLegendLabel: String = "cache-read"
    var outerLegendValue: String = ""

    private let startAngle: Double = 150 // degrees; sweep 240° clockwise to 30°
    private let sweep: Double = 240

    private var clamped: Double { min(max(value, 0), 1) }
    private var innerClamped: Double? { innerValue.map { min(max($0, 0), clamped) } }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                dial
                VStack(spacing: 2) {
                    Text(centerLabel)
                        .font(Theme.numberFont(26))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
                .offset(y: 18)
            }
            .frame(width: 170, height: 150)

            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .kerning(1.2)

            legend.opacity(showsLegend ? 1 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(centerLabel), \(subLabel)")
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendSwatch(innerAccent, innerLegendLabel, innerLegendValue)
            legendSwatch(accent, outerLegendLabel, outerLegendValue)
        }
    }

    private func legendSwatch(_ color: Color, _ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(value.isEmpty ? label : "\(value) \(label)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var dial: some View {
        ZStack {
            // Track
            arc(from: 0, to: 1)
                .stroke(Theme.surfaceRaised, style: StrokeStyle(lineWidth: 12, lineCap: .round))
            // Fill
            if let innerClamped {
                arc(from: 0, to: innerClamped)
                    .stroke(innerAccent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                arc(from: innerClamped, to: clamped)
                    .stroke(accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
            } else {
                arc(from: 0, to: clamped)
                    .stroke(accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
            }
            ticks
        }
    }

    private var ticks: some View {
        ForEach(0..<9) { index in
            let fraction = Double(index) / 8.0
            let angle = Angle.degrees(startAngle + sweep * fraction)
            Rectangle()
                .fill(tickColor(at: fraction))
                .frame(width: 2, height: 7)
                .offset(y: -58)
                .rotationEffect(angle + .degrees(90))
        }
    }

    private func tickColor(at fraction: Double) -> Color {
        if let innerClamped {
            if fraction <= innerClamped { return innerAccent }
            if fraction <= clamped { return accent }
        } else if fraction <= clamped {
            return accent
        }
        return Theme.textSecondary.opacity(0.5)
    }

    private func arc(from: Double, to: Double) -> Path {
        Path { path in
            path.addArc(
                center: CGPoint(x: 85, y: 75),
                radius: 66,
                startAngle: .degrees(startAngle + sweep * from),
                endAngle: .degrees(startAngle + sweep * to),
                clockwise: false
            )
        }
    }
}
