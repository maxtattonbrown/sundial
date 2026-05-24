// ABOUTME: Pure math — given lat/lon + Date, returns the sun's azimuth and elevation in the sky.
// ABOUTME: Schlyter's simplified algorithm (https://stjarnhimlen.se/comp/ppcomp.html), accurate to
// ABOUTME: ~0.01°. No network, no state, no dependencies — Sundial computes this offline.

import Foundation

struct SunPosition: Equatable {
    /// Compass bearing of the sun's projection on the horizon, 0° = North, 90° = East,
    /// 180° = South, 270° = West.
    let azimuth: Double
    /// Angle of the sun above the horizon. Positive = above, negative = below.
    let elevation: Double
}

enum Sun {

    /// Compute the sun's position from any observer location at any moment.
    static func position(latitude: Double, longitude: Double, date: Date) -> SunPosition {
        // Days since J2000.0 (2000-01-01 00:00 UTC). UTC components are extracted explicitly
        // to keep the algorithm independent of the user's calendar/locale.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = Double(c.year ?? 2000)
        let m = Double(c.month ?? 1)
        let d = Double(c.day ?? 1)
        let h = Double(c.hour ?? 0)
              + Double(c.minute ?? 0) / 60.0
              + Double(c.second ?? 0) / 3600.0

        // Schlyter's day number (days since 2000-01-01 00:00 UTC).
        let dn = 367 * y
              - floor((7 * (y + floor((m + 9) / 12))) / 4)
              + floor((275 * m) / 9)
              + d - 730530.0 + h / 24.0

        // Sun's orbital elements at time dn.
        let oblecl = 23.4393 - 3.563e-7 * dn       // obliquity of the ecliptic
        let w = 282.9404 + 4.70935e-5 * dn         // argument of perihelion
        let M = mod(356.0470 + 0.9856002585 * dn)  // mean anomaly
        let e = 0.016709 - 1.151e-9 * dn           // eccentricity

        // Eccentric anomaly (good approximation for small e).
        let Mrad = deg2rad(M)
        let E = M + rad2deg(e * sin(Mrad) * (1.0 + e * cos(Mrad)))
        let Erad = deg2rad(E)

        // Sun's rectangular coordinates in the plane of the ecliptic.
        let xv = cos(Erad) - e
        let yv = sqrt(1 - e * e) * sin(Erad)
        let v = rad2deg(atan2(yv, xv))          // true anomaly
        let r = sqrt(xv * xv + yv * yv)         // distance

        // Sun's longitude.
        let lon = mod(v + w)
        let lonRad = deg2rad(lon)

        // Convert ecliptic → equatorial coordinates.
        let xs = r * cos(lonRad)
        let ys = r * sin(lonRad)
        let oblRad = deg2rad(oblecl)
        let xe = xs
        let ye = ys * cos(oblRad)
        let ze = ys * sin(oblRad)

        let ra = rad2deg(atan2(ye, xe))                // right ascension
        let dec = rad2deg(atan2(ze, sqrt(xe * xe + ye * ye)))  // declination

        // Sidereal time at the observer.
        let GMST0 = mod(lon + 180.0) / 15.0     // hours
        let SIDTIME = mod24(GMST0 + h + longitude / 15.0)
        let HA = mod(SIDTIME * 15.0 - ra)       // hour angle in degrees
        let haRad = deg2rad(HA)
        let decRad = deg2rad(dec)
        let latRad = deg2rad(latitude)

        // Equatorial → horizontal.
        let x = cos(haRad) * cos(decRad)
        let yEq = sin(haRad) * cos(decRad)
        let z = sin(decRad)

        let xhor = x * sin(latRad) - z * cos(latRad)
        let yhor = yEq
        let zhor = x * cos(latRad) + z * sin(latRad)

        let azimuth = mod(rad2deg(atan2(yhor, xhor)) + 180.0)
        let elevation = rad2deg(asin(zhor))

        return SunPosition(azimuth: azimuth, elevation: elevation)
    }

    /// "South-East", "West", etc., for a given azimuth in degrees.
    static func compass(_ azimuth: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW", "N"]
        let idx = Int(((mod(azimuth) + 22.5) / 45.0).rounded(.down))
        return dirs[idx]
    }

    // MARK: - Helpers

    private static func deg2rad(_ d: Double) -> Double { d * .pi / 180.0 }
    private static func rad2deg(_ r: Double) -> Double { r * 180.0 / .pi }
    /// Normalise a degree value to [0, 360).
    private static func mod(_ d: Double) -> Double {
        let m = d.truncatingRemainder(dividingBy: 360.0)
        return m < 0 ? m + 360.0 : m
    }
    /// Normalise hours to [0, 24).
    private static func mod24(_ h: Double) -> Double {
        let m = h.truncatingRemainder(dividingBy: 24.0)
        return m < 0 ? m + 24.0 : m
    }
}
