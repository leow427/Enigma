import Foundation

/// Messages stores times relative to 2001-01-01 UTC (the Foundation reference date):
/// nanoseconds on current macOS, seconds in databases created before macOS 10.13.
enum AppleMessageDate {
  /// Values above this cannot be seconds (it is over 3,000 years), so they are nanoseconds.
  private static let nanosecondThreshold: Int64 = 100_000_000_000

  static func date(_ raw: Int64) -> Date? {
    guard raw != 0 else { return nil }
    let seconds = abs(raw) >= nanosecondThreshold ? Double(raw) / 1_000_000_000 : Double(raw)
    return Date(timeIntervalSinceReferenceDate: seconds)
  }

  static func nanoseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSinceReferenceDate * 1_000_000_000).rounded())
  }

  /// Local ISO 8601 with the UTC offset, so a model can describe times as the user sees them.
  static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}
