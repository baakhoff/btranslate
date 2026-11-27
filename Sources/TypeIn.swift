import Cocoa

// Typing in another language. The shortcut, pressed in a text field with nothing selected,
// opens a small panel under the cursor. What is typed there is translated sentence by sentence,
// a moment after the last key (a finished sentence is translated once and stays as it is), and
// written into the text field through macOS's Accessibility (Sources/Focus.swift). Return keeps
// it, Esc takes it back out. For an app that does not take text that way, the panel shows the
// translation itself and Return pastes it.

enum LiveText {
    struct Piece: Equatable {
        let lead: String   // the blanks before the sentence
        let core: String   // the sentence
        let trail: String  // the blanks after it
    }

    /// A text sentence by sentence; the pieces put together are the text again.
    static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        let whole = text as NSString
        var covered = 0
        whole.enumerateSubstrings(in: NSRange(location: 0, length: whole.length),
                                  options: [.bySentences, .substringNotRequired]) { _, _, range, _ in
            guard range.location == covered else { return }
            covered = range.location + range.length
            let raw = whole.substring(with: range)
            let core = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty, let found = raw.range(of: core) else {
                pieces.append(Piece(lead: raw, core: "", trail: ""))
                return
            }
            pieces.append(Piece(lead: String(raw[..<found.lowerBound]), core: core, trail: String(raw[found.upperBound...])))
        }
        if covered != whole.length || pieces.isEmpty {  // not cut cleanly: one piece
            let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty, let found = text.range(of: core) else { return text.isEmpty ? [] : [Piece(lead: text, core: "", trail: "")] }
            return [Piece(lead: String(text[..<found.lowerBound]), core: core, trail: String(text[found.upperBound...]))]
        }
        return pieces
    }
}

@MainActor
final class TypePanel: NSObject, NSTextViewDelegate, NSWindowDelegate {
    static var current: TypePanel?
    static let width: CGFloat = 400
    private static let pad: CGFloat = 12

    /// How the translation gets into the field.
    enum Way {
        case live    // written there while it is typed
        case atEnd   // the field can't be written into: Return pastes it
        case stuck   // the field took a part and then no more: Return copies the translation
    }

    let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: TypePanel.width, height: 90),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let input = NSTextView()
    private let sink: TextSink
    private let config = Config.load()
    private let engine: Engine
    private(set) var target: Target
    private let arrow = NSTextField(labelWithString: "→")
    private let menu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let methodLabel = NSTextField(labelWithString: "")
    private let windowButton = NSButton()
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString: L("Type in any language…"))
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(labelWithString: "")

    private(set) var way = Way.live
    private(set) var translation = ""  // of all that is typed, as far as it is made
    private(set) var message: String?  // why there is no translation
    private var cache: [String: String] = [:]  // sentences translated already
    private var task: Task<Void, Never>?
    private var number = 0         // of the latest change: an older translation coming in late is dropped
    private var finishing = false
    private var writing = false    // a text is on its way into the field
    private var closed = false
    private var menuOpen = false
    private var clickMonitor: Any?
    // Where the panel hangs: under the cursor's line (`below`), or above it near the screen's bottom.
    private var left: CGFloat = 0
    private var edge: CGFloat = 0
    private var below = true
    var onChange: (() -> Void)?    // after each translation or message (tests)
    var onClose: (() -> Void)?
    /// Puts a text on the clipboard (a check has its own, and leaves the clipboard alone).
    var copy: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    var shownNote: String { preview.isHidden ? "" : preview.stringValue }  // (tests)
    var shownHint: String { hint.stringValue }
    /// The wait after the last key before a translation is asked for.
    var pause: Double

    init(sink: TextSink) {
        self.sink = sink
        engine = config.startEngine
        target = config.typingTarget  // set on the Languages page of the settings; the menu here is for this time only
        pause = engine == .ai ? 0.8 : 0.35
        super.init()
        build()
    }

    private func build() {
        let background = panel.makeFloating()
        panel.delegate = self
        panel.onClose = { [weak self] in self?.cancel() }

        arrow.font = .systemFont(ofSize: 12, weight: .medium)
        arrow.textColor = .secondaryLabelColor
        menu.controlSize = .small
        menu.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        menu.isBordered = false
        for language in config.targets { menu.addItem(withTitle: language.name) }
        menu.selectItem(at: config.targets.firstIndex(of: target) ?? 0)
        menu.target = self
        menu.action = #selector(targetChanged)
        menu.toolTip = L("The language your text is written in there. The one the panel opens with is set in BTranslate's settings, on the Languages page.")
        methodLabel.stringValue = engine == .google ? "Google" : engine == .ai ? L("AI") : L("Offline")
        methodLabel.font = .systemFont(ofSize: 10)
        methodLabel.textColor = .secondaryLabelColor
        methodLabel.toolTip = L("The method that translates what you type. It is the one BTranslate opens with.")
        windowButton.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: L("Translate a window instead"))
        windowButton.imageScaling = .scaleProportionallyDown
        windowButton.isBordered = false
        windowButton.contentTintColor = .secondaryLabelColor
        windowButton.toolTip = L("Translate a window instead")
        windowButton.target = self
        windowButton.action = #selector(pictureInstead)
        windowButton.refusesFirstResponder = true

        input.font = .systemFont(ofSize: 13)
        input.textColor = .labelColor
        input.drawsBackground = false
        input.isRichText = false
        input.allowsUndo = true
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.textContainerInset = NSSize(width: 0, height: 2)
        input.textContainer?.lineFragmentPadding = 0
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.delegate = self
        scroll.documentView = input
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .placeholderTextColor
        preview.font = .systemFont(ofSize: 12)
        preview.isSelectable = true
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        for view in [arrow, menu, methodLabel, windowButton, scroll, placeholder, preview, hint] as [NSView] {
            background.addSubview(view)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidOpen), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidClose), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    // MARK: Showing and closing

    func show() {
        prepare()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(input)
        // A click anywhere else: the text stays as it is written there.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(byReturn: false) }
        }
    }

    /// Everything `show` does short of putting the panel on screen (tests stop here).
    func prepare() {
        let anchor = sink.place ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        hang(by: anchor, first: true)
        layout()
    }

    private func hang(by anchor: NSRect, first: Bool) {
        let probe = anchor.insetBy(dx: -1, dy: -1)
        let visible = (NSScreen.screens.first { $0.frame.intersects(probe) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if first {
            left = min(max(anchor.minX - TypePanel.pad, visible.minX + 6), visible.maxX - TypePanel.width - 6)
            below = anchor.minY - visible.minY > 200 || anchor.minY - visible.minY > visible.maxY - anchor.maxY
        }
        edge = below ? anchor.minY - 8 : anchor.maxY + 8
    }

    private func close() {
        guard !closed else { return }
        closed = true
        task?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel.orderOut(nil)
        if TypePanel.current === self { TypePanel.current = nil }
        onClose?()
    }

    /// Return, or a click elsewhere: what is typed is translated to its end, and stays there.
    /// Only Return pastes or copies it where it could not be written: after a click, the
    /// keyboard may be somewhere else by now, and the clipboard is not the panel's to change unasked.
    func finish(byReturn: Bool = true) {
        guard !closed, !finishing else { return }
        finishing = true
        task?.cancel()
        number += 1
        let mine = number, text = input.string, before = way
        Task { @MainActor in
            guard await self.translateNow(text, number: mine) else {
                self.finishing = false  // the reason is showing: the panel stays for another try, or Esc
                return
            }
            let made = self.translation, way = self.way
            if way == .stuck, before != .stuck {
                self.finishing = false  // the field stopped taking the text just now: the panel says so, and stays
                return
            }
            self.close()
            if byReturn {
                switch way {
                case .live: break
                case .atEnd: await self.sink.paste(made)
                case .stuck: self.copy(made)
                }
            }
            Log.note("typing: done, \(made.count) characters, \(way)\(byReturn || way == .live ? "" : ", put away")")
        }
    }

    /// Esc: what was written there is taken out again, also what is on its way there now.
    func cancel() {
        guard !closed else { return }
        close()
        Task { @MainActor in
            while self.writing { await waitOut(0.01) }
            _ = await self.sink.write("")
        }
        Log.note("typing: cancelled")
    }

    /// The shortcut again: as Return; a panel that only says why it can't translate goes away as it is.
    func putAway() {
        guard !closed else { return }
        if message == nil { finish() } else { close() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if menuOpen || closed { return }
        if let delegate = NSApp.delegate as? AppDelegate, Date() < delegate.handBackUntil { return }
        finish(byReturn: false)
    }

    @objc private func menuDidOpen() { menuOpen = true }

    @objc private func menuDidClose() {
        menuOpen = false
        if !closed && panel.isVisible && !panel.isKeyWindow { panel.makeKey() }
    }

    @objc private func pictureInstead() {
        cancel()
        WindowPicture.start()
    }

    // MARK: Typing and translating

    /// Types for the user (tests).
    func type(_ text: String) {
        input.string = text
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !input.string.isEmpty
        layout()
        guard !input.hasMarkedText() else { return }  // a letter still being put together
        schedule(after: pause)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {  // ⇧↩: a new line
            textView.insertNewlineIgnoringFieldEditor(nil)
        } else {
            finish()
        }
        return true
    }

    @objc private func targetChanged() {
        guard config.targets.indices.contains(menu.indexOfSelectedItem) else { return }
        target = config.targets[menu.indexOfSelectedItem]
        layout()
        schedule(after: 0)
    }

    /// Chooses the language as the menu does (tests).
    func choose(_ language: Target) {
        guard let index = config.targets.firstIndex(of: language) else { return }
        menu.selectItem(at: index)
        targetChanged()
    }

    private func schedule(after wait: Double) {
        task?.cancel()
        number += 1
        let mine = number, text = input.string
        task = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self, !Task.isCancelled, mine == self.number else { return }
            _ = await self.translateNow(text, number: mine)
        }
    }

    /// Translates `text` and puts it there. false: it could not be (a message is showing),
    /// or something newer has been typed since.
    private func translateNow(_ text: String, number mine: Int) async -> Bool {
        var out = ""
        for piece in LiveText.pieces(of: text) {
            var made: String? = piece.core.isEmpty ? "" : cache[key(piece.core)]
            if made == nil {
                do {
                    made = try await translated(piece.core)
                } catch {
                    guard mine == number, !closed, !Task.isCancelled else { return false }
                    message = describe(error)
                    layout()
                    onChange?()
                    return false
                }
                guard mine == number, !closed else { return false }
                cache[key(piece.core)] = made
            }
            out += piece.lead + (made ?? "") + piece.trail
        }
        guard mine == number, !closed else { return false }
        message = nil
        translation = out
        if way == .live {
            // One writing at a time: a second one waits for the first to be in the field.
            while writing { await waitOut(0.01) }
            guard mine == number, !closed else { return false }
            writing = true
            let taken = await sink.write(out)
            writing = false
            guard !closed else { return false }
            if taken {
                if let place = sink.place { hang(by: place, first: false) }
            } else {
                // Nothing of it got in: the field can't be written into. A part did before: it stopped taking it.
                way = sink.written.isEmpty ? .atEnd : .stuck
                Log.note("typing: the field does not take the text (\(way))")
            }
            guard mine == number else { return false }  // typed on meanwhile
        }
        layout()
        onChange?()
        return true
    }

    private func key(_ sentence: String) -> String { "\(target.id)|\(sentence)" }

    private func translated(_ sentence: String) async throws -> String {
        // A keyboard layout that is one language's own says what the text is in; with Latin
        // letters the translator finds out itself.
        let typed = Keyboard.language.flatMap { code in allTargets.first { $0.google == code && !$0.latin } }
        if let typed, OnDevice.same(typed.google, target.google) { return sentence }  // typed in that language already
        var result = ""
        try await translate(sentence, engine: engine, target: target, source: typed, config: config) { _, text in result = text }
        return result
    }

    // MARK: Layout

    private func height(of text: NSTextView, width: CGFloat) -> CGFloat {
        guard let container = text.textContainer, let manager = text.layoutManager else { return 20 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height) + 2 * text.textContainerInset.height
    }

    private func layout() {
        let W = TypePanel.width, pad = TypePanel.pad, row: CGFloat = 20
        let textWidth = W - 2 * pad
        let typedHeight = min(max(height(of: input, width: textWidth), 21), 110)

        // Under what is typed: why there is no translation; or, where the field can't be
        // written into, the translation itself.
        let note = message ?? (way == .live ? "" : translation)
        preview.stringValue = note
        preview.textColor = message != nil ? .systemRed : .secondaryLabelColor
        preview.isHidden = note.isEmpty
        let noteHeight = note.isEmpty ? 0 : min(ceil(preview.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 2000)).height ?? 16), 120)
        switch way {
        case .live: hint.stringValue = L("↩ done   ⎋ take it back")
        case .atEnd: hint.stringValue = L("This app can't be written into while you type: ↩ puts the translation in.")
        case .stuck: hint.stringValue = L("The app stopped taking the text: ↩ copies the translation.")
        }

        let H = pad + row + 6 + typedHeight + (noteHeight > 0 ? 6 + noteHeight : 0) + 8 + 13 + pad - 2
        var frame = NSRect(x: left, y: below ? edge - H : edge, width: W, height: H)
        if let visible = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?.visibleFrame {
            if frame.minY < visible.minY + 6 { frame.origin.y = visible.minY + 6 }
            if frame.maxY > visible.maxY - 6 { frame.origin.y = max(visible.minY + 6, visible.maxY - 6 - H) }
        }
        panel.setFrame(frame, display: true)

        var y = H - pad - row
        arrow.sizeToFit()
        arrow.frame.origin = NSPoint(x: pad, y: y + (row - arrow.frame.height) / 2)
        menu.sizeToFit()
        menu.frame = NSRect(x: arrow.frame.maxX + 2, y: y + (row - menu.frame.height) / 2,
                            width: min(menu.frame.width, 220), height: menu.frame.height)
        windowButton.frame = NSRect(x: W - pad - 18, y: y + 1, width: 20, height: 18)
        methodLabel.sizeToFit()
        methodLabel.frame.origin = NSPoint(x: windowButton.frame.minX - 8 - methodLabel.frame.width, y: y + (row - methodLabel.frame.height) / 2)
        y -= 6 + typedHeight
        scroll.frame = NSRect(x: pad, y: y, width: textWidth, height: typedHeight)
        input.frame.size.width = textWidth
        placeholder.sizeToFit()
        placeholder.frame.origin = NSPoint(x: pad, y: y + typedHeight - placeholder.frame.height - 2)
        if noteHeight > 0 {
            y -= 6 + noteHeight
            preview.frame = NSRect(x: pad, y: y, width: textWidth, height: noteHeight)
        }
        hint.frame = NSRect(x: pad, y: pad - 2, width: textWidth, height: 13)
        panel.invalidateShadow()
    }
}

@MainActor
func showTypePanel(for sink: TextSink) {
    if let delegate = NSApp.delegate as? AppDelegate {
        delegate.handBackUntil = max(delegate.handBackUntil, Date().addingTimeInterval(1.5))
    }
    let panel = TypePanel(sink: sink)
    TypePanel.current = panel
    panel.show()
}
