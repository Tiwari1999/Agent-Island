import AppKit
import SwiftUI

/// What the panel is made of. Solid is the original look and stays the default; glass sits
/// beside it so the two can be compared on the same UI instead of one replacing the other.
enum Surface: String {
    case solid, glass

    var label: String { rawValue }
    var next: Surface { self == .solid ? .glass : .solid }
}

final class Surfaces: ObservableObject {
    static let shared = Surfaces()
    private static let key = "surface"

    @Published var choice: Surface {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: Self.key) }
    }

    private init() {
        choice = Surface(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .solid
    }

    func toggle() { choice = choice.next }

    /// Reduce Transparency is a legibility setting, not a preference — glass yields to it.
    var current: Surface {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .solid : choice
    }
}

/// An `NSVisualEffectView` blurring what is behind the *window* — the only blending mode that
/// reads as glass over the desktop rather than over our own content.
private struct Backdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        // Defaults to following window state, and this panel is deliberately never key — so the
        // material would render inactive and flat exactly while it is on screen.
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.state = .active }
}

/// The island's shell in whichever material is selected.
struct IslandBackground: View {
    @ObservedObject private var surfaces = Surfaces.shared
    let corner: CGFloat
    let expanded: Bool

    private var shape: NotchShape { NotchShape(radius: corner) }

    var body: some View {
        ZStack {
            if surfaces.current == .glass {
                glass
            } else {
                shape.fill(Theme.bg)
            }
        }
        .overlay(shape.stroke(Theme.hairline, lineWidth: 0.7))
        .shadow(color: .black.opacity(0.55), radius: expanded ? 24 : 8, y: 6)
    }

    /// The tint is not decoration: `Theme`'s text colours are fixed RGB tuned for a near-black
    /// ground, and would lose contrast over a bright desktop without it.
    @ViewBuilder
    private var glass: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(Theme.bg.opacity(0.62)), in: shape)
        } else {
            Backdrop()
                .clipShape(shape)
                .overlay(shape.fill(Theme.bg.opacity(0.62)))
        }
    }
}
