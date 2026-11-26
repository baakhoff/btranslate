import Cocoa
import NaturalLanguage
import Network

// Translating without internet: the "Offline" method. Two things can do the work, and
// nothing leaves the Mac with either:
//   - the translation built into macOS (Apple's Translation framework), from macOS 26 on,
//     where a translation can be made without showing a window. About 25 languages; no
//     Latvian, Serbian or Croatian. Depending on the Mac, they are all there already or each
//     is a download that macOS manages;
//   - BTranslate's own language pack (NLLB-200, see NLLB.swift), an optional download with
//     about 200 languages, for what Apple has not got.
// Apple's is used wherever it can translate; the pack does the rest.
//
// The language of a text has to be told on the Mac. The Mac's own recognizer is less sure
// of itself than Google on a short text and does not know Latvian, Lithuanian, Estonian or
// Serbian at all: those are told by their letters and commonest words first. When nothing
// is sure, the popup asks for the pencil, because the pack translates a text read as the
// wrong language into nonsense.
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
    case needsPack(String, String)      // a pair only the language pack translates, and it is not installed
}

enum OnDevice {
    private static let mock = ProcessInfo.processInfo.environment["BTRANSLATE_OFFLINE"] == "mock"

    /// False where neither macOS can do it (too old, or the app was built with old tools) nor
    /// the language pack is installed.
    static var isAvailable: Bool { mock || Apple.isAvailable || LanguagePack.isInstalled }

    /// The languages the language pack translates, as Google's codes.
    private static let packLanguages: Set<String> = Set(googleLanguages.map(\.code).filter { NLLBLanguage.code($0) != nil })

    /// Whether the pack has this language (installed or not). `id` is a language's id in the
    /// lists: Google's code, or "sr-Latn".
    static func packHas(_ id: String) -> Bool { NLLBLanguage.code(id) != nil }

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
    private static let cacheLock = NSLock()  // it is asked for from several threads at once

    /// The languages Apple translates, as their plain codes ("en", "ru", "zh").
    static func supportedLanguages() async -> Set<String> {
        if let known = cacheLock.withLock({ cachedLanguages }) { return known }
        let codes = mock ? Mock.installed.union(Mock.downloadable) : await Apple.supportedLanguages()
        cacheLock.withLock { cachedLanguages = codes }
        return codes
    }

    /// Whether Apple's translation takes a text in the language `source` into `target`.
    private static func appleStatus(from source: String, to target: String) async -> OfflineStatus {
        let supported = await supportedLanguages()
        guard supported.contains(base(source)), supported.contains(base(target)), !same(source, target),
              target != "sr-Latn" else { return .unavailable }
        if mock { return Mock.installed.contains(base(source)) && Mock.installed.contains(base(target)) ? .installed : .downloadable }
        return await Apple.status(from: language(source), to: language(target))
    }

    /// Whether a text in the language `source` can be translated into `target` (Google's
    /// codes; the target may be "sr-Latn"), by Apple's translation or by the language pack.
    static func status(from source: String, to target: String) async -> OfflineStatus {
        let apple = await appleStatus(from: source, to: target)
        if apple == .installed || same(source, target) { return apple }
        let pack = packHas(source) && packHas(target)
        if pack && LanguagePack.isInstalled { return .installed }
        return apple == .downloadable || pack ? .downloadable : .unavailable
    }

    /// Whether each of these languages (ids of the list in Settings) works without internet.
    /// macOS answers for pairs of languages, so a language is asked about together with
    /// English, and English together with every other one: it is there if any pair with it is.
    static func statuses(of ids: [String]) async -> [String: OfflineStatus] {
        var out: [String: OfflineStatus] = [:]
        guard isAvailable else { return out }
        let supported = await supportedLanguages()
        for id in ids {
            var status = OfflineStatus.unavailable
            if supported.contains(base(id)), id != "sr-Latn" {
                if base(id) != "en" {
                    status = await appleStatus(from: "en", to: id)
                } else {
                    status = .downloadable
                    for other in supported.sorted() where other != "en" && status != .installed {
                        if await appleStatus(from: other, to: id) == .installed { status = .installed }
                    }
                }
            }
            // What Apple has not got, or not here, the language pack may have.
            if status != .installed, packHas(id) { status = LanguagePack.isInstalled ? .installed : .downloadable }
            out[id] = status
        }
        return out
    }

    /// True for a language that works offline only with the language pack: Apple has not got it.
    static func needsPack(_ id: String) async -> Bool {
        let supported = await supportedLanguages()
        return packHas(id) && !(supported.contains(base(id)) && id != "sr-Latn")
    }

    // MARK: The language of a text

    /// Words that are among the commonest of one language and are no word in the big ones.
    private static let ownWords: [String: Set<String>] = [
        "lv": ["labdien", "paldies", "lūdzu", "labrīt", "labvakar", "viņš", "viņa", "esmu", "šodien", "kāpēc", "ļoti", "arī", "pēc", "tikai", "vēl", "nekā"],
        "lt": ["ačiū", "prašau", "labas", "labai", "šiandien", "rytoj", "yra", "aš", "kodėl", "taip", "nėra", "ką"],
        "et": ["tere", "aitäh", "palun", "tänan", "täna", "homme", "väga", "olen", "miks", "ning", "või", "veel"],
    ]

    /// A language told by letters and words of its own: the ones the Mac's recognizer does
    /// not know (Latvian, Lithuanian, Estonian, Serbian in Cyrillic, Macedonian, Belarusian).
    /// nil when the text shows no such sign.
    static func bySigns(_ text: String) -> String? {
        let lower = text.lowercased()
        func count(_ letters: String) -> Int {
            lower.unicodeScalars.reduce(0) { $0 + (letters.unicodeScalars.contains($1) ? 1 : 0) }
        }
        if !isMostlyLatin(lower) {
            if count("ѓќѕ") > 0 { return "mk" }
            if count("ћђ") > 0 { return "sr" }
            if count("ў") > 0 { return "be" }
            if count("їєґ") > 0 { return "uk" }
            return count("јљњџ") > 0 ? "sr" : nil
        }
        let words = Set(lower.split { !$0.isLetter }.map(String.init))
        // Letters only one of them has (ū, š, č and ž are shared; ą and ę are Polish too).
        var points = ["lv": count("āēīķļņģ"), "lt": count("ėįų"), "et": 0]
        for (language, own) in ownWords { points[language, default: 0] += 2 * words.intersection(own).count }
        if words.contains("sveiki") { points[points["lt", default: 0] > points["lv", default: 0] ? "lt" : "lv", default: 0] += 2 }  // a greeting in both
        let ranked = points.sorted { $0.value > $1.value }
        return ranked[0].value >= 1 && ranked[0].value > ranked[1].value ? ranked[0].key : nil
    }

    /// The language of `text`, as Google's code; nil when it can't be told. First by the
    /// signs above; then by the Mac's own recognizer: a language it is sure of is returned
    /// whether it can be translated or not, and when it is not sure, only a clear winner
    /// among the languages that can be translated counts.
    static func recognize(_ text: String, among supported: Set<String>) -> String? {
        if let sure = bySigns(text) { return sure }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6 {
            return googleCode(best.key.rawValue)
        }
        recognizer.reset()
        recognizer.languageConstraints = supported.flatMap { $0 == "zh" ? ["zh-Hans", "zh-Hant"] : [$0] }
            .map { NLLanguage(rawValue: ["iw": "he", "no": "nb"][$0] ?? $0) }
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
    /// Returns the translation and the code of the language it was translated from. `partial`
    /// gets that code and the translation so far while the language pack works, a sentence at a time.
    static func translate(_ text: String, from source: Target?, to target: Target,
                          partial: @escaping @Sendable (String, String) -> Void = { _, _ in }) async throws -> (text: String, source: String) {
        guard isAvailable else { throw OfflineError.needsNewerMac }
        let apple = await supportedLanguages()
        let appleHasTarget = apple.contains(base(target.google)) && target.id != "sr-Latn"
        guard appleHasTarget || packHas(target.id) else { throw OfflineError.noLanguage(target.google) }
        let recognized = source == nil ? recognize(text, among: apple.union(LanguagePack.isInstalled ? packLanguages : [])) : nil
        guard let from = source?.google ?? recognized.map({
            asTheUserMeans($0, list: Config.load().languageIDs, recent: UserDefaults.standard.stringArray(forKey: "recentSources") ?? [])
        }) else { throw OfflineError.unknownLanguage }
        guard apple.contains(base(from)) || packHas(from) else { throw OfflineError.noLanguage(from) }
        if same(from, target.google) {
            // Already in that language. Serbian may still need its other alphabet.
            if target.id == "sr-Latn" { return (latinize(text), from) }
            if target.id == "sr", isMostlyLatin(text) { return (cyrillize(text), from) }
            return (text, from)
        }
        let appleCan = await appleStatus(from: from, to: target.google)
        if appleCan == .installed {
            // Line by line, so that the line breaks come out as they went in.
            var lines = text.components(separatedBy: "\n")
            let filled = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
            let translated = mock ? filled.map { Mock.translate(lines[$0], from: from, to: target.google) }
                                  : try await Apple.translate(filled.map { lines[$0] }, from: from, to: target.google)
            for (i, line) in zip(filled, translated) { lines[i] = line }
            return (lines.joined(separator: "\n"), from)
        }
        // What Apple can't do here, the language pack may.
        if let packSource = NLLBLanguage.source(from, text: text), let packTarget = NLLBLanguage.code(target.id) {
            guard LanguagePack.isInstalled else {
                throw appleCan == .downloadable ? OfflineError.notDownloaded(from, target.google) : OfflineError.needsPack(from, target.google)
            }
            let latin = target.latin
            let translation = try await NLLBEngine.shared.translate(text, from: packSource, to: packTarget) { soFar in
                partial(from, latin ? latinize(soFar) : soFar)
            }
            return (latin ? latinize(translation) : translation, from)
        }
        if appleCan == .downloadable { throw OfflineError.notDownloaded(from, target.google) }
        throw apple.contains(base(from)) && appleHasTarget ? OfflineError.noPair(from, target.google)
            : OfflineError.noLanguage(packHas(from) || apple.contains(base(from)) ? target.google : from)
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
