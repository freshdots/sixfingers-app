import AppKit
import HotKey

/// A single source of truth for a keyboard shortcut so the global hotkey, the
/// menu-item display, and (later) a preferences pane can stay in sync without
/// duplicating modifier-mask math.
struct KeyBinding {
    let key: Key
    let modifiers: NSEvent.ModifierFlags
    /// The character we hand to `NSMenuItem.keyEquivalent` — kept explicit
    /// because `Key` does not map 1:1 to a printable menu glyph for every key.
    let menuKeyEquivalent: String

    /// Default trigger for "Draw…". Matches `⌥⇧6`.
    static let draw = KeyBinding(
        key: .six,
        modifiers: [.option, .shift],
        menuKeyEquivalent: "6"
    )
}
