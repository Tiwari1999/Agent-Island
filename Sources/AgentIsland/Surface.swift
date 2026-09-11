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
    var current: Surface { choice }
    var sleek: Bool { choice == .sleek }
}

/// Measured off Droppy over a dark *and* a bright desktop: it reads `#000000` on both, and its
/// edge goes background-to-black in a single pixel with no highlight anywhere.
enum Sleek {
    static let body      = Color.black
    /// Droppy calls this `DroppyEdgeFadeMask`: ~63pt of near-linear alpha ramp, so the panel
    /// dissolves instead of ending. Capped here because our content runs to the boundary.
    static let fadeLength: CGFloat = 26
    static let control   = Color(red: 0.153, green: 0.161, blue: 0.165)   // #27292A pill body
    static let chip      = Color(red: 0.306, green: 0.310, blue: 0.314)   // #4E4F50 selected
    static let chipRim   = Color(red: 0.247, green: 0.259, blue: 0.271)   // #3F4245 1px edge
    static let glyph     = Color.white
    static let glyphIdle = Color(red: 0.576, green: 0.580, blue: 0.584)   // #939495
}

/// The island's shell in whichever material is selected.
struct IslandBackground: View {
    @ObservedObject private var surfaces = Surfaces.shared
    let corner: CGFloat
    let expanded: Bool

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
        let len = min(Sleek.fadeLength, height * 0.3)
        return LinearGradient(
            stops: [.init(color: .black, location: 0),
                    .init(color: .black, location: max(0, (height - len) / max(height, 1))),
                    .init(color: .black.opacity(0), location: 1)],
            startPoint: .top, endPoint: .bottom)
    }
}

/// Droppy's controls are what actually read as glass: the only bright thing on a black ground.
struct SleekChip<Content: View>: View {
    var selected: Bool = false
    @ViewBuilder var content: Content
    @ObservedObject private var surfaces = Surfaces.shared

    var body: some View {
        if surfaces.sleek {
            content
                .foregroundColor(selected ? Sleek.glyph : Sleek.glyphIdle)
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Capsule().fill(selected ? Sleek.chip : Sleek.control))
                .overlay(Capsule().stroke(Sleek.chipRim, lineWidth: 0.8))
        } else {
            content
                .foregroundColor(Theme.muted)
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Capsule().stroke(Theme.hairline))
        }
    }
}
