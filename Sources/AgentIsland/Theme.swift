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

/// What an agent is doing, as far as the hook stream can tell.
enum WorkKind {
    case idle, thinking, reading, writing, running, searching, delegating, waiting

    var label: String {
        switch self {
        case .idle:       return "idle"
        case .thinking:   return "thinking"
        case .reading:    return "reading"
        case .writing:    return "editing"
        case .running:    return "running"
        case .searching:  return "searching"
        case .delegating: return "delegating"
        case .waiting:    return "needs you"
        }
    }
}

/// Proof of life in the resting bar, where the motion carries the meaning.
///
/// Backed by Core Animation rather than SwiftUI: a `repeatForever` here re-renders a view that
/// is on screen all day and measured 6.9% CPU, while a CAAnimation is handed to the render
/// server once and costs this process nothing.
///
/// Hue stays semantic — green works, amber needs you — so the *movement* distinguishes thinking
/// from editing: a rainbow of states reads as decoration, a vocabulary of motion reads as status.
struct RunningPulse: View {
    var kind: WorkKind = .thinking
    var width: CGFloat = 15
    var dot: CGFloat = 5

    // An NSView has no intrinsic size, so without an explicit frame SwiftUI hands it the whole
    // cell and the dot sinks to the bottom of the bar.
    var body: some View {
        PulseLayer(kind: kind, width: width, dot: dot)
            .frame(width: width, height: dot)
    }
}

private struct PulseLayer: NSViewRepresentable {
    var kind: WorkKind
    var width: CGFloat
    var dot: CGFloat

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: dot))
        v.wantsLayer = true
        let track = CALayer()
        track.name = "track"
        track.frame = CGRect(x: 0, y: (dot - dot * 0.6) / 2, width: width, height: dot * 0.6)
        track.cornerRadius = dot * 0.3
        let ball = CALayer()
        ball.name = "dot"
        ball.frame = CGRect(x: 0, y: 0, width: dot, height: dot)
        ball.cornerRadius = dot / 2
        v.layer?.addSublayer(track)
        v.layer?.addSublayer(ball)
        apply(to: v, context: context)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { apply(to: v, context: context) }

    private func apply(to v: NSView, context: Context) {
        guard let track = v.layer?.sublayers?.first(where: { $0.name == "track" }),
              let ball = v.layer?.sublayers?.first(where: { $0.name == "dot" }) else { return }
        let cg = NSColor(color).cgColor
        track.backgroundColor = NSColor(color).withAlphaComponent(0.18).cgColor
        ball.backgroundColor = cg
        ball.shadowColor = cg
        ball.shadowOpacity = 0.5
        ball.shadowRadius = 2
        ball.shadowOffset = .zero
        track.isHidden = !travels
        ball.removeAllAnimations()

        let still = context.environment.accessibilityReduceMotion || kind == .idle
        let mid = (width - dot) / 2
        ball.frame.origin.x = travels ? 0 : mid
        ball.opacity = 1
        ball.transform = CATransform3DIdentity
        guard !still else { return }

        let a: CABasicAnimation
        if travels {
            a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = dot / 2
            a.toValue = width - dot / 2
        } else {
            a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 0.75
            a.toValue = 1.45
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55
            fade.toValue = 1.0
            fade.duration = period
            fade.autoreverses = true
            fade.repeatCount = .infinity
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ball.add(fade, forKey: "fade")
        }
        a.duration = period
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ball.add(a, forKey: "pulse")
    }

    /// Every working state is one colour, because thinking IS working — greying it out made the
    /// most common state read as "nothing is happening", and at 5pt a desaturated dot on this
    /// background just looks black. Only "needs you" changes hue; speed says the rest.
    private var color: Color {
        kind == .waiting ? Theme.waiting : Theme.working
    }

    /// Seconds for one sweep. Deliberation is slow, scanning is quick.
    private var period: Double {
        switch kind {
        case .thinking:   return 1.5
        case .reading:    return 0.5
        case .searching:  return 0.7
        case .running:    return 0.85
        case .delegating: return 1.1
        default:          return 0.9
        }
    }

    /// Editing types in place; everything else travels. Waiting holds still and breathes.
    private var travels: Bool {
        switch kind {
        case .writing, .waiting, .idle: return false
        default:                        return true
        }
    }
}
