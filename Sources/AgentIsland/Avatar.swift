import SwiftUI
import AppKit

/// What the sprite is doing. The reference app this idea came from runs one mascot for the
/// whole window; a roster wants one face per agent, so the expression lives here rather than
/// in a single character, and it scales with the list instead of competing with it.
enum Mood: Equatable {
    case working, needsYou, blocked, idle, done, died

    /// Only these two move. Everything else parks, which is what keeps a panel full of
    /// sprites off the idle budget — nothing animates unless an agent is actually doing
    /// something or actually waiting on you.
    var animates: Bool { self == .working || self == .needsYou }
}

struct AgentAvatar: View {
    let seed: String
    var size: CGFloat = 20
    var mood: Mood = .idle

    init(seed: String, size: CGFloat = 20, mood: Mood = .idle) {
        self.seed = seed; self.size = size; self.mood = mood
    }

    private var hash: UInt64 {
        // FNV-1a: cheap, well-spread, and stable across launches.
        var h: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    private var palette: (Color, Color) {
        let hues: [(Color, Color)] = [
            (Theme.working, Color(red: 0.16, green: 0.55, blue: 0.42)),
            (Theme.waiting, Color(red: 0.25, green: 0.40, blue: 0.72)),
            (Theme.agentTint, Color(red: 0.62, green: 0.32, blue: 0.24)),
            (Color(red: 0.76, green: 0.55, blue: 0.98), Color(red: 0.44, green: 0.30, blue: 0.66)),
            (Theme.amber, Color(red: 0.60, green: 0.44, blue: 0.16)),
            (Color(red: 0.42, green: 0.82, blue: 0.86), Color(red: 0.20, green: 0.48, blue: 0.53)),
        ]
        return hues[Int(hash % UInt64(hues.count))]
    }

    /// 5x5, mirrored down the centre column — the shape language of an invader sprite.
    private var cells: [Bool] {
        var bits: [Bool] = []
        var h = hash
        for _ in 0..<15 { bits.append(h & 1 == 1); h >>= 1 }
        var grid: [Bool] = []
        for row in 0..<5 {
            let l = Array(bits[(row * 3)..<(row * 3 + 3)])
            grid += [l[0], l[1], l[2], l[1], l[0]]
        }
        return grid
    }

    var body: some View {
        let (fg, dim) = palette
        SpriteLayer(cells: cells, size: size, mood: mood,
                    lit: NSColor(fg), dull: NSColor(dim))
            .frame(width: size, height: size)
    }
}

/// One shape layer, not twenty-five SwiftUI rectangles. A panel can hold a dozen of these and
/// each needs a repeating transform while its agent works — the same reason `RunningPulse`
/// is CoreAnimation: SwiftUI's `repeatForever` measured 6.9% CPU, a CAAnimation costs this
/// process nothing once the render server has it.
private struct SpriteLayer: NSViewRepresentable {
    let cells: [Bool]
    let size: CGFloat
    let mood: Mood
    let lit: NSColor
    let dull: NSColor

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        let shape = CAShapeLayer()
        shape.name = "sprite"
        shape.frame = v.bounds
        shape.path = Self.path(cells, size)
        shape.fillRule = .nonZero
        v.layer?.addSublayer(shape)
        apply(to: v, context: context)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { apply(to: v, context: context) }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var mood: Mood? }

    private static func path(_ cells: [Bool], _ size: CGFloat) -> CGPath {
        let px = size / 5
        let p = CGMutablePath()
        for r in 0..<5 {
            for c in 0..<5 where cells[r * 5 + c] {
                // Flipped vertically: CALayer's origin is bottom-left, the grid reads top-down.
                p.addRect(CGRect(x: CGFloat(c) * px, y: CGFloat(4 - r) * px,
                                 width: px, height: px))
            }
        }
        return p
    }

    private func apply(to v: NSView, context: Context) {
        guard let shape = v.layer?.sublayers?.first(where: { $0.name == "sprite" })
                as? CAShapeLayer else { return }
        let reduce = context.environment.accessibilityReduceMotion
        // SwiftUI re-runs this on every store update. Without the edge, a row that sits in
        // .done for the hour `justCompleted` lasts would replay its hop a few times a second.
        let arrived = context.coordinator.mood != mood
        context.coordinator.mood = mood

        shape.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        shape.frame = v.bounds
        shape.removeAllAnimations()

        // Colour and weight carry the state on their own, so the sprite still reads correctly
        // with Reduce Motion on and with every animation stripped.
        switch mood {
        case .working:  shape.fillColor = lit.cgColor;  shape.opacity = 1
        case .needsYou: shape.fillColor = NSColor(Theme.waiting).cgColor; shape.opacity = 1
        // Recently finished, not still running: the hop is the moment, and after it the
        // sprite settles nearer stale than busy — `justCompleted` lasts an hour, and an hour
        // of full-brightness green is indistinguishable from work still in flight.
        case .done:     shape.fillColor = lit.cgColor;  shape.opacity = 0.72
        case .blocked:  shape.fillColor = dull.cgColor; shape.opacity = 0.5
        case .idle:     shape.fillColor = dull.cgColor; shape.opacity = 0.42
        case .died:     shape.fillColor = NSColor(Theme.failed).cgColor; shape.opacity = 0.55
        }

        // A lean is posture, not motion — it survives Reduce Motion because it says something
        // the colour does not: this one is leaning out at you.
        let lean: CGFloat = mood == .needsYou ? 0.10 : (mood == .blocked ? -0.06 : 0)
        let drop: CGFloat = mood == .blocked ? -size * 0.06 : 0
        shape.transform = CATransform3DConcat(
            CATransform3DMakeRotation(lean, 0, 0, 1),
            CATransform3DMakeTranslation(0, drop, 0))

        // A one-shot celebration: a small hop that settles. It plays on arrival at .done and
        // then the sprite is still, because a finished agent must stop asking for attention.
        if mood == .done, arrived, !reduce {
            let hop = CAKeyframeAnimation(keyPath: "transform.scale")
            hop.values = [1.0, 0.86, 1.14, 0.97, 1.0]
            hop.keyTimes = [0, 0.18, 0.42, 0.72, 1]
            hop.duration = 0.52
            hop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shape.add(hop, forKey: "hop")
            return
        }

        guard !reduce, mood.animates else { return }

        let a = CAKeyframeAnimation(keyPath: "transform")
        if mood == .needsYou {
            // Two quick tugs then a wait — a wave, not a vibration. The pause is most of the
            // cycle, which is what stops it reading as an error state you want to mute.
            func tilt(_ r: CGFloat, _ s: CGFloat) -> NSValue {
                NSValue(caTransform3D: CATransform3DConcat(
                    CATransform3DMakeScale(s, s, 1), CATransform3DMakeRotation(r, 0, 0, 1)))
            }
            a.values = [tilt(0.10, 1.0), tilt(0.24, 1.07), tilt(0.02, 1.0),
                        tilt(0.22, 1.06), tilt(0.10, 1.0), tilt(0.10, 1.0)]
            a.keyTimes = [0, 0.08, 0.17, 0.26, 0.36, 1]
            a.duration = 2.2
        } else {
            // Breathing with an occasional bob. One keyframe animation gives "every so often"
            // for free — a timer firing every seven seconds to nudge a sprite is exactly the
            // kind of always-on cost this app does not spend.
            func s(_ x: CGFloat, _ y: CGFloat) -> NSValue {
                NSValue(caTransform3D: CATransform3DMakeScale(x, y, 1))
            }
            a.values = [s(1, 1), s(1.045, 1.045), s(1, 1), s(1.045, 1.045), s(1, 1),
                        s(1.10, 0.90), s(0.96, 1.08), s(1, 1)]
            a.keyTimes = [0, 0.16, 0.32, 0.48, 0.64, 0.74, 0.86, 1]
            a.duration = 7.4
        }
        a.repeatCount = .infinity
        a.calculationMode = .cubic
        // Stagger per sprite, so a panel of agents reads as a crowd rather than one organism
        // breathing in lockstep — which is the thing that looks mechanical.
        a.timeOffset = Double(abs(cells.hashValue % 97)) / 97.0 * a.duration
        shape.add(a, forKey: "mood")
    }
}
