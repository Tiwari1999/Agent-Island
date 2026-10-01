import SwiftUI

/// Three semantic hues only — working, waiting, failed — plus amber reserved solely for quota
/// pressure. A preattentive channel only works while it is rare, so everything else is neutral
/// and differentiated by weight and size instead.
/// Four steps, floored at 10pt — the smallest standard macOS label. Twelve sizes between 7 and
/// 12.5 was not a scale: half-point steps are invisible apart and incoherent together.
enum Type {
    static let micro: CGFloat = 10   // timestamps and secondary metadata
    static let small: CGFloat = 11   // supporting text, chips, pills
    static let body:  CGFloat = 12   // row titles and messages
    static let title: CGFloat = 13   // headings
}

enum Theme {
    private static var sleek: Bool { Surfaces.shared.sleek }

    // Sampled off Droppy: a pure-black ground with brighter, neutral controls. Ours were
    // blue-tinted and dim, which is why the same layout read as flat beside it.
    static var bg: Color { sleek ? .black : Color(red: 0.055, green: 0.059, blue: 0.071) }
    static var raised: Color {
        sleek ? Color(red: 0.153, green: 0.161, blue: 0.165)      // #27292A
              : Color(red: 0.094, green: 0.102, blue: 0.122)
    }
    static var hairline: Color { Color.white.opacity(sleek ? 0.13 : 0.08) }

    static var text: Color {
        sleek ? Color(red: 0.976, green: 0.976, blue: 0.980)
              : Color(red: 0.937, green: 0.945, blue: 0.960)
    }
    static var muted: Color {
        sleek ? Color(red: 0.576, green: 0.580, blue: 0.584)      // #939495
              : Color(red: 0.541, green: 0.576, blue: 0.639)
    }
    static var faint: Color {
        sleek ? Color(red: 0.420, green: 0.424, blue: 0.427)
              : Color(red: 0.353, green: 0.384, blue: 0.443)
    }

    static let working   = Color(red: 0.243, green: 0.788, blue: 0.588)   // teal-green
    static let waiting   = Color(red: 0.478, green: 0.647, blue: 1.000)   // soft blue
    static let failed    = Color(red: 0.906, green: 0.400, blue: 0.451)   // muted rose
    static let idle      = Color(red: 0.396, green: 0.427, blue: 0.486)
    static let amber     = Color(red: 0.960, green: 0.720, blue: 0.300)
    // Was a duplicate of `waiting`, which spent the "needs you" colour on ordinary tool names.
    static let tool      = Color(red: 0.541, green: 0.576, blue: 0.639)
    // Demoted from orange: an agent badge carries identity, not urgency.
    static let agentTint = Color(red: 0.478, green: 0.510, blue: 0.576)

    private static var face: Typeface { Typefaces.shared.choice }

    /// A proportional face sets smaller than a monospaced one at the same point size, so the
    /// non-mono options are nudged up to keep the panel's density where it was.
    private static func sized(_ s: CGFloat) -> CGFloat { face == .mono ? s : s + 0.5 }

    static func name(_ s: CGFloat) -> Font { .system(size: s, weight: .medium, design: .rounded) }
    static func label(_ s: CGFloat) -> Font { .system(size: s, weight: .semibold, design: .rounded) }

    /// Named for what it guarantees — columns that line up — not for being monospaced. The
    /// proportional options keep `monospacedDigit`, so quota and cost figures still align.
    static func mono(_ s: CGFloat) -> Font {
        switch face {
        case .mono:  return .system(size: s, weight: .regular, design: .monospaced)
        case .clean: return .system(size: sized(s), weight: .regular).monospacedDigit()
        case .round: return .system(size: sized(s), weight: .regular, design: .rounded).monospacedDigit()
        }
    }
}

/// One vocabulary for every moving thing. Eleven different curves were in play — a vendor
/// switch on .snappy(0.2) beside a shell on .spring(0.30/0.85) — so things that move together
/// ran on different clocks, which is what reads as rough.
enum Motion {
    /// Opening overshoots slightly on purpose; 0.82 settled dead flat and read as a resize.
    static let shell   = Animation.spring(response: 0.38, dampingFraction: 0.76)
    /// Contents used to hard-cut while the shell sprang around them — the silhouette moved and
    /// everything inside it snapped.
    ///
    /// Asymmetric on purpose. Symmetric, the outgoing bar and the incoming panel cross-dissolve
    /// over the whole spring, which reads as two things sharing a space rather than one becoming
    /// the other — and the new content sits at full size inside a shell still growing around it,
    /// so it looks masked. The old surface leaves quickly, the new one waits for the shape to be
    /// most of the way there and then rises the last 3%.
    static let morph: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
            .animation(.easeOut(duration: 0.20).delay(0.08)),
        removal: .opacity.animation(.easeIn(duration: 0.10)))
    static let content = Animation.spring(response: 0.26, dampingFraction: 0.90)
    static let quick   = Animation.easeOut(duration: 0.15)
    static let hover   = Animation.easeOut(duration: 0.11)
    static let value   = Animation.snappy(duration: 0.24)
    /// One-shot beat when a turn ends. Long enough to register in peripheral vision, short
    /// enough not to leave an afterimage under the next row's hover; never repeats, because a
    /// finished session must stop asking for attention.
    static let settle  = Animation.easeOut(duration: 0.9)
    /// Chip identity changes only, and only just underdamped: 0.58 read as a toy bouncing,
    /// 0.78 sits beside `shell`'s 0.76 so an arriving chip and an opening panel share a feel.
    /// Digits stay on `value` — a count ticking is not a thing appearing.
    static let pop     = Animation.spring(response: 0.28, dampingFraction: 0.78)
    /// Closing is not opening played backwards. A spring's overshoot on the way out reads as
    /// the panel being reluctant; a cubic ease with no bounce reads as dismissed.
    static let close   = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.30)
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

    /// How far from the corner the turn begins, as a multiple of the radius, and how hard the
    /// control points pull toward it. A quadratic corner starts turning AT the radius and its
    /// curvature jumps from zero to maximum in one step — that discontinuity is the shoulder
    /// the eye reads as a hard edge. Starting wider and easing in is what a continuous corner
    /// is. These two numbers are the dial: raise `span` for softer, raise `pull` for tighter.
    private static let span: CGFloat = 1.28
    private static let pull: CGFloat = 0.62

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height, rect.width / 2)
        let t = max(0, min(topRadius, rect.height / 3))
        // The wider span has to stay inside the box, or two corners meet in the middle.
        let s = min(r * Self.span, rect.height, rect.width / 2)
        let k = Self.pull

        func bend(_ p: inout Path, to b: CGPoint, around c: CGPoint, from a: CGPoint) {
            p.addCurve(to: b,
                       control1: CGPoint(x: a.x + k * (c.x - a.x), y: a.y + k * (c.y - a.y)),
                       control2: CGPoint(x: b.x + k * (c.x - b.x), y: b.y + k * (c.y - b.y)))
        }

        var p = Path()
        // The concave flare into the menu bar stays quadratic: at 6pt the curvature ramp is
        // invisible, and this is the edge that has to meet the hardware exactly.
        p.move(to: CGPoint(x: rect.minX - t, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + t),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - s))
        bend(&p, to: CGPoint(x: rect.minX + s, y: rect.maxY),
             around: CGPoint(x: rect.minX, y: rect.maxY),
             from: CGPoint(x: rect.minX, y: rect.maxY - s))
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.maxY))
        bend(&p, to: CGPoint(x: rect.maxX, y: rect.maxY - s),
             around: CGPoint(x: rect.maxX, y: rect.maxY),
             from: CGPoint(x: rect.maxX - s, y: rect.maxY))
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


/// What an agent is doing, as far as the hook stream can tell.
enum WorkKind {
    case idle, thinking, reading, writing, running, searching, delegating, waiting
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

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var kind: WorkKind? }

    private func apply(to v: NSView, context: Context) {
        guard let track = v.layer?.sublayers?.first(where: { $0.name == "track" }),
              let ball = v.layer?.sublayers?.first(where: { $0.name == "dot" }) else { return }
        let cg = NSColor(color).cgColor
        let trackCG = NSColor(color).withAlphaComponent(0.18).cgColor
        // Needs-you arriving mid-work used to swap hue on one frame, which reads as a glitch
        // rather than a change of state. One-shot lerp, no display link, no cost when static.
        if context.coordinator.kind != nil, context.coordinator.kind != kind,
           !context.environment.accessibilityReduceMotion {
            Self.lerp(ball, to: cg, key: "tint")
            Self.lerp(track, to: trackCG, key: "trackTint")
        } else {
            ball.backgroundColor = cg
            track.backgroundColor = trackCG
        }
        context.coordinator.kind = kind
        ball.shadowColor = cg
        ball.shadowOpacity = 0.5
        ball.shadowRadius = 2
        ball.shadowOffset = .zero
        track.isHidden = !travels
        // Keyed removal, not removeAllAnimations: that cancelled the tint lerp mid-flight.
        ball.removeAnimation(forKey: "pulse")
        ball.removeAnimation(forKey: "fade")

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

    private static func lerp(_ layer: CALayer, to: CGColor, key: String) {
        let a = CABasicAnimation(keyPath: "backgroundColor")
        a.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        a.toValue = to
        a.duration = 0.30
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.backgroundColor = to
        layer.add(a, forKey: key)
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
