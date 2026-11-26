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
//   BTranslate --print [--engine google|ai] [--to Russian] "text"   print a translation
//   BTranslate --models                                             print the provider's models
//   BTranslate --selftest                                           checks that need no network
//   BTranslate --keychain-test                                      save, read and delete a dummy key
//   BTranslate --uitest DIR                                         draw the popup and the settings
//                                                                   window into DIR as PNGs, off screen
//   Env: BTRANSLATE_PROVIDER, BTRANSLATE_MODEL, BTRANSLATE_BASE_URL, BTRANSLATE_API_KEY,
//        BTRANSLATE_GOOGLE_URL override the saved settings.

import Cocoa

final class ServiceProvider: NSObject {
    // NSMessage "translateText" in Info.plist → translateText:userData:error:
    @objc func translateText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { error.pointee = "No text is selected."; return }
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
        if let i = args.firstIndex(of: "--text"), i + 1 < args.count {
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
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit BTranslate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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

/// Nothing appears on screen: the settings window and a popup are built, drawn into PNG files,
/// and the popup is checked to stay where it was moved to when it translates again.
@MainActor
func runUITest(into dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let content = SettingsController.shared.preparedContent() {
        snapshot(content, to: dir + "/settings.png")
    }
    let popup = Popup(text: argument(after: "--text") ?? "Labdien! Kā jums klājas? Rīt es būšu birojā no deviņiem līdz pieciem.")
    Popup.current = popup
    var round = 0
    var movedTo = NSPoint.zero
    popup.onSettled = {
        round += 1
        if round == 1 {
            if let view = popup.panel.contentView { snapshot(view, to: dir + "/popup.png") }
            print("popup text: \(popup.shownText)")
            // Move the panel as a drag would, then translate again, as a language switch does.
            let f = popup.panel.frame
            movedTo = NSPoint(x: f.minX + 180, y: f.maxY + 90)
            popup.panel.setFrameTopLeftPoint(movedTo)
            popup.start()
        } else {
            let f = popup.panel.frame
            let kept = abs(f.minX - movedTo.x) < 1 && abs(f.maxY - movedTo.y) < 1
            print("popup stays where it was moved: \(kept ? "yes" : "NO (moved to \(f.origin))")")
            exit(kept ? 0 : 1)
        }
    }
    popup.start()
}

let arguments = CommandLine.arguments
if arguments.contains("--selftest") {
    let failures = selfTest()
    print(failures.isEmpty ? "selftest: ok" : "selftest FAILED: " + failures.joined(separator: "; "))
    exit(failures.isEmpty ? 0 : 1)
} else if arguments.contains("--keychain-test") {
    let account = "selftest", value = "dummy-KEY_\(ProcessInfo.processInfo.processIdentifier)"
    let saved = Keychain.save(value, account: account)
    let replaced = Keychain.save(value + "-2", account: account) && Keychain.read(account) == value + "-2"
    Keychain.delete(account)
    let ok = saved && replaced && Keychain.read(account) == nil
    print(ok ? "keychain: ok" : "keychain FAILED (saved: \(saved), replaced: \(replaced))")
    exit(ok ? 0 : 1)
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
} else if arguments.contains("--print") {
    runHeadless {
        let config = Config.load()
        let engine: Engine = argument(after: "--engine").flatMap(Engine.init(rawValue:)) ?? config.startEngine
        let wanted = (argument(after: "--to") ?? "English").lowercased()
        let target = targets.first { $0.name.lowercased() == wanted } ?? targets[0]
        var updates = 0
        var last: (String?, String) = (nil, "")
        do {
            try await translate(arguments.last ?? "", engine: engine, target: target, config: config) { code, text in
                updates += 1
                last = (code, text)
            }
            print("source: \(last.0.map(languageName) ?? "?") | updates: \(updates)")
            print(last.1)
            return 0
        } catch {
            print("ERROR: \(describe(error))")
            return 1
        }
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
