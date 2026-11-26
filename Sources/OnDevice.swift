import Cocoa
import NaturalLanguage
import Network

// Translating without internet: the "Offline" method. It is the translation built into
// macOS (Apple's Translation framework): it runs on the Mac and nothing leaves it. Apple has
// far fewer languages than Google (about 25; no Latvian, Serbian or Croatian). Depending on
// the Mac, they are all there already or each is a download that macOS manages.
//
// BTranslate uses it from macOS 26 on, where a translation can be made without showing a
// window. The language of a text is told by the Mac's own recognizer, which is less sure of
// itself than Google on a short text: when it can't tell, the popup asks for the pencil.
//
// The installer builds the app on the user's Mac, with whatever Command Line Tools are
// there. Tools from before macOS 26 (Swift older than 6.2) do not know these parts of the
// framework, so everything that touches it is in `Apple` below, which has a second, empty
// version for them: the app then builds without the Offline method.
//
// For tests, BTRANSLATE_OFFLINE=mock stands in for Apple's translation (see `Mock`).

/// Whether a language, or a pair of them, can be translated without internet.
enum OfflineStatus: String {
    case installed     // yes
    case downloadable  // once macOS has downloaded it
    case unavailable   // Apple has not got it
}

enum OfflineError: Error {
    case needsNewerMac
    case unknownLanguage                // the recognizer can't tell what language the text is in
    case noLanguage(String)             // Google's code of a language Apple has not got
    case noPair(String, String)         // two languages Apple does not translate between
    case notDownloaded(String, String)  // a pair that needs a download first
}

enum OnDevice {
    private static let mock = ProcessInfo.processInfo.environment["BTRANSLATE_OFFLINE"] == "mock"

    /// False on a Mac whose macOS is too old for it, and in an app built with old tools.
    static var isAvailable: Bool { mock || Apple.isAvailable }

    // MARK: Languages

    /// Google's code of a language → the language as macOS knows it.
    static func language(_ code: String) -> Locale.Language {
        let known = ["iw": "he", "no": "nb", "zh-CN": "zh-Hans", "zh-TW": "zh-Hant", "pt": "pt-BR"]
        return Locale.Language(identifier: known[code] ?? code)
    }

    /// A language as the Mac's recognizer names it → Google's code.
    static func googleCode(_ recognized: String) -> String {
        ["he": "iw", "nb": "no", "nn": "no", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW"][recognized] ?? recognized
    }

    private static func base(_ code: String) -> String {
        language(code).languageCode?.identifier ?? code
    }

    /// The same language, written the same way: nothing to translate.
    static func same(_ a: String, _ b: String) -> Bool {
        let first = language(a), second = language(b)
        guard first.languageCode == second.languageCode else { return false }
        return first.languageCode?.identifier != "zh" || first.script == second.script
    }

    private static var cachedLanguages: Set<String>?

    /// The languages Apple translates, as their plain codes ("en", "ru", "zh").
    static func supportedLanguages() async -> Set<String> {
        if let cachedLanguages { return cachedLanguages }
        let codes = mock ? Mock.installed.union(Mock.downloadable) : await Apple.supportedLanguages()
        cachedLanguages = codes
        return codes
    }

    /// Whether a text in the language `source` can be translated into `target` (Google's codes).
    static func status(from source: String, to target: String) async -> OfflineStatus {
        let supported = await supportedLanguages()
        guard supported.contains(base(source)), supported.contains(base(target)), !same(source, target),
              target != "sr-Latn" else { return .unavailable }
        if mock { return Mock.installed.contains(base(source)) && Mock.installed.contains(base(target)) ? .installed : .downloadable }
        return await Apple.status(from: language(source), to: language(target))
    }

    /// Whether each of these languages (ids of the list in Settings) works without internet.
    /// macOS answers for pairs of languages, so a language is asked about together with
    /// English, and English together with every other one: it is there if any pair with it is.
    static func statuses(of ids: [String]) async -> [String: OfflineStatus] {
        var out: [String: OfflineStatus] = [:]
        guard isAvailable else { return out }
        let supported = await supportedLanguages()
        for id in ids {
            guard supported.contains(base(id)), id != "sr-Latn" else { out[id] = .unavailable; continue }
            if base(id) != "en" {
                out[id] = await status(from: "en", to: id)
            } else {
                var english = OfflineStatus.downloadable
                for other in supported.sorted() where other != "en" && english != .installed {
                    if await status(from: other, to: id) == .installed { english = .installed }
                }
                out[id] = english
            }
        }
        return out
    }

    // MARK: The language of a text

    /// The language of `text` by the Mac's own recognizer, as Google's code; nil when it can't
    /// tell. A language it is sure of is returned whether Apple translates it or not; when it
    /// is not sure, only a clear winner among the languages that can be translated counts.
    static func recognize(_ text: String, among supported: Set<String>) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6 {
            return googleCode(best.key.rawValue)
        }
        recognizer.reset()
        recognizer.languageConstraints = supported.flatMap { $0 == "zh" ? ["zh-Hans", "zh-Hant"] : [$0] }.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        if let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.75 {
            return googleCode(best.key.rawValue)
        }
        return nil
    }

    /// The Mac's recognizer knows Serbian in Latin letters as Croatian. For someone who has
    /// Serbian among their languages (in the list, or picked with the pencil) and not
    /// Croatian, such a text is Serbian.
    static func asTheUserMeans(_ code: String, list: [String], recent: [String]) -> String {
        guard code == "hr", !list.contains("hr"), !recent.contains("hr") else { return code }
        return (list + recent).contains { $0 == "sr" || $0 == "sr-Latn" } ? "sr" : code
    }

    // MARK: Translating

    /// `source` is the text's language when the user has set it; nil to tell it from the text.
    /// Returns the translation and the code of the language it was translated from.
    static func translate(_ text: String, from source: Target?, to target: Target) async throws -> (text: String, source: String) {
        guard isAvailable else { throw OfflineError.needsNewerMac }
        let supported = await supportedLanguages()
        guard supported.contains(base(target.google)), target.id != "sr-Latn" else { throw OfflineError.noLanguage(target.google) }
        let recognized = source == nil ? recognize(text, among: supported) : nil
        guard let from = source?.google ?? recognized.map({
            asTheUserMeans($0, list: Config.load().languageIDs, recent: UserDefaults.standard.stringArray(forKey: "recentSources") ?? [])
        }) else { throw OfflineError.unknownLanguage }
        guard supported.contains(base(from)) else { throw OfflineError.noLanguage(from) }
        if same(from, target.google) { return (text, from) }  // already in that language
        switch await status(from: from, to: target.google) {
        case .unavailable: throw OfflineError.noPair(from, target.google)
        case .downloadable: throw OfflineError.notDownloaded(from, target.google)
        case .installed: break
        }
        // Line by line, so that the line breaks come out as they went in.
        var lines = text.components(separatedBy: "\n")
        let filled = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let translated = mock ? filled.map { Mock.translate(lines[$0], from: from, to: target.google) }
                              : try await Apple.translate(filled.map { lines[$0] }, from: from, to: target.google)
        for (i, line) in zip(filled, translated) { lines[i] = line }
        return (lines.joined(separator: "\n"), from)
    }

    // MARK: Downloading a language

    /// Asks macOS to download what the language `id` needs to be translated offline: macOS
    /// shows its own sheet on `window` and the user confirms there. macOS downloads for a
    /// pair of languages: `partner` is the other one (for English, a language of the user's
    /// list; for any other language, English). `done` is called when the sheet is gone,
    /// whatever the answer; the download itself goes on in the background.
    @MainActor
    static func download(_ id: String, with partner: String, in window: NSWindow, done: @escaping @MainActor () -> Void) {
        if mock { done(); return }
        Apple.download(from: language(partner), to: language(id), in: window, done: done)
    }

    /// For tests: English, Russian and German are there, French and Spanish need a download,
    /// and a translation is the text with a label in front.
    private enum Mock {
        static let installed: Set<String> = ["en", "ru", "de"]
        static let downloadable: Set<String> = ["fr", "es"]
        static func translate(_ line: String, from: String, to: String) -> String { "OFFLINE \(from)>\(to): \(line)" }
    }
}

// MARK: - Apple's Translation framework

#if compiler(>=6.2) && canImport(Translation)
import SwiftUI
import Translation

private enum Apple {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static func supportedLanguages() async -> Set<String> {
        guard #available(macOS 26.0, *) else { return [] }
        return Set(await LanguageAvailability().supportedLanguages.compactMap { $0.languageCode?.identifier })
    }

    static func status(from source: Locale.Language, to target: Locale.Language) async -> OfflineStatus {
        guard #available(macOS 26.0, *) else { return .unavailable }
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: return .installed
        case .supported: return .downloadable
        default: return .unavailable
        }
    }

    /// Each of `lines` translated, in their order. `from` and `to` are Google's codes.
    static func translate(_ lines: [String], from: String, to: String) async throws -> [String] {
        guard #available(macOS 26.0, *) else { throw OfflineError.needsNewerMac }
        let session = TranslationSession(installedSource: OnDevice.language(from), target: OnDevice.language(to))
        var out = lines
        do {
            let requests = lines.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            for response in try await session.translations(from: requests) {
                if let i = response.clientIdentifier.flatMap(Int.init), out.indices.contains(i) { out[i] = response.targetText }
            }
        } catch {
            if TranslationError.notInstalled ~= error { throw OfflineError.notDownloaded(from, to) }
            if TranslationError.unsupportedSourceLanguage ~= error { throw OfflineError.noLanguage(from) }
            if TranslationError.unsupportedTargetLanguage ~= error { throw OfflineError.noLanguage(to) }
            if TranslationError.unsupportedLanguagePairing ~= error { throw OfflineError.noPair(from, to) }
            throw error
        }
        return out
    }

    /// macOS's "download these languages?" sheet. It can only be asked for from a view in a
    /// window, which is what the tiny SwiftUI view is for.
    @MainActor
    static func download(from source: Locale.Language, to target: Locale.Language, in window: NSWindow, done: @escaping @MainActor () -> Void) {
        guard #available(macOS 26.0, *), let content = window.contentView else { done(); return }
        var holder: NSView?
        let finish: @MainActor () -> Void = {
            holder?.removeFromSuperview()
            holder = nil
            done()
        }
        let host = NSHostingView(rootView: Color.clear.translationTask(source: source, target: target) { session in
            try? await session.prepareTranslation()
            await MainActor.run { finish() }
        })
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        content.addSubview(host)
        holder = host
    }
}

#else

/// Built with tools that do not know the framework: no Offline method.
private enum Apple {
    static var isAvailable: Bool { false }
    static func supportedLanguages() async -> Set<String> { [] }
    static func status(from source: Locale.Language, to target: Locale.Language) async -> OfflineStatus { .unavailable }
    static func translate(_ lines: [String], from: String, to: String) async throws -> [String] { throw OfflineError.needsNewerMac }
    @MainActor
    static func download(from source: Locale.Language, to target: Locale.Language, in window: NSWindow, done: @escaping @MainActor () -> Void) { done() }
}

#endif

// MARK: - Is there a connection?

/// The errors a request ends with when the Mac has no way to the internet.
func isConnectionError(_ error: Error) -> Bool {
    guard let code = (error as? URLError)?.code else { return false }
    return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .timedOut, .internationalRoamingOff, .dataNotAllowed].contains(code)
}

/// A server on this Mac or in the local network: it is reached without internet.
func isLocalAddress(_ address: String) -> Bool {
    guard let host = URL(string: address)?.host?.lowercased() else { return false }
    if host == "localhost" || host == "::1" || host.hasSuffix(".local") || host.hasPrefix("127.") || host.hasPrefix("10.")
        || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") { return true }
    let parts = host.split(separator: ".").compactMap { Int($0) }  // 172.16.0.0 to 172.31.255.255
    return parts.count == 4 && parts[0] == 172 && (16...31).contains(parts[1])
}

/// Tells when the Mac has a way to the internet again.
@MainActor
final class Connection {
    static let shared = Connection()

    private let monitor = NWPathMonitor()
    private var online = true
    private var waiting: [@MainActor () -> Void] = []

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in Connection.shared.changed(to: online) }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.baakhoff.btranslate.connection"))
    }

    /// Runs `work` once, the next time the connection comes back after being gone.
    func whenBack(_ work: @escaping @MainActor () -> Void) {
        waiting.append(work)
    }

    private func changed(to nowOnline: Bool) {
        let cameBack = nowOnline && !online
        online = nowOnline
        guard cameBack else { return }
        // A moment for the new connection to settle (names to resolve) before anything is asked of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.online else { return }
            let work = self.waiting
            self.waiting = []
            for item in work { item() }
        }
    }
}
