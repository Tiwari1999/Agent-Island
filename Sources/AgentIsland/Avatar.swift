import SwiftUI

/// A deterministic pixel glyph per session — the same agent always draws the same badge, so rows
/// become recognisable by shape before you read them. Generated, so there are no assets to ship.
struct AgentAvatar: View {
    let seed: String
    var size: CGFloat = 20
    var active: Bool = true

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
        let px = size / 5
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { c in
                        Rectangle()
                            .fill(cells[r * 5 + c] ? (active ? fg : dim) : Color.clear)
                            .frame(width: px, height: px)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .opacity(active ? 1 : 0.55)
    }
}
