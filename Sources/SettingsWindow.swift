import Cocoa

/// The setup window: which translation methods to use, the AI provider, model and API key,
/// the languages to translate into, and which method a popup opens with. It opens when you
/// start BTranslate yourself (the installer does, once) and from the gear button in the popup.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = SettingsController()

    private var window: NSWindow?
    private var config = Config.load()

    private let googleBox = NSButton(checkboxWithTitle: "Google Translate", target: nil, action: nil)
    private let aiBox = NSButton(checkboxWithTitle: "AI model", target: nil, action: nil)
    private let providerMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelBox = NSComboBox()
    private let urlLabel = NSTextField(labelWithString: "Server:")
    private let urlField = NSTextField()
    private let keyField = NSSecureTextField()
    private let keyHelp = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton(title: "Test", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let defaultControl = NSSegmentedControl(labels: ["Google", "AI"], trackingMode: .selectOne, target: nil, action: nil)
    private var aiLabels: [NSTextField] = []
    private var urlRow: NSGridRow?  // shown for the Custom provider only
    private let languageEditor = LanguageListEditor(width: 436)
    private let googleVoiceBox = NSButton(checkboxWithTitle: "Read aloud with Google's voice where this Mac has none", target: nil, action: nil)

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

    /// The window's content with the saved settings filled in, without showing it (UI test).
    func preparedContent() -> NSView? {
        if window == nil { build() }
        config = Config.load()
        fill()
        return window?.contentView
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
            "Select text in any app, right-click it and choose Services → BTranslate. Choose how it translates:")

        for box in [googleBox, aiBox] {
            box.target = self
            box.action = #selector(methodsChanged)
        }
        let googleNote = caption("Free, no key needed. The selected text goes to Google.")
        let aiNote = caption("Your own API key. Often better with context, names and tone. The selected text goes to the provider you pick.")

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
            [label("Provider:"), providerMenu],
            [label("Model:"), modelBox],
            [urlLabel, urlField],
            [label("API key:"), keyField],
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

        let defaultLabel = NSTextField(labelWithString: "BTranslate opens with:")
        defaultControl.target = self
        defaultControl.action = #selector(defaultChanged)
        let defaultRow = NSStackView(views: [defaultLabel, defaultControl])
        defaultRow.spacing = 8

        let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, save])
        buttons.spacing = 8

        let line1 = NSBox(), line2 = NSBox(), line3 = NSBox()
        for line in [line1, line2, line3] { line.boxType = .separator }
        let languagesLabel = NSTextField(labelWithString: "Languages to translate into:")
        let voiceNote = caption("The speaker buttons use your Mac's voices. It has none for some languages, such as Latvian: with this on, a text you play in one of those is sent to Google.")

        let stack = NSStackView(views: [title, intro, googleBox, googleNote, aiBox, aiNote, grid, line1,
                                        languagesLabel, languageEditor.view, googleVoiceBox, voiceNote,
                                        line3, defaultRow, line2, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: intro)
        stack.setCustomSpacing(2, after: googleBox)
        stack.setCustomSpacing(12, after: googleNote)
        stack.setCustomSpacing(2, after: aiBox)
        stack.setCustomSpacing(12, after: aiNote)
        stack.setCustomSpacing(14, after: grid)
        stack.setCustomSpacing(12, after: line1)
        stack.setCustomSpacing(14, after: languageEditor.view)
        stack.setCustomSpacing(2, after: googleVoiceBox)
        stack.setCustomSpacing(14, after: voiceNote)
        stack.setCustomSpacing(12, after: line3)
        stack.setCustomSpacing(14, after: defaultRow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        let width: CGFloat = 480
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: width),
        ])
        for view in [intro, googleNote, aiNote, voiceNote, grid, line1, line2, line3, buttons] as [NSView] {
            view.widthAnchor.constraint(equalToConstant: width - 44).isActive = true
        }
        grid.column(at: 0).width = 72

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "BTranslate Settings"
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.delegate = self
        window = w
    }

    // MARK: Showing the saved settings

    private func fill() {
        googleBox.state = config.googleEnabled ? .on : .off
        aiBox.state = config.aiEnabled ? .on : .off
        providerMenu.selectItem(at: providers.firstIndex { $0.id == config.providerID } ?? 0)
        urlField.stringValue = config.customURL
        defaultControl.selectedSegment = config.defaultEngine == .google ? 0 : 1
        languageEditor.languages = config.targets
        googleVoiceBox.state = config.googleVoice ? .on : .off
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
        keyField.placeholderString = saved ? "Saved in your Keychain. Paste a new key to replace it." : "Paste your API key"
        keyHelp.stringValue = provider.keyHelp + " The key is stored in your Mac's Keychain."
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
        c.googleVoice = googleVoiceBox.state == .on
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
            return "Enter the server's address, starting with http:// or https://."
        }
        if c.model.isEmpty { return "Enter a model name." }
        if key.isEmpty && c.providerID != "custom" { return "Paste an API key for \(c.provider.name), or turn the AI model off." }
        if !key.isEmpty && !Keychain.isValid(key) { return "That doesn't look like an API key: it has spaces or quotes in it." }
        return nil
    }

    @objc private func runTest() {
        let c = draft(), key = currentKey()
        if let p = problem(c, key: key) { setStatus(p, color: .systemRed); return }
        testTask?.cancel()
        setStatus("Testing…", color: .secondaryLabelColor)
        testTask = Task { [weak self] in
            var result = ""
            do {
                let english = target(id: "en") ?? allTargets[0]
                try await aiTranslate("Labdien! Kā jums klājas?", target: english, config: c, key: key) { _, text in result = text }
                guard let self, !Task.isCancelled else { return }
                self.setStatus("It works. “Labdien! Kā jums klājas?” → “\(result)”", color: .systemGreen)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.setStatus(describe(error), color: .systemRed)
            }
        }
    }

    @objc private func saveSettings() {
        let c = draft()
        let typed = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = problem(c, key: currentKey()) { setStatus(p, color: .systemRed); return }
        if c.aiEnabled && !typed.isEmpty && !Keychain.save(typed, account: c.providerID) {
            setStatus("The key could not be saved to the Keychain.", color: .systemRed)
            return
        }
        c.save()
        config = c
        window?.close()
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
