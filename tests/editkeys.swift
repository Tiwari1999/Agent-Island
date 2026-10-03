// The notch's editing shortcuts. NOT run on its own: tests/selftest.py lifts the real
// Panel.editAction out of Island.swift into `enum Q` and appends this.
var fails = 0
func check(_ n: String, _ ok: Bool) { if !ok { print("FAIL \(n)"); fails += 1 } }
let cmd: NSEvent.ModifierFlags = .command
check("⌘V pastes", Q.editAction(cmd, "v") == #selector(NSText.paste(_:)))
check("⌘C copies", Q.editAction(cmd, "c") == #selector(NSText.copy(_:)))
check("⌘X cuts", Q.editAction(cmd, "x") == #selector(NSText.cut(_:)))
check("⌘A selects all", Q.editAction(cmd, "a") == #selector(NSText.selectAll(_:)))
check("⌘Z undoes", Q.editAction(cmd, "z") == Selector(("undo:")))
check("⇧⌘Z redoes", Q.editAction([.command, .shift], "Z") == Selector(("redo:")))
check("caps lock does not stop paste", Q.editAction(cmd, "V") == #selector(NSText.paste(_:)))
// The app's own hotkeys are ⌘⌥ chords; swallowing them here would break approve/deny.
check("⌘⌥A is left to the hotkeys", Q.editAction([.command, .option], "a") == nil)
check("⌘⌥V is left alone", Q.editAction([.command, .option], "v") == nil)
check("a bare v is typing, not a shortcut", Q.editAction([], "v") == nil)
check("other ⌘ keys pass through", Q.editAction(cmd, "w") == nil)
print(fails == 0 ? "ok" : "\(fails) failed")
