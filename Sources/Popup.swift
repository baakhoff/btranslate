import Cocoa

/// A floating panel that never activates the app: the app you are in stays in front.
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

/// A view whose y runs downward, so that the translations stack from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One language the popup translates into: a row with its menu and buttons, and its text.
@MainActor
final class TranslationSection {
    let name = UUID().uuidString  // what the speaker knows it by
    var target: Target
    var translation = ""
    var settled = false           // a translation or an error message is showing
    var waiting = false           // no translation for lack of a connection: one is made when it is back
    var task: Task<Void, Never>?
    var opensWithDefault = false  // it shows the default language because the popup opened with it, not picked here
    var turnedFrom: Target?       // the default language it left for the second default: the text was in it already
    var packOffer: String?        // a message the language pack would put right: a button under it downloads the pack

    let arrow = NSTextField(labelWithString: "→")
    let menu = NSPopUpButton(frame: .zero, pullsDown: false)
    let speakButton = NSButton()
    let copyButton = NSButton()
    let removeButton = NSButton()
    let textView = NSTextView()
    let packButton = NSButton(title: "", target: nil, action: nil)
    var views: [NSView] { [arrow, menu, speakButton, copyButton, removeButton, textView, packButton] }

    init(target: Target) {
        self.target = target
    }
}

@MainActor
final class Popup: NSObject, NSWindowDelegate {
    static var current: Popup?

    static let width: CGFloat = 460
    static let pad: CGFloat = 14
    static let barHeight: CGFloat = 24
    static let rowHeight: CGFloat = 22
    static let gap: CGFloat = 6
    static let minTextHeight: CGFloat = 20
    static let maxTextHeight: CGFloat = 440  // of all translations together; beyond it they scroll

    let source: String
    let config = Config.load()
    var engine: Engine

    let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: Popup.width, height: 100),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    // The top bar: the original's language, its speaker and pencil; at the right the method and settings.
    // Under it a section per language: "→ language", + (first row only), speaker, copy, × (added rows only), then the text.
    private let sourceLabel = NSTextField(labelWithString: "")
    private let speakSourceButton = NSButton()
    private let sourceButton = NSButton()  // the pencil
    private let engineControl = NSSegmentedControl()  // one segment for each method that is turned on
    private let offlineIcon = NSImageView()
    private let settingsButton = NSButton()
    private let addButton = NSButton()
    private let scroll = NSScrollView()
    private let container = FlippedView()
    private(set) var sections: [TranslationSection] = []

    /// What the popup opens by: the pointer, or the selected text where its place is known
    /// (the shortcut knows it at times; the Services menu never does).
    private let anchor: NSRect
    private var placed = false    // false until the first layout puts the panel by the pointer
    private var growsUp = false   // near the screen's bottom the panel sits above the pointer and grows upward
    private var detectedSource: String?  // the code of the language the translation found the original to be in
    private var chosenSource: Target?    // the original's language set with the pencil; nil: detect it
    private var sourcePicker: LanguagePicker?
    private var sourcePanel: PopupPanel?
    var onSettled: (() -> Void)?  // called when every translation (or its error message) is showing (UI test)
    private var clickMonitor: Any?
    private var menuOpen = false
    private var noConnection = false   // a request has failed for lack of a connection
    private var autoOffline: Engine?   // the method the popup had before it went over to Offline by itself
    private var listening = false      // waiting to be told that the connection is back
    private var closed = false
    private var notice: NSPanel?
    private var noticeNumber = 0       // which note is showing: an older one's timer must not take a newer one away
    private(set) var shownNotice: String?
    var noticeView: NSView? { notice?.contentView }  // (UI test)
    var noticeWindow: NSWindow? { notice }           // (UI test)
    /// Where the first translation's speaker button is on the screen (UI test).
    var speakerFrame: NSRect? { sections.first.map { panel.convertToScreen($0.speakButton.convert($0.speakButton.bounds, to: nil)) } }

    init(text: String, by place: NSRect? = nil) {
        source = text
        engine = config.startEngine
        // By the pointer the popup keeps a little distance, for the pointer's own size.
        anchor = place ?? NSRect(origin: NSEvent.mouseLocation, size: .zero).insetBy(dx: 0, dy: -8)
        super.init()
        build()
        addSection(config.startTarget).opensWithDefault = true
    }

    private func build() {
        let background = panel.makeFloating()
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.onClose = { [weak self] in self?.close() }
        panel.onCopy = { [weak self] in self?.copySelectionOrFirst() }

        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.toolTip = String(source.prefix(600))

        engineControl.controlSize = .small
        engineControl.font = .systemFont(ofSize: 11)
        engineControl.trackingMode = .selectOne
        engineControl.segmentCount = config.engines.count
        for (i, method) in config.engines.enumerated() {
            switch method {
            case .google:
                engineControl.setLabel("Google", forSegment: i)
                engineControl.setToolTip(L("Google Translate"), forSegment: i)
            case .ai:
                engineControl.setLabel(L("AI"), forSegment: i)
                engineControl.setToolTip("\(config.provider.name): \(config.model)", forSegment: i)
            case .device:
                engineControl.setLabel(L("Offline"), forSegment: i)
                engineControl.setToolTip(L("Translated on this Mac: works without internet"), forSegment: i)
            }
        }
        selectEngine()
        engineControl.isHidden = config.engines.count < 2
        engineControl.target = self
        engineControl.action = #selector(engineChanged)

        offlineIcon.image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: L("No internet connection"))
        offlineIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        offlineIcon.contentTintColor = .secondaryLabelColor
        offlineIcon.toolTip = L("No internet connection")
        offlineIcon.isHidden = true

        configure(speakSourceButton, symbol: "speaker.wave.2", size: 12, tip: "", action: #selector(speakSource))
        configure(sourceButton, symbol: "pencil", size: 12, tip: "", action: #selector(toggleSourcePicker))
        configure(settingsButton, symbol: "gearshape", size: 13, tip: L("BTranslate settings"), action: #selector(openSettings))
        configure(addButton, symbol: "plus", size: 12, tip: "", action: #selector(showAddMenu))

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay  // never takes width from the text
        scroll.borderType = .noBorder
        scroll.documentView = container
        container.addSubview(addButton)

        // Any menu of the popup (a language menu, the + menu) is not "a click outside".
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuDidOpen), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuDidClose), name: NSMenu.didEndTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(packChanged), name: PackInstaller.changed, object: nil)

        for view in [sourceLabel, speakSourceButton, sourceButton, offlineIcon, engineControl, settingsButton, scroll] as [NSView] {
            background.addSubview(view)
        }
        // Keys go to the texts only (Esc, ⌘C, ⌘A): no Tab onto a control, where typing could change it.
        for control in [speakSourceButton, sourceButton, engineControl, settingsButton, addButton] as [NSControl] {
            control.refusesFirstResponder = true
        }
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
        button.refusesFirstResponder = true
    }

    func show() {
        prepare()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(sections.first?.textView)
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
        for section in sections { section.task?.cancel() }
        Speaker.shared.stop()
        Speaker.shared.onChange = nil
        Speaker.shared.onError = nil
        hideNotice()
        closeSourcePicker()
        NotificationCenter.default.removeObserver(self)
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
        // Not a click outside: a menu of the popup, the picker taking the keyboard, and the
        // moment right after the app starts, when it hands the front back to your app.
        if menuOpen || sourcePanel != nil { return }
        if let delegate = NSApp.delegate as? AppDelegate, Date() < delegate.handBackUntil { return }
        close()
    }

    @objc private func menuDidOpen() { menuOpen = true }

    @objc private func menuDidClose() {
        menuOpen = false
        if !closed && sourcePanel == nil && panel.isVisible && !panel.isKeyWindow { panel.makeKey() }
    }

    // MARK: The languages to translate into

    /// Adds a language's row and text under the others. The caller starts its translation.
    @discardableResult
    private func addSection(_ target: Target) -> TranslationSection {
        let section = TranslationSection(target: target)
        section.arrow.font = .systemFont(ofSize: 12, weight: .medium)
        section.arrow.textColor = .secondaryLabelColor
        section.menu.controlSize = .small
        section.menu.font = .systemFont(ofSize: 12)
        section.menu.target = self
        section.menu.action = #selector(targetChanged(_:))
        section.menu.refusesFirstResponder = true
        configure(section.speakButton, symbol: "speaker.wave.2", size: 13, tip: "", action: #selector(speakTranslation(_:)))
        configure(section.copyButton, symbol: "doc.on.doc", size: 13, tip: L("Copy this translation"), action: #selector(copyTranslation(_:)))
        configure(section.removeButton, symbol: "xmark", size: 11, tip: L("Take this language out of the popup"), action: #selector(removeLanguage(_:)))
        section.packButton.bezelStyle = .rounded
        section.packButton.controlSize = .small
        section.packButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        section.packButton.target = self
        section.packButton.action = #selector(downloadPack)
        section.packButton.refusesFirstResponder = true
        section.packButton.isHidden = true

        let text = section.textView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 1)
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: Popup.width - Popup.pad * 2, height: .greatestFiniteMagnitude)

        for view in section.views { container.addSubview(view) }
        sections.append(section)
        refreshMenus()
        return section
    }

    func addLanguage(_ target: Target) {
        guard !sections.contains(where: { $0.target == target }) else { return }
        let section = addSection(target)
        start(section)
        refreshBar()
    }

    private func remove(_ section: TranslationSection) {
        guard sections.count > 1, let index = sections.firstIndex(where: { $0 === section }) else { return }
        section.task?.cancel()
        if Speaker.shared.playing == section.name { Speaker.shared.stop() }
        if panel.firstResponder === section.textView { panel.makeFirstResponder(sections[index == 0 ? 1 : 0].textView) }
        for view in section.views { view.removeFromSuperview() }
        sections.remove(at: index)
        refreshMenus()
        refreshBar()
    }

    /// Each row's menu lists your languages; the ones other rows show are greyed out. + offers the rest.
    private func refreshMenus() {
        let names = config.targets.map(\.name)
        for section in sections {
            section.menu.removeAllItems()
            section.menu.addItems(withTitles: names)
            section.menu.selectItem(withTitle: section.target.name)
            section.menu.menu?.autoenablesItems = false
            for item in section.menu.itemArray {
                item.isEnabled = !sections.contains { $0 !== section && $0.target.name == item.title }
            }
            section.removeButton.toolTip = L("Take %@ out of this popup", section.target.inText)
        }
        addButton.toolTip = L("Also translate into another language of your list")
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        guard let section = sections.first(where: { $0.menu === sender }), let name = sender.titleOfSelectedItem,
              let target = config.targets.first(where: { $0.name == name }) else { return }
        section.target = target  // for this popup only; Settings has the default language
        section.opensWithDefault = false
        section.turnedFrom = nil
        refreshMenus()
        start(section)
        refreshBar()
    }

    @objc private func removeLanguage(_ sender: NSButton) {
        if let section = sections.first(where: { $0.removeButton === sender }) { remove(section) }
    }

    @objc private func showAddMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for target in config.targets where !sections.contains(where: { $0.target == target }) {
            let item = NSMenuItem(title: target.name, action: #selector(addFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.id
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: L("Every language of your list is here"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let edit = NSMenuItem(title: L("Edit the List…"), action: #selector(openSettings), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.height + 4), in: addButton)
    }

    @objc private func addFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let target = config.targets.first(where: { $0.id == id }) {
            addLanguage(target)
        }
    }

    // MARK: Translating

    /// Translates into every language of the popup anew.
    func start() {
        Speaker.shared.stop()
        detectedSource = nil
        for section in sections {
            // Back to the default language first: whether the text is in it is found out anew.
            if let before = section.turnedFrom, !sections.contains(where: { $0 !== section && $0.target == before }) {
                section.target = before
                section.turnedFrom = nil
                section.opensWithDefault = true
                refreshMenus()
            }
            start(section)
        }
        refreshBar()
    }

    /// A text already in the popup's default language gains nothing from being translated into
    /// it: the section the popup opened with turns to the second default (Settings, Languages
    /// page) and translates anew. Not a section whose language was picked by hand. True if it turned.
    private func turnToSecond(_ section: TranslationSection, from code: String) -> Bool {
        guard section.opensWithDefault, isAlready(in: section.target, code: code), let second = config.secondTarget,
              !sections.contains(where: { $0.target == second }) else { return false }
        section.opensWithDefault = false
        section.turnedFrom = section.target
        section.target = second
        detectedSource = code
        refreshMenus()
        start(section)
        refreshBar()
        return true
    }

    /// Whether a text found to be in the language `code` is in `target`'s language already,
    /// written its way. Serbian in the other alphabet is not: turning it over is a job.
    private func isAlready(in target: Target, code: String) -> Bool {
        guard OnDevice.same(code, target.google) else { return false }
        return target.google != "sr" || isMostlyLatin(source) == target.latin
    }

    private func start(_ section: TranslationSection) {
        section.task?.cancel()
        if Speaker.shared.playing == section.name { Speaker.shared.stop() }
        section.translation = ""
        section.settled = false
        section.waiting = false
        section.packOffer = nil
        section.packButton.isHidden = true
        setText(L("Translating…"), in: section, color: .secondaryLabelColor)
        let engine = engine, target = section.target, config = config, chosenSource = chosenSource
        section.task = Task { [weak self, weak section] in
            guard let self, let section else { return }
            do {
                try await translate(self.source, engine: engine, target: target, source: chosenSource, config: config) { [weak self, weak section] code, text in
                    guard let self, let section, !Task.isCancelled else { return }
                    if engine != .device { self.noConnection = false }  // an answer from the internet
                    if let code, self.turnToSecond(section, from: code) { return }
                    let firstPiece = section.translation.isEmpty
                    if let code, self.detectedSource == nil || section === self.sections.first { self.detectedSource = code }
                    section.translation = text
                    self.setText(text, in: section, color: .labelColor)
                    if firstPiece { self.refreshBar() } else { self.layout() }
                }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return }
                section.translation = ""
                // The Mac told the text's language, though the Offline method can't translate from it: show it.
                if chosenSource == nil, self.detectedSource == nil {
                    switch error {
                    case OfflineError.noLanguage(let code) where code != target.google: self.detectedSource = code
                    case OfflineError.needsPack(let code, _), OfflineError.notDownloaded(let code, _), OfflineError.noPair(let code, _):
                        self.detectedSource = code
                    default: break
                    }
                }
                let later = L("No internet connection. BTranslate will translate as soon as it is back.")
                let offer = self.packWouldHelp(error, target: target)
                var message = describe(error)
                if offer, case OfflineError.needsPack(let from, let to) = error {
                    message = L("This offline translation needs the NLLB-200 language pack (%@ → %@).",
                                languageName(from, inText: true), languageName(to, inText: true))
                }
                if engine != .device, isConnectionError(error) {
                    if self.goOffline(from: engine) { return }  // every language starts anew, with the Offline method
                    section.waiting = true
                    self.waitForConnection()
                    self.setText(later, in: section, color: .secondaryLabelColor)
                } else if engine == .device, self.autoOffline != nil {
                    // The Offline method can't do this one, and it is only in use for lack of a connection.
                    section.waiting = true
                    message += "\n" + later
                    self.setText(message, in: section, color: .secondaryLabelColor)
                } else {
                    self.setText(message, in: section, color: offer ? .secondaryLabelColor : .systemRed)
                }
                if offer {
                    section.packOffer = message
                    self.showPackOffer(in: section)
                }
            }
            if Task.isCancelled { return }
            section.settled = true
            self.refreshBar()
            if self.sections.allSatisfy(\.settled) { self.onSettled?() }
        }
    }

    // MARK: Offering the language pack

    /// True for what the Offline method could not do and the language pack, not installed yet, would put
    /// right: a pair of languages macOS has not got (or not downloaded), or a text whose language it can't tell.
    private func packWouldHelp(_ error: Error, target: Target) -> Bool {
        guard !LanguagePack.isInstalled, OnDevice.packHas(target.id) else { return false }
        switch error {
        case OfflineError.needsPack, OfflineError.unknownLanguage: return true
        case OfflineError.notDownloaded(let from, _): return OnDevice.packHas(from)
        default: return false
        }
    }

    /// Under such a message: a button that downloads the pack, or how its download stands.
    /// When the pack is there, the section translates anew.
    private func showPackOffer(in section: TranslationSection) {
        guard let offer = section.packOffer else { return }
        func megabytes(_ bytes: Int) -> String { L("%ld MB", bytes / 1_000_000) }
        var text = offer, button = true
        switch PackInstaller.shared.state {
        case .absent:
            break
        case .failed(let why):
            text += "\n" + why
        case .waiting:
            text += "\n" + L("The language pack will be downloaded as soon as there is an internet connection.")
            button = false
        case .downloading(let done, let total):
            text = L("Downloading the language pack: %@ of %@.", megabytes(done), megabytes(total))
            button = false
        case .preparing:
            text = L("macOS is preparing the language pack for the Neural Engine. This takes up to a minute, once.")
            button = false
        case .installed:
            start(section)
            return
        }
        setText(text, in: section, color: .secondaryLabelColor)
        section.packButton.title = L("Download Language Pack (%@)", megabytes(LanguagePack.megabytes * 1_000_000))
        section.packButton.isHidden = !button
    }

    @objc private func packChanged() {
        guard !closed else { return }
        for section in sections where section.packOffer != nil { showPackOffer(in: section) }
        layout()
    }

    @objc func downloadPack() {
        PackInstaller.shared.startWhenPossible()
    }

    var packOffered: [Bool] { sections.map { !$0.packButton.isHidden } }  // (UI test)

    var shownText: String { sections.first?.textView.string ?? "" }
    var shownTexts: [String] { sections.map(\.textView.string) }
    var shownSource: String { sourceLabel.stringValue }

    @objc private func engineChanged() {
        guard config.engines.indices.contains(engineControl.selectedSegment) else { return }
        engine = config.engines[engineControl.selectedSegment]  // for this popup only; Settings has the default
        autoOffline = nil                                       // your choice now, not the popup's
        start()
    }

    private func selectEngine() {
        engineControl.selectedSegment = config.engines.firstIndex(of: engine) ?? 0
    }

    // MARK: Without a connection

    var showsNoConnection: Bool { noConnection }  // (UI test)

    /// The popup goes over to the Offline method, all of it, if that method is turned on.
    /// Returns false if it is not: then the popup waits for the connection.
    private func goOffline(from method: Engine) -> Bool {
        guard config.engines.contains(.device), engine != .device else { return false }
        autoOffline = method
        engine = .device
        selectEngine()
        waitForConnection()
        start()
        return true
    }

    private func waitForConnection() {
        noConnection = true
        guard !listening else { return }
        listening = true
        Connection.shared.whenBack { [weak self] in
            self?.listening = false
            self?.connectionIsBack()
        }
    }

    /// Translates what is still waiting. What the Offline method has translated stays as it
    /// is; if it left a language untranslated, the method the popup had takes over again.
    func connectionIsBack() {
        guard !closed, noConnection else { return }
        noConnection = false
        let before = autoOffline
        autoOffline = nil
        if let before, sections.contains(where: \.waiting) {
            engine = before
            selectEngine()
            start()
        } else {
            for section in sections where section.waiting { start(section) }
            refreshBar()
        }
    }

    @objc private func openSettings() {
        close()
        (NSApp.delegate as? AppDelegate)?.showSettings()
    }

    // MARK: The original's language

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

    /// A picker of every language under "Detect automatically": first what the text may be in besides
    /// the language shown (by the language pack's detector, if it is installed), then the ones picked lately.
    func makeSourcePicker() -> LanguagePicker {
        let picker = LanguagePicker()
        let shown = sourceCode
        let likely = OnDevice.candidates(for: source).filter { $0 != shown }.compactMap { code in sourceLanguages.first { $0.id == code } }
        picker.available = {
            let recent = (UserDefaults.standard.stringArray(forKey: "recentSources") ?? [])
                .compactMap { id in sourceLanguages.first { $0.id == id } }
            let first = likely + recent.filter { !likely.contains($0) }
            return [detectAutomatically] + first + sourceLanguages.filter { !first.contains($0) }
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
            panel.makeFirstResponder(sections.first?.textView)
        }
    }

    // MARK: Reading aloud

    @objc private func speakSource() {
        guard let code = sourceCode else { return }
        Speaker.shared.toggle("original", text: source, code: code, googleVoice: config.googleVoice)
    }

    @objc private func speakTranslation(_ sender: NSButton) {
        guard let section = sections.first(where: { $0.speakButton === sender }) else { return }
        Speaker.shared.toggle(section.name, text: section.translation, code: section.target.google, googleVoice: config.googleVoice)
    }

    /// A text could not be read aloud (no internet for Google's voice, most often): the
    /// speaker button turns red, and a note under it says why.
    private func speechFailed(_ name: String, _ message: String) {
        let button = sections.first { $0.name == name }?.speakButton ?? speakSourceButton
        if Speaker.shared.volume > 0 { NSSound.beep() }  // (a check plays nothing, and so does not beep)
        button.contentTintColor = .systemRed
        button.toolTip = message
        showNotice(message, under: button)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refreshSpeech() }
    }

    /// Shows `text` in a small bubble under `button` for a few seconds. The bubble takes
    /// neither the keyboard nor clicks: the popup stays as it is.
    private func showNotice(_ text: String, under button: NSView) {
        hideNotice()
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 250
        let inner = label.fittingSize
        let size = NSSize(width: ceil(inner.width) + 24, height: ceil(inner.height) + 16)
        label.frame = NSRect(x: 12, y: 8, width: ceil(inner.width), height: ceil(inner.height))

        let bubble = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        bubble.isFloatingPanel = true
        bubble.level = .floating
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.hasShadow = true
        bubble.ignoresMouseEvents = true
        bubble.isReleasedWhenClosed = false
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.addSubview(label)
        bubble.contentView = background

        // Under the button, its middle under the button's; above it where the screen ends.
        let anchor = panel.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 6 - size.height)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if origin.y < visible.minY + 6 { origin.y = anchor.maxY + 6 }
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - 6 - size.width)
        }
        bubble.setFrameOrigin(origin)
        notice = bubble
        shownNotice = text
        noticeNumber += 1
        let number = noticeNumber
        if panel.isVisible { panel.addChildWindow(bubble, ordered: .above) }  // it moves with the popup
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.noticeNumber == number { self?.hideNotice() }
        }
    }

    private func hideNotice() {
        guard let bubble = notice else { return }
        notice = nil
        shownNotice = nil
        panel.removeChildWindow(bubble)
        bubble.orderOut(nil)
    }

    /// The first translation's speaker button, pressed (UI test).
    func pressSpeaker() {
        if let section = sections.first { speakTranslation(section.speakButton) }
    }

    /// The speaker buttons: a stop sign while their text is read, greyed out when there is
    /// nothing to read or no voice to read it.
    private func refreshSpeech() {
        func set(_ button: NSButton, name: String, code: String?, hasText: Bool, what: String) {
            let plan = code.map { Speaker.shared.plan(for: $0, googleVoice: config.googleVoice) } ?? .none
            let playing = Speaker.shared.playing == name
            button.image = NSImage(systemSymbolName: playing ? "stop.fill" : "speaker.wave.2",
                                   accessibilityDescription: playing ? L("Stop") : L("Listen to %@", what))
            button.contentTintColor = playing ? .controlAccentColor : .secondaryLabelColor
            button.isEnabled = hasText && plan != .none
            switch (plan, code) {
            case (_, nil): button.toolTip = L("Listen to %@, once its language is known", what)
            case (.mac, _): button.toolTip = playing ? L("Stop") : L("Listen to %@", what)
            case (.google, _): button.toolTip = playing ? L("Stop") : L("Listen to %@ (Google's voice: this text is sent to Google)", what)
            case (.none, let code?):
                button.toolTip = L("This Mac has no voice for %@. Google's voice can read it: turn it on in Settings.", languageName(code, inText: true))
            }
        }
        set(speakSourceButton, name: "original", code: sourceCode, hasText: true, what: L("the original"))
        for section in sections {
            set(section.speakButton, name: section.name, code: section.target.google, hasText: !section.translation.isEmpty,
                what: sections.count > 1 ? L("the %@ translation", section.target.inText) : L("the translation"))
        }
    }

    // MARK: Copying

    @objc private func copyTranslation(_ sender: NSButton) {
        guard let section = sections.first(where: { $0.copyButton === sender }) else { return }
        copy(section.translation, from: section)
    }

    /// ⌘C: what is selected in a translation; with nothing selected, the translation the
    /// cursor is in, or else the first one.
    private func copySelectionOrFirst() {
        guard let section = sections.first(where: { $0.textView === panel.firstResponder }) ?? sections.first else { return }
        let range = section.textView.selectedRange()
        copy(range.length > 0 ? (section.textView.string as NSString).substring(with: range) : section.translation, from: section)
    }

    private func copy(_ s: String, from section: TranslationSection) {
        guard !s.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        section.copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: L("Copied"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak section] in
            section?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("Copy"))
        }
    }

    // MARK: Drawing

    private func setText(_ s: String, in section: TranslationSection, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        section.textView.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: [
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
            sourceLabel.stringValue = sections.contains { !$0.settled } ? L("Detecting…") : L("Unknown language")
        }
        offlineIcon.isHidden = !noConnection
        sourceButton.contentTintColor = chosenSource == nil ? .secondaryLabelColor : .controlAccentColor
        sourceButton.toolTip = chosenSource == nil
            ? L("Wrong language? Set the language of the original")
            : L("The original's language was set by hand. Click to change it or to detect it again")
        refreshSpeech()
        layout()
    }

    private func textHeight(_ text: NSTextView, width: CGFloat) -> CGFloat {
        text.frame.size.width = width
        guard let lm = text.layoutManager, let tc = text.textContainer else { return Popup.minTextHeight }
        lm.ensureLayout(for: tc)
        return max(ceil(lm.usedRect(for: tc).height + text.textContainerInset.height * 2), Popup.minTextHeight)
    }

    /// Lays the sections out and sizes the panel to them. The first time, the panel goes by the
    /// pointer. After that it stays where it is (you may have dragged it): only its height changes.
    private func layout() {
        let W = Popup.width, pad = Popup.pad, bar = Popup.barHeight, row = Popup.rowHeight
        let contentWidth = W - pad * 2

        // The sections, top down, in the part that scrolls when they get long.
        var y: CGFloat = 0
        for (i, section) in sections.enumerated() {
            if i > 0 { y += 10 }
            func middle(_ view: NSView) -> CGFloat { y + (row - view.frame.height) / 2 }
            var right = contentWidth
            section.removeButton.isHidden = i == 0
            if i > 0 {
                right -= 20
                section.removeButton.frame = NSRect(x: right, y: y, width: 20, height: row)
                right -= 4
            }
            right -= 22
            section.copyButton.frame = NSRect(x: right, y: y, width: 22, height: row)
            right -= 26
            section.speakButton.frame = NSRect(x: right, y: y, width: 22, height: row)

            section.arrow.sizeToFit()
            section.arrow.frame.origin = NSPoint(x: 0, y: middle(section.arrow))
            section.menu.sizeToFit()
            let menuX = section.arrow.frame.maxX + 4
            let menuWidth = min(section.menu.frame.width, right - 10 - menuX - (i == 0 ? 26 : 0))
            section.menu.frame = NSRect(x: menuX, y: middle(section.menu), width: menuWidth, height: section.menu.frame.height)
            if i == 0 { addButton.frame = NSRect(x: section.menu.frame.maxX + 4, y: y, width: 22, height: row) }
            y += row + 4

            let h = textHeight(section.textView, width: contentWidth)
            section.textView.frame = NSRect(x: 0, y: y, width: contentWidth, height: h)
            y += h
            if !section.packButton.isHidden {
                section.packButton.sizeToFit()
                section.packButton.frame.origin = NSPoint(x: 0, y: y + 6)
                y += 6 + section.packButton.frame.height + 2
            }
        }
        let contentHeight = y
        let visibleHeight = min(contentHeight, Popup.maxTextHeight)
        container.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        let H = pad + bar + Popup.gap + visibleHeight + pad

        var frame: NSRect
        if !placed {
            let visible = (NSScreen.screens.first { $0.frame.intersects(anchor.insetBy(dx: -1, dy: -1)) } ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = min(max(anchor.minX - 16, visible.minX + 6), visible.maxX - W - 6)
            let roomBelow = anchor.minY - 6 - visible.minY, roomAbove = visible.maxY - anchor.maxY - 6
            growsUp = roomBelow < 240 && roomAbove > roomBelow
            frame = NSRect(x: x, y: growsUp ? anchor.maxY + 6 : anchor.minY - 6 - H, width: W, height: H)
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

        // The top bar; the original's language is cut short if it has to be.
        let barY = H - pad - bar
        func centred(_ view: NSView) -> CGFloat { barY + (bar - view.frame.height) / 2 }
        settingsButton.frame = NSRect(x: W - pad - 20, y: barY + 1, width: 22, height: 22)
        engineControl.sizeToFit()
        engineControl.frame.origin = NSPoint(x: settingsButton.frame.minX - 8 - engineControl.frame.width, y: centred(engineControl))
        var rightEdge = (engineControl.isHidden ? settingsButton.frame.minX : engineControl.frame.minX) - 10
        if !offlineIcon.isHidden {
            offlineIcon.frame = NSRect(x: rightEdge - 12, y: barY + 2, width: 20, height: 20)
            rightEdge = offlineIcon.frame.minX - 6
        }
        sourceLabel.sizeToFit()
        let labelWidth = min(sourceLabel.frame.width, rightEdge - pad - (4 + 20 + 2 + 18))
        sourceLabel.frame = NSRect(x: pad, y: centred(sourceLabel), width: labelWidth, height: sourceLabel.frame.height)
        speakSourceButton.frame = NSRect(x: sourceLabel.frame.maxX + 4, y: barY + 1, width: 20, height: 22)
        sourceButton.frame = NSRect(x: speakSourceButton.frame.maxX + 2, y: barY + 1, width: 18, height: 22)

        scroll.frame = NSRect(x: pad, y: pad, width: contentWidth, height: visibleHeight)
        panel.invalidateShadow()
    }
}

@MainActor
func showPopup(_ text: String, by place: NSRect? = nil) {
    if let delegate = NSApp.delegate as? AppDelegate {
        delegate.handBackUntil = max(delegate.handBackUntil, Date().addingTimeInterval(1.5))
    }
    Popup.current?.close()
    let popup = Popup(text: text, by: place)
    Popup.current = popup
    popup.show()
}
