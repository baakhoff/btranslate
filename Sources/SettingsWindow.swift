import Cocoa

/// The setup window: which translation methods to use, the AI provider, model and API key,
/// the languages to translate into, which method a popup opens with, and the language of
/// BTranslate itself. It opens when you
/// start BTranslate yourself (the installer does, once) and from the gear button in the popup.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = SettingsController()

    private var window: NSWindow?
    private var config = Config.load()

    private let googleBox = NSButton(checkboxWithTitle: L("Google Translate"), target: nil, action: nil)
    private let aiBox = NSButton(checkboxWithTitle: L("AI model"), target: nil, action: nil)
    private let providerMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelBox = NSComboBox()
    private let urlLabel = NSTextField(labelWithString: L("Server:"))
    private let urlField = NSTextField()
    private let keyField = NSSecureTextField()
    private let keyHelp = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton(title: L("Test"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let defaultControl = NSSegmentedControl(labels: ["Google", L("AI")], trackingMode: .selectOne, target: nil, action: nil)
    private var aiLabels: [NSTextField] = []
    private var urlRow: NSGridRow?  // shown for the Custom provider only
    private let languageEditor = LanguageListEditor(width: 436)
    private let googleVoiceBox = NSButton(checkboxWithTitle: L("Read aloud with Google's voice where this Mac has none"), target: nil, action: nil)
    private let languageMenu = NSPopUpButton(frame: .zero, pullsDown: false)  // the language of BTranslate itself
    // Two pages, so the window fits a small screen: how to translate, and into which languages.
    private let pageControl = NSSegmentedControl(labels: [L("Translation"), L("Languages")], trackingMode: .selectOne, target: nil, action: nil)
    private var pages: [NSView] = []

    private var modelTask: Task<Void, Never>?
    private var testTask: Task<Void, Never>?

    var isVisible: Bool { window?.isVisible ?? false }

    private var selectedProvider: Provider { providers[max(0, providerMenu.indexOfSelectedItem)] }

    func show() {
        if window == nil { build() }
        if window?.isVisible != true {
            config = Config.load()
            fill()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Shows one of the two pages; the window keeps its top edge and takes the page's height.
    func showPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        pageControl.selectedSegment = index
        let top = window.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY) }
        for (i, page) in pages.enumerated() { page.isHidden = i != index }
        window?.layoutIfNeeded()
        if let window, let content = window.contentView {
            window.setContentSize(content.fittingSize)
            if let top { window.setFrameTopLeftPoint(top) }
        }
    }

    @objc private func pageChanged() {
        languageEditor.picker.popover.close()
        showPage(pageControl.selectedSegment)
    }

    /// The window's content with the saved settings filled in, without showing it (UI test).
    func preparedContent(page: Int = 0) -> NSView? {
        if window == nil { build() }
        config = Config.load()
        fill()
        showPage(page)
        return window?.contentView
    }

    var currentContent: NSView? { window?.contentView }

    /// The window's content height on each page (UI test). Leaves the second page showing.
    var pageHeights: (CGFloat, CGFloat) {
        showPage(0)
        let first = window?.contentView?.fittingSize.height ?? 0
        showPage(1)
        return (first, window?.contentView?.fittingSize.height ?? 0)
    }

    /// The "+" picker's content as it looks after typing `search` (UI test).
    func preparedPicker(search: String) -> NSView {
        languageEditor.picker.setSearch(search)
        return languageEditor.picker.view
    }

    /// Adds the picker's first match to the list, and reports the list and what the picker
    /// still offers (UI test). Nothing is saved.
    func addFirstFoundLanguage() -> (list: [String], stillOffered: [String]) {
        languageEditor.picker.addFirstFound()
        return (draft().languageIDs, languageEditor.picker.foundIDs)
    }

    /// Works the list's buttons on its last row: up, make default, then remove the row that was
    /// first (UI test). Returns the order and the default after each step. Nothing is saved.
    func reorderForTest() -> [String] {
        func state() -> String { "\(draft().languageIDs.joined(separator: ",")) default=\(draft().defaultLanguageID)" }
        var steps = [state()]
        let last = languageEditor.languages.count - 1
        languageEditor.select(row: last)
        languageEditor.moveSelected(by: -1)
        steps.append(state())
        languageEditor.makeSelectedDefault()
        steps.append(state())
        languageEditor.select(row: 0)
        languageEditor.moveSelected(by: 1)
        steps.append(state())
        return steps
    }

    /// What the language menu's items stand for, each picked in turn: "" is the Mac's own
    /// language (UI test). Nothing is saved.
    func languageChoicesForTest() -> [String] {
        let was = languageMenu.indexOfSelectedItem
        defer { languageMenu.selectItem(at: was) }
        return (0..<languageMenu.numberOfItems).map { item in
            languageMenu.selectItem(at: item)
            return draft().languageChoice
        }
    }

    // MARK: Building the window

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func build() {
        let title = NSTextField(labelWithString: "BTranslate")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let intro = NSTextField(wrappingLabelWithString:
            L("Select text in any app, right-click it and choose Services → BTranslate."))
        pageControl.target = self
        pageControl.action = #selector(pageChanged)

        for box in [googleBox, aiBox] {
            box.target = self
            box.action = #selector(methodsChanged)
        }
        let googleNote = caption(L("Free, no key needed. The selected text goes to Google."))
        let aiNote = caption(L("Your own API key. Often better with context, names and tone. The selected text goes to the provider you pick."))

        providerMenu.addItems(withTitles: providers.map(\.name))
        providerMenu.target = self
        providerMenu.action = #selector(providerChanged)
        modelBox.isEditable = true
        modelBox.completes = true
        modelBox.numberOfVisibleItems = 14
        urlField.placeholderString = "http://127.0.0.1:8000/v1"
        keyField.delegate = self
        testButton.target = self
        testButton.action = #selector(runTest)
        testButton.bezelStyle = .rounded
        status.font = .systemFont(ofSize: 11)
        status.isSelectable = true

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.alignment = .right
            aiLabels.append(l)
            return l
        }
        aiLabels.append(urlLabel)
        urlLabel.alignment = .right
        keyHelp.font = .systemFont(ofSize: 11)
        keyHelp.textColor = .secondaryLabelColor
        let grid = NSGridView(views: [
            [label(L("Provider:")), providerMenu],
            [label(L("Model:")), modelBox],
            [urlLabel, urlField],
            [label(L("API key:")), keyField],
            [NSGridCell.emptyContentView, keyHelp],
            [testButton, status],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline
        grid.row(at: 4).rowAlignment = .none
        grid.row(at: 5).rowAlignment = .none
        grid.row(at: 5).yPlacement = .top
        urlRow = grid.row(at: 2)

        let defaultLabel = NSTextField(labelWithString: L("BTranslate opens with:"))
        defaultControl.target = self
        defaultControl.action = #selector(defaultChanged)
        let defaultRow = NSStackView(views: [defaultLabel, defaultControl])
        defaultRow.spacing = 8

        let save = NSButton(title: L("Save"), target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelSettings))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, save])
        buttons.spacing = 8

        let line1 = NSBox(), line2 = NSBox(), line3 = NSBox()
        for line in [line1, line2, line3] { line.boxType = .separator }
        let languagesLabel = NSTextField(labelWithString: L("Languages to translate into:"))
        let voiceNote = caption(L("The speaker buttons use your Mac's voices. It has none for some languages, such as Latvian: with this on, a text you play in one of those is sent to Google."))
        // BTranslate's own language: the Mac's, or one of those it comes in, each named in itself.
        languageMenu.addItems(withTitles: [L("Same as the Mac")] + interfaceLanguages.map(\.name))
        let ownLanguageRow = NSStackView(views: [NSTextField(labelWithString: L("BTranslate's language:")), languageMenu])
        ownLanguageRow.spacing = 8

        let width: CGFloat = 480, inner = width - 44
        func page(_ views: [NSView]) -> NSStackView {
            let page = NSStackView(views: views)
            page.orientation = .vertical
            page.alignment = .leading
            page.spacing = 8
            return page
        }
        // Page 1: how to translate.
        let translation = page([googleBox, googleNote, aiBox, aiNote, grid, line1, defaultRow])
        translation.setCustomSpacing(2, after: googleBox)
        translation.setCustomSpacing(12, after: googleNote)
        translation.setCustomSpacing(2, after: aiBox)
        translation.setCustomSpacing(12, after: aiNote)
        translation.setCustomSpacing(14, after: grid)
        translation.setCustomSpacing(12, after: line1)
        // Page 2: into which languages, reading aloud, and the language of BTranslate itself.
        let languages = page([languagesLabel, languageEditor.view, googleVoiceBox, voiceNote, line3, ownLanguageRow])
        languages.setCustomSpacing(16, after: languageEditor.view)
        languages.setCustomSpacing(2, after: googleVoiceBox)
        languages.setCustomSpacing(14, after: voiceNote)
        languages.setCustomSpacing(12, after: line3)
        pages = [translation, languages]

        let stack = NSStackView(views: [title, intro, pageControl, translation, languages, line2, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: intro)
        stack.setCustomSpacing(16, after: pageControl)
        stack.setCustomSpacing(16, after: translation)
        stack.setCustomSpacing(16, after: languages)
        stack.setCustomSpacing(14, after: line2)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: width),
        ])
        for view in [intro, googleNote, aiNote, voiceNote, grid, line1, line2, line3, buttons, translation, languages] as [NSView] {
            view.widthAnchor.constraint(equalToConstant: inner).isActive = true
        }
        // The first column fits its widest label (they are longer in some languages) and the Test button.
        let widest = (aiLabels as [NSView] + [testButton]).map { ceil($0.intrinsicContentSize.width) }.max() ?? 0
        grid.column(at: 0).width = max(72, widest)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("BTranslate Settings")
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.delegate = self
        window = w
        showPage(0)
    }

    // MARK: Showing the saved settings

    private func fill() {
        googleBox.state = config.googleEnabled ? .on : .off
        aiBox.state = config.aiEnabled ? .on : .off
        providerMenu.selectItem(at: providers.firstIndex { $0.id == config.providerID } ?? 0)
        urlField.stringValue = config.customURL
        defaultControl.selectedSegment = config.defaultEngine == .google ? 0 : 1
        languageEditor.languages = config.targets
        languageEditor.defaultID = config.startTarget.id
        googleVoiceBox.state = config.googleVoice ? .on : .off
        languageMenu.selectItem(at: (interfaceLanguages.firstIndex { $0.code == config.languageChoice } ?? -1) + 1)
        setStatus("", color: .secondaryLabelColor)
        showProvider(keepModel: config.model)
        refreshEnabled()
    }

    /// Updates the model list, key field and hints for the provider in the menu.
    private func showProvider(keepModel: String? = nil) {
        let provider = selectedProvider
        modelBox.removeAllItems()
        modelBox.addItems(withObjectValues: provider.models)
        modelBox.stringValue = keepModel ?? provider.models.first ?? ""
        urlRow?.isHidden = provider.id != "custom"
        keyField.stringValue = ""
        let saved = Keychain.read(provider.id) != nil
        keyField.placeholderString = saved ? L("Saved in your Keychain. Paste a new key to replace it.") : L("Paste your API key")
        keyHelp.stringValue = provider.keyHelp + " " + L("The key is stored in your Mac's Keychain.")
        loadModels()
    }

    private func refreshEnabled() {
        let google = googleBox.state == .on, ai = aiBox.state == .on
        for control in [providerMenu, modelBox, urlField, keyField, testButton] as [NSControl] { control.isEnabled = ai }
        for l in aiLabels { l.textColor = ai ? .labelColor : .disabledControlTextColor }
        defaultControl.isEnabled = google && ai
        if google != ai { defaultControl.selectedSegment = google ? 0 : 1 }
    }

    private func setStatus(_ text: String, color: NSColor) {
        status.stringValue = text
        status.textColor = color
    }

    /// The settings as the window shows them now.
    private func draft() -> Config {
        var c = config
        c.googleEnabled = googleBox.state == .on
        c.aiEnabled = aiBox.state == .on
        c.providerID = selectedProvider.id
        c.model = modelBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.customURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.defaultEngine = defaultControl.selectedSegment == 1 ? .ai : .google
        c.languageIDs = languageEditor.languages.map(\.id)
        c.defaultLanguageID = languageEditor.defaultLanguage?.id ?? ""
        c.googleVoice = googleVoiceBox.state == .on
        let chosen = languageMenu.indexOfSelectedItem - 1  // -1: the first item, "Same as the Mac"
        c.languageChoice = interfaceLanguages.indices.contains(chosen) ? interfaceLanguages[chosen].code : ""
        return c
    }

    /// The key typed in the window, or else the saved one.
    private func currentKey() -> String {
        let typed = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (Keychain.read(selectedProvider.id) ?? "") : typed
    }

    /// Fills the model menu with the provider's own list (it needs the key for most providers).
    private func loadModels() {
        modelTask?.cancel()
        let c = draft(), key = currentKey(), providerID = selectedProvider.id
        if key.isEmpty && providerID != "custom" && providerID != "openrouter" { return }
        if c.baseURL.isEmpty { return }
        modelTask = Task { [weak self] in
            guard let list = try? await listModels(config: c, key: key), !list.isEmpty else { return }
            guard let self, !Task.isCancelled, self.selectedProvider.id == providerID else { return }
            let typed = self.modelBox.stringValue
            self.modelBox.removeAllItems()
            self.modelBox.addItems(withObjectValues: list)
            self.modelBox.stringValue = typed
        }
    }

    // MARK: Actions

    @objc private func methodsChanged() {
        if googleBox.state == .off && aiBox.state == .off {  // at least one method stays on
            googleBox.state = .on
        }
        refreshEnabled()
    }

    @objc private func providerChanged() {
        setStatus("", color: .secondaryLabelColor)
        showProvider(keepModel: selectedProvider.id == config.providerID ? config.model : nil)
        refreshEnabled()
    }

    @objc private func defaultChanged() {}

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === keyField || (obj.object as? NSTextField) === urlField { loadModels() }
    }

    /// What is wrong with the AI settings, or nil if they can be used.
    private func problem(_ c: Config, key: String) -> String? {
        guard c.aiEnabled else { return nil }
        if c.providerID == "custom" && !(c.customURL.hasPrefix("http://") || c.customURL.hasPrefix("https://")) {
            return L("Enter the server's address, starting with http:// or https://.")
        }
        if c.model.isEmpty { return L("Enter a model name.") }
        if key.isEmpty && c.providerID != "custom" { return L("Paste an API key for %@, or turn the AI model off.", c.provider.name) }
        if !key.isEmpty && !Keychain.isValid(key) { return L("That doesn't look like an API key: it has spaces or quotes in it.") }
        return nil
    }

    @objc private func runTest() {
        let c = draft(), key = currentKey()
        if let p = problem(c, key: key) { setStatus(p, color: .systemRed); return }
        testTask?.cancel()
        setStatus(L("Testing…"), color: .secondaryLabelColor)
        testTask = Task { [weak self] in
            var result = ""
            do {
                let english = target(id: "en") ?? allTargets[0]
                try await aiTranslate("Labdien! Kā jums klājas?", target: english, config: c, key: key) { _, text in result = text }
                guard let self, !Task.isCancelled else { return }
                self.setStatus(L("It works. “Labdien! Kā jums klājas?” → “%@”", result), color: .systemGreen)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.setStatus(describe(error), color: .systemRed)
            }
        }
    }

    @objc private func saveSettings() {
        let c = draft()
        let typed = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = problem(c, key: currentKey()) {
            showPage(0)  // where the message shows
            setStatus(p, color: .systemRed)
            return
        }
        if c.aiEnabled && !typed.isEmpty && !Keychain.save(typed, account: c.providerID) {
            showPage(0)
            setStatus(L("The key could not be saved to the Keychain."), color: .systemRed)
            return
        }
        let languageChanged = c.languageChoice != config.languageChoice
        c.save()
        config = c
        window?.close()
        // The app takes its language when it starts: start it anew, in the background.
        if languageChanged { (NSApp.delegate as? AppDelegate)?.restart() }
    }

    @objc private func cancelSettings() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        modelTask?.cancel()
        testTask?.cancel()
        languageEditor.picker.popover.close()
        keyField.stringValue = ""
        (NSApp.delegate as? AppDelegate)?.handBack()  // back to the app you were in
    }
}
