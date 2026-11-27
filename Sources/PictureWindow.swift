import Cocoa
import ScreenCaptureKit

// A window, translated: the shortcut, pressed with no text selected and no text field under
// the cursor, has you choose a window in macOS's own picker, the one screen sharing uses;
// BTranslate gets the one window that was chosen, once. macOS still wants the permission to
// record the screen for it and asks the first time: until it is given, the picture is refused.

// MARK: - Choosing a window and taking its picture

@MainActor
final class WindowShot: NSObject, SCContentSharingPickerObserver {
    static let shared = WindowShot()

    struct Shot {
        let image: CGImage
        let scale: CGFloat  // pixels to a point
        let frame: NSRect?  // where the window is on the screen
    }

    private(set) var isChoosing = false
    private var waiting: CheckedContinuation<SCContentFilter?, Error>?

    /// nil: no window was chosen.
    func take() async throws -> Shot? {
        let picker = SCContentSharingPicker.shared
        var setup = SCContentSharingPickerConfiguration()
        setup.allowedPickerModes = [.singleWindow]
        if let own = Bundle.main.bundleIdentifier { setup.excludedBundleIDs = [own] }
        picker.defaultConfiguration = setup
        picker.add(self)
        picker.isActive = true
        isChoosing = true
        defer {
            isChoosing = false
            picker.isActive = false
            picker.remove(self)
        }
        let chosen = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCContentFilter?, Error>) in
            waiting = continuation
            picker.present(using: .window)
        }
        isChoosing = false  // the choosing is over: taking the picture must not hold the shortcut
        guard let chosen else { return nil }
        let scale = CGFloat(chosen.pointPixelScale)
        let rect = chosen.contentRect
        let how = SCStreamConfiguration()
        how.width = max(1, Int(rect.width * scale))
        how.height = max(1, Int(rect.height * scale))
        how.showsCursor = false
        how.ignoreShadowsSingleWindow = true
        how.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: chosen, configuration: how)
        // The picker counts from the top left corner of the first screen, AppKit from its bottom left.
        var frame: NSRect?
        if let first = NSScreen.screens.first, rect.width > 0 {
            frame = NSRect(x: rect.minX, y: first.frame.height - rect.maxY, width: rect.width, height: rect.height)
        }
        Log.note("window: picture \(image.width)x\(image.height), scale \(scale), at \(rect)")
        return Shot(image: image, scale: scale > 0 ? scale : 2, frame: frame)
    }

    /// Puts the picker away (the shortcut pressed once more).
    func cancel() {
        guard isChoosing else { return }
        SCContentSharingPicker.shared.isActive = false
        answer(.success(nil))
    }

    private func answer(_ result: Result<SCContentFilter?, Error>) {
        waiting?.resume(with: result)
        waiting = nil
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { WindowShot.shared.answer(.success(nil)) } }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let chosen = Carried(filter)
        DispatchQueue.main.async { MainActor.assumeIsolated { WindowShot.shared.answer(.success(chosen.value)) } }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { MainActor.assumeIsolated { WindowShot.shared.answer(.failure(error)) } }
    }
}

/// Takes a value that is used by one thread at a time over to another.
private struct Carried<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
enum WindowPicture {
    /// Has a window chosen, and shows it translated.
    static func start() {
        guard !WindowShot.shared.isChoosing else { return }
        Log.note("window: choosing")
        Task { @MainActor in
            do {
                guard let shot = try await WindowShot.shared.take() else {
                    Log.note("window: none chosen")
                    return
                }
                PictureWindow.show(image: shot.image, scale: shot.scale, over: shot.frame)
            } catch {
                Log.note("window: no picture: \(error)")
                if !ScreenAccess.isAllowed {
                    // macOS refuses the picture until BTranslate may record the screen. It asks once by itself.
                    ScreenAccess.ask()
                    showNote(L("To translate a window, macOS needs your permission for BTranslate to record the screen: System Settings → Privacy & Security → Screen & System Audio Recording. Then press the shortcut again."))
                } else {
                    showNote(L("macOS did not hand over the window's picture: %@", error.localizedDescription))
                }
            }
        }
    }
}

// MARK: - The translated picture's window

@MainActor
final class PictureWindow: NSObject, NSWindowDelegate {
    static var current: PictureWindow?
    private static let bar: CGFloat = 36
    private static let statusRoom: CGFloat = 150  // the least width the bar keeps for what it says

    let panel: PopupPanel  // floats over the app you are in without becoming the active app; Esc and ⌘W close it, ⌘C copies
    private let original: CGImage
    private let scale: CGFloat
    private let pixels: Pixels?
    private let config = Config.load()
    private(set) var engine: Engine
    private(set) var target: Target
    private(set) var blocks: [PictureBlock]?  // nil until the picture is read
    private(set) var painted: CGImage?
    private(set) var statusText = ""
    private(set) var failed = false

    private let imageView = NSImageView()
    private let arrow = NSTextField(labelWithString: "→")
    private let menu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let engineControl = NSSegmentedControl()
    private let status = NSTextField(labelWithString: "")
    private let originalButton = NSButton(title: L("Original"), target: nil, action: nil)
    private let copyButton = NSButton(title: L("Copy"), target: nil, action: nil)
    private let settingsButton = NSButton()
    private var task: Task<Void, Never>?
    private var closed = false
    var onSettled: (() -> Void)?  // the translation, or the reason there is none, is showing (tests)

    static func show(image: CGImage, scale: CGFloat, over frame: NSRect?) {
        current?.close()
        let window = PictureWindow(image: image, scale: scale, over: frame)
        current = window
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.handBackUntil = max(delegate.handBackUntil, Date().addingTimeInterval(1.5))
        }
        window.panel.orderFrontRegardless()
        window.panel.makeKey()
        window.start()
    }

    init(image: CGImage, scale: CGFloat, over frame: NSRect?) {
        original = image
        self.scale = scale
        pixels = Pixels(image)
        // Both are set in the settings; the menu and the selector in the bar are for this window only.
        engine = config.windowStartEngine
        target = config.windowTarget
        // As large as the window it shows, where the screen has the room.
        var size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let anchor = frame ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor.insetBy(dx: -1, dy: -1)) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        let chrome = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: style).height - 100
        let fits = min(1, (visible.width - 12) / size.width, (visible.height - 12 - chrome - PictureWindow.bar) / size.height)
        size = NSSize(width: max(360, floor(size.width * fits)), height: floor(size.height * fits))
        var content = NSRect(x: 0, y: 0, width: size.width, height: size.height + PictureWindow.bar)
        if let frame {  // the picture lies over the window it was taken of
            content.origin = NSPoint(x: frame.minX, y: frame.maxY - size.height - PictureWindow.bar)
        } else {
            content.origin = NSPoint(x: visible.midX - content.width / 2, y: visible.midY - content.height / 2)
        }
        var whole = NSWindow.frameRect(forContentRect: content, styleMask: style)
        whole.origin.x = min(max(whole.minX, visible.minX + 6), visible.maxX - whole.width - 6)
        whole.origin.y = min(max(whole.minY, visible.minY + 6), visible.maxY - whole.height - 6)
        panel = PopupPanel(contentRect: NSWindow.contentRect(forFrameRect: whole, styleMask: style), styleMask: style,
                             backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        panel.title = "BTranslate"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onClose = { [weak self] in self?.close() }
        panel.onCopy = { [weak self] in self?.copyPicture() }

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        // The window's size is its own to keep. Left to itself, the picture would hold out for
        // its full size and make the window grow: one as tall as the screen then has its bar,
        // with the selectors, under the screen's edge. So the picture gives way, and is shown smaller.
        for way in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            imageView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: way)
            imageView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: way)
        }
        arrow.font = .systemFont(ofSize: 12, weight: .medium)
        arrow.textColor = .secondaryLabelColor
        menu.controlSize = .small
        menu.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for language in config.targets { menu.addItem(withTitle: language.name) }
        menu.selectItem(at: config.targets.firstIndex(of: target) ?? 0)
        menu.target = self
        menu.action = #selector(targetChanged)
        menu.toolTip = L("The language this window is translated into. The one it opens with is set in BTranslate's settings, on the Defaults page.")
        engineControl.offerMethods(of: config, showing: engine)
        engineControl.target = self
        engineControl.action = #selector(engineChanged)
        settingsButton.beGear()
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        // What the bar says takes the room between the selectors and the buttons, which keep their places.
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        originalButton.setButtonType(.pushOnPushOff)
        originalButton.toolTip = L("Shows the window as it is, without the translations")
        for button in [originalButton, copyButton] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
        }
        originalButton.action = #selector(showPicture)
        copyButton.action = #selector(copyPicture)
        copyButton.toolTip = L("Copies the picture")

        let row = NSStackView(views: [arrow, menu, engineControl, status, originalButton, copyButton, settingsButton])
        row.distribution = .fill
        row.spacing = 8
        row.setCustomSpacing(2, after: arrow)
        status.widthAnchor.constraint(greaterThanOrEqualToConstant: PictureWindow.statusRoom).isActive = true
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(imageView)
        content.addSubview(row)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: content.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: row.topAnchor),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            row.heightAnchor.constraint(equalToConstant: PictureWindow.bar),
        ])
        panel.contentView = content
        // The bar has to fit, with room for a few words of the status: the picture of a narrow
        // window gets a window wider than itself.
        let needed = max(360, ceil(row.fittingSize.width))
        panel.contentMinSize = NSSize(width: needed, height: 200)
        if panel.frame.width < needed {
            var frame = panel.frame
            frame.size.width = needed
            if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
                frame.origin.x = max(visible.minX + 6, min(frame.minX, visible.maxX - needed - 6))
            }
            panel.setFrame(frame, display: false)
        }
        showPicture()
    }

    var contentView: NSView? { panel.contentView }  // (UI test)

    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel()
        panel.orderOut(nil)
        if PictureWindow.current === self { PictureWindow.current = nil }
    }

    func windowWillClose(_ notification: Notification) { close() }

    // MARK: Reading and translating

    /// Reads the picture's texts (once) and translates them into the chosen language.
    func start() {
        task?.cancel()
        failed = false
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if self.blocks == nil {
                    self.say(L("Reading the text in the picture…"))
                    // The very first reading waits for macOS to make its reader ready: say so, so that it does not look stuck.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, !self.closed, self.blocks == nil, !self.failed else { return }
                        self.say(L("Reading the text in the picture… The first time, macOS makes its reader ready, which can take a minute."))
                    }
                    let image = self.original
                    let expected = self.config.targets.map(\.google) + macLanguages()
                    let began = Date()
                    let lines = try await PictureReader.linesApart(in: image, languages: expected)
                    try Task.checkCancellation()
                    self.blocks = PictureReader.blocks(lines)
                    Log.note(String(format: "window: %d lines read, %d texts, in %.1f s", lines.count, self.blocks?.count ?? 0, Date().timeIntervalSince(began)))
                }
                try await self.translateBlocks()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, !self.closed else { return }
                self.failed = true
                self.say(describe(error), problem: true)
                Log.note("window: \(error)")
                self.onSettled?()
            }
        }
    }

    private func translateBlocks() async throws {
        guard var all = blocks else { return }
        for i in all.indices { all[i].translation = nil }
        blocks = all
        let worth = all.indices.filter { all[$0].hasWords }
        guard !worth.isEmpty else {
            painted = nil
            showPicture()
            say(L("No text was found in this window."))
            onSettled?()
            return
        }
        var done = 0
        say(L("Translating… %ld of %ld", 0, worth.count))
        var lastPaint = Date.distantPast
        let began = Date()
        let result = try await translateMany(worth.map { all[$0].text }, engine: engine, target: target, config: config) { place, made in
            guard !Task.isCancelled else { return }  // a late one, for a method or a language no longer chosen
            all[worth[place]].translation = made
            done += 1
            self.blocks = all
            self.say(L("Translating… %ld of %ld", done, worth.count))
            // The picture fills in while the translations come; not more often than it can be watched.
            if Date().timeIntervalSince(lastPaint) > 0.4 || done == worth.count {
                lastPaint = Date()
                self.repaint()
            }
        }
        try Task.checkCancellation()
        repaint()
        if result.failed > 0 {
            say(L("Not translated: %ld.", result.failed) + (result.reason.map { " " + $0 } ?? ""), problem: result.failed == worth.count)
        } else {
            say(L("Translation into %@", target.inText))
        }
        Log.note(String(format: "window: %d texts, %d not translated, \(engine), in %.1f s", worth.count, result.failed, Date().timeIntervalSince(began)))
        onSettled?()
    }

    private func repaint() {
        guard let blocks, let pixels else { return }
        painted = PicturePainter.paint(original, blocks: blocks, pixels: pixels, scale: scale)
        showPicture()
    }

    private func say(_ text: String, problem: Bool = false) {
        statusText = text
        status.stringValue = text
        status.textColor = problem ? .systemRed : .secondaryLabelColor
        status.toolTip = text
    }

    @objc private func showPicture() {
        let shown = originalButton.state == .on ? original : (painted ?? original)
        imageView.image = NSImage(cgImage: shown, size: NSSize(width: CGFloat(shown.width) / scale, height: CGFloat(shown.height) / scale))
    }

    @objc private func targetChanged() {
        guard config.targets.indices.contains(menu.indexOfSelectedItem) else { return }
        target = config.targets[menu.indexOfSelectedItem]
        start()
    }

    /// Another method: the texts, read once, are translated anew by it.
    @objc private func engineChanged() {
        guard config.engines.indices.contains(engineControl.selectedSegment) else { return }
        engine = config.engines[engineControl.selectedSegment]
        start()
    }

    /// Chooses the method as the selector does (tests). false: it is not among the methods.
    func choose(_ method: Engine) -> Bool {
        guard let index = config.engines.firstIndex(of: method) else { return false }
        engineControl.selectedSegment = index
        engineChanged()
        return true
    }

    /// The gear: the settings open in the picture's place. (It floats over every window, and
    /// would lie over theirs.)
    @objc private func openSettings() {
        close()
        (NSApp.delegate as? AppDelegate)?.showSettingsFromGear()
    }

    var gear: NSButton { settingsButton }  // (checks)

    @objc func copyPicture() {
        guard let image = imageView.image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        let before = copyButton.title
        copyButton.title = L("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton.title = before }
    }
}

// MARK: - A short note by the pointer

/// A few words in a small floating panel by the pointer, for when the shortcut can't do what
/// it was pressed for. A click, Esc or a few seconds take it away.
@MainActor
enum Note {
    private static var panel: PopupPanel?
    private static var monitor: Any?
    private static var number = 0

    static func show(_ text: String) {
        hide()
        let width: CGFloat = 340, pad: CGFloat = 12
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.isSelectable = false
        let height = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 2 * pad, height: 1000)).height ?? 16)
        let made = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height + 2 * pad),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let background = made.makeFloating()
        label.frame = NSRect(x: pad, y: pad, width: width - 2 * pad, height: height)
        background.addSubview(label)
        made.onClose = { hide() }
        let pointer = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(pointer.x - 16, visible.minX + 6), visible.maxX - width - 6)
        let y = max(visible.minY + 6, pointer.y - 14 - made.frame.height)
        made.setFrameOrigin(NSPoint(x: x, y: y))
        made.orderFrontRegardless()
        panel = made
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { hide() }
        }
        number += 1
        let mine = number
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if mine == number { hide() } }
    }

    static func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
func showNote(_ text: String) { Note.show(text) }
