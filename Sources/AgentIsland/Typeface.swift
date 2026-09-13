import SwiftUI

/// Which typeface the panel is set in. Kept switchable rather than swapped outright, so the
/// current look stays available to compare against — the same bargain as `Surfaces`.
enum Typeface: String, CaseIterable {
    /// SF Mono throughout. Dense and technical; what the panel shipped as.
    case mono
    /// SF Pro for words, fixed-width digits only where they line up. Reads as a UI, not a log.
    case clean
    /// SF Pro Rounded. Softest, and closest to the Dynamic Island it sits in.
    case round

    var label: String { rawValue }
}

final class Typefaces: ObservableObject {
    static let shared = Typefaces()
    private static let key = "typeface"

    @Published var choice: Typeface {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: Self.key) }
    }

    private init() {
        choice = Typeface(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .clean
    }
}
