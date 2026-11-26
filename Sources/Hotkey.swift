import Carbon.HIToolbox
import Cocoa

// The shortcut that brings BTranslate up from any app.
//
// It is a key by its place on the keyboard (so it is the same key in every layout, Russian or
// English) with modifier keys. macOS tells the app that it was pressed whatever app is in
// front; that part needs no permission. What the shortcut then does is in Sources/Focus.swift.

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32  // Carbon's: controlKey, optionKey, shiftKey, cmdKey

    /// ⌃⌥T
    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey))

    private static let modifierNames: [(mask: Int, word: String, sign: String, flag: NSEvent.ModifierFlags)] = [
        (controlKey, "control", "⌃", .control), (optionKey, "option", "⌥", .option),
        (shiftKey, "shift", "⇧", .shift), (cmdKey, "command", "⌘", .command),
    ]

    /// F1…F20 by key code: they may be a shortcut on their own.
    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// As it is kept in the settings: "control+option+17" (modifier words, then the key's code).
    init?(saved: String) {
        var parts = saved.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.popLast(), let code = UInt32(last), code < 128 else { return nil }
        var mask = 0
        for part in parts {
            guard let known = Shortcut.modifierNames.first(where: { $0.word == part }) else { return nil }
            mask |= known.mask
        }
        self.init(keyCode: code, modifiers: UInt32(mask))
        guard isUsable else { return nil }
    }

    var saved: String {
        (Shortcut.modifierNames.filter { Int(modifiers) & $0.mask != 0 }.map(\.word) + [String(keyCode)]).joined(separator: "+")
    }

    /// The shortcut a key press is, if it can be one.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mask = Shortcut.modifierNames.filter { flags.contains($0.flag) }.reduce(0) { $0 | $1.mask }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(mask))
        guard isUsable else { return nil }
    }

    /// A shortcut needs ⌃, ⌥ or ⌘ (a letter alone, or with ⇧, is typing), unless it is a function key.
    var isUsable: Bool {
        Int(modifiers) & (controlKey | optionKey | cmdKey) != 0 || Shortcut.functionKeys[Int(keyCode)] != nil
    }

    /// As it is shown: "⌃⌥T".
    var text: String {
        Shortcut.modifierNames.filter { Int(modifiers) & $0.mask != 0 }.map(\.sign).joined() + Shortcut.keyName(keyCode)
    }

    /// What is printed on the key, in the Latin layout the Mac has (a shortcut is shown as
    /// "T" even while the Russian layout is on).
    static func keyName(_ code: UInt32) -> String {
        if code == UInt32(kVK_Space) { return L("Space") }
        if let name = functionKeys[Int(code)] ?? namedKeys[Int(code)] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let layout = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var length = 0
        var letters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, letters.count, &length, &letters)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        let name = String(utf16CodeUnits: letters, count: length).uppercased()
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "#\(code)" : name
    }
}

/// Has macOS tell the app when the shortcut is pressed.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onPress: (() -> Void)?
    private(set) var current: Shortcut?
    private var registered: EventHotKeyRef?
    private var listening = false

    /// Makes `shortcut` the one that is listened for (nil: none). false: macOS would not have
    /// it; then none is listened for. (macOS does not refuse a shortcut that another app
    /// listens for too: then both are told.)
    @discardableResult
    func use(_ shortcut: Shortcut?) -> Bool {
        if let registered { UnregisterEventHotKey(registered) }
        registered = nil
        current = nil
        guard let shortcut else { return true }
        listen()
        var made: EventHotKeyRef?
        let name = EventHotKeyID(signature: 0x4254_524E, id: 1)  // "BTRN"
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, name, GetEventDispatcherTarget(), 0, &made) == noErr,
              let made else { return false }
        registered = made
        current = shortcut
        return true
    }

    /// Whether macOS would have `shortcut`; what is listened for stays as it is.
    func isFree(_ shortcut: Shortcut) -> Bool {
        if shortcut == current { return true }
        var made: EventHotKeyRef?
        let name = EventHotKeyID(signature: 0x4254_524E, id: 2)
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, name, GetEventDispatcherTarget(), 0, &made) == noErr,
              let made else { return false }
        UnregisterEventHotKey(made)
        return true
    }

    private func listen() {
        guard !listening else { return }
        listening = true
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.onPress?() } }
            return noErr
        }, 1, &kind, nil, nil)
    }
}

/// The settings' control for the shortcut: it shows it; a click, and the next keys pressed
/// become it. Esc leaves it as it was, ⌫ takes it away.
@MainActor
final class ShortcutField: NSButton {
    var shortcut: Shortcut? { didSet { refresh() } }
    var onChange: (() -> Void)?
    private(set) var isRecording = false
    private var monitor: Any?
    private var paused: Shortcut?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        title = isRecording ? L("Press the keys…") : (shortcut?.text ?? L("None"))
        toolTip = L("Click, then press the keys of the shortcut. Esc leaves it as it is, ⌫ takes it away.")
    }

    @objc private func clicked() { isRecording ? stop() : start() }

    private func start() {
        isRecording = true
        // The shortcut in use must not go off while its keys are pressed here.
        paused = HotkeyCenter.shared.current
        HotkeyCenter.shared.use(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.take(event)
            return nil
        }
        refresh()
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotkeyCenter.shared.use(paused)
        refresh()
    }

    /// A key pressed while recording (also the UI test's way in).
    func take(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
        if plain && event.keyCode == UInt16(kVK_Escape) { stop(); return }
        if plain && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) {
            shortcut = nil
            stop()
            onChange?()
            return
        }
        guard let pressed = Shortcut(event: event) else { return }  // a letter alone: still waiting
        shortcut = pressed
        stop()
        onChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }
}
