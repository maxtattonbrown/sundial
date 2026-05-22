// ABOUTME: Measures the real battery cost of the EDR boost on this specific Mac.
// ABOUTME: Reads the system's instantaneous discharge wattage from ioreg AppleSmartBattery
// ABOUTME: before and after the boost engages, takes the delta, and projects it forward as
// ABOUTME: minutes-of-battery-lost-per-hour. No modelling, no assumed averages — just measurement.

import Foundation

@MainActor
final class BatteryCost {
    /// Total laptop battery capacity in watt-hours. M4/M5 14" MBP is ~70Wh.
    /// This is a one-line approximation — the indicator is qualitative, not financial advice.
    private let nominalBatteryWh: Double = 70.0

    private var baselineWatts: Double?

    /// Battery percentage 0–100, read from `pmset -g batt`. Defaults to 100 if read fails.
    func batteryPercent() -> Int {
        let out = shellRead("pmset -g batt")
        // Format: " -InternalBattery-0 (id=...)\t87%; discharging; 3:42 remaining present: true"
        if let match = out.range(of: #"(\d+)%"#, options: .regularExpression) {
            let pct = out[match].replacingOccurrences(of: "%", with: "")
            return Int(pct) ?? 100
        }
        return 100
    }

    /// Capture the current discharge wattage as the pre-boost baseline.
    func startSampling() {
        baselineWatts = currentDischargeWatts()
    }

    /// Sample current draw, diff against baseline, project minutes-of-battery-lost-per-hour.
    /// Returns nil if the delta is below the noise floor or if no baseline was captured.
    func estimateMinutesLostPerHour() -> Int? {
        guard let baseline = baselineWatts else { return nil }
        guard let now = currentDischargeWatts() else { return nil }

        let delta = max(0, now - baseline)
        guard delta > 0.5 else { return nil }   // noise floor — CPU spikes can shift draw by ~0.3W

        // If we draw `delta` extra watts continuously, time-lost per hour of use:
        //   fraction of battery used per hour = delta / nominalBatteryWh
        //   minutes of total runtime "owed" per hour = (delta / nominalBatteryWh) * 60
        // That's how many fewer minutes of runtime each hour of boosting costs.
        let minutesLostPerHour = (delta / nominalBatteryWh) * 60.0
        return Int(minutesLostPerHour.rounded())
    }

    func stopSampling() {
        baselineWatts = nil
    }

    // MARK: - Internals

    private func currentDischargeWatts() -> Double? {
        // ioreg gives instantaneous Amperage (mA, signed: negative = discharging) and Voltage (mV).
        // We take the absolute product → watts.
        let cmd = "ioreg -rn AppleSmartBattery | awk '/\"Amperage\"/ {a=$3} /\"Voltage\"/ {v=$3} END {if (a && v) print (a*v)/1000000}'"
        let out = shellRead(cmd).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Double(out) else { return nil }
        return abs(raw)
    }

    private func shellRead(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
