import AppKit
import Carbon.HIToolbox

/// Global hotkeys for answering a blocked agent without reaching for the mouse.
///
/// Carbon is the right tool despite its age: the panel is a `.nonactivatingPanel`, so this app is
/// almost never frontmost — `addLocalMonitorForEvents` and `.onKeyPress` both need a key window
/// and would never fire. A global NSEvent monitor would work but demands Accessibility, which is
/// a worse first-run experience for a keyboard shortcut.
final class Hotkeys {
    static let shared = Hotkeys()

    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false

    /// Registered only while a card is on screen, so these keys stay free the rest of the time.
    func bind(_ bindings: [(key: Int, mods: Int, action: () -> Void)]) {
        unbind()
        installHandlerIfNeeded()
        for (i, b) in bindings.enumerated() {
            let id = UInt32(i + 1)
            actions[id] = b.action
            var ref: EventHotKeyRef?
            // Another app owning the chord makes registration fail, and discarding the status
            // made that indistinguishable from a key that simply does nothing.
            let err = RegisterEventHotKey(UInt32(b.key), UInt32(b.mods),
                                          EventHotKeyID(signature: OSType(0x41494C44), id: id),
                                          GetApplicationEventTarget(), 0, &ref)
            if err != noErr || ref == nil {
                Diagnostics.log("hotkey: key \(b.key) mods \(b.mods) not available (\(err))")
                actions[id] = nil
                continue
            }
            refs.append(ref)
        }
    }

    func unbind() {
        for r in refs where r != nil { UnregisterEventHotKey(r!) }
        refs.removeAll()
        actions.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { Hotkeys.shared.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    // Number keys 1-4 for multiple choice.
    static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4]
    static let cmdOpt = cmdKey | optionKey
    /// Jumping between the questions of one ask. Shift distinguishes it from picking an option.
    static let cmdOptShift = cmdKey | optionKey | shiftKey
}
