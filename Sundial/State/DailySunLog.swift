// ABOUTME: Accumulates today's outdoor stats — boost minutes, peak irradiance, time-weighted average
// ABOUTME: UV. Auto-rolls over at midnight. Persisted to UserDefaults so quitting and re-launching
// ABOUTME: doesn't lose your tan. Vitamin D % is the optimistic-fuzzy version — UV5 × 20min ≈ 100%.

import Foundation
import Observation

@MainActor
@Observable
final class DailySunLog {

    /// One day's worth of accumulated stats. Stored verbatim in UserDefaults.
    struct Day: Codable, Equatable {
        var dateKey: String                // "2026-05-24"
        var totalMinutes: Double           // total time the boost has been engaged today
        var uvMinuteSum: Double            // Σ(uv × minutes) — denominator-on-demand average
        var peakIrradiance: Double         // W/m² peak observed while engaged today
    }

    private let storageKey = "Sundial.DailySunLog.v1"
    private let defaults: UserDefaults
    private(set) var today: Day

    /// Production callers use `.standard`. Tests inject a transient suite to avoid polluting
    /// the real app's plist — see DailySunLogTests for the pattern.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.today = Self.load(from: defaults, key: storageKey) ?? Day.fresh(for: Date())
    }

    // MARK: - Mutation

    /// Add `minutes` of engaged time at the given UV index and irradiance. Called from the
    /// SundialManager tick loop while the boost is engaged (every 3s = 0.05 min).
    func tick(durationMinutes: Double, uvIndex: Double, irradiance: Double) {
        rolloverIfNeeded()
        today.totalMinutes += durationMinutes
        today.uvMinuteSum += uvIndex * durationMinutes
        today.peakIrradiance = max(today.peakIrradiance, irradiance)
        persist()
    }

    /// Resets stats for a new day if midnight has passed since we last persisted.
    func rolloverIfNeeded() {
        let key = Self.dateKey(for: Date())
        if today.dateKey != key {
            today = Day.fresh(for: Date())
            persist()
        }
    }

    // MARK: - Derived values

    /// Time-weighted average UV index during today's boost time. Returns 0 if no boost time.
    var averageUVDuringBoost: Double {
        guard today.totalMinutes > 0 else { return 0 }
        return today.uvMinuteSum / today.totalMinutes
    }

    /// Optimistic fuzzy Vitamin D as a 0-100 percentage. UV5 × 20min ≈ 100%. Not medical advice.
    /// Capped at 100; goes to 0 below UV1 (no UVB-mediated synthesis at very low indices).
    var vitaminDPercent: Int {
        let avgUV = averageUVDuringBoost
        guard avgUV >= 1.0 else { return 0 }
        let raw = today.totalMinutes * avgUV
        return min(100, max(0, Int(raw.rounded())))
    }

    /// Human-friendly "1h 42m" string for today's boost time.
    var formattedMinutes: String {
        let m = Int(today.totalMinutes.rounded())
        if m < 60 { return "\(m) min" }
        return "\(m / 60)h \(m % 60)m"
    }

    /// 0.0-1.0 representing how "tanned" the menu bar icon should be. Saturates at 2h of boost.
    var tanFraction: Double {
        min(1.0, today.totalMinutes / 120.0)
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(today) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(from defaults: UserDefaults, key: String) -> Day? {
        guard let data = defaults.data(forKey: key),
              let day = try? JSONDecoder().decode(Day.self, from: data) else {
            return nil
        }
        // Stale entries from previous days are discarded — caller will get a fresh Day.
        if day.dateKey != dateKey(for: Date()) {
            return nil
        }
        return day
    }

    nonisolated private static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

extension DailySunLog.Day {
    static func fresh(for date: Date) -> Self {
        Self(
            dateKey: DailySunLog.dateKeyPublic(for: date),
            totalMinutes: 0,
            uvMinuteSum: 0,
            peakIrradiance: 0
        )
    }
}

extension DailySunLog {
    /// Public hook so `Day.fresh(for:)` can reach the same date-key formatter without exposing it widely.
    nonisolated static func dateKeyPublic(for date: Date) -> String {
        dateKey(for: date)
    }
}
