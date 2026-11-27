import Cocoa
import WebKit

// Checks of the shortcut's three things, run from the command line (Sources/main.swift lists
// them). None shows a window, makes macOS ask for a permission or touches the clipboard,
// but for --ax-check, which says so.

/// Before any of them: macOS is never asked for a permission, and the shortcut's log is left alone.
@MainActor
func beginCheck() {
    Accessibility.mayAsk = false
    Log.isOn = false
}

// MARK: - The shortcut

/// The shortcut as the settings keep it and as it is shown, and whether macOS takes one.
/// (The one tried is ⌃⌥⇧⌘F19: nobody has it, and it is let go at once.)
@MainActor
func runShortcutCheck() -> Int32 {
    beginCheck()
    let saved = Config.load().shortcut
    print("shortcut: \(saved?.text ?? "none") (kept as \"\(saved?.saved ?? "")\")")
    let rare = Shortcut(saved: "control+option+shift+command+80")!  // F19
    let taken = HotkeyCenter.shared.use(rare)
    print("macOS takes a shortcut: \(taken ? "yes" : "NO") (\(rare.text))")
    HotkeyCenter.shared.use(nil)
    print("and lets it go: \(HotkeyCenter.shared.current == nil && HotkeyCenter.shared.isFree(rare) ? "yes" : "NO")")
    print("permission to read the app in front: \(Accessibility.isAllowed ? "yes" : "no")")
    print("permission to take a window's picture: \(ScreenAccess.isAllowed ? "yes" : "no")")
    print("opens at login: \(LoginItem.isOn ? "yes" : "no")")
    return taken ? 0 : 1
}

/// The shortcut's page of the settings, off screen: what it says about the permission and the
/// login item, a shortcut recorded as a click and three keys do it, and whether every text fits.
@MainActor
func runShortcutPageCheck() -> Int32 {
    beginCheck()
    let settings = SettingsController.shared
    guard let content = settings.preparedContent(page: .shortcut) else { return 1 }
    print("the page shows: \(settings.shortcutField.title)")
    print("permission: \(settings.accessText.hasPrefix("✓") ? "given" : "asked for")\(settings.accessText.isEmpty ? " (NO TEXT)" : "")")
    print("permission for a window's picture: \(settings.screenText.hasPrefix("✓") ? "given" : "asked for")\(settings.screenText.isEmpty ? " (NO TEXT)" : "")")
    print("opens at login: \(settings.loginIsTicked ? "ticked" : "not ticked")")
    func draw(_ name: String) {
        guard let dir = argument(after: "--picture") else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        content.layoutSubtreeIfNeeded()
        snapshot(content, to: "\(dir)/\(name).png")
    }
    draw("settings-shortcut")
    // Recording: a click, then ⌃⌥⇧K.
    settings.shortcutField.performClick(nil)
    print("while recording: \(settings.shortcutField.title)")
    if let keys = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option, .shift], timestamp: 0, windowNumber: 0,
                                   context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40) {
        settings.shortcutField.take(keys)
    }
    print("recorded: \(settings.shortcutField.title) (kept as \"\(settings.shortcutField.shortcut?.saved ?? "")\")")
    // A letter alone is not taken; ⌫ takes the shortcut away.
    settings.shortcutField.performClick(nil)
    if let letter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40) {
        settings.shortcutField.take(letter)
    }
    print("a letter alone: \(settings.shortcutField.isRecording ? "still waiting" : "TAKEN")")
    if let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51) {
        settings.shortcutField.take(delete)
    }
    print("after ⌫: \(settings.shortcutField.title)")
    content.layoutSubtreeIfNeeded()
    let cut = cutOffTexts(in: content)
    print("every text of the page fits: \(cut.isEmpty ? "yes" : "NO (\(cut.joined(separator: " | ")))")")
    return cut.isEmpty ? 0 : 1
}

// MARK: - Typing in another language

/// A stand-in for another app's text field: it takes a number of writings, then no more;
/// a slow one takes a fifth of a second over each, as an app that is busy does.
@MainActor
final class FakeField: TextSink {
    private let takes: Int
    private let slow: Bool
    private(set) var written = ""
    private(set) var writings = 0
    private(set) var pasted: String?
    private(set) var busy = false

    init(takes: Int, slow: Bool = false) {
        self.takes = takes
        self.slow = slow
    }

    var place: NSRect? { NSRect(x: 300, y: 500, width: 0, height: 16) }

    func write(_ text: String) async -> Bool {
        if text == written { return true }  // as a real field: there is nothing to do
        guard writings < takes else { return false }
        if slow {
            busy = true
            await waitOut(0.2)
            busy = false
        }
        writings += 1
        written = text
        return true
    }

    func paste(_ text: String) async { pasted = text }
}

/// The typing panel off screen, with a stand-in for the text field. The text is typed in two
/// goes (its first sentence, then all of it), then Return is pressed, or Esc with --esc, or
/// the panel is ended as a click elsewhere ends it with --click.
///   --field live|none|stuck|slow   the field takes every writing, none, only the first, or each slowly
///   --esc-early               Esc while the first writing is still on its way into a slow field
///   --to LANGUAGE             the language chosen in the panel
///   --with google|ai|device   the method chosen in the panel, once all is typed
@MainActor
func runTypeCheck(_ text: String) async -> Int32 {
    beginCheck()
    let kind = argument(after: "--field") ?? "live"
    let field = FakeField(takes: kind == "live" || kind == "slow" ? .max : kind == "stuck" ? 1 : 0, slow: kind == "slow")
    let panel = TypePanel(sink: field)
    panel.pause = 0.05
    var copied: String?
    panel.copy = { copied = $0 }  // a check leaves the clipboard alone
    var closed = false
    panel.onClose = { closed = true }
    panel.prepare()
    if let wanted = argument(after: "--to") {
        guard let language = findTarget(wanted, in: Config.load().targets) else {
            print("ERROR: \(wanted) is not among the languages of the settings.")
            return 1
        }
        panel.choose(language)
    }
    print("writes in: \(panel.target.id)")
    print("translates with: \(panel.engine.rawValue)")

    /// Waits until the panel has made something of what was typed.
    func settled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var answered = false
            panel.onChange = {
                guard !answered else { return }
                answered = true
                continuation.resume()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard !answered else { return }
                answered = true
                continuation.resume()
            }
        }
        panel.onChange = nil
    }
    func show(_ what: String) -> String { what.isEmpty ? "(nothing)" : what.replacingOccurrences(of: "\n", with: " / ") }

    if arguments.contains("--esc-early") {
        panel.type(text)
        var waited = 0
        while !field.busy, waited < 100 {
            await waitOut(0.02)
            waited += 1
        }
        print("Esc while the text is on its way: \(field.busy ? "yes" : "NO (it was not)")")
        panel.cancel()
        await waitOut(0.8)
        print("after Esc: panel \(closed ? "closed" : "STILL OPEN"), in the field: \(show(field.written))")
        return closed && field.written.isEmpty ? 0 : 1
    }
    let first = LiveText.pieces(of: text).first.map { $0.lead + $0.core + $0.trail } ?? text
    for typed in first == text ? [text] : [first, text] {
        panel.type(typed)
        await settled()
        print("typed: \(show(typed))")
        print("   in the field: \(show(field.written)); the panel shows: \(show(panel.shownNote)); \(panel.way)")
    }
    if let wanted = argument(after: "--with") {
        guard let method = Engine(rawValue: wanted), panel.choose(method) else {
            print("ERROR: \(wanted) is not among the methods here.")
            return 1
        }
        await settled()
        print("with \(panel.engine.rawValue):")
        print("   in the field: \(show(field.written)); the panel shows: \(show(panel.shownNote)); \(panel.way)")
    }
    print("hint: \(panel.shownHint)")
    if let dir = argument(after: "--picture"), let view = panel.panel.contentView {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        snapshot(view, to: "\(dir)/type-\(kind).png")
        let cut = cutOffTexts(in: view)
        print("every text of the panel fits: \(cut.isEmpty ? "yes" : "NO (\(cut.joined(separator: " | ")))")")
    }
    let ending = arguments.contains("--esc") ? "after Esc" : arguments.contains("--click") ? "after a click elsewhere" : "after Return"
    if arguments.contains("--esc") { panel.cancel() } else { panel.finish(byReturn: !arguments.contains("--click")) }
    var waited = 0
    while !closed, waited < 80 {
        try? await Task.sleep(nanoseconds: 50_000_000)
        waited += 1
    }
    try? await Task.sleep(nanoseconds: 100_000_000)  // what Esc takes back out goes after the panel
    print("\(ending): panel \(closed ? "closed" : "STILL OPEN"), "
          + "in the field: \(show(field.written)), pasted: \(show(field.pasted ?? "")), copied: \(show(copied ?? "")), writings: \(field.writings)")
    print(panel.gear.gearLine)
    return closed ? 0 : 1
}

// MARK: - A window's picture

/// Draws a picture that stands for a window (for --picture-make): a heading,
/// a paragraph of three lines, a list on a dark side bar, a button, and lines in several languages.
@MainActor
func makeTestPicture(at path: String) -> Bool {
    let scale: CGFloat = 2, width = 900, height = 520
    guard let context = CGContext(data: nil, width: width * Int(scale), height: height * Int(scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)  // y runs downward from the top
    let before = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    defer { NSGraphicsContext.current = before }
    func fill(_ rect: NSRect, _ colour: NSColor, radius: CGFloat = 0) {
        colour.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    func write(_ text: String, at point: NSPoint, size: CGFloat = 13, weight: NSFont.Weight = .regular, colour: NSColor = .black, width: CGFloat = 0) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: colour]
        if width > 0 {
            (text as NSString).draw(with: NSRect(x: point.x, y: point.y, width: width, height: 400), options: [.usesLineFragmentOrigin], attributes: attributes)
        } else {
            (text as NSString).draw(at: point, withAttributes: attributes)
        }
    }
    fill(NSRect(x: 0, y: 0, width: width, height: height), .white)
    fill(NSRect(x: 0, y: 0, width: 200, height: height), NSColor(srgbRed: 0.16, green: 0.17, blue: 0.2, alpha: 1))
    for (i, item) in ["Datei öffnen", "Bearbeiten", "Einstellungen", "Hilfe"].enumerated() {
        write(item, at: NSPoint(x: 24, y: 70 + CGFloat(i) * 34), colour: NSColor(white: 0.92, alpha: 1))
    }
    write("Welcome back", at: NSPoint(x: 236, y: 28), size: 24, weight: .bold)
    write("The quick brown fox jumps over the lazy dog near the river bank. It was a bright cold day in April, and the clocks were striking thirteen. Nobody in the village noticed anything at all.",
          at: NSPoint(x: 236, y: 80), width: 420)
    write("Labdien! Kā jums klājas šodien?", at: NSPoint(x: 236, y: 190))
    write("Добар дан, како сте данас?", at: NSPoint(x: 236, y: 230))
    write("Сегодня хорошая погода", at: NSPoint(x: 236, y: 270))
    write("12:45   100%   v2.3.1", at: NSPoint(x: 236, y: 310))
    fill(NSRect(x: 236, y: 360, width: 150, height: 34), NSColor(srgbRed: 0.1, green: 0.45, blue: 0.95, alpha: 1), radius: 8)
    write("Save changes", at: NSPoint(x: 265, y: 368), weight: .medium, colour: .white)
    fill(NSRect(x: 400, y: 360, width: 110, height: 34), NSColor(white: 0.9, alpha: 1), radius: 8)
    write("Cancel", at: NSPoint(x: 432, y: 368))
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

/// Reads a picture file as a window's picture is read, translates its texts and prints them:
/// which lines were put together, what each became, what stayed. --times also prints how
/// long the reading, the translating and the painting took.
@MainActor
func runPictureCheck(_ file: String) async -> Int32 {
    beginCheck()
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("ERROR: no picture at \(file)")
        return 1
    }
    let config = Config.load()
    let engine: Engine = argument(after: "--engine").flatMap(Engine.init(rawValue:)) ?? config.startEngine
    guard let target = argument(after: "--to").map({ findTarget($0) }) ?? config.startTarget else {
        print("ERROR: no such language. Give its name or code, such as Russian or ru.")
        return 1
    }
    do {
        var clock = Date()
        /// The seconds since the last call (--times prints them: how long each step takes).
        func lap() -> String {
            defer { clock = Date() }
            return String(format: "%.1f s", Date().timeIntervalSince(clock))
        }
        let timed = arguments.contains("--times")
        let lines = try PictureReader.lines(in: image, languages: config.targets.map(\.google) + macLanguages())
        var blocks = PictureReader.blocks(lines)
        let worth = blocks.indices.filter { blocks[$0].hasWords }
        print("\(lines.count) lines read, \(blocks.count) texts, \(worth.count) with words; into \(target.id) by \(engine.rawValue)")
        if timed { print("read in \(lap())") }
        let result = try await translateMany(worth.map { blocks[$0].text }, engine: engine, target: target, config: config) { place, made in
            blocks[worth[place]].translation = made
        }
        if timed { print("translated in \(lap())") }
        for block in blocks.sorted(by: { $0.box.minY < $1.box.minY }) {
            let lines = block.lines.count > 1 ? "(\(block.lines.count) lines) " : ""
            print("   \(lines)\(block.text)\(block.translation.map { " → \($0)" } ?? (block.hasWords ? " = stays" : " = no words"))")
        }
        if result.failed > 0 { print("not translated: \(result.failed) (\(result.reason ?? "?"))") }
        if let dir = argument(after: "--picture"), let pixels = Pixels(image) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let painted = PicturePainter.paint(image, blocks: blocks, pixels: pixels, scale: 2),
               let png = NSBitmapImageRep(cgImage: painted).representation(using: .png, properties: [:]) {
                if timed { print("painted in \(lap())") }
                try? png.write(to: URL(fileURLWithPath: "\(dir)/picture-translated.png"))
                print("painted: \(painted.width)x\(painted.height), \(blocks.filter { $0.translation != nil }.count) texts painted over")
            }
        }
        return result.failed == worth.count && !worth.isEmpty ? 1 : 0
    } catch {
        print("ERROR: \(describe(error))")
        return 1
    }
}

/// The window that shows a translated picture, made off screen for a picture file: what its
/// bar says in the end, and (--picture DIR) the window drawn into DIR. --then METHOD chooses
/// another method in its bar once it is translated, and waits for that too.
@MainActor
func runPictureWindowCheck(_ file: String) {
    beginCheck()
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("ERROR: no picture at \(file)")
        exit(1)
    }
    let window = PictureWindow(image: image, scale: 2, over: nil)
    PictureWindow.current = window
    var then = argument(after: "--then")
    print(window.gear.gearLine)
    window.onSettled = {
        print("the bar says: \(window.statusText)")
        print("texts painted over: \(window.blocks?.filter { $0.translation != nil }.count ?? 0) of \(window.blocks?.count ?? 0), "
              + "by \(window.engine.rawValue) into \(window.target.id)")
        if let wanted = then {
            then = nil
            guard let method = Engine(rawValue: wanted), window.choose(method) else {
                print("ERROR: \(wanted) is not among the methods here.")
                exit(1)
            }
            return  // it translates anew
        }
        if let dir = argument(after: "--picture"), let view = window.contentView {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            view.layoutSubtreeIfNeeded()
            snapshot(view, to: "\(dir)/picture-window.png")
            let cut = cutOffTexts(in: view).filter { $0 != window.statusText }  // the bar's own line is cut short on purpose
            print("every text of the window fits: \(cut.isEmpty ? "yes" : "NO (\(cut.joined(separator: " | ")))")")
        }
        // The bar with the selectors is the window's bottom: a window that grew past its screen has it out of reach.
        window.panel.layoutIfNeeded()
        let screen = (window.panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let whole = screen.insetBy(dx: -1, dy: -1).contains(window.panel.frame)
        print("the window is on its screen, bar and all: \(whole ? "yes" : "NO (\(window.panel.frame) on \(screen))")")
        exit(window.failed || !whole ? 1 : 0)
    }
    window.start()
}

// MARK: - Writing into a real text field (needs the permission)

/// A small window with a text field in it, for --ax-check to write into: it stands for
/// another app. Every tenth of a second it writes what its field holds into FILE.
///   appkit             a Mac text view
///   input              a web page's one-line <input>
///   textarea[-empty]   a web page's <textarea>, with a text in it already, or empty
///   editable[-full]    a web page's editable <div>, as chat pages have: empty, or with a text
/// Those that are not empty hold "before -- after", with the cursor between the dashes.
@MainActor
final class AXTarget: NSObject {
    static var shared: AXTarget?
    static let text = "before -- after"
    static let cursor = 8
    private let window = NSPanel(contentRect: NSRect(x: 40, y: 80, width: 380, height: 110),
                                 styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    private let kind: String
    private let file: String
    private let text = NSTextView()
    private var web: WKWebView?

    init(kind: String, file: String) {
        self.kind = kind
        self.file = file
        super.init()
        window.title = "BTranslate: a check (it closes by itself)"
        window.level = .floating
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 110))
        if kind == "appkit" {
            text.frame = content.bounds.insetBy(dx: 10, dy: 10)
            text.font = .systemFont(ofSize: 14)
            text.string = AXTarget.text
            text.setSelectedRange(NSRange(location: AXTarget.cursor, length: 0))
            content.addSubview(text)
            window.contentView = content
            window.makeFirstResponder(text)
        } else {
            let page = WKWebView(frame: content.bounds.insetBy(dx: 10, dy: 10))
            let look = "width:330px;font:14px -apple-system"
            let field: String
            switch kind {
            case "textarea": field = "<textarea id=t style='\(look);height:70px'>\(AXTarget.text)</textarea>"
            case "textarea-empty": field = "<textarea id=t style='\(look);height:70px'></textarea>"
            case "input": field = "<input id=t style='\(look)' value='\(AXTarget.text)'>"
            case "editable": field = "<div id=t contenteditable style='\(look);height:70px;border:1px solid #999'></div>"
            default: field = "<div id=t contenteditable style='\(look);height:70px;border:1px solid #999'>\(AXTarget.text)</div>"
            }
            page.loadHTMLString("<html><body style='margin:0'>\(field)<script>var t=document.getElementById('t');t.focus();</script></body></html>", baseURL: nil)
            content.addSubview(page)
            window.contentView = content
            window.makeFirstResponder(page)
            web = page
        }
        window.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
    }

    private func report() {
        if let web {
            web.evaluateJavaScript("var t=document.getElementById('t'); t.value!==undefined ? t.value : t.innerText") { [file] value, _ in
                if let value = value as? String { try? value.write(toFile: file, atomically: true, encoding: .utf8) }
            }
        } else {
            try? text.string.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }
}

/// Writes into a real text field of another process as the typing panel does, and reads a
/// selection as the shortcut does. The other process is a small window of BTranslate's own
/// (see AXTarget), shown for a few seconds in the screen's bottom left corner; it is never
/// made the active app, nothing is clicked, and no app of yours is read or written into.
/// It needs the Accessibility permission, which belongs to the installed app:
///   open -n -g ~/Applications/BTranslate.app --stdout FILE --args --ax-check appkit
///
/// What is right: a Mac's field, a web page's one-line field and its boxes that are empty take
/// each writing, and hold just that between what was there. A web page's box with a text in
/// it (`textarea`, `editable-full`) must refuse and keep its text as it was: the two can't be
/// told apart, and writing would flatten what an editor holds.
@MainActor
func runAXCheck(_ kind: String) async -> Int32 {
    beginCheck()
    guard AXIsProcessTrusted() else {
        print("skipped: this copy of BTranslate has no Accessibility permission")
        return 2
    }
    let file = NSTemporaryDirectory() + "btranslate-ax-\(ProcessInfo.processInfo.processIdentifier).txt"
    try? FileManager.default.removeItem(atPath: file)
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    let target = Process()
    target.executableURL = Bundle.main.executableURL
    target.arguments = ["--ax-target", kind, file]
    guard (try? target.run()) != nil else {
        print("ERROR: the window to write into did not start")
        return 1
    }
    defer {
        target.terminate()
        try? FileManager.default.removeItem(atPath: file)
    }
    func held() -> String { (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }
    func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    let app = AXUIElementCreateApplication(target.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1)
    func find(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        let role = element.text(kAXRoleAttribute) ?? ""
        if [kAXTextAreaRole, kAXTextFieldRole].contains(role) { return element }
        guard depth < 14 else { return nil }
        for child in element.children() {
            if let found = find(child, depth: depth + 1) { return found }
        }
        return nil
    }
    var element: AXUIElement?
    for _ in 0..<50 where element == nil {
        await pause(0.1)
        element = app.children(kAXWindowsAttribute).lazy.compactMap { find($0) }.first
    }
    guard let element else {
        print("ERROR: no text field found in the other window")
        return 1
    }
    await pause(0.3)
    let empty = kind == "editable" || kind == "textarea-empty", refuses = kind == "editable-full" || kind == "textarea"
    let whole = AXTarget.text as NSString
    let before = empty ? "" : whole.substring(to: AXTarget.cursor), after = empty ? "" : whole.substring(from: AXTarget.cursor)
    print("field: \(element.text(kAXRoleAttribute) ?? "?"), holds \"\(held())\"")
    var failures = 0

    // What is selected, as the shortcut reads it.
    if !empty {
        element.select(CFRange(location: 0, length: 6))
        await pause(0.2)
        let selection = element.text(kAXSelectedTextAttribute)
        print("selected text read: \(selection ?? "nothing") \(selection == "before" ? "(right)" : "(WRONG)")")
        if selection != "before" { failures += 1 }
        let place = element.range(kAXSelectedTextRangeAttribute).flatMap { element.frame(of: $0) }
        print("its place on the screen: \(place.map { "\(Int($0.minX)), \(Int($0.minY)), \(Int($0.width))x\(Int($0.height))" } ?? "not told")")
    }

    // Writing at the cursor, as the typing panel does: each text takes the place of the one before.
    element.select(CFRange(location: empty ? 0 : AXTarget.cursor, length: 0))
    await pause(0.2)
    let field = AXField(element: element, app: NSRunningApplication(processIdentifier: target.processIdentifier),
                        writable: element.canSet(kAXValueAttribute) || element.canSet(kAXSelectedTextAttribute))
    print("the cursor's place: \(field.place.map { "\(Int($0.minX)), \(Int($0.minY))" } ?? "not told")")
    for text in ["Hello", "Hello, wor", "Hello, world!", "Hello, world! Привет 👋", "Hello. Second sentence", ""] {
        let taken = await field.write(text)
        await pause(0.25)
        let now = held()
        let right = refuses ? !taken && AXField.alike(now, AXTarget.text) : taken && AXField.alike(now, before + text + after)
        let cursor = element.range(kAXSelectedTextRangeAttribute)?.location
        let behind = refuses || cursor == (before as NSString).length + (text as NSString).length
        print("write \"\(text)\": \(taken ? "taken" : "not taken"); the field holds \"\(now.trimmingCharacters(in: .newlines))\" "
              + "\(right ? "(right)" : "(WRONG)")\(behind ? "" : ", the cursor is not behind it (WRONG: at \(cursor.map(String.init) ?? "?"))")")
        if !right || !behind { failures += 1 }
        if refuses { break }  // the panel asks no more of a field that refused
    }
    print("app in front before and after: \(front) / \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    print(failures == 0 ? "ax-check \(kind): ok" : "ax-check \(kind): \(failures) FAILED")
    return failures == 0 ? 0 : 1
}

// MARK: - Checks that need nothing (part of --selftest)

func shortcutSelfTest() -> [String] {
    var failures: [String] = []
    func expect(_ what: String, _ ok: Bool) { if !ok { failures.append(what) } }

    // What macOS prepared for the Neural Engine, in a folder made up here: under the macOS
    // that runs, a model of the pack's (large: 60 MB of nothing) and a piece of the reader of
    // pictures (small); under an earlier macOS, one of each.
    let files = FileManager.default
    let made = files.temporaryDirectory.appendingPathComponent("btranslate-prepared-\(ProcessInfo.processInfo.processIdentifier)")
    func piece(_ path: String, bytes: UInt64) {
        let file = made.appendingPathComponent(path).appendingPathComponent("model.bundle/weights")
        try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        files.createFile(atPath: file.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: file) {
            try? handle.truncate(atOffset: bytes)
            try? handle.close()
        }
    }
    piece("NOW/pack", bytes: 60_000_000)
    piece("NOW/reader", bytes: 60_000)
    piece("BEFORE/pack", bytes: 60_000_000)
    piece("BEFORE/reader", bytes: 60_000)
    expect("prepared models: the pack's are seen to be there", LanguagePack.holdsModels(made, system: "NOW"))
    LanguagePack.forget(in: made, system: "NOW")
    expect("prepared models: and to be gone, whatever the reader of pictures keeps there", !LanguagePack.holdsModels(made, system: "NOW"))
    let left = (files.subpaths(atPath: made.path) ?? []).filter { $0.hasSuffix("weights") }
    expect("prepared models: the pack's go, the reader of pictures keeps its own, an earlier macOS's all go (left: \(left))",
           left == ["NOW/reader/model.bundle/weights"])
    try? files.removeItem(at: made)

    let standard = Shortcut.standard
    expect("shortcut: the standard one is kept as words and a key code", standard.saved == "control+option+17")
    expect("shortcut: and read back", Shortcut(saved: standard.saved) == standard)
    expect("shortcut: shown with its signs", standard.text.hasPrefix("⌃⌥"))
    expect("shortcut: a letter alone is typing, not a shortcut", Shortcut(saved: "17") == nil && Shortcut(saved: "shift+17") == nil)
    expect("shortcut: a function key alone may be one", Shortcut(saved: "80") != nil)
    expect("shortcut: nonsense is not one", Shortcut(saved: "hyper+17") == nil && Shortcut(saved: "") == nil && Shortcut(saved: "control+x") == nil)
    expect("shortcut: all four modifiers, in a fixed order", Shortcut(saved: "command+shift+option+control+49")?.saved == "control+option+shift+command+49")

    expect("layout: Russian says Russian", Keyboard.languageOfLayout("ru") == "ru")
    expect("layout: Ukrainian says Ukrainian", Keyboard.languageOfLayout("uk") == "uk")
    expect("layout: Latin letters say nothing", Keyboard.languageOfLayout("en") == nil && Keyboard.languageOfLayout("de") == nil
           && Keyboard.languageOfLayout("sr-Latn") == nil && Keyboard.languageOfLayout("lv") == nil)

    let typed = "  Hello there. How are you?\nFine"
    let pieces = LiveText.pieces(of: typed)
    expect("typing: the pieces put together are the text", pieces.map { $0.lead + $0.core + $0.trail }.joined() == typed)
    expect("typing: three sentences", pieces.map(\.core) == ["Hello there.", "How are you?", "Fine"])
    expect("typing: nothing typed, nothing to translate", LiveText.pieces(of: "").isEmpty && LiveText.pieces(of: "  ").allSatisfy { $0.core.isEmpty })
    expect("typing: a finished sentence is the same piece while the next is typed",
           LiveText.pieces(of: "One. Tw").first == LiveText.pieces(of: "One. Two and three").first)

    expect("field: what two texts begin alike with", AXField.sharedStart("Hello, wor", "Hello, world!") == 10)
    expect("field: nothing alike", AXField.sharedStart("abc", "xbc") == 0)
    expect("field: counted in UTF-16 units, a letter never cut in two",
           AXField.sharedStart("Привет 👋 мир", "Привет 👋🏽 мир") == 7 && AXField.sharedStart("e\u{301}a", "eb") == 0)

    expect("field: texts alike but for their blanks", AXField.alike("Hello,\u{a0}world \n", "Hello, world") && !AXField.alike("Hello world", "Helloworld")
           && !AXField.alike(nil, ""))
    expect("field: still holding what was written, give or take a correction of the app's own",
           AXField.near("Hello world", "Hello world") && AXField.near("Hello wörld", "Hello world") && AXField.near("", " \n")
           && AXField.near("He said “hi” and “bye” to all of them.", "He said \"hi\" and \"bye\" to all of them."))
    expect("field: another text in its place is not ours to write over",
           !AXField.near("Lunch at one? I'll book a table.", "Hello world") && !AXField.near("", "Hello world")
           && !AXField.near("Hello world", "") && !AXField.near(nil, "Hello world"))

    let answer = parseNumbered("1| Привет\n 2 |  Открыть файл\nnoise\n4| a | b\n")
    expect("many texts: numbered lines read", answer[1] == "Привет" && answer[2] == "Открыть файл" && answer[3] == nil && answer[4] == "a | b")

    func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, height: CGFloat = 30) -> PictureLine {
        PictureLine(text: text, box: CGRect(x: x, y: y, width: width, height: height))
    }
    let paragraph = PictureReader.blocks([
        line("The quick brown fox jumps over the lazy dog near the", 100, 100, 800),
        line("river bank and nobody in the village noticed it at", 100, 136, 790),
        line("all.", 100, 172, 60),
    ])
    expect("picture: a paragraph's lines are one text", paragraph.count == 1 && paragraph[0].lines.count == 3
           && paragraph[0].text.hasSuffix("noticed it at all."))
    let list = PictureReader.blocks([line("Open file", 40, 100, 140), line("Edit", 40, 136, 60), line("Settings", 40, 172, 130)])
    expect("picture: the rows of a list stay apart", list.count == 3)
    let columns = PictureReader.blocks([
        line("The quick brown fox jumps over the lazy dog", 100, 100, 600),
        line("An unrelated line far to the right of that one", 900, 136, 600),
    ])
    expect("picture: lines that begin elsewhere stay apart", columns.count == 2)
    let sizes = PictureReader.blocks([line("A heading of four words here", 100, 100, 600, height: 60), line("and small print under it", 100, 170, 300, height: 24)])
    expect("picture: letters of another size are another text", sizes.count == 2)
    expect("picture: numbers and signs are not words", !PictureBlock(lines: [line("12:45 100% v2", 0, 0, 100)]).hasWords
           && PictureBlock(lines: [line("Save", 0, 0, 60)]).hasWords)
    let centred = PictureBlock(lines: [line("A long first line of a centred paragraph", 100, 100, 600), line("and a short one", 280, 136, 240)])
    expect("picture: a centred paragraph is seen as one", centred.centred)
    return failures
}

// MARK: - Updates (Sources/Updates.swift)

// None of these asks GitHub or runs the installer: the check asks BTRANSLATE_UPDATE_URL (the
// mock server), and the update runs BTRANSLATE_UPDATE_COMMAND, without which it refuses. Their
// bookkeeping (the last check, the note of a started update) stays in memory.

/// One check, as Check Now does it; --scheduled: as the daily check does, which the setting
/// checkForUpdates and the date of the last check (-lastUpdateCheck) may skip.
@MainActor
func runUpdateCheck() async -> Int32 {
    beginCheck()
    let updater = Updater.shared
    print("this copy: \(updater.current)")
    if arguments.contains("--scheduled") {
        updater.lookIfDue()
        await waitOut(0.2)
        if updater.state == .never {
            print("update check: not done (\(Config.load().checkForUpdates ? "the last one is less than a day old" : "checkForUpdates is off"))")
            return 0
        }
        while updater.isBusy { await waitOut(0.05) }
    } else {
        await updater.check()
    }
    print("update check: \(updater.stateName)")
    print("last check kept: \(updater.lastCheck == nil ? "no" : "yes")")
    return 0
}

/// The Update button, with BTRANSLATE_UPDATE_WAITING as the version found and
/// BTRANSLATE_UPDATE_COMMAND in the installer's place: what it starts, what it would note,
/// and what the About page says once the command has ended. --auto: as an automatic update.
@MainActor
func runUpdateRun() async -> Int32 {
    beginCheck()
    let updater = Updater.shared
    guard let version = updater.waitingVersion else {
        print("ERROR: give the version found as BTRANSLATE_UPDATE_WAITING")
        return 1
    }
    updater.update(asked: !arguments.contains("--auto"))
    print("update to \(version): \(updater.stateName)")
    print("the note it keeps: \(updater.noteText)")
    var waited = 0
    while case .updating = updater.state, waited < 600 {
        await waitOut(0.05)
        waited += 1
    }
    print("once the command has ended: \(updater.stateName)")
    print("the note then: \(updater.noteText)")
    guard let content = SettingsController.shared.preparedContent(page: .about) else { return 1 }
    content.layoutSubtreeIfNeeded()
    print("the About page says: \(SettingsController.shared.aboutForTest)")
    return 0
}

/// The automatic update: a version is found with -autoUpdate as given. --showing popup: a
/// popup is showing at first, and is closed after a while. Prints the states it went through.
@MainActor
func runUpdateAutoCheck() async -> Int32 {
    beginCheck()
    let updater = Updater.shared
    updater.quietWait = 0.3
    var states: [String] = []
    let watch = NotificationCenter.default.addObserver(forName: Updater.changed, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { states.append(Updater.shared.stateName) }
    }
    defer { NotificationCenter.default.removeObserver(watch) }
    var popup: Popup?
    if argument(after: "--showing") == "popup" {
        popup = Popup(text: "Labdien")
        Popup.current = popup
        popup?.prepare()
    }
    updater.found("9.9.9")
    await waitOut(1)
    func started() -> String { states.contains { $0.hasPrefix("updating") } ? "yes" : "no" }
    print("a version found, \(popup == nil ? "nothing showing" : "a popup showing"): \(states.joined(separator: " → ")); the update started: \(started())")
    if let popup {
        popup.close()
        await waitOut(1)
        print("the popup closed: \(states.joined(separator: " → ")); the update started: \(started())")
    }
    while case .updating = updater.state { await waitOut(0.05) }
    return 0
}

/// The start after an update, with its note given as -updateFrom, -updateTo and -updateAsked,
/// and BTRANSLATE_VERSION as the version that started.
@MainActor
func runUpdateNoteCheck() -> Int32 {
    beginCheck()
    let updater = Updater.shared
    var opened = false
    updater.openAbout = { opened = true }
    print("the note: \(updater.noteText); this copy: \(updater.current)")
    updater.lookAtNoteForTest()
    print("at the start: \(updater.stateName); the note then: \(updater.noteText); the settings open on the About page: \(opened ? "yes" : "no")")
    return 0
}

/// The About page in each state, off screen: every text fits, and the window a small screen.
@MainActor
func runAboutCheck() -> Int32 {
    beginCheck()
    let settings = SettingsController.shared
    let dir = argument(after: "--picture")
    if let dir { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    // The longest a failure can be: the installer's own last line about a failed build.
    let longest = "BTranslate installer: the build failed. If the lines above are the compiler's about the Swift language, the Command Line Tools are too old for this version: update them (System Settings → General → Software Update) and run this again."
    let states: [(String, UpdateState)] = [
        ("never", .never), ("checking", .checking), ("up-to-date", .upToDate(Date())), ("available", .available("9.10.11")),
        ("failed", .failed(L("No internet connection."))), ("updating", .updating("9.10.11")),
        ("update-failed", .updateFailed(longest)), ("installed", .installed("9.10.11")),
    ]
    var fits = true, tallest = 0
    for (name, state) in states {
        Updater.shared.show(state)
        guard let content = settings.preparedContent(page: .about) else { return 1 }
        content.layoutSubtreeIfNeeded()
        let cut = cutOffTexts(in: content)
        let height = Int(content.fittingSize.height)
        tallest = max(tallest, height)
        if !cut.isEmpty { fits = false }
        print("about, \(name): \(settings.aboutForTest); \(height) points\(cut.isEmpty ? "" : "; CUT SHORT: \(cut.joined(separator: " | "))")")
        if let dir { snapshot(content, to: "\(dir)/about-\(name).png") }
    }
    print("the About page, every state: every text fits: \(fits ? "yes" : "NO"); at most \(tallest) points tall: \(tallest <= 760 ? "it fits a small screen" : "TOO TALL for a small screen")")
    return fits && tallest <= 760 ? 0 : 1
}
