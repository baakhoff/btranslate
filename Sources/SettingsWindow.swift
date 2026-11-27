import Cocoa

/// A method chosen among the ones that can be used now, a segment for each. The one picked
/// is kept while it is not on offer (the AI model unticked, then ticked again).
@MainActor
private final class MethodChoice: NSObject {
    let control = NSSegmentedControl(labels: ["Google"], trackingMode: .selectOne, target: nil, action: nil)
    private(set) var offered: [Engine] = [.google]
    var chosen: Engine = .google

    override init() {
        super.init()
        control.target = self
        control.action = #selector(changed)
    }

    /// The method it shows.
    var shown: Engine { offered.indices.contains(control.selectedSegment) ? offered[control.selectedSegment] : offered[0] }

    /// Offers `methods` (never none). While the one chosen is not among them it shows `otherwise`, or the first.
    func offer(_ methods: [Engine], otherwise: Engine? = nil) {
        offered = methods
        control.segmentCount = methods.count
        for (i, method) in methods.enumerated() {
            control.setLabel(method.label, forSegment: i)
            control.setWidth(0, forSegment: i)  // as wide as its label
        }
        control.selectedSegment = methods.firstIndex(of: chosen) ?? otherwise.flatMap(methods.firstIndex(of:)) ?? 0
        control.isEnabled = methods.count > 1  // with one, there is nothing to choose
    }

    @objc private func changed() { chosen = shown }
}

/// The settings window. It opens when you start BTranslate yourself (the installer does,
/// once) and from the gear button of a popup, of the typing panel and of a translated window.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = SettingsController()

    private var window: NSWindow?
    private var config = Config.load()

    private let googleBox = NSButton(checkboxWithTitle: L("Google Translate"), target: nil, action: nil)
    private let aiBox = NSButton(checkboxWithTitle: L("AI model"), target: nil, action: nil)
    private let deviceBox = NSButton(checkboxWithTitle: L("Offline, on this Mac"), target: nil, action: nil)
    // The language pack (NLLB.swift): what it is or how its download stands, and the button for it.
    private let packNote = NSTextField(wrappingLabelWithString: "")
    private let packButton = NSButton(title: L("Download"), target: nil, action: nil)
    private let packProgress = NSProgressIndicator()
    private let providerMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelBox = NSComboBox()
    private let urlLabel = NSTextField(labelWithString: L("Server:"))
    private let urlField = NSTextField()
    private let keyField = NSSecureTextField()
    private let keyHelp = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton(title: L("Test"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    // The method each opens with: a popup, the typing panel, a window's picture.
    private let popupMethod = MethodChoice(), typingMethod = MethodChoice(), windowMethod = MethodChoice()
    private var aiLabels: [NSTextField] = []
    private var urlRow: NSGridRow?  // shown for the Custom provider only
    private let languageEditor = LanguageListEditor(width: 436)
    // The languages the typing panel writes in and a window is translated into: of the list of
    // the Languages page. Selected text goes into that list's default, which is only named here.
    private let popupLanguage = NSTextField(labelWithString: "")
    private let typingMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private var typingID = ""  // as it was chosen; "" or gone from the list: the second default
    private let windowMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private var windowID = ""  // as it was chosen; "" or gone from the list: the default
    private let googleVoiceBox = NSButton(checkboxWithTitle: L("Read aloud with Google's voice where this Mac has none"), target: nil, action: nil)
    private let languageMenu = NSPopUpButton(frame: .zero, pullsDown: false)  // the language of BTranslate itself
    // The shortcut that brings BTranslate up from any app, and what it needs.
    let shortcutField = ShortcutField()
    private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    private let accessNote = NSTextField(wrappingLabelWithString: "")
    private let accessButton = NSButton(title: L("Open System Settings…"), target: nil, action: nil)
    private let screenNote = NSTextField(wrappingLabelWithString: "")
    private let screenButton = NSButton(title: L("Open System Settings…"), target: nil, action: nil)
    private let loginBox = NSButton(checkboxWithTitle: L("Open BTranslate when I log in"), target: nil, action: nil)
    private var accessTimer: Timer?
    // About: the version, and whether there is a newer one (Sources/Updates.swift).
    private let updateText = NSTextField(wrappingLabelWithString: "")
    private let updateSpinner = NSProgressIndicator()
    private let updateButton = NSButton(title: L("Check Now"), target: nil, action: nil)
    private let checkBox = NSButton(checkboxWithTitle: L("Check for updates once a day"), target: nil, action: nil)
    private let autoBox = NSButton(checkboxWithTitle: L("Install updates automatically"), target: nil, action: nil)
    private var adHocNote: NSTextField?
    // Five pages, so the window fits a small screen.
    enum Page: Int, CaseIterable { case translation, languages, defaults, shortcut, about }
    private let pageControl = NSSegmentedControl(labels: [L("Translation"), L("Languages"), L("Defaults"), L("Shortcut"), L("About")],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private var pages: [NSView] = []
    private var shownPage: Page { Page(rawValue: pageControl.selectedSegment) ?? .translation }

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
        // The permission is given in System Settings, while this window is open: it shows it when it is.
        accessTimer?.invalidate()
        accessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        }
    }

    /// Shows one of the pages; the window keeps its top edge and takes the page's height.
    func showPage(_ which: Page) {
        let index = which.rawValue
        guard pages.indices.contains(index) else { return }
        pageControl.selectedSegment = index
        let top = window.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY) }
        for (i, page) in pages.enumerated() { page.isHidden = i != index }
        window?.layoutIfNeeded()
        if let window, let content = window.contentView {
            window.setContentSize(content.fittingSize)
            if let top { window.setFrameTopLeftPoint(top) }
        }
        if which == .about, window?.isVisible == true { Updater.shared.aboutShown() }
    }

    @objc private func pageChanged() {
        languageEditor.picker.popover.close()
        showPage(shownPage)
    }

    /// The window's content with the saved settings filled in, without showing it (UI test).
    func preparedContent(page: Page = .translation) -> NSView? {
        if window == nil { build() }
        config = Config.load()
        fill()
        showPage(page)
        return window?.contentView
    }

    var currentContent: NSView? { window?.contentView }

    /// The window's content height on each page (UI test). Leaves the last page showing.
    var pageHeights: [CGFloat] {
        Page.allCases.map { page in
            showPage(page)
            return window?.contentView?.fittingSize.height ?? 0
        }
    }

    /// What the shortcut's page says about the permission (UI test).
    var accessText: String { accessNote.stringValue }
    var screenText: String { screenNote.stringValue }
    var loginIsTicked: Bool { loginBox.state == .on }

    /// What the About page says and offers (UI test).
    var aboutForTest: String {
        "\(updateText.stringValue.replacingOccurrences(of: "\n", with: " / ")) [\(updateButton.title)\(updateButton.isEnabled ? "" : ", off")"
            + "\(updateSpinner.isHidden ? "" : ", spinning")]; ad hoc note: \(adHocNote?.isHidden == false ? "shown" : "hidden")"
            + "; ticks: daily \(checkBox.state == .on ? "on" : "off"), automatic \(autoBox.state == .on ? "on" : "off")\(autoBox.isEnabled ? "" : " (off while the daily check is)")"
    }

    /// The "+" picker's content as it looks after typing `search` (UI test).
    func preparedPicker(search: String) -> NSView {
        languageEditor.picker.setSearch(search)
        return languageEditor.picker.view
    }

    /// Adds the picker's first match to the list; returns the list and what the picker still offers (UI test). Nothing is saved.
    func addFirstFoundLanguage() -> (list: [String], stillOffered: [String]) {
        languageEditor.picker.addFirstFound()
        return (draft().languageIDs, languageEditor.picker.foundIDs)
    }

    /// Works the list's buttons (UI test). Returns the order, the default and the second default
    /// after each step. Nothing is saved.
    func reorderForTest() -> [String] {
        func state() -> String { "\(draft().languageIDs.joined(separator: ",")) default=\(draft().defaultLanguageID) second=\(draft().secondLanguageID)" }
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
        languageEditor.select(row: languageEditor.languages.count - 1)
        languageEditor.makeSelectedSecond()
        steps.append(state())
        return steps
    }

    /// The methods "Opens with" offers now (UI test).
    var offeredMethods: [Engine] { popupMethod.offered }

    /// The method and the language each of the three opens with, as the window shows them (UI test).
    var defaultsForTest: String {
        let c = draft()
        return "popup \(c.defaultEngine.rawValue) \(c.defaultLanguageID), typing \(c.typingEngine?.rawValue ?? "none") \(c.typingLanguageID), "
            + "window \(c.windowEngine?.rawValue ?? "none") \(c.windowLanguageID)"
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
            L("Select text in any app and press the shortcut, or right-click it and choose Services → BTranslate."))
        pageControl.target = self
        pageControl.action = #selector(pageChanged)

        for box in [googleBox, aiBox, deviceBox] {
            box.target = self
            box.action = #selector(methodsChanged)
        }
        let deviceNote = caption(L("Translation on the Mac itself, without internet: BTranslate turns to it by itself when there is none, and the text stays on your Mac. macOS has about 25 languages for it (macOS 26 or later)."))
        packNote.font = .systemFont(ofSize: 11)
        packNote.textColor = .secondaryLabelColor
        packNote.isSelectable = true
        packButton.bezelStyle = .rounded
        packButton.controlSize = .small
        packButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        packButton.target = self
        packButton.action = #selector(packButtonClicked)
        packProgress.style = .bar
        packProgress.controlSize = .small
        packProgress.minValue = 0
        packProgress.maxValue = 1
        packProgress.translatesAutoresizingMaskIntoConstraints = false
        packProgress.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let packRow = NSStackView(views: [packButton, packProgress])
        packRow.spacing = 10
        PackInstaller.shared.onChange = { [weak self] in self?.refreshPack() }
        languageEditor.onDownload = { [weak self] language in
            guard let self, let window = self.window else { return }
            Task { [weak self] in
                guard let self else { return }
                if await OnDevice.needsPack(language.id) {
                    // Apple has not got this language: the language pack has. Its download shows on the first page.
                    self.showPage(.translation)
                    PackInstaller.shared.start()
                    return
                }
                // macOS downloads languages in pairs: English goes with another language of the list.
                let others = self.languageEditor.languages.filter { $0.id != language.id && self.languageEditor.offline[$0.id] != .unavailable }
                let partner = language.google == "en" ? (others.first?.google ?? "es") : "en"
                OnDevice.download(language.id, with: partner, in: window) { [weak self] in self?.refreshOffline() }
            }
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
        urlField.delegate = self
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

        let save = NSButton(title: L("Save"), target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelSettings))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, save])
        buttons.spacing = 8

        let line2 = NSBox(), line3 = NSBox()
        for line in [line2, line3] { line.boxType = .separator }
        let languagesLabel = NSTextField(labelWithString: L("Languages to translate into:"))
        let voiceNote = caption(L("The speaker buttons use your Mac's voices. It has none for some languages, such as Latvian: with this on, a text you play in one of those is sent to Google."))
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
        let translation = page([googleBox, googleNote, aiBox, aiNote, grid, deviceBox, deviceNote, packNote, packRow])
        translation.setCustomSpacing(2, after: googleBox)
        translation.setCustomSpacing(12, after: googleNote)
        translation.setCustomSpacing(2, after: aiBox)
        translation.setCustomSpacing(12, after: aiNote)
        translation.setCustomSpacing(14, after: grid)
        translation.setCustomSpacing(2, after: deviceBox)
        translation.setCustomSpacing(8, after: deviceNote)
        translation.setCustomSpacing(6, after: packNote)
        // Page 2: into which languages, reading aloud, and the language of BTranslate itself.
        languageEditor.onChange = { [weak self] in self?.refreshOtherLanguages() }
        let languages = page([languagesLabel, languageEditor.view, googleVoiceBox, voiceNote, line3, ownLanguageRow])
        languages.setCustomSpacing(14, after: languageEditor.view)
        languages.setCustomSpacing(2, after: googleVoiceBox)
        languages.setCustomSpacing(14, after: voiceNote)
        languages.setCustomSpacing(12, after: line3)
        // Page 3: the method and the language each of the three things opens with.
        for menu in [typingMenu, windowMenu] {
            menu.target = self
            menu.action = #selector(otherLanguageChanged(_:))
        }
        popupLanguage.textColor = .secondaryLabelColor
        popupLanguage.lineBreakMode = .byTruncatingTail
        popupLanguage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            return label
        }
        var rowLabels: [NSTextField] = []
        func rowLabel(_ text: String) -> NSTextField {
            rowLabels.append(NSTextField(labelWithString: text))
            return rowLabels[rowLabels.count - 1]
        }
        func with() -> NSTextField { rowLabel(L("Translate with:")) }
        func into() -> NSTextField { rowLabel(L("Translate into:")) }
        let defaultsGrid = NSGridView(views: [
            [heading(L("Selected text"))],
            [with(), popupMethod.control],
            [into(), popupLanguage],
            [heading(L("What you type in a text field"))],
            [with(), typingMethod.control],
            [into(), typingMenu],
            [heading(L("A window"))],
            [with(), windowMethod.control],
            [into(), windowMenu],
        ])
        defaultsGrid.rowSpacing = 8
        defaultsGrid.columnSpacing = 8
        defaultsGrid.yPlacement = .center
        // The first column is as wide as its labels, not as the headings, which run across both.
        defaultsGrid.column(at: 0).width = rowLabels.map { ceil($0.intrinsicContentSize.width) }.max() ?? 100
        for row in [0, 3, 6] {
            defaultsGrid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: row, length: 1))
            if row > 0 { defaultsGrid.row(at: row).topPadding = 10 }
        }
        let defaultsNote = caption(L("What each opens with. The popup, the typing panel and a translated window have the same selectors, to switch for that one time."))
        let defaults = page([defaultsNote, defaultsGrid])
        defaults.setCustomSpacing(14, after: defaultsNote)
        // Page 4: the shortcut, the permission it needs, and starting with the Mac.
        let shortcutRow = NSStackView(views: [NSTextField(labelWithString: L("Shortcut:")), shortcutField])
        shortcutRow.spacing = 8
        shortcutField.onChange = { [weak self] in self?.shortcutChanged() }
        let shortcutNote = caption(L("Press it in any app. With text selected, BTranslate translates it in its popup. With the cursor in a text field and nothing selected, it opens a small panel to type in: what you type there, in any language, is written into the field in the language you choose. Otherwise it has you choose a window, and shows it with every text translated."))
        shortcutStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shortcutStatus.textColor = .systemRed
        accessNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accessButton.target = self
        accessButton.action = #selector(openAccessSettings)
        screenNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        screenButton.target = self
        screenButton.action = #selector(openScreenSettings)
        let loginNote = caption(L("The shortcut works only while BTranslate is running. The Services menu starts BTranslate by itself; the shortcut can't."))
        let line4 = NSBox(), line5 = NSBox()
        for line in [line4, line5] { line.boxType = .separator }
        let shortcut = page([shortcutRow, shortcutStatus, shortcutNote, line4, accessNote, accessButton, screenNote, screenButton, line5, loginBox, loginNote])
        shortcut.setCustomSpacing(12, after: accessNote)
        shortcut.setCustomSpacing(14, after: screenNote)
        shortcut.setCustomSpacing(4, after: shortcutRow)
        shortcut.setCustomSpacing(4, after: shortcutStatus)
        shortcut.setCustomSpacing(14, after: shortcutNote)
        shortcut.setCustomSpacing(12, after: line4)
        shortcut.setCustomSpacing(12, after: accessButton)
        shortcut.setCustomSpacing(14, after: screenButton)
        shortcut.setCustomSpacing(12, after: line5)
        shortcut.setCustomSpacing(2, after: loginBox)
        // Page 5: about BTranslate, and its updates.
        let version = NSTextField(labelWithString: L("Version %@", Updater.shared.current))
        version.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let what = NSTextField(wrappingLabelWithString: L("Translates in any Mac app, in a popup, with Google Translate, an AI model or offline."))
        let home = NSButton(title: "", target: self, action: #selector(openHome))
        home.isBordered = false
        home.attributedTitle = NSAttributedString(string: "github.com/baakhoff/btranslate",
                                                  attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        let licence = caption(L("Free software under the MIT licence. The optional language pack's model, NLLB-200 by Meta AI, is under CC-BY-NC 4.0: non-commercial use only."))
        updateText.isSelectable = true
        updateSpinner.style = .spinning
        updateSpinner.controlSize = .small
        updateSpinner.isDisplayedWhenStopped = false
        updateButton.bezelStyle = .rounded
        updateButton.target = self
        updateButton.action = #selector(updateButtonClicked)
        // The button keeps one width, whichever it says, and the text takes what is left.
        let buttonWidth = [L("Check Now"), L("Update")].map { title -> CGFloat in
            updateButton.title = title
            return ceil(updateButton.intrinsicContentSize.width)
        }.max() ?? 100
        updateButton.widthAnchor.constraint(equalToConstant: buttonWidth).isActive = true
        let stateRow = NSStackView(views: [updateText, updateSpinner, updateButton])
        stateRow.alignment = .top
        stateRow.spacing = 8
        updateText.widthAnchor.constraint(equalToConstant: inner - buttonWidth - 16 - 16).isActive = true
        for box in [checkBox, autoBox] {
            box.target = self
            box.action = #selector(updateBoxChanged)
        }
        let adHoc = caption(L("BTranslate is signed ad hoc on this Mac: after each update macOS wants the shortcut's permissions given again. tools/local-signing.sh, in BTranslate's source, gives this Mac a certificate that keeps them."))
        adHoc.isHidden = !Updater.isSignedAdHoc
        adHocNote = adHoc
        let updateNote = caption(L("The check is one small request to GitHub a day, with nothing of yours in it. An update is the install again: the source is downloaded and built on this Mac, which takes about a minute and needs the Command Line Tools. Your settings stay. To do it by hand, run this in Terminal:"))
        let installLine = NSTextField(wrappingLabelWithString: Updater.installLine)
        installLine.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        installLine.lineBreakMode = .byCharWrapping
        installLine.isSelectable = true
        let line6 = NSBox(), line7 = NSBox()
        for line in [line6, line7] { line.boxType = .separator }
        let about = page([version, what, home, licence, line6, stateRow, checkBox, autoBox, adHoc, line7, updateNote, installLine])
        about.setCustomSpacing(4, after: version)
        about.setCustomSpacing(2, after: what)
        about.setCustomSpacing(2, after: home)
        about.setCustomSpacing(12, after: licence)
        about.setCustomSpacing(12, after: line6)
        about.setCustomSpacing(12, after: stateRow)
        about.setCustomSpacing(2, after: autoBox)
        about.setCustomSpacing(12, after: adHoc)
        about.setCustomSpacing(12, after: line7)
        about.setCustomSpacing(6, after: updateNote)
        NotificationCenter.default.addObserver(forName: Updater.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUpdate() }
        }
        pages = [translation, languages, defaults, shortcut, about]

        let stack = NSStackView(views: [title, intro, pageControl, translation, languages, defaults, shortcut, about, line2, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: intro)
        stack.setCustomSpacing(16, after: pageControl)
        stack.setCustomSpacing(16, after: translation)
        stack.setCustomSpacing(16, after: languages)
        stack.setCustomSpacing(16, after: defaults)
        stack.setCustomSpacing(16, after: shortcut)
        stack.setCustomSpacing(16, after: about)
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
        for view in [intro, googleNote, aiNote, deviceNote, packNote, voiceNote, defaultsNote, grid, line2, line3, buttons, translation, languages, defaults,
                     shortcut, shortcutNote, shortcutStatus, accessNote, screenNote, loginNote, line4, line5,
                     about, what, licence, stateRow, adHoc, updateNote, installLine, line6, line7] as [NSView] {
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
        showPage(.translation)
    }

    // MARK: Showing the saved settings

    private func fill() {
        shortcutField.shortcut = config.shortcut
        shortcutStatus.stringValue = ""
        shortcutStatus.isHidden = true
        // Ticked from the first setup on: without it the shortcut is gone after a restart of the Mac.
        loginBox.state = LoginItem.isOn || !Config.isSetUp ? .on : .off
        accessButton.isHidden = !Accessibility.isAllowed  // (refreshAccess goes by a change of these)
        screenButton.isHidden = !ScreenAccess.isAllowed
        refreshAccess()
        AISetup.forget()  // a key may have come or gone since the window was last open
        googleBox.state = config.googleEnabled ? .on : .off
        aiBox.state = config.aiEnabled ? .on : .off
        deviceBox.isEnabled = OnDevice.isAvailable
        deviceBox.state = config.deviceEnabled && OnDevice.isAvailable ? .on : .off
        PackInstaller.shared.lookAgain()
        refreshPack()
        refreshOffline()
        providerMenu.selectItem(at: providers.firstIndex { $0.id == config.providerID } ?? 0)
        urlField.stringValue = config.customURL
        popupMethod.chosen = config.defaultEngine
        typingMethod.chosen = config.typingEngine ?? config.defaultEngine
        windowMethod.chosen = config.windowEngine ?? config.defaultEngine
        typingID = config.typingLanguageID
        windowID = config.windowLanguageID
        languageEditor.languages = config.targets
        languageEditor.defaultID = config.startTarget.id
        languageEditor.secondID = config.secondTarget?.id ?? ""
        googleVoiceBox.state = config.googleVoice ? .on : .off
        languageMenu.selectItem(at: (interfaceLanguages.firstIndex { $0.code == config.languageChoice } ?? -1) + 1)
        setStatus("", color: .secondaryLabelColor)
        showProvider(keepModel: config.model)
        refreshEnabled()
        checkBox.state = config.checkForUpdates ? .on : .off
        autoBox.state = config.autoUpdate ? .on : .off
        refreshUpdate()
    }

    // MARK: About, and updates

    /// The update's state in words, and the one button beside it.
    private func refreshUpdate() {
        let updater = Updater.shared
        updateText.stringValue = updater.stateText
        switch updater.state {
        case .failed, .updateFailed: updateText.textColor = .systemRed
        default: updateText.textColor = .labelColor
        }
        var offersUpdate = updater.waitingVersion != nil
        if case .updating = updater.state { offersUpdate = true }
        updateButton.title = offersUpdate ? L("Update") : L("Check Now")
        updateButton.isEnabled = !updater.isBusy
        if updater.isBusy { updateSpinner.startAnimation(nil) } else { updateSpinner.stopAnimation(nil) }
        updateSpinner.isHidden = !updater.isBusy
        autoBox.isEnabled = checkBox.state == .on
        if let window, let content = window.contentView, shownPage == .about, window.isVisible {
            let top = NSPoint(x: window.frame.minX, y: window.frame.maxY)  // the text's height may have changed
            window.setContentSize(content.fittingSize)
            window.setFrameTopLeftPoint(top)
        }
    }

    @objc private func updateButtonClicked() {
        if Updater.shared.waitingVersion != nil {
            Updater.shared.update(asked: true)
        } else {
            Task { await Updater.shared.check() }
        }
    }

    @objc private func updateBoxChanged() {
        autoBox.isEnabled = checkBox.state == .on
    }

    @objc private func openHome() {
        guard Accessibility.mayAsk, let url = URL(string: "https://github.com/baakhoff/btranslate") else { return }
        NSWorkspace.shared.open(url)
    }

    private func showProvider(keepModel: String? = nil) {
        let provider = selectedProvider
        modelBox.removeAllItems()
        modelBox.addItems(withObjectValues: provider.models)
        modelBox.stringValue = keepModel ?? provider.models.first ?? ""
        urlRow?.isHidden = provider.id != "custom"
        keyField.stringValue = ""
        let saved = AISetup.hasKey(provider.id)
        keyField.placeholderString = saved ? L("Saved in your Keychain. Paste a new key to replace it.") : L("Paste your API key")
        keyHelp.stringValue = provider.keyHelp + " " + L("The key is stored in your Mac's Keychain.")
        loadModels()
    }

    private func refreshEnabled() {
        let ai = aiBox.state == .on
        for control in [providerMenu, modelBox, urlField, keyField, testButton] as [NSControl] { control.isEnabled = ai }
        for l in aiLabels { l.textColor = ai ? .labelColor : .disabledControlTextColor }
        // "Opens with" offers the methods a popup would: the ones that are on, and the AI
        // model only once it has what it needs.
        let typedKey = !keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let aiReady = ai && (selectedProvider.id == "custom"
                             ? !urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             : typedKey || AISetup.hasKey(selectedProvider.id))
        var offered: [Engine] = (googleBox.state == .on ? [.google] : []) + (aiReady ? [.ai] : []) + (deviceBox.state == .on ? [.device] : [])
        if offered.isEmpty { offered = [.google] }
        popupMethod.offer(offered)
        typingMethod.offer(offered, otherwise: popupMethod.shown)
        windowMethod.offer(offered, otherwise: popupMethod.shown)
    }

    private var packKind = ""  // "downloading", "installed"…: the state the page was last made to fit
    private var offlineTask: Task<Void, Never>?

    private func refreshPack() {
        func megabytes(_ bytes: Int) -> String { L("%ld MB", bytes / 1_000_000) }
        var note = "", button = L("Download"), color = NSColor.secondaryLabelColor
        packProgress.isHidden = true
        packProgress.stopAnimation(nil)
        packButton.isHidden = false
        switch PackInstaller.shared.state {
        case .absent:
            note = L("Language pack NLLB-200 (Meta AI): about 140 more languages for it, Latvian and Serbian among them, on the Neural Engine. %@; non-commercial use only.",
                     megabytes(LanguagePack.megabytes * 1_000_000))
        case .waiting:
            note = L("The language pack will be downloaded as soon as there is an internet connection.")
            button = L("Cancel")
        case .downloading(let done, let total):
            note = L("Downloading the language pack: %@ of %@.", megabytes(done), megabytes(total))
            button = L("Cancel")
            packProgress.isHidden = false
            packProgress.isIndeterminate = false
            packProgress.doubleValue = total > 0 ? Double(done) / Double(total) : 0
        case .preparing:
            note = L("macOS is preparing the language pack for the Neural Engine. This takes up to a minute, once.")
            packButton.isHidden = true
            packProgress.isHidden = false
            packProgress.isIndeterminate = true
            packProgress.startAnimation(nil)
        case .installed:
            note = L("Language pack NLLB-200 is installed: about 140 more languages. It runs on the Neural Engine and leaves memory after each translation.")
            button = L("Remove")
        case .failed(let why):
            note = why
            color = .systemRed
        }
        packNote.stringValue = note
        packNote.textColor = color
        packButton.title = button
        // The rest only when the state is another one, not for every megabyte of a download.
        let kind = String(String(describing: PackInstaller.shared.state).prefix { $0 != "(" })
        guard kind != packKind else { return }
        packKind = kind
        // With the pack a Mac has an Offline method even where macOS has none of its own.
        let was = deviceBox.isEnabled
        deviceBox.isEnabled = OnDevice.isAvailable
        if deviceBox.isEnabled != was { deviceBox.state = deviceBox.isEnabled && config.deviceEnabled ? .on : .off }
        refreshEnabled()
        refreshOffline()
        if let window, let content = window.contentView, shownPage == .translation, window.isVisible {
            let top = NSPoint(x: window.frame.minX, y: window.frame.maxY)  // the text's height may have changed
            window.setContentSize(content.fittingSize)
            window.setFrameTopLeftPoint(top)
        }
    }

    @objc private func packButtonClicked() {
        switch PackInstaller.shared.state {
        case .downloading, .waiting: PackInstaller.shared.cancel()
        case .installed: PackInstaller.shared.remove()
        case .preparing: break
        default: PackInstaller.shared.startWhenPossible()
        }
    }

    /// Asks which languages the Offline method has, for the marks in the language lists.
    private func refreshOffline() {
        offlineTask?.cancel()  // one question at a time: an older answer must not land on a newer one
        offlineTask = Task { [weak self] in
            let statuses = await OnDevice.statuses(of: allTargets.map(\.id))
            guard !Task.isCancelled else { return }
            self?.languageEditor.offline = statuses
        }
    }

    /// The same, waited for (UI test).
    func loadOfflineForTest() async -> [String: OfflineStatus] {
        if window == nil { build() }
        let statuses = await OnDevice.statuses(of: allTargets.map(\.id))
        languageEditor.offline = statuses
        return statuses
    }

    /// Whether Download is offered once the list's row `row` is selected (UI test).
    func downloadOfferedForTest(row: Int) -> Bool {
        languageEditor.select(row: row)
        return languageEditor.canDownloadSelected
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshOffline()  // a language may have been downloaded or removed in System Settings meanwhile
    }

    func windowDidResignKey(_ notification: Notification) {
        shortcutField.stop()  // while it records, no shortcut is listened for
    }

    private func setStatus(_ text: String, color: NSColor) {
        status.stringValue = text
        status.textColor = color
    }

    // MARK: The languages to write in, and to translate a window into

    /// Both menus' languages are the list's, as it stands in the window. The one shown is the
    /// one chosen, or else the second default for writing (see Config.typingTarget) and the
    /// default for a window (Config.windowTarget).
    private func refreshOtherLanguages() {
        let list = languageEditor.languages
        func show(_ shown: Target?, in menu: NSPopUpButton) {
            menu.removeAllItems()
            menu.addItems(withTitles: list.map(\.name))
            if let shown, let index = list.firstIndex(of: shown) { menu.selectItem(at: index) }
        }
        show(list.first { $0.id == typingID } ?? languageEditor.secondLanguage ?? languageEditor.defaultLanguage, in: typingMenu)
        show(list.first { $0.id == windowID } ?? languageEditor.defaultLanguage, in: windowMenu)
        popupLanguage.stringValue = L("%@, the default language of your list", languageEditor.defaultLanguage?.name ?? "")
    }

    @objc private func otherLanguageChanged(_ menu: NSPopUpButton) {
        let list = languageEditor.languages
        guard list.indices.contains(menu.indexOfSelectedItem) else { return }
        if menu === typingMenu { typingID = list[menu.indexOfSelectedItem].id } else { windowID = list[menu.indexOfSelectedItem].id }
    }

    /// The language to write in, as the menu shows it: at first, with the list's first language
    /// chosen in the menu, and after that language is taken off the list (UI test). Nothing is saved.
    func typingForTest() -> [String] {
        var steps = [draft().typingLanguageID]
        typingMenu.selectItem(at: 0)
        otherLanguageChanged(typingMenu)
        steps.append(draft().typingLanguageID)
        languageEditor.select(row: 0)
        languageEditor.removeSelected()
        steps.append(draft().typingLanguageID)
        return steps
    }

    // MARK: The shortcut's page

    private func refreshAccess() {
        let allowed = Accessibility.isAllowed
        accessNote.stringValue = allowed
            ? L("✓ macOS lets BTranslate read the selected text of the app in front, and write into its text fields.")
            : L("The shortcut needs your permission. BTranslate reads the selected text of the app in front, and writes into its text fields, through macOS's Accessibility: turn BTranslate on in System Settings → Privacy & Security → Accessibility. If it is on there already and this still says so, take BTranslate off that list with “–” and add it again: macOS drops the permission when the app is updated.")
        accessNote.textColor = allowed ? .secondaryLabelColor : .labelColor
        let screen = ScreenAccess.isAllowed
        screenNote.stringValue = screen
            ? L("✓ macOS lets BTranslate take the picture of a window you choose.")
            : L("To translate a window, macOS needs one more permission, to record the screen: it asks the first time you choose a window. The switch is in System Settings → Privacy & Security → Screen & System Audio Recording. BTranslate takes a picture only of the window you choose, when you choose it.")
        screenNote.textColor = screen ? .secondaryLabelColor : .labelColor
        if accessButton.isHidden != allowed || screenButton.isHidden != screen {
            accessButton.isHidden = allowed
            screenButton.isHidden = screen
            if shownPage == .shortcut { showPage(.shortcut) }  // the page's height has changed
        }
    }

    @objc private func openScreenSettings() {
        ScreenAccess.ask()  // macOS puts BTranslate on its list, to be turned on there
        ScreenAccess.openSystemSettings()
    }

    @objc private func openAccessSettings() {
        Accessibility.ask()
        Accessibility.openSystemSettings()
    }

    private func shortcutChanged() {
        if let wanted = shortcutField.shortcut, !HotkeyCenter.shared.isFree(wanted) {
            shortcutStatus.stringValue = L("macOS would not have %@ as a shortcut. Choose another one.", wanted.text)
        } else {
            shortcutStatus.stringValue = ""
        }
        shortcutStatus.isHidden = shortcutStatus.stringValue.isEmpty
        if shownPage == .shortcut { showPage(.shortcut) }
    }

    /// The settings as the window shows them now.
    private func draft() -> Config {
        var c = config
        c.shortcut = shortcutField.shortcut
        c.googleEnabled = googleBox.state == .on
        c.aiEnabled = aiBox.state == .on
        if OnDevice.isAvailable { c.deviceEnabled = deviceBox.state == .on }
        c.providerID = selectedProvider.id
        c.model = modelBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.customURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.defaultEngine = popupMethod.shown
        c.typingEngine = typingMethod.shown
        c.windowEngine = windowMethod.shown
        c.languageIDs = languageEditor.languages.map(\.id)
        c.defaultLanguageID = languageEditor.defaultLanguage?.id ?? ""
        c.secondLanguageID = languageEditor.secondLanguage?.id ?? ""
        let listed = languageEditor.languages
        c.typingLanguageID = listed.indices.contains(typingMenu.indexOfSelectedItem) ? listed[typingMenu.indexOfSelectedItem].id : ""
        c.windowLanguageID = listed.indices.contains(windowMenu.indexOfSelectedItem) ? listed[windowMenu.indexOfSelectedItem].id : ""
        c.googleVoice = googleVoiceBox.state == .on
        let chosen = languageMenu.indexOfSelectedItem - 1  // -1: the first item, "Same as the Mac"
        c.languageChoice = interfaceLanguages.indices.contains(chosen) ? interfaceLanguages[chosen].code : ""
        c.checkForUpdates = checkBox.state == .on
        c.autoUpdate = c.checkForUpdates && autoBox.state == .on
        return c
    }

    private func currentKey() -> String {
        let typed = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (AISetup.key(selectedProvider.id) ?? "") : typed
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
        if googleBox.state == .off && aiBox.state == .off && deviceBox.state == .off {  // at least one method stays on
            googleBox.state = .on
        }
        refreshEnabled()
    }

    @objc private func providerChanged() {
        testTask?.cancel()  // its answer would be shown for the other provider
        setStatus("", color: .secondaryLabelColor)
        showProvider(keepModel: selectedProvider.id == config.providerID ? config.model : nil)
        refreshEnabled()
    }

    /// A key or an address typed in: the AI model may be on offer in "Opens with" now.
    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === keyField || (obj.object as? NSTextField) === urlField { refreshEnabled() }
    }

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
        shortcutField.stop()  // still recording: the shortcut that was listened for is put back first
        let c = draft()
        let typed = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = problem(c, key: currentKey()) {
            showPage(.translation)  // where the message shows
            setStatus(p, color: .systemRed)
            return
        }
        if let wanted = c.shortcut, !HotkeyCenter.shared.isFree(wanted) {
            showPage(.shortcut)
            shortcutChanged()
            return
        }
        // Nothing is kept before everything has been found in order: the key comes after the checks.
        if c.aiEnabled && !typed.isEmpty {
            let saved = Keychain.save(typed, account: c.providerID)
            AISetup.forget()
            if !saved {
                showPage(.translation)
                setStatus(L("The key could not be saved to the Keychain."), color: .systemRed)
                return
            }
        }
        if (loginBox.state == .on) != LoginItem.isOn, let why = LoginItem.set(loginBox.state == .on) {
            shortcutStatus.stringValue = L("macOS did not change the login items: %@", why)
            shortcutStatus.isHidden = false
            showPage(.shortcut)
            return
        }
        AISetup.forget()
        let languageChanged = c.languageChoice != config.languageChoice
        c.save()
        config = c
        (NSApp.delegate as? AppDelegate)?.useShortcut()
        window?.close()
        // The app takes its language when it starts: start it anew, in the background. (Not
        // in the middle of the language pack's download: then it holds from the next start.)
        if languageChanged, !PackInstaller.shared.isBusy { (NSApp.delegate as? AppDelegate)?.restart() }
    }

    @objc private func cancelSettings() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        accessTimer?.invalidate()
        accessTimer = nil
        shortcutField.stop()
        modelTask?.cancel()
        testTask?.cancel()
        languageEditor.picker.popover.close()
        keyField.stringValue = ""
        (NSApp.delegate as? AppDelegate)?.handBack()  // back to the app you were in
    }
}
