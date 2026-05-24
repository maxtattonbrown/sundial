// ABOUTME: Solar awareness for Sundial — sun position (offline math), weather/irradiance (Open-Meteo),
// ABOUTME: sunrise/sunset. Refreshes every 15 min. Graceful degradation when location is denied:
// ABOUTME: published `availability` flips to `.noLocation` and the UI hides solar features.

import Foundation
import CoreLocation
import Observation
import AppKit

@MainActor
@Observable
final class SolarContext: NSObject {

    enum Availability: Equatable {
        case unknown            // hasn't tried yet
        case fetching           // location pending
        case ready              // we have location + weather
        case noLocation         // user denied or location services off
        case networkError       // Open-Meteo unreachable
    }

    // MARK: - Published state

    private(set) var availability: Availability = .unknown

    /// Sun's azimuth (0-360°, 0=N). Always valid once we have location.
    private(set) var sunAzimuth: Double = 180
    /// Sun's elevation above horizon. Negative when sun is down.
    private(set) var sunElevation: Double = 0
    /// Cached sunrise/sunset for today, computed by Open-Meteo (more accurate than our math because
    /// it accounts for atmospheric refraction, terrain, etc).
    private(set) var sunriseToday: Date?
    private(set) var sunsetToday: Date?
    /// Solar irradiance in W/m² — "how bright is it outside right now". 0 at night, ~1000 in direct sun.
    private(set) var currentIrradiance: Double = 0
    /// UV index. 0 = none, 3-5 = moderate, 6-7 = high, 8-10 = very high, 11+ = extreme.
    private(set) var currentUVIndex: Double = 0
    /// 0-100. Higher = more cloud.
    private(set) var cloudCover: Double = 0
    /// Open-Meteo's "is it daytime" flag, from sunrise/sunset boundaries.
    private(set) var isDay: Bool = false

    // MARK: - Internals

    private let manager = CLLocationManager()
    private var refreshTimer: Timer?
    /// Last fetched coordinate. Used to recompute sun position between weather refreshes.
    private var lastCoordinate: CLLocationCoordinate2D?
    private var sunTickTimer: Timer?

    override init() {
        super.init()
        manager.delegate = self
        // ~3km accuracy is plenty for solar position / weather lookup, and uses less battery
        // than precise location.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    /// Kick off the first location request and start the refresh cycle. Call this from
    /// SundialManager after the user has signalled willingness (e.g. on first toggle).
    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            availability = .fetching
            manager.requestWhenInUseAuthorization()
            manager.requestLocation()
        case .restricted, .denied:
            availability = .noLocation
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            availability = .fetching
            manager.requestLocation()
        @unknown default:
            availability = .noLocation
        }

        // Refresh weather every 15 min once we have it.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.manager.requestLocation() }
        }

        // Sun position changes every second — recompute every 30s for the UI. Pure math, cheap.
        sunTickTimer?.invalidate()
        sunTickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateSunPositionOnly() }
        }
    }

    /// Opens System Settings → Privacy & Security → Location so the user can flip it on.
    func openLocationSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Weather fetch

    private func fetchWeather(for coordinate: CLLocationCoordinate2D) {
        lastCoordinate = coordinate
        updateSunPositionOnly()

        let lat = coordinate.latitude
        let lon = coordinate.longitude
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", lon)),
            URLQueryItem(name: "current", value: "shortwave_radiation,cloud_cover,is_day,uv_index"),
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        guard let url = components.url else { return }

        Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
                await MainActor.run {
                    self?.apply(decoded)
                }
            } catch {
                await MainActor.run {
                    self?.availability = .networkError
                }
            }
        }
    }

    private func apply(_ response: OpenMeteoResponse) {
        currentIrradiance = response.current.shortwave_radiation ?? 0
        currentUVIndex = response.current.uv_index ?? 0
        cloudCover = response.current.cloud_cover ?? 0
        isDay = (response.current.is_day ?? 0) == 1
        sunriseToday = response.daily.sunrise.first.flatMap { parseISO($0, timezone: response.timezone) }
        sunsetToday = response.daily.sunset.first.flatMap { parseISO($0, timezone: response.timezone) }
        availability = .ready
        updateSunPositionOnly()
    }

    private func updateSunPositionOnly() {
        guard let coord = lastCoordinate else { return }
        let pos = Sun.position(latitude: coord.latitude, longitude: coord.longitude, date: Date())
        sunAzimuth = pos.azimuth
        sunElevation = pos.elevation
    }

    private func parseISO(_ string: String, timezone: String?) -> Date? {
        // Open-Meteo returns ISO-8601 *without* timezone when timezone=auto, e.g. "2026-05-24T05:08".
        // Parse against the response's timezone field if provided.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter.date(from: string)
    }
}

// MARK: - CLLocationManagerDelegate

extension SolarContext: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.fetchWeather(for: loc.coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.availability != .ready {
                self.availability = .noLocation
            }
            // Once-ready, transient failures don't downgrade — keep showing the last-known weather.
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorized, .authorizedAlways, .authorizedWhenInUse:
                self.availability = .fetching
                manager.requestLocation()
            case .denied, .restricted:
                self.availability = .noLocation
            default:
                break
            }
        }
    }
}

// MARK: - Open-Meteo response shape

private struct OpenMeteoResponse: Decodable {
    let timezone: String?
    let current: Current
    let daily: Daily

    struct Current: Decodable {
        let shortwave_radiation: Double?
        let cloud_cover: Double?
        let is_day: Int?
        let uv_index: Double?
    }

    struct Daily: Decodable {
        let sunrise: [String]
        let sunset: [String]
    }
}

