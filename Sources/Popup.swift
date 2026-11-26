import Cocoa

/// The floating panel. It never activates the app: the app you are in stays in front.
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
            case "c": onCopy?(); return true
            case "a": (firstResponder as? NSTextView)?.selectAll(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class Popup: NSObject, NSWindowDelegate {
    static var current: Popup?

    static let width: CGFloat = 460
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
    private let header = NSTextField(labelWithString: "")
    private let targetButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let engineControl = NSSegmentedControl(labels: ["Google", "AI"], trackingMode: .selectOne, target: nil, action: nil)
    private let copyButton = NSButton()
    private let settingsButton = NSButton()
    private let scroll = NSScrollView()
    private let textView = NSTextView()

    private let anchor = NSEvent.mouseLocation
    private var placed = false    // false until the first layout puts the panel by the pointer
    private var growsUp = false   // near the screen's bottom the panel sits above the pointer and grows upward
    private var translation = ""
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
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onClose = { [weak self] in self?.close() }
        panel.onCopy = { [weak self] in self?.copySelectionOrAll() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.toolTip = String(source.prefix(600))

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

        configure(copyButton, symbol: "doc.on.doc", tip: "Copy the translation (⌘C)", action: #selector(copyAll))
        configure(settingsButton, symbol: "gearshape", tip: "BTranslate settings", action: #selector(openSettings))

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
        for control in [targetButton, engineControl, copyButton, settingsButton] as [NSControl] {
            control.refusesFirstResponder = true
        }
        for view in [header, targetButton, engineControl, copyButton, settingsButton, scroll] as [NSView] {
            background.addSubview(view)
        }
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    func show() {
        header.stringValue = "Translating to"
        setText("Translating…", color: .secondaryLabelColor)
        layout()
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

    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel()
        task = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        panel.orderOut(nil)
        if Popup.current === self { Popup.current = nil }
    }

    func windowDidResignKey(_ notification: Notification) {
        // While the app is handing the front back to your app (right after it starts), the
        // panel loses key for a moment: that is not a click outside. Nor is the language menu.
        if menuOpen { return }
        if let delegate = NSApp.delegate as? AppDelegate, Date() < delegate.handBackUntil { return }
        close()
    }

    @objc private func menuDidOpen() { menuOpen = true }

    @objc private func menuDidClose() {
        menuOpen = false
        if !closed && !panel.isKeyWindow { panel.makeKey() }
    }

    func start() {
        task?.cancel()
        translation = ""
        let engine = engine, target = target, config = config
        header.stringValue = "Translating to"
        setText("Translating…", color: .secondaryLabelColor)
        layout()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await translate(self.source, engine: engine, target: target, config: config) { [weak self] code, text in
                    guard let self, !Task.isCancelled else { return }
                    if let code { self.header.stringValue = "\(languageName(code)) →" }
                    self.translation = text
                    self.setText(text, color: .labelColor)
                    self.layout()
                }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return }
                self.translation = ""
                self.header.stringValue = "Translating to"
                self.setText(describe(error), color: .systemRed)
                self.layout()
            }
            if !Task.isCancelled { self.onSettled?() }
        }
    }

    var shownText: String { textView.string }

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

    private func setText(_ s: String, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        textView.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: color, .paragraphStyle: style,
        ]))
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
        header.sizeToFit()
        header.frame.origin = NSPoint(x: pad, y: barY + (bar - header.frame.height) / 2)
        targetButton.sizeToFit()
        targetButton.frame.origin = NSPoint(x: header.frame.maxX + 4, y: barY + (bar - targetButton.frame.height) / 2)
        settingsButton.frame = NSRect(x: W - pad - 20, y: barY + 1, width: 22, height: 22)
        copyButton.frame = NSRect(x: settingsButton.frame.minX - 26, y: barY + 1, width: 22, height: 22)
        engineControl.sizeToFit()
        engineControl.frame.origin = NSPoint(x: copyButton.frame.minX - 8 - engineControl.frame.width,
                                             y: barY + (bar - engineControl.frame.height) / 2)
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
