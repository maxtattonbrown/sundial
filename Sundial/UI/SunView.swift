// ABOUTME: v0.6 experimental — the unified bar replaced by a single animated sun. Two visual
// ABOUTME: channels: a core sized/coloured by UV index, and a halo whose bloom reflects boost
// ABOUTME: intensity. The metaphor and the UI are the same thing.

import SwiftUI

struct SunView: View {
    @Bindable var manager: SundialManager

    private let canvasSize: CGFloat = 180

    var body: some View {
        VStack(spacing: 14) {
            Canvas { context, size in
                draw(into: context, size: size)
            }
            .frame(width: canvasSize, height: canvasSize)
            .animation(.easeOut(duration: 0.5), value: manager.solar.currentUVIndex)
            .animation(.easeOut(duration: 0.4), value: manager.currentEffectiveBoost)
            .animation(.easeInOut(duration: 0.3), value: manager.state == .engaged)

            Text(statRow)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(statColor)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Drawing

    /// One pass paints both channels. Halo is drawn first (under the core) so the sun feels
    /// like it's emitting light rather than being overlaid by a separate layer.
    private func draw(into context: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let uv = manager.solar.currentUVIndex
        let boost = manager.currentEffectiveBoost
        let isEngaged = manager.state == .engaged && manager.isOn
        let isOn = manager.isOn

        // Core radius scales with UV. At UV 0 we still want a visible disc — a "your sun is off
        // / asleep" silhouette — so floor at 10pt. At UV 10+ the sun nearly fills the inner area.
        let normalisedUV = min(1.0, max(0.0, uv / 10.0))
        let coreRadius: CGFloat = 10 + normalisedUV * 22

        // Halo radius and intensity scale with boost (only when engaged).
        // Ceiling at 3.0× → halo reaches ~3× the core radius with strong opacity.
        let haloVisible = isEngaged && boost > 0.1
        let haloIntensity: CGFloat = haloVisible
            ? CGFloat(min(1.0, max(0.0, (boost - 1.5) / 1.5)))
            : 0
        let haloRadius: CGFloat = coreRadius + 18 + haloIntensity * 60
        let haloPeakOpacity: CGFloat = 0.18 + haloIntensity * 0.45

        // Draw halo as a radial gradient bloom. Drawn even when haloIntensity == 0 (engaged at
        // floor) so the user always sees *something* indicating Sundial is doing its job.
        if haloVisible {
            let haloRect = CGRect(
                x: center.x - haloRadius,
                y: center.y - haloRadius,
                width: haloRadius * 2,
                height: haloRadius * 2
            )
            let gradient = Gradient(stops: [
                .init(color: haloColor.opacity(haloPeakOpacity), location: 0.0),
                .init(color: haloColor.opacity(haloPeakOpacity * 0.45), location: 0.55),
                .init(color: haloColor.opacity(0), location: 1.0),
            ])
            context.fill(
                Path(ellipseIn: haloRect),
                with: .radialGradient(
                    gradient,
                    center: center,
                    startRadius: coreRadius * 0.7,
                    endRadius: haloRadius
                )
            )
        }

        // Draw the sun core. Solid disc with a soft outer rim that blends back into the halo.
        let coreRect = CGRect(
            x: center.x - coreRadius,
            y: center.y - coreRadius,
            width: coreRadius * 2,
            height: coreRadius * 2
        )
        let coreFill = coreColor(uv: uv, isOn: isOn)
        let coreGradient = Gradient(stops: [
            .init(color: coreFill, location: 0.0),
            .init(color: coreFill, location: 0.65),
            .init(color: coreFill.opacity(0.85), location: 1.0),
        ])
        context.fill(
            Path(ellipseIn: coreRect),
            with: .radialGradient(
                coreGradient,
                center: center,
                startRadius: 0,
                endRadius: coreRadius
            )
        )
    }

    // MARK: - Visual mapping

    /// UV index → sun core colour. Discrete brackets keep the visual language clear; we're not
    /// trying to be a scientific scale, we're trying to be the felt experience.
    private func coreColor(uv: Double, isOn: Bool) -> Color {
        guard isOn else { return Color.gray.opacity(0.35) }
        switch uv {
        case ..<1:   return Color(red: 0.55, green: 0.55, blue: 0.58)   // grey-blue (no real sun)
        case ..<3:   return Color(red: 0.95, green: 0.88, blue: 0.55)   // pale yellow
        case ..<6:   return Color(red: 1.0,  green: 0.78, blue: 0.20)   // yellow
        case ..<8:   return Color(red: 1.0,  green: 0.55, blue: 0.10)   // orange
        default:     return Color(red: 1.0,  green: 0.32, blue: 0.10)   // red-orange (extreme)
        }
    }

    /// Halo colour stays warm regardless of UV — it represents Sundial's response, not the sun.
    private var haloColor: Color {
        Color(red: 1.0, green: 0.65, blue: 0.18)
    }

    // MARK: - Stat row

    private var statRow: String {
        if !manager.isOn { return "Off" }
        let uvDisplay = uvString
        switch manager.state {
        case .dormant:
            return "\(uvDisplay) · Waiting"
        case .engaged:
            return String(format: "%@ · Boosting %.1f×", uvDisplay, manager.currentEffectiveBoost)
        }
    }

    private var uvString: String {
        guard manager.solar.availability == .ready else { return "UV —" }
        let uv = manager.solar.currentUVIndex
        // Show integer for UV ≥ 1, one decimal for lower (so the user sees motion at dawn/dusk).
        if uv >= 1 {
            return "UV \(Int(uv.rounded()))"
        }
        return String(format: "UV %.1f", uv)
    }

    private var statColor: Color {
        if !manager.isOn { return .secondary }
        return manager.state == .engaged ? .orange : .secondary
    }
}
