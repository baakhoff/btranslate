// BTranslate
//
// Adds "BTranslate" to the Services menu: select text in any app, right-click it and choose
// Services → BTranslate (or give it a keyboard shortcut in System Settings → Keyboard →
// Keyboard Shortcuts → Services). The translation appears in a small floating panel next to
// the mouse pointer, and the app you are in stays in front. Esc, ⌘W or a click anywhere
// else closes the panel.
//
// Open BTranslate itself (Spotlight, Finder) for its settings: the translation methods, the
// AI provider, model and API key, and the method a popup opens with.
//
// Command line, for tests:
//   BTranslate --print [--engine google|ai|device] [--from lv] [--to Russian|ru] "text"
//                                                                   print a translation (device: the
//                                                                   Offline method)
//   BTranslate --offline [FROM TO]                                  say whether this Mac has the Offline
//                                                                   method, its languages, and whether
//                                                                   a pair of them is downloaded
//   BTranslate --pack                                               say whether the NLLB-200 language
//                                                                   pack is installed, and where
//   BTranslate --pack-install | --pack-remove                       download and install it (from
//                                                                   BTRANSLATE_PACK_URL if set), or remove it
//   BTranslate --pack-check FILE                                    check the pack's tokenizer against
//                                                                   Meta's (tests/nllb-tokens.json), and
//                                                                   that the model is let go after a translation
//   BTranslate --pack-languages                                     which of Google's languages the pack
//                                                                   has, and under which of its codes
//   BTranslate --download-check                                     the Download button's way to macOS,
//                                                                   without a download: for English and
//                                                                   German, if both are there already,
//                                                                   macOS answers at once and shows nothing
//   BTranslate --offline-uitest switch|wait|settings DIR            the popup without a connection and
//                                                                   the settings' offline marks, drawn
//                                                                   into DIR off screen (tests/run.sh
//                                                                   says how each is set up)
//   BTranslate --speech-check CODE "text"                           say which voice would read a
//                                                                   text in that language, make the
//                                                                   audio, and play it at volume zero
//   BTranslate --screen-check                                       show a popup for a few seconds and
//                                                                   report what a still picture can't:
//                                                                   which app stays in front, and that
//                                                                   typing reaches the pencil's search
//   BTranslate --models                                             print the provider's models
//   BTranslate --selftest                                           checks that need no network
//   BTranslate --prompts                                            how an AI model is told each language
//   BTranslate --cyrillize "text"                                   Serbian in Latin letters → Cyrillic
//   BTranslate --keychain-test                                      save, read and delete a dummy key
//   BTranslate --language-test                                      choose Russian for BTranslate as its
//                                                                   settings do, read the choice back,
//                                                                   and put back what was chosen
//   open -g BTranslate.app --args --background --restart-check      (while it is not running) the app
//                                                                   starts itself anew once, as it does
//                                                                   after a change of its language
//   BTranslate --uitest DIR                                         draw the popup and the settings
//                                                                   window into DIR as PNGs, off screen
//   Env: BTRANSLATE_PROVIDER, BTRANSLATE_MODEL, BTRANSLATE_BASE_URL, BTRANSLATE_API_KEY,
//        BTRANSLATE_GOOGLE_URL override the saved settings; BTRANSLATE_LANGUAGE=en|ru sets
//        the language of BTranslate's own texts (and of what these modes print from them);
//        BTRANSLATE_OFFLINE=mock stands in for Apple's translation (Sources/OnDevice.swift);
//        BTRANSLATE_PACK_DIR is where the language pack is kept instead of Application Support.

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
        remember(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.remember(app) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSRegisterServicesProvider(provider, "BTranslate")  // = NSPortName in Info.plist
        buildMenu()
        let args = CommandLine.arguments
        if args.contains("--restart-check") {
            restart()  // a check of restart(): the app started anew has no such argument
        } else if let i = args.firstIndex(of: "--text"), i + 1 < args.count {
            showPopup(args[i + 1])
        } else if args.contains("--settings") {
            showSettings()
        } else if !args.contains("--background"),
                  notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true {
            // Started by you, not by the Services menu: show the settings. (A moment's wait
            // makes sure no translation request came with the launch.)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.servedRequest else { return }
                self.showSettings()
            }
        }
    }

    /// Opening the app while it runs shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc func showSettings() {
        handBackUntil = .distantPast
        Popup.current?.close()
        SettingsController.shared.show()
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
        again.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open -g \"$0\" --args --background",
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
    snapshot(SettingsController.shared.preparedPicker(search: "ser"), to: dir + "/languages.png")
    // Add a language through the picker: it joins the list and leaves the picker.
    let before = Config.load().targets.map(\.id)
    let added = SettingsController.shared.addFirstFoundLanguage()
    let addedOK = added.list.count == before.count + 1 && added.list.dropLast().elementsEqual(before)
        && !added.stillOffered.contains(added.list.last ?? "")
    print("picker adds a language to the list: \(addedOK ? "yes" : "NO (\(before) → \(added.list))")")
    if !addedOK { exit(1) }
    // The list's buttons: the last language up one place, made the default, the first one down.
    let steps = SettingsController.shared.reorderForTest()
    print("list buttons: \(steps.joined(separator: " → "))")
    if let content = SettingsController.shared.currentContent {
        snapshot(content, to: dir + "/settings-reordered.png")
        print("settings pages are \(Int(SettingsController.shared.pageHeights.0)) and \(Int(SettingsController.shared.pageHeights.1)) points tall")
    }
    // A translation can be longer than the English text the window was laid out for.
    var cut: [String] = []
    for page in 0...1 {
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

    let popup = Popup(text: argument(after: "--text") ?? "Labdien! Kā jums klājas? Rīt es būšu birojā no deviņiem līdz pieciem.")
    Popup.current = popup
    popup.prepare()
    let lithuanian = sourceLanguages.first { $0.id == "lt" }?.name ?? "Lithuanian"  // as the bar shows it

    // The pencil's picker, as it looks after typing "lat".
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
            // Move the panel as a drag would, to a place well inside the screen (wherever the
            // pointer is), then translate again, as a language switch does.
            let screen = (popup.panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            movedTo = NSPoint(x: screen.midX - 137, y: screen.midY + 61)
            popup.panel.setFrameTopLeftPoint(movedTo)
            popup.start()
        case 2:
            let f = popup.panel.frame
            let kept = abs(f.minX - movedTo.x) < 1 && abs(f.maxY - movedTo.y) < 1
            print("popup stays where it was moved: \(kept ? "yes" : "NO (moved to \(f.origin))")")
            if !kept { exit(1) }
            // Add two more languages of the list, as + does one at a time.
            let others = popup.config.targets.filter { other in !popup.sections.contains { $0.target == other } }
            if others.isEmpty {
                print("several languages at once: skipped (the list has one language)")
                popup.setSource(sourceLanguages.first { $0.id == "lt" }, remember: false)
            }
            for other in others.prefix(2) { popup.addLanguage(other) }
        case 3 where popup.sections.count > 1 && popup.shownSource != lithuanian:
            if let view = popup.panel.contentView { snapshot(view, to: dir + "/popup-several.png") }
            let texts = popup.shownTexts
            let several = texts.allSatisfy { !$0.isEmpty && $0 != L("Translating…") } && Set(texts).count == texts.count
            print("several languages at once: \(several ? "yes" : "NO") (\(popup.sections.map(\.target.id).joined(separator: ", ")))")
            if !several { exit(1) }
            // Set the original's language by hand, as picking it with the pencil does.
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
    let popup = Popup(text: argument(after: "--text") ?? "Guten Tag! Ich bin morgen von neun bis fünf im Büro.")
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
    let popup = Popup(text: argument(after: "--text") ?? "Labdien! Kā jums klājas?")
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
                                    let several = texts.count == 2 && texts.allSatisfy { !$0.isEmpty && $0 != L("Translating…") } && grew
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
    print(cyrillize(arguments.last ?? ""))  // Serbian in Latin letters → Cyrillic, to try the rules
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
    chooseInterfaceLanguage("ru")
    let russian = chosenInterfaceLanguage() == "ru"
    chooseInterfaceLanguage("")
    let theMacs = chosenInterfaceLanguage().isEmpty
    chooseInterfaceLanguage(was)
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
            // A translation, and then the model must be gone again.
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
} else {
    MainActor.assumeIsolated {  // top-level code runs on the main thread
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
