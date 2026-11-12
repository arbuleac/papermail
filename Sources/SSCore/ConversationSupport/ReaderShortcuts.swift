import Foundation

/// Keyboard rules for the reader, on raw event values so they stay AppKit-free and testable.
///
/// The modifier bits are `NSEvent.ModifierFlags` raw values; `ReaderShortcutsTests` asserts they match AppKit.
public enum ReaderShortcuts {
    public static let capsLock: UInt = 1 << 16
    public static let shift: UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option: UInt = 1 << 19
    public static let command: UInt = 1 << 20
    public static let numericPad: UInt = 1 << 21
    public static let function: UInt = 1 << 23

    /// Return and keypad Enter.
    public static let returnKeyCodes: Set<UInt16> = [36, 76]

    /// The modifiers a chord is defined by. Caps Lock, the keypad bit and Fn describe the keyboard's
    /// state, not what the user meant, so Cmd+Return with Caps Lock on is still Cmd+Return.
    public static let chordMask: UInt = shift | control | option | command

    public static func chord(_ rawModifierFlags: UInt) -> UInt {
        rawModifierFlags & chordMask
    }

    /// Cmd+Return or Cmd+keypad Enter sends the quick reply, as its Send button does (spec §5.23).
    public static func isSend(keyCode: UInt16, rawModifierFlags: UInt) -> Bool {
        returnKeyCodes.contains(keyCode) && chord(rawModifierFlags) == command
    }

    /// Shift+Cmd+Return (or keypad Enter) sends the quick reply and archives its conversation, whatever Send does.
    public static func isSendAndArchive(keyCode: UInt16, rawModifierFlags: UInt) -> Bool {
        returnKeyCodes.contains(keyCode) && chord(rawModifierFlags) == shift | command
    }

    /// An unmodified Space, the Quick Look key.
    public static func isPlainSpace(charactersIgnoringModifiers: String?, rawModifierFlags: UInt) -> Bool {
        charactersIgnoringModifiers == " " && chord(rawModifierFlags) == 0
    }

    public enum SpaceOutcome: Equatable {
        case closePreview
        case preview(AttachmentInfo)
        /// Nothing to preview, or focus on an elision mark: the event belongs to the web view, where Space pages
        /// down, or presses the focused mark.
        case passThrough
    }

    /// Space closes an open Quick Look panel, else presses a focused elision mark (spec §5.15), else previews the
    /// first real attachment. Inline parts are pictures in the body, not something to open.
    public static func spaceOutcome(previewVisible: Bool, markFocused: Bool = false, attachments: [AttachmentInfo]) -> SpaceOutcome {
        if previewVisible { return .closePreview }
        if markFocused { return .passThrough }
        guard let first = attachments.first(where: { !$0.isInline }) else { return .passThrough }
        return .preview(first)
    }
}
