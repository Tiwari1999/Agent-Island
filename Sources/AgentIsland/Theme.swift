import SwiftUI

/// Three semantic hues only — working, waiting, failed — plus amber reserved solely for quota
/// pressure. A preattentive channel only works while it is rare, so everything else is neutral
/// and differentiated by weight and size instead.
enum Theme {
    static let bg        = Color(red: 0.055, green: 0.059, blue: 0.071)
    static let raised    = Color(red: 0.094, green: 0.102, blue: 0.122)
    static let hairline  = Color.white.opacity(0.08)

    static let text      = Color(red: 0.937, green: 0.945, blue: 0.960)
    static let muted     = Color(red: 0.541, green: 0.576, blue: 0.639)
    static let faint     = Color(red: 0.353, green: 0.384, blue: 0.443)

    static let working   = Color(red: 0.243, green: 0.788, blue: 0.588)   // teal-green
    static let waiting   = Color(red: 0.478, green: 0.647, blue: 1.000)   // soft blue
    static let failed    = Color(red: 0.906, green: 0.400, blue: 0.451)   // muted rose
    static let idle      = Color(red: 0.396, green: 0.427, blue: 0.486)
    static let amber     = Color(red: 0.960, green: 0.720, blue: 0.300)
    // Was a duplicate of `waiting`, which spent the "needs you" colour on ordinary tool names.
    static let tool      = Color(red: 0.541, green: 0.576, blue: 0.639)
    // Demoted from orange: an agent badge carries identity, not urgency.
    static let agentTint = Color(red: 0.478, green: 0.510, blue: 0.576)

    static func name(_ s: CGFloat) -> Font { .system(size: s, weight: .medium, design: .rounded) }
    static func label(_ s: CGFloat) -> Font { .system(size: s, weight: .semibold, design: .rounded) }
    static func mono(_ s: CGFloat) -> Font { .system(size: s, weight: .regular, design: .monospaced) }
}

/// Flush to the screen edge on top, rounded below — reads as part of the hardware.
struct NotchShape: Shape {
    var radius: CGFloat
    /// Concave flare into the menu bar, so the panel reads as growing out of the hardware.
    var topRadius: CGFloat = 6

    /// Without this the radius snaps while the frame springs — the silhouette and the size
    /// animate on different clocks, which is what makes a morph look cheap.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, topRadius) }
        set { radius = newValue.first; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height, rect.width / 2)
        let t = max(0, min(topRadius, rect.height / 3))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX - t, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + t),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX + t, y: rect.minY),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Live-activity bars — motion is the signal that something is actually running.
struct ActivityBars: View {
    var color: Color
    var height: CGFloat = 12
    var active: Bool = true
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: 2.5, height: bar(i))
                    .animation(
                        active && !reduceMotion
                            ? .easeInOut(duration: 0.40 + Double(i) * 0.11).repeatForever(autoreverses: true)
                            : .default, value: phase)
            }
        }
        .frame(height: height)
        .onAppear { phase = active && !reduceMotion }
        .onChange(of: active) { _, v in phase = v && !reduceMotion }
    }

    private func bar(_ i: Int) -> CGFloat {
        guard active, !reduceMotion else { return 3 }
        let lo: [CGFloat] = [0.32, 0.55, 0.38, 0.70]
        let hi: [CGFloat] = [0.95, 1.0, 0.72, 0.50]
        return max(3, height * (phase ? hi[i % 4] : lo[i % 4]))
    }
}

struct Dot: View {
    let color: Color
    var size: CGFloat = 6
    var pulse = false
    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: color.opacity(0.5), radius: pulse && up ? 4 : 2)
            .onAppear {
                guard pulse, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { up = true }
            }
    }
}


extension Theme {
    /// Depth without colour noise — a faint top sheen so panels read as glass, not paint.
    static let sheen = LinearGradient(
        colors: [Color.white.opacity(0.06), Color.white.opacity(0.0)],
        startPoint: .top, endPoint: .bottom)

    static func surface(_ raised: Bool) -> LinearGradient {
        LinearGradient(colors: raised
            ? [Color(red: 0.118, green: 0.126, blue: 0.149), Color(red: 0.086, green: 0.094, blue: 0.114)]
            : [Color(red: 0.063, green: 0.067, blue: 0.082), Color(red: 0.043, green: 0.047, blue: 0.059)],
            startPoint: .top, endPoint: .bottom)
    }
}
