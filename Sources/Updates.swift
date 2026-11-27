import Cocoa
import Security

// BTranslate learns of a newer version of itself and updates by running its installer again.
// The installer builds from source on the Mac (there is no developer signature, so a
// downloaded binary would be blocked), and it already knows how to replace a running app and
// keep the settings: an update is that same line, started by the app.
//
// The check asks two things of GitHub: the VERSION file on main (what the installer of the one
// line installs), and whether the source archive of that version's tag is there. The tag is
// pushed some minutes after VERSION changes, and until then the installer would fail.

/// A version as "1.10.0": compared by its numbers, so 1.10.0 is newer than 1.9.0.
struct Version: Comparable, CustomStringConvertible {
    let parts: [Int]

    /// nil for anything that is not three numbers with dots between them.
    init?(_ text: String) {
        let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 6, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(piece) else { return nil }
            parts.append(number)
        }
        self.parts = parts
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (a: Version, b: Version) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

/// Where the update stands. The About page of the settings shows it in words.
enum UpdateState: Equatable {
    case never                  // not looked for yet in this run
    case checking
    case upToDate(Date)         // when it was last found to be so
    case available(String)      // a newer version, with its release there
    case failed(String)         // could not check, and why
    case updating(String)       // the installer is at work, to this version
    case updateFailed(String)   // the installer ended without the update, and why
    case installed(String)      // this run is the version an update the user asked for aimed at
}

@MainActor
final class Updater {
    static let shared = Updater()
    /// Posted whenever `state` changes: the About page and the gears follow it.
    static let changed = Notification.Name("io.github.baakhoff.btranslate.update")

    /// Only the app itself (Sources/main.swift sets this) writes its bookkeeping into the
    /// settings and may run the real installer. Every command-line mode is a check, and a
    /// check that reached the real installer would reinstall the user's app under them.
    static var isTheApp = false

    private let env = ProcessInfo.processInfo.environment
    private(set) var state: UpdateState = .never {
        didSet { if state != oldValue { NotificationCenter.default.post(name: Updater.changed, object: nil) } }
    }

    /// How long the automatic update waits before it looks again whether something of
    /// BTranslate is on the screen. (A check makes it short.)
    var quietWait: TimeInterval = 60
    /// What the automatic update waits for: nothing of BTranslate on the screen.
    var nothingShowing: () -> Bool = {
        Popup.current == nil && TypePanel.current == nil && PictureWindow.current == nil
            && !SettingsController.shared.isVisible && !WindowShot.shared.isChoosing
    }
    /// What happens after an update the user asked for: the settings open on the About page.
    var openAbout: () -> Void = {
        (NSApp.delegate as? AppDelegate)?.showSettings()
        SettingsController.shared.showPage(.about)
    }

    private var dailyTimer: Timer?
    private var quietTimer: Timer?
    private var memory: [String: Any] = [:]  // a check's bookkeeping: it never reaches the settings

    private init() {
        // For the checks of the gears: as if a check had found this version.
        if !Updater.isTheApp, let waiting = env["BTRANSLATE_UPDATE_WAITING"], Version(waiting) != nil { state = .available(waiting) }
    }

    // MARK: What is asked, and of whom

    /// The version this copy of BTranslate is (BTRANSLATE_VERSION stands in for it in tests).
    var current: String {
        env["BTRANSLATE_VERSION"] ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// The folder on main the installer of the one line comes from. BTRANSLATE_UPDATE_URL stands in for it.
    private var base: String {
        var url = env["BTRANSLATE_UPDATE_URL"] ?? "https://raw.githubusercontent.com/baakhoff/btranslate/main"
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    private func archive(_ version: String) -> String {
        let path = "/archive/refs/tags/v\(version).tar.gz"
        return env["BTRANSLATE_UPDATE_URL"] != nil ? base + path : "https://github.com/baakhoff/btranslate" + path
    }

    /// The line that installs BTranslate, as the README and the About page show it.
    static let installLine = "curl -fsSL https://raw.githubusercontent.com/baakhoff/btranslate/main/install.sh | bash"

    static var logFile: URL {
        if let own = ProcessInfo.processInfo.environment["BTRANSLATE_UPDATE_LOG"], !own.isEmpty { return URL(fileURLWithPath: own) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BTranslate-update.log")
    }

    /// Whether this copy is signed ad hoc, as the installer signs it without this Mac's own
    /// certificate: then macOS wants the shortcut's permissions given again after each update.
    /// BTRANSLATE_SIGNED=adhoc|own stands in for the answer.
    static let isSignedAdHoc: Bool = {
        if let forced = ProcessInfo.processInfo.environment["BTRANSLATE_SIGNED"] { return forced != "own" }
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return true }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }()

    // MARK: The bookkeeping: the last check, and the note of a started update

    private func stored(_ key: String) -> Any? {
        if !Updater.isTheApp, let value = memory[key] { return value is NSNull ? nil : value }
        return UserDefaults.standard.object(forKey: key)  // a check is given these as -key value
    }

    private func store(_ value: Any?, _ key: String) {
        guard Updater.isTheApp else {
            memory[key] = value ?? NSNull()
            return
        }
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// (A check may give it as text: -lastUpdateCheck 2026-11-27T10:00:00Z.)
    private func storedBool(_ key: String) -> Bool {
        if !Updater.isTheApp, let value = memory[key] { return value as? Bool ?? false }
        return UserDefaults.standard.bool(forKey: key)  // also "YES" given as -key value
    }

    var lastCheck: Date? {
        let value = stored("lastUpdateCheck")
        return value as? Date ?? (value as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// The note of a started update, as it would be kept: "from 1.0.0 to 1.1.0, asked by the user" (checks).
    var noteText: String {
        guard let to = stored("updateTo") as? String, !to.isEmpty else { return "none" }
        let asked = storedBool("updateAsked")
        return "from \(stored("updateFrom") as? String ?? "?") to \(to), \(asked ? "asked by the user" : "automatic")"
    }

    // MARK: When to look

    /// The app has started: the note of an update is looked at, and the daily check begins.
    func appStarted() {
        lookAtNote()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.lookIfDue() }
        // The Mac sleeps and the app runs for days: the day is kept by the date of the last
        // check, looked at every hour, not by one long timer.
        dailyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.lookIfDue() }
        }
    }

    /// The daily check: while the setting is on, once the last check is a day old.
    func lookIfDue() {
        guard Config.load().checkForUpdates else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        Task { await check() }
    }

    /// The About page has come up: what it says should not be more than an hour old.
    func aboutShown() {
        guard Config.load().checkForUpdates, state != .checking, !isBusy else { return }
        if case .available = state { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 3600 { return }
        Task { await check() }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .updating: return true
        default: return false
        }
    }

    var waitingVersion: String? {
        if case .available(let version) = state { return version }
        return nil
    }

    // MARK: The check

    private enum Answer: Sendable {
        case newer(String), notYet, same, notAVersion, http(Int)
    }

    /// Asks GitHub (or BTRANSLATE_UPDATE_URL) whether there is a newer version, fifteen seconds at most.
    func check() async {
        guard !isBusy else { return }
        // No check asks GitHub: the tests give every run an address of their own.
        if !Updater.isTheApp && env["BTRANSLATE_UPDATE_URL"] == nil {
            state = .failed("a check asks only BTRANSLATE_UPDATE_URL, and it is not set")
            return
        }
        state = .checking
        let versionURL = base + "/VERSION", mine = current, template = archive("VERSION_HERE")
        do {
            let answer = try await withThrowingTaskGroup(of: Answer?.self) { group -> Answer in
                group.addTask { try await Updater.ask(versionURL, mine: mine, archive: template) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                guard let first else { throw URLError(.timedOut) }
                return first
            }
            switch answer {
            case .newer(let version):
                store(Date(), "lastUpdateCheck")
                found(version)
            case .notYet, .same:
                store(Date(), "lastUpdateCheck")
                state = .upToDate(Date())
            case .notAVersion:
                state = .failed(L("GitHub's answer is not a version number."))
            case .http(let code):
                state = .failed(L("GitHub answered HTTP %ld.", code))
            }
        } catch {
            state = .failed(describe(error))
        }
    }

    private nonisolated static func ask(_ versionURL: String, mine: String, archive template: String) async throws -> Answer {
        guard let url = URL(string: versionURL) else { return .notAVersion }
        let (data, response) = try await net.data(for: URLRequest(url: url, timeoutInterval: 15))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { return .http(code) }
        guard let theirs = Version(String(decoding: data.prefix(64), as: UTF8.self)) else { return .notAVersion }
        guard let own = Version(mine), own < theirs else { return Version(mine) == nil ? .notAVersion : .same }
        // The release must be there too: the installer downloads its source.
        guard let tag = URL(string: template.replacingOccurrences(of: "VERSION_HERE", with: theirs.description)) else { return .notYet }
        var head = URLRequest(url: tag, timeoutInterval: 15)
        head.httpMethod = "HEAD"
        let (_, tagResponse) = try await net.data(for: head)
        return (tagResponse as? HTTPURLResponse)?.statusCode == 200 ? .newer(theirs.description) : .notYet
    }

    /// A newer version is there. With automatic updates on, it is installed as soon as
    /// nothing of BTranslate is on the screen.
    func found(_ version: String) {
        state = .available(version)
        if Config.load().autoUpdate { updateWhenQuiet() }
    }

    private func updateWhenQuiet() {
        quietTimer?.invalidate()
        quietTimer = nil
        guard case .available = state, Config.load().autoUpdate else { return }
        if nothingShowing() {
            update(asked: false)
            return
        }
        quietTimer = Timer.scheduledTimer(withTimeInterval: quietWait, repeats: false) { _ in
            MainActor.assumeIsolated { Updater.shared.updateWhenQuiet() }
        }
    }

    // MARK: The update

    /// The command the update runs: what the one line does, unless BTRANSLATE_UPDATE_COMMAND stands in for it.
    private var command: String? {
        if let own = env["BTRANSLATE_UPDATE_COMMAND"], !own.isEmpty { return own }
        guard Updater.isTheApp else { return nil }
        return "/usr/bin/curl -fsSL '\(base)/install.sh' | /bin/bash"
    }

    private var logStart: UInt64 = 0

    /// Runs the installer as a process of its own. It ends this app before it replaces it,
    /// and starts the new one, so it must outlive the app: its output goes to a file, never
    /// to a pipe the app would hold (a pipe with nobody reading kills a writer).
    func update(asked: Bool) {
        guard case .available(let version) = state else { return }
        quietTimer?.invalidate()
        guard let command else {
            state = .updateFailed("a check never runs the real installer: BTRANSLATE_UPDATE_COMMAND is not set")
            return
        }
        let log = Updater.logFile
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        logStart = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64) ?? 0
        let stamp = ISO8601DateFormatter().string(from: Date())
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\n\(stamp) BTranslate \(current) → \(version)\(asked ? "" : ", automatic")\n".utf8))
            logStart = (try? handle.offset()) ?? logStart
            try? handle.close()
        }
        // Noted first: the next start tells from it whether the update arrived.
        store(current, "updateFrom")
        store(version, "updateTo")
        store(asked, "updateAsked")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The shell appends to the log itself, and reads nothing: there is no terminal to ask on.
        process.arguments = ["-c", "exec >>\"$0\" 2>&1 </dev/null\n" + command, log.path]
        var environment = env
        environment["BTRANSLATE_PACK"] = "no"        // the language pack is the user's own choice, made in the settings
        environment["BTRANSLATE_AUTOUPDATE"] = "keep"  // and so is updating by itself
        process.environment = environment
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task { @MainActor in Updater.shared.ended(status: status) }
        }
        do {
            try process.run()
            state = .updating(version)
        } catch {
            forgetNote()
            state = .updateFailed(error.localizedDescription)
        }
    }

    /// The installer ended and this app still runs: the real one ends the app before it
    /// replaces it, so it failed before that (no Command Line Tools, no network, a build that
    /// failed). Its last line says why.
    private func ended(status: Int32) {
        guard case .updating(let version) = state else { return }
        forgetNote()
        if status == 0 {
            state = .available(version)  // it said it was done, yet this copy is still the old one: Update stays on offer
            return
        }
        state = .updateFailed(lastLogLine() ?? L("The installer ended with status %ld.", Int(status)))
    }

    private func lastLogLine() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: Updater.logFile) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: logStart)
        let tail = handle.readDataToEndOfFile().suffix(4000)
        let lines = String(decoding: tail, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        return last.count > 300 ? String(last.prefix(300)) + "…" : last
    }

    private func forgetNote() {
        for key in ["updateFrom", "updateTo", "updateAsked"] { store(nil, key) }
    }

    /// At the start: if an update was started, whether this is the version it aimed at.
    private func lookAtNote() {
        guard let to = stored("updateTo") as? String, !to.isEmpty else { return }
        let asked = storedBool("updateAsked")
        forgetNote()
        if let wanted = Version(to), let now = Version(current), now >= wanted {
            state = .installed(now.description)
            if asked { openAbout() }
        } else {
            state = .updateFailed(L("The update to %@ did not finish.", to) + (lastLogLine().map { " " + $0 } ?? ""))
        }
    }

    /// The same, for a check: the note is given as -updateTo, -updateFrom, -updateAsked.
    func lookAtNoteForTest() { lookAtNote() }

    /// Sets the state, to draw each on the About page (checks only).
    func show(_ state: UpdateState) {
        guard !Updater.isTheApp else { return }
        self.state = state
    }

    // MARK: In words

    /// What the About page says.
    var stateText: String {
        switch state {
        case .never:
            return L("BTranslate has not looked for a newer version yet.")
        case .checking:
            return L("Looking for a newer version…")
        case .upToDate(let date):
            let when = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
            return L("BTranslate is up to date. Last checked: %@.", when)
        case .available(let version):
            return L("BTranslate %@ is available. This one is %@.", version, current)
        case .failed(let why):
            return L("Could not look for a newer version: %@", why)
        case .updating(let version):
            return L("Updating to %@: it is downloaded and built on this Mac, which takes about a minute. BTranslate then starts again by itself.", version)
        case .updateFailed(let why):
            return L("The update did not work: %@", why) + "\n" + L("The installer's log: %@", Updater.logFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        case .installed(let version):
            return L("BTranslate %@ is installed.", version)
        }
    }

    /// One word for the state, as the checks print it.
    var stateName: String {
        switch state {
        case .never: return "never checked"
        case .checking: return "checking"
        case .upToDate: return "up to date"
        case .available(let v): return "available: \(v)"
        case .failed(let why): return "could not check: \(why)"
        case .updating(let v): return "updating to \(v)"
        case .updateFailed(let why): return "update failed: \(why)"
        case .installed(let v): return "installed: \(v)"
        }
    }
}

/// Versions compared (for --selftest).
func updateSelfTest() -> [String] {
    var failures: [String] = []
    func expect(_ what: String, _ ok: Bool) { if !ok { failures.append(what) } }
    func newer(_ a: String, _ b: String) -> Bool { Version(a).map { mine in Version(b).map { mine < $0 } ?? false } ?? false }
    expect("versions: by their numbers", newer("1.9.0", "1.10.0") && !newer("1.10.0", "1.9.0") && newer("1.0.0", "1.0.1") && newer("1.2.3", "2.0.0"))
    expect("versions: the same is not newer", !newer("1.0.0", "1.0.0") && Version("1.0.0") == Version(" 1.0.0\n"))
    expect("versions: what is not one", Version("1.0") == nil && Version("1.0.0.0") == nil && Version("v1.0.0") == nil && Version("1..0") == nil
        && Version("<html>") == nil && Version("1.0.x") == nil && Version("") == nil && Version("1.-1.0") == nil)
    expect("versions: written back", Version("01.10.0")?.description == "1.10.0")
    return failures
}

// MARK: - The gears

extension NSButton {
    /// A gear that opens the settings: tinted, and saying so, while a newer version waits.
    func beGear() {
        beSymbol("gearshape", size: 13, tip: L("BTranslate settings"))
        if let version = Updater.shared.waitingVersion {
            contentTintColor = .controlAccentColor
            toolTip = L("BTranslate %@ is available. Click to see it in the settings.", version)
        }
    }

    /// How a gear looks and where it leads, as the checks print it.
    var gearLine: String {
        let tinted = contentTintColor == .controlAccentColor
        return "gear: \(tinted ? "tinted" : "plain"), tooltip “\(toolTip ?? "")”, opens \(Updater.shared.waitingVersion != nil ? "the About page" : "the settings")"
    }
}

extension AppDelegate {
    /// What a gear does: the settings, on the About page while a newer version waits.
    func showSettingsFromGear() {
        showSettings()
        if Updater.shared.waitingVersion != nil { SettingsController.shared.showPage(.about) }
    }
}
