import Foundation

/// Shared ISO8601 timestamp parsing for all session-log parsers. Timestamps arrive
/// with fractional seconds ("2026-07-03T11:32:17.602Z") but the plain form appears
/// in older files, so both are tolerated.
enum LogTimestamp {

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }
}
