import ApplicationServices
import Carbon.HIToolbox
import Cocoa

// What the shortcut finds in the app in front: the selected text, or the text field the
// cursor is in, or neither. Reading that, and writing into the field (Sources/TypeIn.swift),
// needs the user's permission: System Settings → Privacy & Security → Accessibility.

// MARK: - The permission

@MainActor
enum Accessibility {
    /// For tests: BTRANSLATE_ACCESSIBILITY=on|off stands for macOS's answer, and macOS is
    /// then never asked to show its request.
    private static let forced = ProcessInfo.processInfo.environment["BTRANSLATE_ACCESSIBILITY"]
    /// false in the command-line checks: none of them may make macOS show a request.
    static var mayAsk = true

    static var isAllowed: Bool { forced.map { $0 == "on" } ?? AXIsProcessTrusted() }

    /// macOS shows its request once; after that the switch is in System Settings.
    static func ask() {
        guard mayAsk, forced == nil else { return }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func openSystemSettings() {
        guard mayAsk, forced == nil,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The permission to take a window's picture: System Settings → Privacy & Security → Screen &
/// System Audio Recording. macOS asks for it the first time a window is chosen.
@MainActor
enum ScreenAccess {
    /// For tests: BTRANSLATE_SCREEN=on|off stands for macOS's answer.
    private static let forced = ProcessInfo.processInfo.environment["BTRANSLATE_SCREEN"]

    static var isAllowed: Bool { forced.map { $0 == "on" } ?? CGPreflightScreenCaptureAccess() }

    /// Has macOS show its request, which it does once, and put BTranslate on its list.
    static func ask() {
        guard Accessibility.mayAsk, forced == nil else { return }
        _ = CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        guard Accessibility.mayAsk, forced == nil,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - A note of what the shortcut did

/// ~/Library/Logs/BTranslate.log: which of its three things the shortcut did and what stood
/// in the way, to find a fault by. Never a text that was selected, typed or read: only its length.
enum Log {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BTranslate.log")
    private static let lock = NSLock()
    /// The command-line checks write nothing there.
    nonisolated(unsafe) static var isOn = true

    static func note(_ line: String) {
        guard isOn else { return }
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > 200_000 { try? FileManager.default.removeItem(at: file) }  // it starts anew
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }
}

// MARK: - Reading another app's interface

extension AXUIElement {
    func raw(_ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attribute as CFString, &out) == .success ? out : nil
    }

    func text(_ attribute: String) -> String? { raw(attribute) as? String }

    func child(_ attribute: String) -> AXUIElement? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func children(_ attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        (raw(attribute) as? [AXUIElement]) ?? []
    }

    func range(_ attribute: String) -> CFRange? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    /// An attribute that takes a parameter, such as the text in a range.
    func answer(_ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(self, attribute as CFString, parameter, &out) == .success ? out : nil
    }

    func canSet(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, attribute as CFString, value) == .success
    }

    @discardableResult
    func select(_ range: CFRange) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return set(kAXSelectedTextRangeAttribute, value)
    }

    func string(in range: CFRange) -> String? {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        return answer(kAXStringForRangeParameterizedAttribute, value) as? String
    }

    /// Where a range of a text is on the screen, as AppKit counts; nil if the app does not say.
    func frame(of range: CFRange) -> NSRect? {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range),
              let answer = answer(kAXBoundsForRangeParameterizedAttribute, value),
              CFGetTypeID(answer) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(answer as! AXValue, .cgRect, &rect) else { return nil }
        return onScreen(rect)
    }

    var frame: NSRect? {
        guard let position = raw(kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = raw(kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &rect.origin),
              AXValueGetValue(size as! AXValue, .cgSize, &rect.size) else { return nil }
        return onScreen(rect)
    }
}

/// Accessibility counts from the top left corner of the first screen downward, AppKit from
/// its bottom left corner upward. nil for a place no screen has (apps answer with those when
/// they do not know).
private func onScreen(_ rect: CGRect) -> NSRect? {
    guard rect.height > 0, rect.height < 5000, rect.origin.x.isFinite, rect.origin.y.isFinite,
          let first = NSScreen.screens.first else { return nil }
    let turned = NSRect(x: rect.minX, y: first.frame.height - rect.maxY, width: rect.width, height: rect.height)
    let probe = turned.insetBy(dx: -1, dy: -1)
    return NSScreen.screens.contains { $0.frame.intersects(probe) } ? turned : nil
}

// MARK: - What is under the keyboard

@MainActor
struct Focus {
    var app: NSRunningApplication?
    var role = ""
    var selection: String?  // the selected text ("": none); nil: the app does not say
    var place: NSRect?      // where the selection, or the cursor, is on the screen
    var field: AXField?
    var waking = false      // the app kept its interface to itself and has just been asked for it: it answers in a moment

    /// Apps where the place to type is not a text field to macOS, and yet text can be pasted.
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty", "org.alacritty", "com.github.wez.wezterm",
    ]

    static func read() -> Focus {
        var focus = Focus()
        focus.app = NSWorkspace.shared.frontmostApplication
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)  // an app that is busy must not hold the shortcut up
        var element = system.child(kAXFocusedUIElementAttribute)
        var appElement: AXUIElement?
        if let app = focus.app {
            let made = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(made, 0.5)
            appElement = made
            if element == nil { element = made.child(kAXFocusedUIElementAttribute) }
        }
        guard let element else {
            focus.waking = appElement?.set("AXManualAccessibility", kCFBooleanTrue) ?? false
            return focus
        }
        AXUIElementSetMessagingTimeout(element, 0.5)
        focus.role = element.text(kAXRoleAttribute) ?? ""
        if let text = element.text(kAXSelectedTextAttribute) {
            focus.selection = text
        } else if let markers = element.raw("AXSelectedTextMarkerRange"),  // web pages
                  let text = element.answer("AXStringForTextMarkerRange", markers) as? String {
            focus.selection = text
        }
        let range = element.range(kAXSelectedTextRangeAttribute)
        if let range { focus.place = element.frame(of: range) }

        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        let secure = element.text(kAXSubroleAttribute) == kAXSecureTextFieldSubrole
        let writable = element.canSet(kAXValueAttribute) || element.canSet(kAXSelectedTextAttribute)
        let terminal = Focus.terminals.contains(focus.app?.bundleIdentifier ?? "")
        if !secure, (textRoles.contains(focus.role) && (writable || terminal)) || (range != nil && writable) {
            focus.field = AXField(element: element, app: focus.app, writable: writable)
        } else if focus.selection == nil {
            // Apps built with Electron keep all this to themselves until they are asked; the
            // answer is there a moment later (the caller reads again).
            focus.waking = appElement?.set("AXManualAccessibility", kCFBooleanTrue) ?? false
        }
        return focus
    }

    /// The selected text by the app's own Copy command, for apps that do not say what is selected.
    /// The command is chosen in the app's menu, so no key is pressed for it; a greyed Copy means
    /// nothing is selected, and nothing is done. The clipboard is put back as it was.
    static func copiedSelection(of app: NSRunningApplication) async -> String? {
        guard let copy = menuCommand(of: app, key: "C") else { return nil }
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let kept = Clipboard.contents()
        AXUIElementPerformAction(copy, kAXPressAction as CFString)
        var waited = 0
        while pasteboard.changeCount == before, waited < 20 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        Clipboard.put(back: kept)
        return text
    }

    /// A command of the app's menus by its key (with ⌘ alone), if it can be chosen now.
    static func menuCommand(of app: NSRunningApplication, key: String) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        guard let bar = appElement.child(kAXMenuBarAttribute) else { return nil }
        for title in bar.children().dropFirst() {  // not the Apple menu
            for menu in title.children() {
                for item in menu.children() where item.text(kAXMenuItemCmdCharAttribute) == key {
                    guard ((item.raw(kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0) == 0 else { continue }  // 0: ⌘ alone
                    return (item.raw(kAXEnabledAttribute) as? Bool) == true ? item : nil
                }
            }
        }
        return nil
    }
}

// MARK: - The clipboard, kept and put back

@MainActor
enum Clipboard {
    typealias Contents = [[NSPasteboard.PasteboardType: Data]]

    static func contents() -> Contents {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var kinds: [NSPasteboard.PasteboardType: Data] = [:]
            for kind in item.types { kinds[kind] = item.data(forType: kind) }
            return kinds
        }
    }

    static func put(back contents: Contents) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = contents.map { kinds -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (kind, data) in kinds { item.setData(data, forType: kind) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

// MARK: - The keyboard layout

enum Keyboard {
    /// The language of the keyboard layout that is on, when the layout is one language's own
    /// (Russian, Ukrainian, Greek…): what is typed with it is in that language. nil for a
    /// layout of Latin letters: many languages are typed with those.
    static var language: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]
        return languages?.first.flatMap(languageOfLayout)
    }

    /// "ru" → "ru"; "en", "de", "sr-Latn" → nil.
    static func languageOfLayout(_ identifier: String) -> String? {
        let language = Locale.Language(identifier: identifier)
        guard !language.maximalIdentifier.contains("Latn"), let code = language.languageCode?.identifier else { return nil }
        return code
    }
}

// MARK: - A text field of another app, written into

/// Where the typing panel puts its text: a text field of another app in the app, a stand-in in tests.
@MainActor
protocol TextSink: AnyObject {
    /// Where the cursor is on the screen, if that can be told.
    var place: NSRect? { get }
    /// What has been written into it so far.
    var written: String { get }
    /// Puts `text` in the place of what was written before. false: this field can't be
    /// written into while you type; `paste` is the way then.
    func write(_ text: String) async -> Bool
    /// Pastes `text` at the cursor, once: for fields that can't be written into otherwise.
    func paste(_ text: String) async
}

@MainActor
final class AXField: TextSink {
    let element: AXUIElement
    let app: NSRunningApplication?
    private let writable: Bool

    /// How this field takes text. Found out with the first writing.
    private enum Way {
        case selection  // what was written before is selected and replaced: a Mac's own text fields
        case whole      // the field's whole text is set anew: the way text fields of web pages take it
    }
    private var way: Way?
    private var start: Int?      // where the written text begins, in UTF-16 units
    private(set) var written = ""
    private var length: Int?     // the field's whole length after the last writing, if it says
    // The field's text around the cursor as it was found (for the `whole` way); nil: the field does not say.
    private var around: (before: String, after: String)?
    /// A writing that was not seen to arrive in time. A slow app may have taken it all the same.
    private var unseen: (text: String, whole: String)?

    init(element: AXUIElement, app: NSRunningApplication?, writable: Bool = true) {
        self.element = element
        self.app = app
        self.writable = writable
    }

    var place: NSRect? {
        guard let range = element.range(kAXSelectedTextRangeAttribute) else { return fieldPlace }
        let end = range.location + range.length
        // The cursor itself; apps that give no place for it give one for the letter before or after it.
        if let rect = element.frame(of: CFRange(location: end, length: 0)), rect.height < 200 { return rect }
        if end > 0, let rect = element.frame(of: CFRange(location: end - 1, length: 1)), rect.height < 200 {
            return NSRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
        }
        if let rect = element.frame(of: CFRange(location: end, length: 1)), rect.height < 200 {
            return NSRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
        }
        return fieldPlace
    }

    /// A field of one line stands for its cursor; a large one does not say where in it the cursor is.
    private var fieldPlace: NSRect? {
        guard let frame = element.frame, frame.height < 60 else { return nil }
        return NSRect(x: frame.minX, y: frame.minY, width: 0, height: frame.height)
    }

    /// A text field of a web page (in a browser, or in an app made of web pages): those
    /// answer to questions about "text markers", which a Mac's own fields do not know.
    private lazy var isWeb: Bool = {
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(element, &names)
        return ((names as? [String]) ?? []).contains("AXStringForTextMarkerRange")
    }()

    /// Texts alike but for their blanks: a web page turns spaces into no-break spaces and drops some at an end.
    nonisolated static func alike(_ a: String?, _ b: String) -> Bool {
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{a0}", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard let a else { return false }
        return plain(a) == plain(b)
    }

    func write(_ text: String) async -> Bool {
        if text == written { return true }
        guard writable else { return false }
        if let way {
            switch way {
            case .selection: return await writeOverSelection(text)
            case .whole: return await writeWhole(text)
            }
        }
        if arrivedLate() { return await writeWhole(text) }
        guard unseen == nil, let caret = element.range(kAXSelectedTextRangeAttribute) else { return false }
        if start == nil {
            start = caret.location
            if let whole = element.text(kAXValueAttribute) as NSString?, caret.location + caret.length <= whole.length {
                around = (whole.substring(to: caret.location), whole.substring(from: caret.location + caret.length))
            }
        }
        // A Mac's own field takes a replaced selection. A web page's field says yes to that and
        // does nothing (or worse): there the whole text is set, where that can do no harm.
        let kind = "\(element.text(kAXRoleAttribute) ?? "?")\(isWeb ? ", a web page's" : "")"
        if !isWeb, await writeOverSelection(text) {
            way = .selection
            Log.note("typing: written over the selection (\(kind))")
            return true
        }
        if written.isEmpty, mayWriteWhole, await writeWhole(text) {
            way = .whole
            Log.note("typing: written as the field's whole text (\(kind))")
            return true
        }
        Log.note("typing: not written while typed (\(kind), \(mayWriteWhole ? "it did not take it" : "it has a text in it already, or does not let its text be set"))")
        return false
    }

    /// Setting a field's whole text makes plain text of it. That loses nothing in a field of
    /// plain text; in an editor of a web page it would flatten what is written there already,
    /// so there it is done only when nothing is.
    private var mayWriteWhole: Bool {
        guard let around, element.canSet(kAXValueAttribute) else { return false }
        if !isWeb { return true }
        let role = element.text(kAXRoleAttribute) ?? ""
        if role == kAXTextFieldRole || role == kAXComboBoxRole { return true }  // one line: plain by nature
        return (around.before + around.after).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func writeOverSelection(_ text: String) async -> Bool {
        guard let start else { return false }
        var old = (written as NSString).length
        // Has the app changed the field since (a correction of its own)? Then its length says by how much.
        if let length, let now = (element.raw(kAXNumberOfCharactersAttribute) as? Int), now != length, old + now - length >= 0 {
            old += now - length
        }
        // Only what differs is replaced, so the sentences before stay as they are. That needs
        // the field to hold what was written, letter for letter.
        var keep = 0
        if old == (written as NSString).length, element.string(in: CFRange(location: start, length: old)) == written {
            keep = AXField.sharedStart(written, text)
        }
        let rest = (text as NSString).substring(from: keep)
        guard element.select(CFRange(location: start + keep, length: old - keep)),
              element.set(kAXSelectedTextAttribute, rest as CFString) else { return false }
        // Has it arrived? The cursor is then right behind it, and the field holds it.
        let end = start + (text as NSString).length
        for attempt in 0..<8 {
            let there = element.string(in: CFRange(location: start, length: end - start))
            if element.range(kAXSelectedTextRangeAttribute)?.location == end, there == nil || there == text {
                written = text
                length = element.raw(kAXNumberOfCharactersAttribute) as? Int
                return true
            }
            if attempt < 7 { try? await Task.sleep(nanoseconds: 30_000_000) }
        }
        return false
    }

    private func writeWhole(_ text: String) async -> Bool {
        guard let start, let around else { return false }
        let whole = around.before + text + around.after
        guard element.set(kAXValueAttribute, whole as CFString) else { return false }
        for attempt in 0..<14 {  // a web page takes it a moment later
            if AXField.alike(element.text(kAXValueAttribute), whole) {
                written = text
                unseen = nil
                element.select(CFRange(location: start + (text as NSString).length, length: 0))  // the cursor behind what was written
                return true
            }
            if attempt < 13 { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        unseen = (text, whole)
        return false
    }

    private func arrivedLate() -> Bool {
        guard let unseen, AXField.alike(element.text(kAXValueAttribute), unseen.whole) else { return false }
        written = unseen.text
        way = .whole
        self.unseen = nil
        return true
    }

    /// How many UTF-16 units two texts begin alike with, never cutting a letter in two.
    nonisolated static func sharedStart(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a, b) {
            guard x == y, x.unicodeScalars.elementsEqual(y.unicodeScalars) else { break }
            count += x.utf16.count
        }
        return count
    }

    func paste(_ text: String) async {
        guard !text.isEmpty else { return }
        // A slow app may have taken a writing after all: then pasting would put the text there twice.
        if arrivedLate(), await writeWhole(text) { return }
        let kept = Clipboard.contents()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Clipboard managers leave alone what is marked so (nspasteboard.org).
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        try? await Task.sleep(nanoseconds: 150_000_000)  // the app has the keyboard again by then
        if let app, let command = Focus.menuCommand(of: app, key: "V") {
            AXUIElementPerformAction(command, kAXPressAction as CFString)
        } else {
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let key = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
                key?.flags = .maskCommand
                key?.post(tap: .cghidEventTap)
            }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        Clipboard.put(back: kept)
    }
}
