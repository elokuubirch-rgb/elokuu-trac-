import Foundation

/// Reuses a calendar interval while visiting dates in the same month. Interval
/// endpoints preserve calendar/time-zone semantics without per-point date components.
struct CalendarMonthCursor {
    let calendar: Calendar
    private(set) var interval: DateInterval?

    init(calendar: Calendar = .current) { self.calendar = calendar }

    /// Returns true at the first valid date and whenever the calendar month changes.
    mutating func advance(to date: Date) -> Bool {
        if let interval, date >= interval.start, date < interval.end { return false }
        let next = calendar.dateInterval(of: .month, for: date)
        let changed = next != interval
        interval = next
        return changed
    }
}
