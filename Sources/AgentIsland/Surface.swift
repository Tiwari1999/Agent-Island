import AppKit
import SwiftUI

/// What the panel is made of. Solid is the original look and stays the default; sleek sits
/// beside it so the two can be compared on the same UI instead of one replacing the other.
enum Surface: String {
    case solid, sleek

    var label: String { rawValue }
    var next: Surface { self == .solid ? .sleek : .solid }
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
    var sleek: Bool { choice == .sleek }
}

/// Measured off Droppy over a dark *and* a bright desktop: it reads `#000000` on both, and its
/// edge goes background-to-black in a single pixel with no highlight anywhere.
enum Sleek {
    static let body      = Color.black
    /// Droppy calls this `DroppyEdgeFadeMask`: ~63pt of near-linear alpha ramp, so the panel
    /// dissolves instead of ending. Theirs can be that long because their panels end in empty
    /// space; ours is clamped to whatever inset the state actually leaves below its content.
    static let fadeLength: CGFloat = 26
}

/// The island's shell in whichever material is selected.
struct IslandBackground: View {
    @ObservedObject private var surfaces = Surfaces.shared
    let corner: CGFloat
    let expanded: Bool
    /// Empty space below the content. The fade may not exceed it, or text renders over desktop.
    var inset: CGFloat = 6

    private var shape: NotchShape { NotchShape(radius: corner) }

    var body: some View {
        ZStack {
            if surfaces.sleek {
                // No stroke of any kind: Droppy's edge is one hard pixel, and the lit rim that
                // replaced it read as a drawn-on white line rather than light.
                GeometryReader { g in
                    shape.fill(Sleek.body).mask(dissolve(over: g.size.height))
                }
            } else {
                shape.fill(Theme.bg)
                shape.stroke(Theme.hairline, lineWidth: 0.7)
            }
        }
        .shadow(color: .black.opacity(0.55), radius: expanded ? 24 : 8, y: 6)
    }

    /// Scaled to the panel, so a 32pt collapsed bar is softened rather than erased.
    private func dissolve(over height: CGFloat) -> LinearGradient {
        let len = min(Sleek.fadeLength, height * 0.3, max(0, inset))
        return LinearGradient(
            stops: [.init(color: .black, location: 0),
                    .init(color: .black, location: max(0, (height - len) / max(height, 1))),
                    .init(color: .black.opacity(0), location: 1)],
            startPoint: .top, endPoint: .bottom)
    }
}
