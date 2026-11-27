// BTranslate
//
// Adds "BTranslate" to the Services menu: the selected text's translation appears in a small
// floating panel by the pointer, and the app you are in stays in front. The same from any app
// with a shortcut (⌃⌥T unless another is set): with text selected, its translation; in a text
// field, a panel to type in another language; otherwise a window of your choice, translated
// as a picture (Sources/Hotkey.swift, Sources/Focus.swift). Opening BTranslate itself
// (Spotlight, Finder) shows its settings.
//
// Command line (BTranslate MODE …), for tests. Where a mode takes --picture DIR, it also draws
// what it made into DIR.
//   --print [--engine google|ai|device] [--from lv] [--to Russian|ru] "text"
//                                  print a translation (device: the Offline method)
//   --offline [FROM TO]            whether this Mac has the Offline method, its languages, and
//                                  whether a pair of them is downloaded
//   --pack                         whether the NLLB-200 language pack is installed, and where
//   --pack-install | --pack-remove  download and install it (from BTRANSLATE_PACK_URL if set), or remove it
//   --pack-compile FOLDER | --pack-prepare  (the app's own helpers) compile a downloaded pack's models,
//                                  and have macOS prepare them for the Neural Engine: the gigabytes
//                                  that takes go with this process
//   --pack-check FILE              the pack's tokenizer against Meta's (tests/nllb-tokens.json), and
//                                  that the model is let go after a translation
//   --pack-languages               which of Google's languages the pack has, and under which of its codes
//   --detect "text"                what the pack's detector, the Mac's recognizer and both together
//                                  make of a text's language
//   --detect-check FILE [DETECTOR]  the detector's arithmetic against the Python that made its file
//                                  (tests/detect-vectors.json)
//   --detect-eval FILE [DETECTOR] [--own en,ru]  how often a text's language is told right, over
//                                  "language<tab>kind<tab>text" lines (tools/nllb/README.md)
//   --download-check               the Download button's way to macOS, without a download: with
//                                  English and German both there already, macOS answers at once
//   --popup-check "text" [--download] [--speak] [--picture DIR]  a popup made off screen (runPopupCheck)
//   --offline-uitest switch|wait|settings DIR  the popup without a connection and the settings'
//                                  offline marks, drawn into DIR off screen (tests/run.sh sets each up)
//   --speech-check CODE "text"     which voice would read a text in that language; the audio is
//                                  made, and played at volume zero
//   --screen-check                 show a popup for a few seconds and report what a still picture
//                                  can't: which app stays in front, typing reaching the pencil's search
//   --login on|off|status          BTranslate among the login items
//   --shortcut-check               the shortcut as the settings keep it, and whether macOS takes one
//   --shortcut-page [--picture DIR]  the settings' page for it, off screen
//   --type-check "text" [--field live|none|stuck] [--to LANGUAGE] [--esc] [--picture DIR]
//                                  the panel for typing in another language, off screen (runTypeCheck)
//   --picture-make FILE            draw a picture that stands for a window
//   --picture-check FILE [--engine …] [--to …] [--picture DIR]
//                                  read a picture as a window's is read, translate its texts, print them
//   --picture-window-check FILE [--picture DIR]  the window that shows it, off screen
//   --read-picture LANGUAGES       (the app's own helper) a picture on standard input, its lines as JSON
//   --prepare-reading              have macOS make its reader of pictures ready (the installer and
//                                  the app do)
//   --ax-check appkit|input|textarea[-empty]|editable[-full]
//                                  write into a real text field of another process and read its
//                                  selection; needs the Accessibility permission (runAXCheck)
//   --models                       print the provider's models
//   --selftest                     checks that need no network
//   --prompts                      how an AI model is told each language
//   --cyrillize "text"             Serbian in Latin letters → Cyrillic
//   --keychain-test                save, read and delete a dummy key
//   --language-test                choose Russian for BTranslate as its settings do, read the choice
//                                  back, and put back what was chosen
//   --uitest DIR                   draw the popup and the settings window into DIR as PNGs, off screen
//   --background                   the app itself, without its settings window (as after an update)
// Env: BTRANSLATE_KEYCHAIN=off is a Mac without saved API keys, BTRANSLATE_CONNECTION=off one
//      without a network; BTRANSLATE_ACCESSIBILITY=on|off and BTRANSLATE_SCREEN=on|off stand
//      for macOS's answers about the permissions, BTRANSLATE_LOGIN=on|off for its login items:
//      none is then asked or changed; BTRANSLATE_PROVIDER, BTRANSLATE_MODEL, BTRANSLATE_BASE_URL,
//      BTRANSLATE_API_KEY, BTRANSLATE_GOOGLE_URL, BTRANSLATE_GOOGLE_SPEECH_URL override the saved
//      settings and Google's addresses; BTRANSLATE_LANGUAGE=en|ru sets the language of
//      BTranslate's own texts; BTRANSLATE_OFFLINE=mock stands in for Apple's translation;
//      BTRANSLATE_PACK_DIR is where the language pack is kept instead of Application Support.

import Cocoa

final class ServiceProvider: NSObject {
    // NSMessage "translateText" in Info.plist → translateText:userData:error:
    @objc func translateText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { error.pointee = L("No text is selected.") as NSString; return }
        Task { @MainActor in
            (NSApp.delegate as? AppDelegate)?.servedRequest = true
            showPopup(text)
        }
    }
}

/// The app has no Dock icon and stays running once started (~25 MB), so the Services menu
/// reaches it without launching it again. A popup never makes it the active app; when macOS
/// activates it anyway (launching it does), it hands the front straight back to your app.
/// Only the settings window makes it the active app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let provider = ServiceProvider()
    var previousApp: NSRunningApplication?
    var handBackUntil = Date().addingTimeInterval(5)
    var servedRequest = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        LoginItem.noteStart()
        remember(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.remember(app) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Connection.shared  // it starts watching the network now, to know later whether there is one
        NSRegisterServicesProvider(provider, "BTranslate")  // = NSPortName in Info.plist
        buildMenu()
        HotkeyCenter.shared.onPress = { [weak self] in self?.shortcutPressed() }
        useShortcut()
        // The first reading of a picture can take macOS a minute: have it done now, apart.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { PictureReader.prepare() }
        if !CommandLine.arguments.contains("--background"),
                  !LoginItem.startedThisRun,
                  notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true {
            // Started by you, not by the Services menu: show the settings. (A moment's wait
            // makes sure no translation request came with the launch.)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.servedRequest else { return }
                self.showSettings()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc func showSettings() {
        handBackUntil = .distantPast
        Popup.current?.close()
        SettingsController.shared.show()
    }

    /// Listens for the shortcut of the settings.
    func useShortcut() {
        let shortcut = Config.load().shortcut
        if !HotkeyCenter.shared.use(shortcut) { Log.note("shortcut: macOS would not have \(shortcut?.saved ?? "")") }
    }

    private var looking = false          // a press is being looked into: another one meanwhile is left alone
    private var asked: Set<pid_t> = []   // the apps that were asked to show their text fields (see below)

    /// The shortcut, pressed in whatever app is in front. With text selected there: its
    /// translation in a popup. In a text field with nothing selected: the panel to type in
    /// another language. Otherwise: a window of your choice, translated as a picture.
    /// Pressed while one of those is showing, it puts it away.
    func shortcutPressed() {
        // Two presses looked into at once would each save and put back the other's clipboard.
        guard !looking else { return }
        if let popup = Popup.current { popup.close(); return }
        if let typing = TypePanel.current { typing.putAway(); return }
        if WindowShot.shared.isChoosing { WindowShot.shared.cancel(); return }
        if let picture = PictureWindow.current, picture.panel.isKeyWindow { picture.close(); return }
        // What is selected, and where the cursor is, macOS tells only with your permission.
        guard Accessibility.isAllowed else {
            Log.note("shortcut: no permission to read the app in front")
            showSettings()
            SettingsController.shared.showPage(2)
            Accessibility.ask()
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        var focus = Focus.read()
        looking = true
        // An app built with Electron shows its text fields to other apps only once it is
        // asked, and takes a moment over it: read again until it has, for up to a second.
        // Once per app: asked a second time it says yes again, with nothing new to show.
        let firstAsk = focus.waking && (focus.app.map { asked.insert($0.processIdentifier).inserted } ?? false)
        Task { @MainActor in
            defer { self.looking = false }
            var tries = 0
            while firstAsk, focus.selection == nil, focus.field == nil, tries < 10 {
                await waitOut(0.1)
                tries += 1
                let again = Focus.read()
                if again.selection != nil || again.field != nil || !again.waking { focus = again }
            }
            if focus.selection == nil, focus.field == nil, let app = focus.app {
                // The app does not say what is selected: its own Copy command does.
                if let copied = await Focus.copiedSelection(of: app) {
                    focus.selection = copied
                } else {
                    let again = Focus.read()  // an app that keeps its interface to itself until asked has answered by now
                    if again.selection != nil || again.field != nil { focus = again }
                }
            }
            let text = focus.selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let app = focus.app?.bundleIdentifier ?? "?"
            if !text.isEmpty {
                Log.note("shortcut: \(text.count) characters selected in \(app) (\(focus.role))")
                self.servedRequest = true
                showPopup(text, by: focus.place)
            } else if let field = focus.field {
                Log.note("shortcut: a text field in \(app) (\(focus.role))")
                showTypePanel(for: field)
            } else {
                Log.note("shortcut: nothing selected and no text field in \(app) (\(focus.role))")
                WindowPicture.start()
            }
        }
    }

    func remember(_ app: NSRunningApplication?) {
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = app }
    }

    /// Makes the app you were in the active app again.
    func handBack() {
        if let app = previousApp, !app.isTerminated {
            NSApp.yieldActivation(to: app)
            app.activate(options: [])
        } else {
            NSApp.deactivate()
        }
    }

    /// Starts the app anew, in the background, as after an update. (A change of BTranslate's
    /// own language needs it: macOS fixes an app's language when the app starts.)
    func restart() {
        let again = Process()
        again.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait until this one is gone (the Services menu knows one BTranslate), then open the app.
        // (A moment more: macOS itself has to know that it is gone, or `open` turns to the one that was.)
        again.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; sleep 0.5; "
                               + "/usr/bin/open -g \"$0\" --args --background || { sleep 1; exec /usr/bin/open -g \"$0\" --args --background; }",
                           Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        guard (try? again.run()) != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }  // after the front is handed back
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if Date() < handBackUntil && !SettingsController.shared.isVisible { handBack() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if let popup = Popup.current { popup.panel.makeKey() }  // keep Esc and ⌘C working in the panel
    }

    /// A menu bar is never shown for this app, but its shortcuts work in the settings window.
    private func buildMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit BTranslate"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: L("Window"))
        window.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for menu in [appMenu, edit, window] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }
}

// MARK: - Command line

func argument(after flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Runs an async job for a command-line mode, then exits with its status.
func runHeadless(_ job: @escaping @MainActor () async -> Int32) -> Never {
    Task { @MainActor in exit(await job()) }
    RunLoop.main.run()
    exit(0)
}

/// Writes a view to a PNG without it being on screen.
@MainActor
func snapshot(_ view: NSView, to path: String) {
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    // Start from about the window's background, light or dark: the view draws no background itself.
    let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: dark ? 0.16 : 0.93, alpha: 1).setFill()
    NSRect(origin: .zero, size: rep.size).fill()
    NSGraphicsContext.restoreGraphicsState()
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// The labels and buttons under `view` whose text does not fit their frame. (Table rows are
/// left out: they cut a long name short on purpose.)
@MainActor
func cutOffTexts(in view: NSView) -> [String] {
    if view.isHidden || view is NSTableView { return [] }
    var found: [String] = []
    if let label = view as? NSTextField {
        if label.isEditable, let hint = label.placeholderString, let font = label.font {  // a field's grey hint
            if (hint as NSString).size(withAttributes: [.font: font]).width > label.frame.width - 10 { found.append(hint) }
        } else if !label.isEditable, !label.stringValue.isEmpty, let cell = label.cell {
            let wide = label.intrinsicContentSize.width > label.frame.width + 0.5
            let tall = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)).height > label.frame.height + 0.5
            if cell.wraps ? tall : wide { found.append(label.stringValue) }
        }
    } else if let control = view as? NSControl, control is NSButton || control is NSSegmentedControl,
              control.intrinsicContentSize.width > control.frame.width + 0.5 {
        found.append((control as? NSButton)?.title ?? "segmented control")
    }
    return found + view.subviews.flatMap(cutOffTexts)
}

/// Nothing appears on screen: the settings window and a popup are built, drawn into PNG files,
/// and the popup is checked to stay where it was moved to when it translates again.
@MainActor
func runUITest(into dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let content = SettingsController.shared.preparedContent(page: 0) {
        snapshot(content, to: dir + "/settings.png")
    }
    if let content = SettingsController.shared.preparedContent(page: 1) {
        snapshot(content, to: dir + "/settings-languages.png")
    }
    if let content = SettingsController.shared.preparedContent(page: 2) {
        snapshot(content, to: dir + "/settings-shortcut.png")
    }
    snapshot(SettingsController.shared.preparedPicker(search: "ser"), to: dir + "/languages.png")
    // Add a language through the picker: it joins the list and leaves the picker.
    let before = Config.load().targets.map(\.id)
    let added = SettingsController.shared.addFirstFoundLanguage()
    let addedOK = added.list.count == before.count + 1 && added.list.dropLast().elementsEqual(before)
        && !added.stillOffered.contains(added.list.last ?? "")
    print("picker adds a language to the list: \(addedOK ? "yes" : "NO (\(before) → \(added.list))")")
    if !addedOK { exit(1) }
    let steps = SettingsController.shared.reorderForTest()
    print("list buttons: \(steps.joined(separator: " → "))")
    print("language to write in: \(SettingsController.shared.typingForTest().joined(separator: " → "))")
    if let content = SettingsController.shared.currentContent {
        snapshot(content, to: dir + "/settings-reordered.png")
        print("settings pages are \(Int(SettingsController.shared.pageHeights.0)) and \(Int(SettingsController.shared.pageHeights.1)) points tall")
    }
    // A translation can be longer than the English text the window was laid out for.
    var cut: [String] = []
    for page in 0...2 {
        if let content = SettingsController.shared.preparedContent(page: page) {
            content.layoutSubtreeIfNeeded()
            cut += cutOffTexts(in: content)
        }
    }
    let choices = SettingsController.shared.languageChoicesForTest().map { $0.isEmpty ? "the Mac's" : $0 }
    print("language menu: \(choices.joined(separator: ", "))")
    print("interface language: \(interfaceLanguage)")
    print("settings window, every text fits: \(cut.isEmpty ? "yes" : "NO (\(cut.joined(separator: " | ")))")")
    if !cut.isEmpty { exit(1) }

    let popup = Popup(text: "Labdien! Kā jums klājas? Rīt es būšu birojā no deviņiem līdz pieciem.")
    Popup.current = popup
    popup.prepare()
    let lithuanian = sourceLanguages.first { $0.id == "lt" }?.name ?? "Lithuanian"  // as the bar shows it

    let picker = popup.makeSourcePicker()
    picker.setSearch("lat")
    snapshot(picker.view, to: dir + "/source-picker.png")
    print("source picker finds: \(picker.foundIDs.prefix(4).joined(separator: ", "))")

    var round = 0
    var movedTo = NSPoint.zero
    popup.onSettled = {
        round += 1
        switch round {
        case 1:
            if let view = popup.panel.contentView { snapshot(view, to: dir + "/popup.png") }
            print("popup text: \(popup.shownText)")
            // Move the panel as a drag would, to a place well inside the screen, then translate
            // again, as a language switch does.
            let screen = (popup.panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            movedTo = NSPoint(x: screen.midX - 137, y: screen.midY + 61)
            popup.panel.setFrameTopLeftPoint(movedTo)
            popup.start()
        case 2:
            let f = popup.panel.frame
            let kept = abs(f.minX - movedTo.x) < 1 && abs(f.maxY - movedTo.y) < 1
            print("popup stays where it was moved: \(kept ? "yes" : "NO (moved to \(f.origin))")")
            if !kept { exit(1) }
            let others = popup.config.targets.filter { other in !popup.sections.contains { $0.target == other } }
            if others.isEmpty {
                print("several languages at once: skipped (the list has one language)")
                popup.setSource(sourceLanguages.first { $0.id == "lt" }, remember: false)
            }
            for other in others.prefix(2) { popup.addLanguage(other) }
        case 3 where popup.sections.count > 1 && popup.shownSource != lithuanian:
            if let view = popup.panel.contentView { snapshot(view, to: dir + "/popup-several.png") }
            let texts = popup.shownTexts
            let several = popup.sections.allSatisfy { !$0.translation.isEmpty } && Set(texts).count == texts.count  // (an error is no translation)
            print("several languages at once: \(several ? "yes" : "NO") (\(popup.sections.map(\.target.id).joined(separator: ", ")))")
            if !several { exit(1) }
            popup.setSource(sourceLanguages.first { $0.id == "lt" }, remember: false)
        default:
            if let view = popup.panel.contentView { snapshot(view, to: dir + "/popup-source-set.png") }
            let set = popup.shownSource == lithuanian
            print("the original's language can be set by hand: \(set ? "yes" : "NO (bar says \(popup.shownSource))")")
            exit(set ? 0 : 1)
        }
    }
    popup.start()
}

/// The popup without a connection, off screen. Google's address is one that does not answer
/// (tests/run.sh sets it), so the first translation fails as it does without internet:
///   switch   the Offline method is on: the popup goes over to it; a language it has not got
///            waits, and the first method takes over again when the connection is back
///   wait     the Offline method is off: the popup waits, and translates when the connection is back
/// After the first result, a second language of the list is added, then the connection "comes back".
@MainActor
func runOfflineUITest(_ scenario: String, into dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let popup = Popup(text: "Guten Tag! Ich bin morgen von neun bis fünf im Büro.")
    Popup.current = popup
    popup.prepare()
    var stage = "without a connection"
    var pictures = 0
    func report() {
        pictures += 1
        if let view = popup.panel.contentView { snapshot(view, to: "\(dir)/offline-\(scenario)-\(pictures).png") }
        let texts = popup.shownTexts.map { $0.replacingOccurrences(of: "\n", with: " / ") }.joined(separator: " | ")
        print("\(scenario), \(stage): method \(popup.engine.rawValue), no connection shown: \(popup.showsNoConnection ? "yes" : "no"), texts: \(texts)")
    }
    var steps: [(String, () -> Void)] = []
    if let other = popup.config.targets.first(where: { other in !popup.sections.contains { $0.target == other } }) {
        steps.append(("a second language added", { popup.addLanguage(other) }))
    }
    steps.append(("the connection is back", { popup.connectionIsBack() }))
    func next() {
        report()
        while !steps.isEmpty {
            let (name, step) = steps.removeFirst()
            stage = name
            step()
            if !popup.sections.allSatisfy(\.settled) { return }  // it translates again: the next report comes when it has
            report()
        }
        exit(0)
    }
    popup.onSettled = { next() }
    popup.start()
}

/// A popup made off screen for a text. Prints the methods it offers and, for each language
/// it translates into, what it shows and whether the language pack is offered under it.
/// --download then presses the offer's button and prints the popup again once the pack is
/// there; --speak presses the first speaker button (without sound) and prints the popup's note.
@MainActor
func runPopupCheck(text: String) {
    let popup = Popup(text: text)
    Popup.current = popup
    popup.prepare()
    var pressed = false
    func report(_ stage: String) {
        print("\(stage): methods \(popup.config.engines.map(\.rawValue).joined(separator: ", ")); the original: \(popup.shownSource)")
        for (section, offered) in zip(popup.sections, popup.packOffered) {
            let shown = section.textView.string.replacingOccurrences(of: "\n", with: " / ")
            print("   \(section.target.id): \(shown)\(offered ? " [\(section.packButton.title)]" : "")")
        }
        if let dir = argument(after: "--picture"), let view = popup.panel.contentView {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            snapshot(view, to: "\(dir)/popup-check\(pressed ? "-after" : "").png")
        }
    }
    popup.onSettled = {
        report(pressed ? "with the pack" : "popup")
        if arguments.contains("--speak") {
            // Never a sound from a check.
            Speaker.shared.volume = 0
            popup.pressSpeaker()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    Speaker.shared.stop()
                    print("the speaker's notice: \(popup.shownNotice ?? "none")")
                    if let dir = argument(after: "--picture"), let view = popup.noticeView { snapshot(view, to: "\(dir)/popup-notice.png") }
                    popup.close()
                    exit(0)
                }
            }
            return
        }
        guard arguments.contains("--download"), !pressed, popup.packOffered.contains(true) else { exit(0) }
        pressed = true
        _ = NotificationCenter.default.addObserver(forName: PackInstaller.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if case .failed(let why) = PackInstaller.shared.state {
                    report("the download failed (\(why))")
                    exit(1)
                }
            }
        }
        popup.downloadPack()
        if PackInstaller.shared.state == .waiting {  // no network: the download is put off until there is one
            report("waiting for a connection")
            exit(0)
        }
    }
    popup.start()
}

/// The settings window's offline marks and Download button, off screen.
@MainActor
func runOfflineSettingsTest(into dir: String) async {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    _ = SettingsController.shared.preparedContent(page: 0)
    let statuses = await SettingsController.shared.loadOfflineForTest()
    var cut: [String] = []
    for (page, name) in [(0, "offline-settings"), (1, "offline-languages")] {
        guard let content = SettingsController.shared.preparedContent(page: page) else { continue }
        content.layoutSubtreeIfNeeded()
        cut += cutOffTexts(in: content)
        snapshot(content, to: "\(dir)/\(name).png")
    }
    let list = Config.load().targets
    print("offline marks: \(list.map { "\($0.id) \(statuses[$0.id]?.rawValue ?? "none")" }.joined(separator: ", "))")
    let offered = list.indices.map { "\(list[$0].id) \(SettingsController.shared.downloadOfferedForTest(row: $0) ? "yes" : "no")" }
    print("Download offered: \(offered.joined(separator: ", "))")
    _ = SettingsController.shared.preparedContent(page: 0)
    print("opens with: \(SettingsController.shared.offeredMethods.map(\.rawValue).joined(separator: ", "))")
    print("settings pages are \(Int(SettingsController.shared.pageHeights.0)) and \(Int(SettingsController.shared.pageHeights.1)) points tall")
    print("settings window, every text fits: \(cut.isEmpty ? "yes" : "NO (\(cut.joined(separator: " | ")))")")
    exit(cut.isEmpty ? 0 : 1)
}

/// Shows a real popup by the pointer for about two seconds, opens the pencil's picker, types
/// into it and closes it with Esc. Prints what it saw. Nothing is clicked in other apps.
@MainActor
func runScreenCheck() {
    func front() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }
    func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
    }
    let before = front()
    let popup = Popup(text: "Labdien! Kā jums klājas?")
    Popup.current = popup
    popup.show()
    var activeAt: [String] = []
    var becameActive = false
    func note(_ step: String) {
        // The system's view of who is active. (NSApp.isActive is AppKit's own flag and is
        // set whenever a panel of the app has the keyboard, in front or not.)
        let active = NSRunningApplication.current.isActive || front() != before
        if active { becameActive = true }
        activeAt.append("\(step): \(active ? "ACTIVE" : "no")")
    }
    after(0.7) {
        print("popup: on screen \(popup.panel.isVisible ? "yes" : "NO"), takes the keyboard \(popup.panel.isKeyWindow ? "yes" : "NO")")
        note("popup shown")
        popup.toggleSourcePicker()  // what a click on the pencil does
        after(0.4) {
            note("picker open")
            let opened = popup.sourcePickerState
            popup.pressInSourcePicker("l")
            popup.pressInSourcePicker("a")
            popup.pressInSourcePicker("t")
            after(0.3) {
                let typed = popup.sourcePickerState
                note("typed")
                print("pencil's picker: open \(opened.open ? "yes" : "NO"), takes the keyboard \(opened.key ? "yes" : "NO"), "
                    + "search field focused \(opened.searchFocused ? "yes" : "NO")")
                print("typing \"lat\" finds: \(typed.found.prefix(3).joined(separator: ", "))")
                popup.pressInSourcePicker("\u{1b}", keyCode: 53)  // Esc closes the picker, not the popup
                after(0.3) {
                    let closed = popup.sourcePickerState
                    print("Esc: picker closed \(closed.open ? "NO" : "yes"), popup still open \(popup.panel.isVisible ? "yes" : "NO"), "
                        + "popup has the keyboard again \(popup.panel.isKeyWindow ? "yes" : "NO")")
                    note("picker closed")
                    print("app in front: \(before) before, \(front()) after")
                    let first = opened.open && opened.key && opened.searchFocused && typed.found.prefix(3) == ["ltg", "la", "lv"]
                        && !closed.open && popup.panel.isVisible && popup.panel.isKeyWindow
                    // Open it again, type a language and press Return: the popup translates anew.
                    let recent = UserDefaults.standard.stringArray(forKey: "recentSources")
                    popup.toggleSourcePicker()
                    after(0.3) {
                        for ch in "lithu" { popup.pressInSourcePicker(String(ch)) }
                        after(0.2) {
                            popup.pressInSourcePicker("\r", keyCode: 36)
                            after(0.3) {
                                note("language picked")
                                UserDefaults.standard.set(recent, forKey: "recentSources")  // leave your list of recent ones alone
                                let lithuanian = sourceLanguages.first { $0.id == "lt" }?.name ?? "Lithuanian"
                                let picked = !popup.sourcePickerState.open && popup.shownSource == lithuanian && popup.panel.isKeyWindow
                                print("Return on \"lithu\": picker closed \(popup.sourcePickerState.open ? "NO" : "yes"), "
                                    + "the bar now says \(popup.shownSource)")
                                // Add another language of your list, as + does, and wait for both translations.
                                let others = popup.config.targets.filter { other in !popup.sections.contains { $0.target == other } }
                                @MainActor func finish(_ several: Bool) {
                                    note("language added")
                                    print("BTranslate the active app? \(activeAt.joined(separator: ", "))")
                                    let ok = first && picked && several && !becameActive
                                    popup.close()
                                    print(ok ? "screen check: ok" : "screen check: FAILED")
                                    exit(ok ? 0 : 1)
                                }
                                guard let other = others.first else {
                                    print("a second language: skipped (your list has one language)")
                                    finish(true)
                                    return
                                }
                                let heightBefore = popup.panel.frame.height, topBefore = popup.panel.frame.maxY
                                var done = false
                                popup.onSettled = {
                                    guard !done else { return }
                                    done = true
                                    let texts = popup.shownTexts
                                    let grew = popup.panel.frame.height > heightBefore + 20
                                    let several = texts.count == 2 && popup.sections.allSatisfy { !$0.translation.isEmpty } && grew
                                        && popup.panel.isKeyWindow
                                    print("+ \(other.name): \(texts.count) translations showing, popup \(Int(heightBefore)) → \(Int(popup.panel.frame.height)) points tall, "
                                        + "top edge \(abs(popup.panel.frame.maxY - topBefore) < 1 || popup.panel.frame.maxY < topBefore ? "in place" : "MOVED UP")")
                                    finish(several)
                                }
                                popup.addLanguage(other)
                                after(12) { if !done { done = true; print("+ \(other.name): no translation after 12 s"); finish(false) } }
                            }
                        }
                    }
                }
            }
        }
    }
}

let arguments = CommandLine.arguments
setlinebuf(stdout)        // read through a pipe (the installer's progress), a line must not wait for the end
signal(SIGPIPE, SIG_IGN)  // a helper that ends early must not take the app with it
if arguments.contains("--selftest") {
    let failures = selfTest()
    print(failures.isEmpty ? "selftest: ok" : "selftest FAILED: " + failures.joined(separator: "; "))
    exit(failures.isEmpty ? 0 : 1)
} else if arguments.contains("--prompts") {
    // The same lines whatever BTranslate's own language is: the tests compare them.
    for language in (allTargets + sourceLanguages).sorted(by: { ($0.id, $0.prompt) < ($1.id, $1.prompt) }) {
        print("\(language.id)\t\(language.prompt)")
    }
    exit(0)
} else if arguments.contains("--cyrillize") {
    print(cyrillize(arguments.last ?? ""))  // to try the rules
    exit(0)
} else if arguments.contains("--keychain-test") {
    let account = "selftest", value = "dummy-KEY_\(ProcessInfo.processInfo.processIdentifier)"
    let saved = Keychain.save(value, account: account)
    let replaced = Keychain.save(value + "-2", account: account) && Keychain.read(account) == value + "-2"
    Keychain.delete(account)
    let ok = saved && replaced && Keychain.read(account) == nil
    print(ok ? "keychain: ok" : "keychain FAILED (saved: \(saved), replaced: \(replaced))")
    exit(ok ? 0 : 1)
} else if arguments.contains("--language-test") {
    let was = chosenInterfaceLanguage()
    let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"]
    chooseInterfaceLanguage("ru")
    let russian = chosenInterfaceLanguage() == "ru"
    chooseInterfaceLanguage("")
    let theMacs = chosenInterfaceLanguage().isEmpty
    // Put back exactly what was there, also a language BTranslate does not come in.
    if let stored { UserDefaults.standard.set(stored, forKey: "AppleLanguages") }
    let ok = russian && theMacs && chosenInterfaceLanguage() == was
    print(ok ? "language choice: ok" : "language choice FAILED (Russian chosen: \(russian), the Mac's again: \(theMacs))")
    exit(ok ? 0 : 1)
} else if arguments.contains("--pack-languages") {
    for (code, name) in googleLanguages {
        print("\(code)\t\(NLLBLanguage.code(code) ?? "-")\t\(name)")
    }
    exit(0)
} else if arguments.contains("--pack") {
    if let pack = LanguagePack.installed() {
        print("language pack: installed, version \(pack.version), \(pack.languages.count) languages, sentences of up to \(pack.length) tokens")
    } else {
        print("language pack: not installed")
        print("download: \(LanguagePack.megabytes) MB")
    }
    print("folder: \(LanguagePack.folder.path)")
    exit(0)
} else if arguments.contains("--pack-remove") {
    LanguagePack.remove()
    print("language pack: removed")
    exit(0)
} else if arguments.contains("--pack-install") {
    runHeadless {
        let installer = PackInstaller.shared
        var said = ""
        installer.onChange = {
            var line = ""
            switch installer.state {
            case .downloading(let done, let total): line = total > 0 ? "downloading: \(done * 10 / total * 10)%" : ""
            case .preparing: line = "preparing the model for the Neural Engine"
            default: break
            }
            if !line.isEmpty, line != said { print(line); said = line }
        }
        installer.start()
        while installer.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
        switch installer.state {
        case .installed: print("language pack: installed"); return 0
        case .failed(let why): print("language pack: FAILED: \(why)"); return 1
        default: print("language pack: not installed (\(installer.state))"); return 1
        }
    }
} else if let folder = argument(after: "--pack-compile") {
    runHeadless {
        do {
            try await NLLBEngine.compile(in: URL(fileURLWithPath: folder))
            return 0
        } catch {
            print(error.localizedDescription)  // the app shows it
            return 1
        }
    }
} else if arguments.contains("--pack-prepare") {
    runHeadless {
        do {
            try await NLLBEngine.shared.prepare()
            return 0
        } catch {
            print(error.localizedDescription)  // the app shows it
            return 1
        }
    }
} else if let file = argument(after: "--pack-check") {
    runHeadless {
        struct Case: Decodable { let text: String; let ids: [Int32]; let back: String }
        guard let manifest = LanguagePack.installed() else { print("pack check: skipped (the language pack is not installed)"); return 0 }
        guard let cases = (try? Data(contentsOf: URL(fileURLWithPath: file))).flatMap({ try? JSONDecoder().decode([Case].self, from: $0) }) else {
            print("pack check: can't read \(file)"); return 1
        }
        do {
            let started = Date()
            let tokenizer = try NLLBTokenizer(file: LanguagePack.folder.appendingPathComponent("tokens.tsv"), unknown: manifest.unknown)
            let loaded = Date().timeIntervalSince(started)
            var wrong = 0
            for item in cases {
                let ids = tokenizer.encode(item.text), back = tokenizer.decode(item.ids)
                if ids != item.ids || back != item.back {
                    wrong += 1
                    print("DIFFERENT: \(item.text.debugDescription)\n   mine \(ids)\n   Meta \(item.ids)\n   back \(back.debugDescription) / \(item.back.debugDescription)")
                }
            }
            print(String(format: "tokenizer: %d of %d texts as Meta's tokenizer has them (vocabulary read in %.2f s)", cases.count - wrong, cases.count, loaded))
            let started2 = Date()
            let text = try await NLLBEngine.shared.translate("Sveiki! Vai jūs varētu pateikt, cikos rīt sākas sapulce?", from: "lvs_Latn", to: "rus_Cyrl") { _ in }
            print(String(format: "translation (%.1f s): %@", Date().timeIntervalSince(started2), text))
            print("model let go after the translation: \(NLLBEngine.shared.isLoaded ? "NO" : "yes")")
            return wrong == 0 && !NLLBEngine.shared.isLoaded && !text.isEmpty ? 0 : 1
        } catch {
            print("pack check: FAILED: \(describe(error))")
            return 1
        }
    }
} else if let file = argument(after: "--detect-check") {
    struct Case: Decodable {
        let text: String
        let best: [Best]
        struct Best: Decodable {
            let label: String, chance: Double
            init(from decoder: Decoder) throws {
                var pair = try decoder.unkeyedContainer()
                label = try pair.decode(String.self)
                chance = try pair.decode(Double.self)
            }
        }
    }
    let other = Array(arguments.drop { $0 != "--detect-check" }.dropFirst(2)).first.flatMap { $0.hasPrefix("-") ? nil : $0 }
    guard let detector = other.map({ PackDetector(file: URL(fileURLWithPath: $0)) }) ?? PackDetector.installed() else {
        print("detector check: skipped (the language pack is not installed, or has no detector)")
        exit(0)
    }
    guard let cases = (try? Data(contentsOf: URL(fileURLWithPath: file))).flatMap({ try? JSONDecoder().decode([Case].self, from: $0) }) else {
        print("detector check: can't read \(file)")
        exit(1)
    }
    var wrong = 0
    let started = Date()
    for item in cases {
        let mine = detector.chances(of: item.text, count: 3)
        let same = mine.count == item.best.count && zip(mine, item.best).allSatisfy { abs($0.chance - $1.chance) < 0.002 && ($0.label == $1.label || abs($0.chance - $1.chance) < 0.0002 && $1.chance < 0.001) }
        if !same {
            wrong += 1
            print("DIFFERENT: \(item.text.debugDescription)\n   mine \(mine)\n   file \(item.best.map { ($0.label, $0.chance) })")
        }
    }
    print(String(format: "detector: %d of %d texts as the Python that made it has them (%.1f ms a text)", cases.count - wrong, cases.count,
                 1000 * Date().timeIntervalSince(started) / Double(max(cases.count, 1))))
    // And what the app makes of the detector's scores: shares of 1, nothing for a text
    // without a letter, more for a language that is one of the user's own.
    var rules = true
    for item in cases where OnDevice.prepared(item.text).contains(where: { $0 != " " }) {
        let plain = OnDevice.guesses(for: item.text, own: [], with: detector)
        guard plain.count > 1, abs(plain.reduce(0) { $0 + $1.chance } - 1) < 1e-6 else { rules = false; continue }
        let second = plain[1].code
        let boosted = OnDevice.guesses(for: item.text, own: [second], with: detector)
        if plain[1].chance > 1e-9, (boosted.first { $0.code == second }?.chance ?? 0) <= plain[1].chance { rules = false }
    }
    if !OnDevice.guesses(for: "12345 !!! 🙂", own: [], with: detector).isEmpty { rules = false }
    print("detector's answers as shares, and the user's languages counting for more: \(rules ? "yes" : "NO")")
    exit(wrong == 0 && rules ? 0 : 1)
} else if let text = argument(after: "--detect") {
    guard let detector = PackDetector.installed() else {
        print("detector: the language pack is not installed, or has no detector")
        exit(0)
    }
    let own = OnDevice.ownLanguages
    let started = Date()
    let guesses = OnDevice.guesses(for: text, own: own, with: detector)
    let took = 1000 * Date().timeIntervalSince(started)
    print("the detector alone: " + detector.chances(of: OnDevice.prepared(text), count: 3).map { "\($0.label) \(String(format: "%.2f", $0.chance))" }.joined(separator: ", "))
    print("the Mac's recognizer: " + OnDevice.macGuesses(text, count: 3).map { "\($0.code) \(String(format: "%.2f", $0.chance))" }.joined(separator: ", "))
    print("together, with your languages (\(own.joined(separator: ", "))): "
          + guesses.prefix(3).map { "\($0.code) \(String(format: "%.2f", $0.chance))" }.joined(separator: ", "))
    if let best = guesses.first, best.chance >= OnDevice.sureEnough, OnDevice.packHas(best.code) {
        print(String(format: "taken for: %@ (%.1f ms)", languageName(best.code), took))
    } else {
        print(String(format: "not sure enough: the popup would ask (%.1f ms)", took))
    }
    exit(0)
} else if let file = argument(after: "--detect-eval") {
    // The file's lines are "language<tab>kind<tab>text", with Google's codes; the kinds are counted apart.
    let other = Array(arguments.drop { $0 != "--detect-eval" }.dropFirst(2)).first.flatMap { $0.hasPrefix("-") ? nil : $0 }
    guard let detector = other.map({ PackDetector(file: URL(fileURLWithPath: $0)) }) ?? PackDetector.installed(),
          let lines = try? String(contentsOfFile: file, encoding: .utf8) else {
        print("can't read the file, or there is no detector")
        exit(1)
    }
    let own = argument(after: "--own")?.split(separator: ",").map(String.init) ?? []
    let macKnows = Set("ar bg bn bo ca cs da de el en es fi fr gu iw hi hr hu hy id is it ja ka kk km kn ko lo ml mr my no nl or pa pl pt ro ru si sk sv ta te th tr uk ur vi zh-CN zh-TW".split(separator: " ").map(String.init))
    func plain(_ code: String) -> String { ["bs": "hr", "fa-AF": "fa"][code] ?? code }  // told apart by nobody, and one to the translator
    struct Count { var texts = 0, right = 0, answered = 0, rightAnswers = 0, oldRight = 0 }
    var counts: [String: [Count]] = [:]  // by kind: all, the Mac's languages, the others
    var kinds: [String] = []
    let apple = Set(macKnows.map { OnDevice.language($0).languageCode?.identifier ?? $0 })
    for line in lines.split(separator: "\n") {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3 else { continue }
        if counts[fields[1]] == nil { counts[fields[1]] = [Count(), Count(), Count()]; kinds.append(fields[1]) }
        let truth = own.contains("sr") && ["hr", "bs"].contains(fields[0]) ? "sr" : plain(fields[0])
        let best = OnDevice.guesses(for: fields[2], own: own, with: detector).first
        let old = OnDevice.recognize(fields[2], among: apple)
        for group in [0, macKnows.contains(fields[0]) ? 1 : 2] {
            counts[fields[1]]![group].texts += 1
            if let best, plain(best.code) == truth {
                counts[fields[1]]![group].right += 1
                if best.chance >= OnDevice.sureEnough { counts[fields[1]]![group].rightAnswers += 1 }
            }
            if let best, best.chance >= OnDevice.sureEnough { counts[fields[1]]![group].answered += 1 }
            if let old, plain(old) == truth { counts[fields[1]]![group].oldRight += 1 }
        }
    }
    func share(_ a: Int, _ b: Int) -> String { String(format: "%.1f%%", 100 * Double(a) / Double(max(b, 1))) }
    for kind in kinds {
        for (group, name) in ["all languages", "the Mac's 52", "the others"].enumerated() {
            let c = counts[kind]![group]
            print("\(kind), \(name) (\(c.texts) texts): best guess right \(share(c.right, c.texts)); answered \(share(c.answered, c.texts)), "
                  + "of the answers right \(share(c.rightAnswers, c.answered)); without the pack's detector right \(share(c.oldRight, c.texts))")
        }
    }
    exit(0)
} else if arguments.contains("--offline") {
    runHeadless {
        guard OnDevice.isAvailable else {
            print("offline method: not on this Mac (it needs macOS 26 or later)")
            return 0
        }
        print("offline method: yes; languages: \(await OnDevice.supportedLanguages().sorted().joined(separator: " "))")
        let pair = Array(arguments.drop { $0 != "--offline" }.dropFirst().prefix(2))
        if pair.count == 2 { print("\(pair[0]) → \(pair[1]): \(await OnDevice.status(from: pair[0], to: pair[1]).rawValue)") }
        return 0
    }
} else if arguments.contains("--models") {
    runHeadless {
        let config = Config.load()
        do {
            let list = try await listModels(config: config, key: Keychain.read(config.providerID) ?? "")
            print(list.joined(separator: "\n"))
            return 0
        } catch {
            print("ERROR: \(describe(error))")
            return 1
        }
    }
} else if let code = argument(after: "--speech-check") {
    runHeadless {
        let googleVoice = Config.load().googleVoice
        let made = await speechCheck(arguments.last ?? "", code: code, googleVoice: googleVoice)
        print(made)
        if made.contains("ERROR") || made.hasPrefix("no voice") { return made.contains("ERROR") ? 1 : 0 }
        let played = await playSilently(arguments.last ?? "", code: code, googleVoice: googleVoice)
        print(played)
        return played.contains("ERROR") ? 1 : 0
    }
} else if arguments.contains("--print") {
    runHeadless {
        let config = Config.load()
        let engine: Engine = argument(after: "--engine").flatMap(Engine.init(rawValue:)) ?? config.startEngine
        guard let target = findTarget(argument(after: "--to") ?? "English") else {
            print("ERROR: no such language. Give its name or code, such as Russian or ru.")
            return 1
        }
        var from: Target?
        if let wanted = argument(after: "--from") {
            guard let found = findTarget(wanted, in: sourceLanguages) else {
                print("ERROR: no such language to translate from. Give its name or code, such as Latvian or lv.")
                return 1
            }
            from = found
        }
        var updates = 0
        var last: (String?, String) = (nil, "")
        do {
            try await translate(arguments.last ?? "", engine: engine, target: target, source: from, config: config) { code, text in
                updates += 1
                last = (code, text)
            }
            print("source: \(last.0.map { languageName($0) } ?? "?") | updates: \(updates)")
            print(last.1)
            return 0
        } catch {
            print("ERROR: \(describe(error))")
            return 1
        }
    }
} else if let languages = argument(after: "--read-picture") {
    exit(PictureReader.readForTheApp(languages: languages))
} else if arguments.contains("--prepare-reading") {
    // macOS makes its reader of pictures ready for a program the first time it reads one, which
    // takes some twenty seconds: the installer and the app have it done here, in the background.
    MainActor.assumeIsolated {
        let made = NSTemporaryDirectory() + "btranslate-prepare-\(ProcessInfo.processInfo.processIdentifier).png"
        let drawn = makeTestPicture(at: made)
        let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: made) as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        try? FileManager.default.removeItem(atPath: made)  // (not in a `defer`: this ends with exit())
        guard drawn, let image else { exit(1) }
        let start = Date()
        let lines = (try? PictureReader.lines(in: image, languages: [])) ?? []
        print(String(format: "reading is ready: %d lines in %.1f s", lines.count, Date().timeIntervalSince(start)))
        exit(lines.isEmpty ? 1 : 0)
    }
} else if let wanted = argument(after: "--login") {
    MainActor.assumeIsolated {
        if wanted == "on" || wanted == "off", let why = LoginItem.set(wanted == "on") {
            print("ERROR: \(why)")
            exit(1)
        }
        print("opens at login: \(LoginItem.isOn ? "yes" : "no")")
        exit(0)
    }
} else if arguments.contains("--shortcut-check") {
    runHeadless { runShortcutCheck() }
} else if arguments.contains("--shortcut-page") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        exit(runShortcutPageCheck())
    }
} else if let text = argument(after: "--type-check") {
    runHeadless { await runTypeCheck(text) }
} else if let file = argument(after: "--picture-make") {
    runHeadless { makeTestPicture(at: file) ? 0 : 1 }
} else if let file = argument(after: "--picture-check") {
    runHeadless { await runPictureCheck(file) }
} else if let file = argument(after: "--picture-window-check") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        runPictureWindowCheck(file)
        app.run()
    }
} else if let kind = argument(after: "--ax-target") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AXTarget.shared = AXTarget(kind: kind, file: arguments.last ?? "")
        app.run()
    }
} else if let kind = argument(after: "--ax-check") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in exit(await runAXCheck(kind)) }
        app.run()
    }
} else if arguments.contains("--screen-check") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        runScreenCheck()
        app.run()
    }
} else if arguments.contains("--download-check") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            guard await OnDevice.status(from: "en", to: "de") == .installed else {
                print("download check: skipped (English and German are not both downloaded on this Mac)")
                exit(0)
            }
            // macOS asks from a view in a window: this one is far off every screen.
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 100), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.orderFrontRegardless()
            OnDevice.download("de", with: "en", in: window) {
                print("download check: ok (macOS answered; nothing needed downloading)")
                exit(0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                print("download check: FAILED (macOS never answered)")
                exit(1)
            }
        }
        app.run()
    }
} else if let text = argument(after: "--popup-check") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        runPopupCheck(text: text)
        app.run()
    }
} else if let scenario = argument(after: "--offline-uitest") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let dir = arguments.last ?? "."
        if scenario == "settings" {
            Task { @MainActor in await runOfflineSettingsTest(into: dir) }
        } else {
            runOfflineUITest(scenario, into: dir)
        }
        app.run()
    }
} else if let dir = argument(after: "--uitest") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        runUITest(into: dir)
        app.run()
    }
} else if let unknown = arguments.dropFirst().first(where: { $0.hasPrefix("--") && $0 != "--background" }) {
    // Not the app itself by mistake: a second one running would answer the shortcut too.
    FileHandle.standardError.write(Data("BTranslate: unknown option \(unknown), or one without its value. Sources/main.swift lists them.\n".utf8))
    exit(2)
} else {
    // One BTranslate at a time: two would both answer the shortcut. (macOS sees to that for
    // one copy of the app, not for two copies in different folders.)
    let lock = open(NSTemporaryDirectory() + "io.github.baakhoff.btranslate.lock", O_CREAT | O_RDWR, 0o600)
    if lock >= 0, flock(lock, LOCK_EX | LOCK_NB) != 0 {
        FileHandle.standardError.write(Data("BTranslate is running already.\n".utf8))
        exit(0)
    }
    MainActor.assumeIsolated {  // top-level code runs on the main thread
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
