import SwiftUI
import AppKit

/// What the face is doing. The reference app this idea came from runs one character for the
/// whole window; a roster wants one face per agent, so the expression lives on the per-session
/// avatar and the body colour is the session's own.
enum Mood: Equatable {
    case working, needsYou, blocked, idle, done, died, confused

    /// Only these two run a CONTINUOUS animation. Hover still perks and glances and done
    /// still hops, but those are one-shots — what this gates is the forever loop, which is
    /// what would otherwise put a panel of a dozen faces on the idle budget.
    var animates: Bool { self == .working || self == .needsYou }
}

/// A head and two eyes. Shape and pose geometry follow CX-ArtLab/agent-robot-avatar (MIT),
/// reimplemented on CoreAnimation rather than its SVG/CSS. The head and its lids carry the
/// session's hue; the eyes are whatever shade stays readable against it, which is not always
/// white — see `eyeColor(on:)`.
struct AgentAvatar: View {
    let seed: String
    var size: CGFloat = 20
    var mood: Mood = .idle
    /// Pointer is over this row. The face looks up at you — one-shot, so hovering a list costs
    /// nothing once the pointer settles.
    var hovered: Bool = false

    private var hash: UInt64 {
        // FNV-1a: cheap, well-spread, and stable across launches.
        var h: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// One hue per chat, evenly spaced around the wheel. An earlier pass desaturated these to
    /// under 0.30 and all eight collapsed into the same grey-blue; eight faces have to be told
    /// apart at 17pt in a menu bar, so what matters is the spacing, not the restraint.
    private var skin: Color {
        let hues: [Color] = [
            Color(red: 0.80, green: 0.45, blue: 0.34),   // vermilion
            Color(red: 0.80, green: 0.80, blue: 0.34),   // yellow
            Color(red: 0.46, green: 0.80, blue: 0.34),   // chartreuse
            Color(red: 0.34, green: 0.80, blue: 0.56),   // green
            Color(red: 0.34, green: 0.69, blue: 0.80),   // cyan
            Color(red: 0.34, green: 0.34, blue: 0.80),   // blue
            Color(red: 0.68, green: 0.34, blue: 0.80),   // violet
            Color(red: 0.80, green: 0.34, blue: 0.57),   // magenta
        ]
        return hues[Int(hash % UInt64(hues.count))]
    }

    var body: some View {
        FaceLayer(mood: mood, size: size, tint: NSColor(skin), hovered: hovered,
                  phase: Double(hash % 1000) / 1000.0)
            .frame(width: size, height: size)
    }
}

/// Pose numbers are the reference's, in its own 240x240 space, scaled to our size at draw time.
/// Every expression in the set falls out of six numbers: the eye's width and height, where
/// each lid sits, how far the pair is tilted, and a cock applied to one eye alone.
private struct Pose {
    var w: CGFloat, h: CGFloat, topY: CGFloat, botY: CGFloat
    /// Mirrored between the eyes, which is what keeps sad and angry symmetrical.
    var tiltTop: CGFloat = 0, tiltBot: CGFloat = 0
    /// Added to one eye only. Symmetry reads as a mood; asymmetry reads as a question — this
    /// is the single number that makes a face look puzzled rather than merely surprised.
    var cock: CGFloat = 0

    static func of(_ m: Mood) -> Pose {
        switch m {
        case .working:  return Pose(w: 46, h: 50, topY: -32, botY: 32)
        // Half again the size of working, not a nudge above it. A session blocked on you
        // looked identical to one merely busy at 30pt, which is the one confusion this face
        // exists to prevent.
        case .needsYou: return Pose(w: 70, h: 70, topY: -42, botY: 42)
        case .done:     return Pose(w: 50, h: 50, topY: -32, botY: 0)
        case .blocked:  return Pose(w: 50, h: 48, topY: 0, botY: 32)
        case .died:     return Pose(w: 50, h: 50, topY: -4, botY: 32, tiltTop: -16, tiltBot: 16)
        // One brow up, one down, eyes a little uneven: being asked something is not the same
        // as being interrupted, and the card should not look alarmed about a multiple choice.
        case .confused: return Pose(w: 52, h: 54, topY: -20, botY: 34, tiltTop: -7, cock: 26)
        // Shut, and shut cleanly. A short line of eye with the lids kept well clear of it reads
        // as closed; the first attempt left a sliver of white pinched between two lids, which
        // is a creature squinting rather than a session asleep.
        case .idle:     return Pose(w: 42, h: 5, topY: -30, botY: 30)
        }
    }
}

private struct FaceLayer: NSViewRepresentable {
    let mood: Mood
    let size: CGFloat
    let tint: NSColor
    let hovered: Bool
    let phase: Double

    /// The reference's viewBox. Every constant below is in this space and scaled once.
    private static let box: CGFloat = 240
    private static let eyeY: CGFloat = 126
    private static let eyeL: CGFloat = 86
    private static let eyeR: CGFloat = 154

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        let head = CAShapeLayer(); head.name = "head"
        v.layer?.addSublayer(head)
        for side in ["L", "R"] {
            // The eye sits under two lids painted in the head's own colour; the visible
            // aperture is whatever they leave uncovered. That is the whole expression system.
            let white = CAShapeLayer(); white.name = "eye" + side
            let top = CAShapeLayer(); top.name = "top" + side
            let bot = CAShapeLayer(); bot.name = "bot" + side
            let mask = CAShapeLayer(); mask.name = "mask" + side
            let g = CALayer(); g.name = "g" + side
            g.addSublayer(white); g.addSublayer(top); g.addSublayer(bot)
            g.mask = mask
            v.layer?.addSublayer(g)
        }
        apply(to: v, context: context)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { apply(to: v, context: context) }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var mood: Mood?; var hovered = false }

    /// White eyes were hardcoded, and measured 1.70:1 against the yellow body — seven of the
    /// eight hues failed the 4.5:1 readable floor, which at 17pt in a menu bar means the face
    /// has no eyes at all. Dark eyes on a light face, light on a dark one, then walk until it
    /// actually passes rather than assuming it does. The rule is blobatar's (MIT).
    static func eyeColor(on body: NSColor) -> NSColor {
        let lit = Self.luminance(body) > 0.18
        var l: CGFloat = lit ? 0.10 : 0.98
        for _ in 0..<40 {
            let c = NSColor(white: l, alpha: 1)
            if Self.contrast(c, body) >= 4.5 { return c }
            l += lit ? -0.02 : 0.02
            if l < 0 || l > 1 { break }
        }
        return NSColor(white: lit ? 0 : 1, alpha: 1)
    }

    private static func luminance(_ c: NSColor) -> CGFloat {
        guard let s = c.usingColorSpace(.sRGB) else { return 0.5 }
        func f(_ x: CGFloat) -> CGFloat { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(s.redComponent) + 0.7152 * f(s.greenComponent) + 0.0722 * f(s.blueComponent)
    }

    private static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func apply(to v: NSView, context: Context) {
        guard let root = v.layer else { return }
        let reduce = context.environment.accessibilityReduceMotion
        let arrived = context.coordinator.mood != mood
        // Everything below assigns layer properties directly, which on a layer-backed NSView
        // lands on the next frame with no interpolation — so a mood change snapped the eye
        // shape, the lid angles and the colour all at once. An explicit transaction turns the
        // same assignments into one coordinated 0.32s ease, which is the whole difference
        // between a face that changes expression and a face that cuts to a different frame.
        CATransaction.begin()
        CATransaction.setDisableActions(!arrived || reduce)
        if arrived && !reduce {
            CATransaction.setAnimationDuration(0.32)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(controlPoints: 0.33, 0, 0.2, 1))   // cubic out
        }
        defer { CATransaction.commit() }
        let justHovered = hovered && !context.coordinator.hovered
        context.coordinator.mood = mood
        context.coordinator.hovered = hovered
        let s = size / Self.box
        // Looked at, so it looks back — but a busy agent does not stop to stare. One that is
        // working glances sideways and keeps going; one that is idle opens its eyes at you.
        let glancing = hovered && mood == .working
        let p = (hovered && !glancing)
            ? Pose(w: 58, h: 58, topY: -36, botY: 36)
            : Pose.of(mood)

        // Dim the whole face at once, never the parts. Fading the head and the lids
        // separately composited two translucent layers wherever they overlapped, which drew
        // exactly the pair of bands above and below the eye that the lids exist to hide.
        root.opacity = mood == .idle ? 0.42 : 1
        let skin = tint.cgColor
        if let head = root.sublayers?.first(where: { $0.name == "head" }) as? CAShapeLayer {
            // The reference ships a 160-point polyline approximating a squircle. A continuous
            // rounded rect is the same silhouette in one call, and it is the curve the rest of
            // this app already draws.
            let inset: CGFloat = 20 * s
            let side = size - inset * 2
            head.path = NSBezierPath(roundedRect: CGRect(x: inset, y: inset,
                                                         width: side, height: side),
                                     xRadius: side * 0.24, yRadius: side * 0.24).cgPath
            head.fillColor = skin
        }

        for (side, cx) in [("L", Self.eyeL), ("R", Self.eyeR)] {
            guard let g = root.sublayers?.first(where: { $0.name == "g" + side }),
                  let white = g.sublayers?.first(where: { $0.name == "eye" + side }) as? CAShapeLayer,
                  let top = g.sublayers?.first(where: { $0.name == "top" + side }) as? CAShapeLayer,
                  let bot = g.sublayers?.first(where: { $0.name == "bot" + side }) as? CAShapeLayer,
                  let mask = g.mask as? CAShapeLayer else { continue }
            g.frame = root.bounds
            let c = CGPoint(x: cx * s, y: size - Self.eyeY * s)
            white.path = CGPath(ellipseIn: CGRect(x: c.x - p.w * s / 2, y: c.y - p.h * s / 2,
                                                  width: p.w * s, height: p.h * s), transform: nil)
            white.fillColor = Self.eyeColor(on: tint).cgColor
            mask.path = CGPath(rect: CGRect(x: c.x - 40 * s, y: c.y - 54 * s,
                                            width: 80 * s, height: 108 * s), transform: nil)
            // Lids are oversized slabs: only their inner edge is ever on screen, so rotating
            // them cannot expose a corner.
            for (lid, y, tilt) in [(top, p.topY, p.tiltTop), (bot, p.botY, p.tiltBot)] {
                let isTop = lid === top
                let rect = CGRect(x: -70 * s, y: isTop ? 0 : -90 * s, width: 140 * s, height: 90 * s)
                lid.path = CGPath(rect: rect, transform: nil)
                // Exactly the head colour, not a shade of it. Lifting the brightness by 0.05
                // was left over from when the head was shaded, and against a flat head it drew
                // two visible bands across the face — the lids have to disappear into it, so
                // that the only thing on screen is whatever eye they leave uncovered.
                lid.fillColor = skin
                lid.bounds = CGRect(origin: .zero, size: root.bounds.size)
                lid.position = CGPoint(x: c.x, y: c.y - y * s)
                lid.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                // The cock lands on the left top lid alone, so the two brows disagree.
                let extra = (lid === top && side == "L") ? p.cock : 0
                let a = ((side == "L" ? tilt : -tilt) + extra) * .pi / 180
                lid.transform = CATransform3DMakeRotation(a, 0, 0, 1)
            }
            white.removeAllAnimations()
            g.removeAllAnimations()

            if glancing, !reduce {
                // Eyes slide within the lid aperture: a glance, not a head turn. It only runs
                // while the pointer is on this row, and one row is hovered at a time.
                let look = CAKeyframeAnimation(keyPath: "transform.translation.x")
                let d = 11 * s
                look.values = [0, -d, -d, d, d, 0, 0]
                look.keyTimes = [0, 0.12, 0.34, 0.5, 0.72, 0.84, 1]
                look.duration = 2.6
                look.repeatCount = .infinity
                look.calculationMode = .cubic
                white.add(look, forKey: "look")
                continue
            }
            guard !reduce, !hovered, mood.animates else { continue }
            if mood == .working {
                // A blink is a height change on the white, not a different shape — and it is
                // mostly pause, which is what stops a row of faces reading as a strobe.
                let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
                blink.values = [1.0, 1.0, 0.08, 1.0, 1.0]
                blink.keyTimes = [0, 0.93, 0.955, 0.985, 1]
                blink.duration = 4.2
                blink.repeatCount = .infinity
                blink.timeOffset = phase * 4.2
                white.add(blink, forKey: "blink")
            } else {
                // Needs-you leans in and bobs: the eyes are already wide, so the motion only
                // has to say "over here" without becoming an alarm.
                let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
                bob.values = [0, -1.6 * s * 10, 0, -1.0 * s * 10, 0, 0]
                bob.keyTimes = [0, 0.09, 0.2, 0.29, 0.4, 1]
                bob.duration = 2.0
                bob.repeatCount = .infinity
                bob.calculationMode = .cubic
                g.add(bob, forKey: "bob")
            }
        }

        guard !reduce,
              let head = root.sublayers?.first(where: { $0.name == "head" }) else { return }
        if justHovered {
            let perk = CAKeyframeAnimation(keyPath: "transform.scale")
            perk.values = [1.0, 1.12, 0.98, 1.0]
            perk.keyTimes = [0, 0.35, 0.7, 1]
            perk.duration = 0.28
            perk.timingFunction = CAMediaTimingFunction(name: .easeOut)
            head.add(perk, forKey: "perk")
            return
        }
        guard arrived, mood == .done else { return }
        let hop = CAKeyframeAnimation(keyPath: "transform.scale")
        hop.values = [1.0, 0.9, 1.1, 0.98, 1.0]
        hop.keyTimes = [0, 0.18, 0.44, 0.74, 1]
        hop.duration = 0.5
        head.add(hop, forKey: "hop")
    }
}

private extension NSBezierPath {
    /// NSBezierPath has no cgPath before macOS 14's rename settled; this is the stable spelling.
    var cgPath: CGPath {
        let p = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo:    p.move(to: pts[0])
            case .lineTo:    p.addLine(to: pts[0])
            case .curveTo:   p.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath: p.closeSubpath()
            @unknown default: break
            }
        }
        return p
    }
}
