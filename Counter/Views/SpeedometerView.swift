import SwiftUI

/// A tachometer-style gauge: 240° arc with tick marks, a needle, and a redline zone.
/// `value` is 0...1 of `redlineAt`-scaled range; the last 20% of the arc is the redline.
struct SpeedometerView: View {
    let title: String
    let value: Double          // 0...1 (clamped)
    let centerLabel: String    // big number in the middle
    let subLabel: String       // small line under it
    var accent: Color = Theme.accent

    private let startAngle: Double = 150 // degrees; sweep 240° clockwise to 30°
    private let sweep: Double = 240

    private var clamped: Double { min(max(value, 0), 1) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                dial
                needle
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
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(centerLabel), \(subLabel)")
    }

    private var dial: some View {
        ZStack {
            // Track
            arc(from: 0, to: 1)
                .stroke(Theme.surfaceRaised, style: StrokeStyle(lineWidth: 12, lineCap: .round))
            // Redline zone (last 20%)
            arc(from: 0.8, to: 1)
                .stroke(Theme.danger.opacity(0.35), style: StrokeStyle(lineWidth: 12, lineCap: .round))
            // Fill
            arc(from: 0, to: clamped)
                .stroke(
                    clamped >= 0.8 ? Theme.danger : accent,
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
            ticks
        }
    }

    private var ticks: some View {
        ForEach(0..<9) { index in
            let fraction = Double(index) / 8.0
            let angle = Angle.degrees(startAngle + sweep * fraction)
            Rectangle()
                .fill(Theme.textSecondary.opacity(0.5))
                .frame(width: 2, height: 7)
                .offset(y: -58)
                .rotationEffect(angle + .degrees(90))
        }
    }

    private var needle: some View {
        Capsule()
            .fill(Theme.textPrimary)
            .frame(width: 3, height: 52)
            .offset(y: -26)
            .rotationEffect(.degrees(startAngle + 90 + sweep * clamped))
            .animation(.spring(duration: 0.6), value: clamped)
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
