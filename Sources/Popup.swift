import Cocoa

/// A floating panel that never activates the app: the app you are in stays in front.
/// The translation popup is one, and so is the language picker that opens from its pencil.
final class PopupPanel: NSPanel {
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { onClose?(); return }  // Esc
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "w", "q": onClose?(); return true  // ⌘Q here must not quit the background app
            case "c": if let onCopy { onCopy(); return true }
            case "a": if let text = firstResponder as? NSTextView { text.selectAll(nil); return true }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The look both panels share: floating, see-through, with rounded corners.
    func makeFloating() -> NSVisualEffectView {
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        contentView = background
        return background
    }
}

@MainActor
final class Popup: NSObject, NSWindowDelegate {
    static var current: Popup?

    static let width: CGFloat = 500
    static let pad: CGFloat = 14
    static let barHeight: CGFloat = 24
    static let gap: CGFloat = 8
    static let minTextHeight: CGFloat = 20
    static let maxTextHeight: CGFloat = 420

    let source: String
    let config = Config.load()
    var engine: Engine
    var target: Target

    let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: Popup.width, height: 100),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    // The bar, left to right: the original's language, its speaker and pencil, an arrow, the
    // language to translate into; then at the right the method, the translation's speaker,
    // copy and settings.
    private let sourceLabel = NSTextField(labelWithString: "")
    private let speakSourceButton = NSButton()
    private let sourceButton = NSButton()  // the pencil
    private let arrow = NSTextField(labelWithString: "→")
    private let targetButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let engineControl = NSSegmentedControl(labels: ["Google", "AI"], trackingMode: .selectOne, target: nil, action: nil)
    private let speakButton = NSButton()
    private let copyButton = NSButton()
    private let settingsButton = NSButton()
    private let scroll = NSScrollView()
    private let textView = NSTextView()

    private let anchor = NSEvent.mouseLocation
    private var placed = false    // false until the first layout puts the panel by the pointer
    private var growsUp = false   // near the screen's bottom the panel sits above the pointer and grows upward
    private var translation = ""
    private var translating = false
    private var detectedSource: String?  // the code of the language the translation found the original to be in
    private var chosenSource: Target?    // the original's language set with the pencil; nil: detect it
    private var sourcePicker: LanguagePicker?
    private var sourcePanel: PopupPanel?
    var onSettled: (() -> Void)?  // called when a translation or an error message is showing (UI test)
    private var task: Task<Void, Never>?
    private var clickMonitor: Any?
    private var menuOpen = false  // the language menu is showing
    private var closed = false

    init(text: String) {
        source = text
        engine = config.startEngine
        target = config.startTarget
        super.init()
        build()
    }

    private func build() {
        let background = panel.makeFloating()
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.onClose = { [weak self] in self?.close() }
        panel.onCopy = { [weak self] in self?.copySelectionOrAll() }

        for label in [sourceLabel, arrow] {
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
        }
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.toolTip = String(source.prefix(600))

        targetButton.controlSize = .small
        targetButton.font = .systemFont(ofSize: 12)
        targetButton.addItems(withTitles: config.targets.map(\.name))  // the list from Settings
        targetButton.selectItem(withTitle: target.name)
        targetButton.target = self
        targetButton.action = #selector(targetChanged)
        if let menu = targetButton.menu {
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(menuDidOpen), name: NSMenu.didBeginTrackingNotification, object: menu)
            center.addObserver(self, selector: #selector(menuDidClose), name: NSMenu.didEndTrackingNotification, object: menu)
        }

        engineControl.controlSize = .small
        engineControl.font = .systemFont(ofSize: 11)
        engineControl.selectedSegment = engine == .google ? 0 : 1
        engineControl.setToolTip("Google Translate", forSegment: 0)
        engineControl.setToolTip("\(config.provider.name): \(config.model)", forSegment: 1)
        engineControl.isHidden = config.engines.count < 2
        engineControl.target = self
        engineControl.action = #selector(engineChanged)

        configure(speakSourceButton, symbol: "speaker.wave.2", size: 12, tip: "", action: #selector(speakSource))
        configure(sourceButton, symbol: "pencil", size: 12, tip: "", action: #selector(toggleSourcePicker))
        configure(speakButton, symbol: "speaker.wave.2", size: 13, tip: "", action: #selector(speakTranslation))
        configure(copyButton, symbol: "doc.on.doc", size: 13, tip: "Copy the translation (⌘C)", action: #selector(copyAll))
        configure(settingsButton, symbol: "gearshape", size: 13, tip: "BTranslate settings", action: #selector(openSettings))

        let textWidth = Popup.width - Popup.pad * 2
        scroll.frame = NSRect(x: 0, y: 0, width: textWidth, height: 100)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        textView.frame = NSRect(x: 0, y: 0, width: textWidth, height: 100)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        // Keys go to the text only (Esc, ⌘C, ⌘A): no Tab onto a control, where typing could change it.
        let controls: [NSControl] = [speakSourceButton, sourceButton, targetButton, engineControl, speakButton, copyButton, settingsButton]
        for control in controls { control.refusesFirstResponder = true }
        for view in [sourceLabel, arrow, scroll] as [NSView] + controls { background.addSubview(view) }
    }

    private func configure(_ button: NSButton, symbol: String, size: CGFloat, tip: String, action: Selector) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    func show() {
        prepare()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(textView)
        // A click anywhere outside the panel closes it. Clicks in other apps arrive here;
        // a click in another window of this app makes the panel lose key (windowDidResignKey).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        start()
    }

    /// Everything `show` does short of putting the panel on screen (the UI test stops here).
    func prepare() {
        Speaker.shared.onChange = { [weak self] in self?.refreshSpeech() }
        Speaker.shared.onError = { [weak self] name, message in self?.speechFailed(name, message) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel()
        task = nil
        Speaker.shared.stop()
        Speaker.shared.onChange = nil
        Speaker.shared.onError = nil
        closeSourcePicker()
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        panel.orderOut(nil)
        if Popup.current === self { Popup.current = nil }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window !== panel {  // the pencil's picker
            if window === sourcePanel { closeSourcePicker() }  // a click outside it; else it is closing itself
            return
        }
        // Not a click outside: the language menu, the picker taking the keyboard, and the
        // moment right after the app starts, when it hands the front back to your app.
        if menuOpen || sourcePanel != nil { return }
        if let delegate = NSApp.delegate as? AppDelegate, Date() < delegate.handBackUntil { return }
        close()
    }

    @objc private func menuDidOpen() { menuOpen = true }

    @objc private func menuDidClose() {
        menuOpen = false
        if !closed && !panel.isKeyWindow { panel.makeKey() }
    }

    // MARK: Translating

    func start() {
        task?.cancel()
        Speaker.shared.stop()
        translation = ""
        translating = true
        detectedSource = nil
        let engine = engine, target = target, config = config, chosenSource = chosenSource
        setText("Translating…", color: .secondaryLabelColor)
        refreshBar()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await translate(self.source, engine: engine, target: target, source: chosenSource, config: config) { [weak self] code, text in
                    guard let self, !Task.isCancelled else { return }
                    let firstPiece = self.translation.isEmpty
                    if let code { self.detectedSource = code }
                    self.translation = text
                    self.setText(text, color: .labelColor)
                    if firstPiece { self.refreshBar() } else { self.layout() }
                }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return }
                self.translation = ""
                self.setText(describe(error), color: .systemRed)
            }
            if Task.isCancelled { return }
            self.translating = false
            self.refreshBar()
            self.onSettled?()
        }
    }

    var shownText: String { textView.string }
    var shownSource: String { sourceLabel.stringValue }

    @objc private func targetChanged() {
        if let name = targetButton.titleOfSelectedItem, let t = config.targets.first(where: { $0.name == name }) {
            target = t
            Config.remember(t)
        }
        start()
    }

    @objc private func engineChanged() {
        engine = engineControl.selectedSegment == 0 ? .google : .ai  // for this popup only; Settings has the default
        start()
    }

    @objc private func openSettings() {
        close()
        (NSApp.delegate as? AppDelegate)?.showSettings()
    }

    // MARK: The original's language

    /// The language the original is taken to be in: set by hand, or detected, or not known yet.
    private var sourceCode: String? { chosenSource?.google ?? detectedSource }

    /// Translates again, reading the original as `language`; nil goes back to detecting it.
    func setSource(_ language: Target?, remember: Bool = true) {
        chosenSource = language
        if let language, remember {
            var recent = UserDefaults.standard.stringArray(forKey: "recentSources") ?? []
            recent.removeAll { $0 == language.id }
            recent.insert(language.id, at: 0)
            UserDefaults.standard.set(Array(recent.prefix(5)), forKey: "recentSources")
        }
        start()
    }

    /// A picker of every language, the ones picked lately first, under "Detect automatically".
    func makeSourcePicker() -> LanguagePicker {
        let picker = LanguagePicker()
        picker.available = {
            let recent = (UserDefaults.standard.stringArray(forKey: "recentSources") ?? [])
                .compactMap { id in sourceLanguages.first { $0.id == id } }
            return [detectAutomatically] + recent + sourceLanguages.filter { !recent.contains($0) }
        }
        picker.onAdd = { [weak self] choice in
            self?.closeSourcePicker()
            self?.setSource(choice.id == detectAutomatically.id ? nil : choice)
        }
        return picker
    }

    // For the on-screen check (BTranslate --screen-check).
    var sourcePickerState: (open: Bool, key: Bool, searchFocused: Bool, found: [String]) {
        (sourcePanel != nil, sourcePanel?.isKeyWindow ?? false, sourcePicker?.searchHasFocus ?? false, sourcePicker?.foundIDs ?? [])
    }

    /// Sends key presses to the picker's panel, as the keyboard does while it is the key window.
    func pressInSourcePicker(_ characters: String, keyCode: UInt16 = 0) {
        guard let window = sourcePanel else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
                window.sendEvent(event)
            }
        }
    }

    @objc func toggleSourcePicker() {
        if sourcePanel != nil { closeSourcePicker(); return }
        let picker = makeSourcePicker()
        let size = picker.view.frame.size
        let pickerPanel = PopupPanel(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let background = pickerPanel.makeFloating()
        picker.view.autoresizingMask = [.width, .height]
        picker.view.frame = NSRect(origin: .zero, size: size)
        background.addSubview(picker.view)
        pickerPanel.onClose = { [weak self] in self?.closeSourcePicker() }  // Esc
        pickerPanel.delegate = self

        // Under the pencil, or above it when the screen ends there.
        let pencil = panel.convertToScreen(sourceButton.convert(sourceButton.bounds, to: nil))
        var origin = NSPoint(x: pencil.minX - 14, y: pencil.minY - 6 - size.height)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if origin.y < visible.minY + 6 { origin.y = min(pencil.maxY + 6, visible.maxY - 6 - size.height) }
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - 6 - size.width)
        }
        pickerPanel.setFrameOrigin(origin)

        sourcePicker = picker
        sourcePanel = pickerPanel
        panel.addChildWindow(pickerPanel, ordered: .above)  // it moves with the popup
        pickerPanel.makeKey()                               // typing goes to its search field
        picker.setSearch("")
        picker.focusSearch()
    }

    private func closeSourcePicker() {
        guard let pickerPanel = sourcePanel else { return }
        sourcePanel = nil
        sourcePicker = nil
        panel.removeChildWindow(pickerPanel)
        pickerPanel.orderOut(nil)
        if !closed {
            panel.makeKey()
            panel.makeFirstResponder(textView)
        }
    }

    // MARK: Reading aloud

    @objc private func speakSource() {
        guard let code = sourceCode else { return }
        Speaker.shared.toggle("original", text: source, code: code, googleVoice: config.googleVoice)
    }

    @objc private func speakTranslation() {
        Speaker.shared.toggle("translation", text: translation, code: target.google, googleVoice: config.googleVoice)
    }

    private func speechFailed(_ name: String, _ message: String) {
        let button = name == "original" ? speakSourceButton : speakButton
        NSSound.beep()
        button.contentTintColor = .systemRed
        button.toolTip = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refreshSpeech() }
    }

    /// The two speaker buttons: a stop sign while their text is read, greyed out when there
    /// is nothing to read or no voice to read it.
    private func refreshSpeech() {
        func set(_ button: NSButton, name: String, code: String?, hasText: Bool, what: String) {
            let plan = code.map { Speaker.shared.plan(for: $0, googleVoice: config.googleVoice) } ?? .none
            let playing = Speaker.shared.playing == name
            button.image = NSImage(systemSymbolName: playing ? "stop.fill" : "speaker.wave.2",
                                   accessibilityDescription: playing ? "Stop" : "Listen to \(what)")
            button.contentTintColor = playing ? .controlAccentColor : .secondaryLabelColor
            button.isEnabled = hasText && plan != .none
            switch (plan, code) {
            case (_, nil): button.toolTip = "Listen to \(what), once its language is known"
            case (.mac, _): button.toolTip = playing ? "Stop" : "Listen to \(what)"
            case (.google, _): button.toolTip = playing ? "Stop" : "Listen to \(what) (Google's voice: this text is sent to Google)"
            case (.none, let code?):
                button.toolTip = "This Mac has no voice for \(languageName(code)). Google's voice can read it: turn it on in Settings."
            }
        }
        set(speakSourceButton, name: "original", code: sourceCode, hasText: true, what: "the original")
        set(speakButton, name: "translation", code: target.google, hasText: !translation.isEmpty, what: "the translation")
    }

    // MARK: Copying

    @objc private func copyAll() {
        copy(translation)
    }

    private func copySelectionOrAll() {
        let range = textView.selectedRange()
        copy(range.length > 0 ? (textView.string as NSString).substring(with: range) : translation)
    }

    private func copy(_ s: String) {
        guard !s.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        }
    }

    // MARK: Drawing

    private func setText(_ s: String, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        textView.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: color, .paragraphStyle: style,
        ]))
    }

    /// The bar's texts and button states, then the layout (the language's name changes its width).
    private func refreshBar() {
        if let chosenSource {
            sourceLabel.stringValue = chosenSource.name
        } else if let detectedSource {
            sourceLabel.stringValue = languageName(detectedSource)
        } else {
            sourceLabel.stringValue = translating ? "Detecting…" : "Unknown language"
        }
        sourceButton.contentTintColor = chosenSource == nil ? .secondaryLabelColor : .controlAccentColor
        sourceButton.toolTip = chosenSource == nil
            ? "Wrong language? Set the language of the original"
            : "The original's language was set by hand. Click to change it or to detect it again"
        refreshSpeech()
        layout()
    }

    private func textHeight() -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return Popup.minTextHeight }
        lm.ensureLayout(for: tc)
        let h = ceil(lm.usedRect(for: tc).height + textView.textContainerInset.height * 2)
        return min(max(h, Popup.minTextHeight), Popup.maxTextHeight)
    }

    /// Sizes the panel to its text. The first time, it goes next to the mouse pointer. After
    /// that it stays wherever it is (you may have dragged it): only its height changes.
    private func layout() {
        let W = Popup.width, pad = Popup.pad, bar = Popup.barHeight
        let textH = textHeight()
        let H = pad + bar + Popup.gap + textH + pad

        var frame: NSRect
        if !placed {
            let visible = (NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = min(max(anchor.x - 16, visible.minX + 6), visible.maxX - W - 6)
            let roomBelow = anchor.y - 14 - visible.minY, roomAbove = visible.maxY - anchor.y - 14
            growsUp = roomBelow < 240 && roomAbove > roomBelow
            frame = NSRect(x: x, y: growsUp ? anchor.y + 14 : anchor.y - 14 - H, width: W, height: H)
            placed = true
        } else {
            let now = panel.frame
            frame = NSRect(x: now.minX, y: growsUp ? now.minY : now.maxY - H, width: W, height: H)
        }
        // Keep the whole panel on its screen when it grows.
        if let visible = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?.visibleFrame {
            if frame.minY < visible.minY + 6 { frame.origin.y = visible.minY + 6 }
            if frame.maxY > visible.maxY - 6 { frame.origin.y = max(visible.minY + 6, visible.maxY - 6 - H) }
        }
        panel.setFrame(frame, display: true)

        let barY = H - pad - bar
        func centred(_ view: NSView) -> CGFloat { barY + (bar - view.frame.height) / 2 }

        // The right end: method, the translation's speaker, copy, settings.
        settingsButton.frame = NSRect(x: W - pad - 20, y: barY + 1, width: 22, height: 22)
        copyButton.frame = NSRect(x: settingsButton.frame.minX - 26, y: barY + 1, width: 22, height: 22)
        speakButton.frame = NSRect(x: copyButton.frame.minX - 26, y: barY + 1, width: 22, height: 22)
        engineControl.sizeToFit()
        engineControl.frame.origin = NSPoint(x: speakButton.frame.minX - 8 - engineControl.frame.width, y: centred(engineControl))
        let rightEdge = (engineControl.isHidden ? speakButton.frame.minX : engineControl.frame.minX) - 10

        // The left end: the original's language (cut short if it has to be), its speaker and
        // pencil, the arrow, the language to translate into.
        sourceLabel.sizeToFit()
        arrow.sizeToFit()
        targetButton.sizeToFit()
        let afterLabel = 4 + 20 + 2 + 18 + 4 + arrow.frame.width + 4
        let targetWidth = min(targetButton.frame.width, rightEdge - pad - afterLabel - 44)
        let labelWidth = min(sourceLabel.frame.width, rightEdge - pad - afterLabel - targetWidth)
        sourceLabel.frame = NSRect(x: pad, y: centred(sourceLabel), width: labelWidth, height: sourceLabel.frame.height)
        var x = sourceLabel.frame.maxX + 4
        speakSourceButton.frame = NSRect(x: x, y: barY + 1, width: 20, height: 22)
        x += 20 + 2
        sourceButton.frame = NSRect(x: x, y: barY + 1, width: 18, height: 22)
        x += 18 + 4
        arrow.frame.origin = NSPoint(x: x, y: centred(arrow))
        x = arrow.frame.maxX + 4
        targetButton.frame = NSRect(x: x, y: centred(targetButton), width: targetWidth, height: targetButton.frame.height)

        scroll.frame = NSRect(x: pad, y: pad, width: W - pad * 2, height: textH)
        panel.invalidateShadow()
    }
}

@MainActor
func showPopup(_ text: String) {
    if let delegate = NSApp.delegate as? AppDelegate {
        delegate.handBackUntil = max(delegate.handBackUntil, Date().addingTimeInterval(1.5))
    }
    Popup.current?.close()
    let popup = Popup(text: text)
    Popup.current = popup
    popup.show()
}
