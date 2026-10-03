import AppKit
import Sparkle

/// Sparkle, in-process on its own daily timer — never on the refresh path, which must spawn
/// nothing. Off entirely without a real EdDSA key in the bundle (dev builds, the bare binary).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    private let controller: SPUStandardUpdaterController?

    var available: Bool { controller != nil }

    /// Sparkle persists this itself; the mirror is only so Settings redraws when it flips.
    @Published var automatic: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automatic }
    }

    private init() {
        // Started with the placeholder key, Sparkle alerts "failed to start" on every launch.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = Data(base64Encoded: key)?.count == 32
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                           userDriverDelegate: nil)
            : nil
        automatic = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    func check() { controller?.checkForUpdates(nil) }
}
