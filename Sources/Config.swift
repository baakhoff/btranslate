import Foundation

// MARK: - Translation methods and AI providers

/// `device` is the "Offline" method: the translation built into macOS (Sources/OnDevice.swift).
enum Engine: String { case google, ai, device }

struct Provider {
    enum API { case anthropic, openAI }  // openAI: any server with /chat/completions
    let id: String
    let name: String
    let api: API
    let baseURL: String    // empty: the user types it (Custom)
    let models: [String]   // suggestions, the first is the default; the live list replaces them once a key is in
    let keyHelp: String
}

let providers: [Provider] = [
    Provider(id: "anthropic", name: "Anthropic (Claude)", api: .anthropic,
             baseURL: "https://api.anthropic.com/v1",
             models: ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"],
             keyHelp: L("Get a key at %@.", "platform.claude.com → API keys")),
    Provider(id: "openai", name: "OpenAI", api: .openAI,
             baseURL: "https://api.openai.com/v1",
             models: ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.2-sol"],
             keyHelp: L("Get a key at %@.", "platform.openai.com → API keys")),
    Provider(id: "gemini", name: "Google Gemini", api: .openAI,
             baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
             models: ["gemini-3.8-flash"],
             keyHelp: L("Get a key at %@.", "aistudio.google.com → Get API key")),
    Provider(id: "deepseek", name: "DeepSeek", api: .openAI,
             baseURL: "https://api.deepseek.com",
             models: ["deepseek-chat"],
             keyHelp: L("Get a key at %@.", "platform.deepseek.com → API keys")),
    Provider(id: "openrouter", name: "OpenRouter", api: .openAI,
             baseURL: "https://openrouter.ai/api/v1",
             models: ["anthropic/claude-haiku-5.5", "deepseek/deepseek-v4.1-flash", "google/gemini-3.8-flash", "openai/gpt-6-luna"],
             keyHelp: L("Get a key at %@.", "openrouter.ai/keys") + " " + L("One key reaches models from many providers.")),
    Provider(id: "custom", name: L("Custom (OpenAI-compatible)"), api: .openAI,
             baseURL: "",
             models: [],
             keyHelp: L("Any server with /chat/completions, such as Ollama, LM Studio or oMLX. The key is optional.")),
]

// MARK: - Settings

struct Config {
    var googleEnabled = true
    var aiEnabled = false
    var deviceEnabled = true
    var providerID = "anthropic"
    var model = "claude-haiku-5-5"
    var customURL = ""
    var defaultEngine: Engine = .google
    var languageIDs: [String] = []  // the languages in the popup's menus, in order
    var defaultLanguageID = ""      // the language a popup opens with; "" or gone from the list: the first one
    var secondLanguageID = ""       // the one it turns to for a text that is in the default language already;
                                    // "" or gone from the list: the first other language of the list
    var typingLanguageID = ""       // the language the typing panel writes in; "" or gone from the list: the second default
    var googleVoice = true          // read aloud with Google's voice where the Mac has none
    var languageChoice = ""         // BTranslate's own language: "en", "ru", or "" to follow the Mac
    var shortcut: Shortcut? = .standard  // brings BTranslate up from any app; nil: none

    var provider: Provider { providers.first { $0.id == providerID } ?? providers[0] }

    /// The API's base address, without a trailing slash.
    var baseURL: String {
        if let override = ProcessInfo.processInfo.environment["BTRANSLATE_BASE_URL"], !override.isEmpty { return override }
        var url = (provider.baseURL.isEmpty ? customURL : provider.baseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// Whether the AI method has what it needs to answer: an API key for the provider, or,
    /// for a server of your own (where a key is optional), its address.
    var aiIsSetUp: Bool {
        providerID == "custom" ? !baseURL.isEmpty : AISetup.hasKey(providerID)
    }

    /// The methods a popup offers: the ones that are turned on, and of those the AI model
    /// only once it is set up. Never empty.
    var engines: [Engine] {
        let list: [Engine] = (googleEnabled ? [.google] : []) + (aiEnabled && aiIsSetUp ? [.ai] : [])
            + (deviceEnabled && OnDevice.isAvailable ? [.device] : [])
        return list.isEmpty ? [.google] : list
    }

    var startEngine: Engine { engines.contains(defaultEngine) ? defaultEngine : engines[0] }

    /// The languages the popup offers. Never empty.
    var targets: [Target] {
        let list = languageIDs.compactMap(target(id:))
        return list.isEmpty ? defaultLanguageIDs().compactMap(target(id:)) : list
    }

    var startTarget: Target { targets.first { $0.id == defaultLanguageID } ?? targets[0] }

    /// The second default: the one chosen in Settings, or else the first language of the list
    /// that is another language than the default (not its other alphabet). nil with one language.
    var secondTarget: Target? {
        let first = startTarget
        return targets.first { $0.id == secondLanguageID && $0 != first }
            ?? targets.first { !OnDevice.same($0.google, first.google) }
    }

    /// The language the typing panel opens with (Sources/TypeIn.swift): the one chosen in Settings,
    /// or else the second default (what one mostly writes to others in), or else the only language.
    var typingTarget: Target { targets.first { $0.id == typingLanguageID } ?? secondTarget ?? startTarget }

    static var isSetUp: Bool { UserDefaults.standard.bool(forKey: "setupDone") }

    static func load() -> Config {
        let d = UserDefaults.standard
        d.register(defaults: ["googleEnabled": true, "googleVoice": true, "deviceEnabled": true])
        var c = Config()
        c.googleEnabled = d.bool(forKey: "googleEnabled")
        c.aiEnabled = d.bool(forKey: "aiEnabled")
        c.deviceEnabled = d.bool(forKey: "deviceEnabled")
        c.providerID = d.string(forKey: "aiProvider") ?? c.providerID
        c.model = d.string(forKey: "aiModel") ?? c.model
        c.customURL = d.string(forKey: "aiBaseURL") ?? ""
        c.defaultEngine = Engine(rawValue: d.string(forKey: "defaultEngine") ?? "") ?? .google
        c.languageIDs = d.stringArray(forKey: "languages") ?? defaultLanguageIDs()
        c.defaultLanguageID = d.string(forKey: "defaultLanguage") ?? ""
        c.secondLanguageID = d.string(forKey: "secondLanguage") ?? ""
        c.typingLanguageID = d.string(forKey: "typingLanguage") ?? ""
        c.googleVoice = d.bool(forKey: "googleVoice")
        c.languageChoice = chosenInterfaceLanguage()
        // "" is "none"; a shortcut that can't be read is the standard one.
        if let saved = d.string(forKey: "shortcut") { c.shortcut = saved.isEmpty ? nil : (Shortcut(saved: saved) ?? .standard) }
        // For tests: BTRANSLATE_PROVIDER / BTRANSLATE_MODEL override the saved settings.
        let env = ProcessInfo.processInfo.environment
        if let p = env["BTRANSLATE_PROVIDER"], providers.contains(where: { $0.id == p }) {
            c.providerID = p
            c.aiEnabled = true
            c.model = c.provider.models.first ?? c.model
        }
        if let m = env["BTRANSLATE_MODEL"], !m.isEmpty { c.model = m }
        return c
    }

    func save() {
        let d = UserDefaults.standard
        d.set(googleEnabled, forKey: "googleEnabled")
        d.set(aiEnabled, forKey: "aiEnabled")
        d.set(deviceEnabled, forKey: "deviceEnabled")
        d.set(providerID, forKey: "aiProvider")
        d.set(model, forKey: "aiModel")
        d.set(customURL, forKey: "aiBaseURL")
        d.set(defaultEngine.rawValue, forKey: "defaultEngine")
        d.set(languageIDs, forKey: "languages")
        d.set(startTarget.id, forKey: "defaultLanguage")
        d.set(secondTarget?.id ?? "", forKey: "secondLanguage")
        d.set(typingTarget.id, forKey: "typingLanguage")
        d.set(googleVoice, forKey: "googleVoice")
        d.set(shortcut?.saved ?? "", forKey: "shortcut")
        if languageChoice != chosenInterfaceLanguage() { chooseInterfaceLanguage(languageChoice) }
        d.set(true, forKey: "setupDone")
    }
}

// MARK: - API keys in the Keychain

/// Keys live in the login Keychain as "BTranslate" items, one per provider. They are read and
/// written through /usr/bin/security, so the app can read its key again after an update
/// without a Keychain prompt (an ad hoc signed app gets a new identity with every build).
/// A new key is passed on standard input, never as a command-line argument.
enum Keychain {
    static let service = "BTranslate"

    static func read(_ account: String) -> String? { lookUp(account).key }

    /// The saved key, and whether that is the Keychain's answer (`sure`), not a failure to ask it.
    static func lookUp(_ account: String) -> (key: String?, sure: Bool) {
        if let k = ProcessInfo.processInfo.environment["BTRANSLATE_API_KEY"], !k.isEmpty { return (k, true) }
        if ProcessInfo.processInfo.environment["BTRANSLATE_KEYCHAIN"] == "off" { return (nil, true) }  // for tests: a Mac without saved keys
        guard let answer = run(["find-generic-password", "-a", account, "-s", service, "-w"]) else { return (nil, false) }
        let key = answer.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // `security` ends with 44 when there is no such item; anything else is no answer (a locked Keychain, say).
        if answer.status == 0 { return (key.isEmpty ? nil : key, true) }
        return (nil, answer.status == 44)
    }

    static func isValid(_ key: String) -> Bool {
        !key.isEmpty && !key.contains { $0.isWhitespace || $0 == "\"" || $0 == "\\" || $0 == "'" }
    }

    @discardableResult
    static func save(_ key: String, account: String) -> Bool {
        guard isValid(key) else { return false }
        return run(["-i"], input: "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -w \"\(key)\"\n")?.status == 0
            && read(account) == key
    }

    static func delete(_ account: String) {
        _ = run(["delete-generic-password", "-a", account, "-s", service])
    }

    /// Runs /usr/bin/security; returns how it ended and what it printed, or nil if it did not start.
    private static func run(_ arguments: [String], input: String? = nil) -> (status: Int32, output: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = arguments
        let out = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if input != nil { p.standardInput = inPipe }
        do { try p.run() } catch { return nil }
        if let input {
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// A provider's key, remembered while the app runs: reading the Keychain starts a program,
/// too slow to do for every translation. `forget` after a key was saved or deleted.
enum AISetup {
    private static var known: [String: String?] = [:]
    private static let lock = NSLock()

    static func key(_ provider: String) -> String? {
        if let answer = lock.withLock({ known[provider] }) { return answer }
        let (key, sure) = Keychain.lookUp(provider)
        if sure { lock.withLock { known[provider] = .some(key) } }
        return key
    }

    static func hasKey(_ provider: String) -> Bool { key(provider) != nil }

    static func forget() {
        lock.withLock { known = [:] }
    }
}

// MARK: - Languages to translate into

struct Target: Equatable {
    let id: String        // what the settings store: Google's code, or "sr-Latn"
    let name: String      // shown in menus and lists, in BTranslate's language: "Latvian", "Латышский"
    let inText: String    // the same inside a sentence: "Latvian", "латышский"
    let english: String   // the English name: the command line goes by it, and so do the tests
    let google: String
    let prompt: String    // how an AI model is told the language
    let latin: Bool       // Google writes Serbian in Cyrillic: convert it to Latin
    let ownName: String?  // the language's name in the language itself; nil where `name` is that already

    /// `inText` is the name in BTranslate's language as a sentence has it; nil: Google's name
    /// for the code `google`.
    init(id: String, english: String, inText: String? = nil, google: String, prompt: String, latin: Bool = false, ownName: String?) {
        let local = inText ?? localName(google, english: english)
        self.id = id
        self.english = english
        self.inText = interfaceLanguage == "en" ? english : local
        self.name = interfaceLanguage == "en" ? english : capitalizedFirst(local)
        self.google = google
        self.prompt = prompt
        self.latin = latin
        self.ownName = ownName.flatMap { $0.caseInsensitiveCompare(interfaceLanguage == "en" ? english : local) == .orderedSame ? nil : $0 }
    }

    static func == (a: Target, b: Target) -> Bool { a.id == b.id }
}

/// Google's codes that macOS knows under another name.
private let appleCode = ["iw": "he", "jw": "jv", "zh-CN": "zh-Hans", "zh-TW": "zh-Hant", "pt": "pt-BR"]

/// A language's name in BTranslate's language, as a sentence has it ("латышский"): Google's
/// own name for it, or else macOS's, or else the English one.
private func localName(_ code: String, english: String) -> String {
    if interfaceLanguage == "en" { return english }
    return localizedLanguageNames[interfaceLanguage]?[code]
        ?? Locale(identifier: interfaceLanguage).localizedString(forIdentifier: appleCode[code] ?? code)
        ?? english
}

/// A language's name in the language itself ("latviešu"), as macOS has it. Where macOS has
/// none, it answers in English or in the language the app runs in: that is not the
/// language's own name, and an AI model must be told the same whatever BTranslate's language.
private func ownName(_ code: String) -> String? {
    let id = appleCode[code] ?? code
    guard let own = Locale(identifier: id).localizedString(forIdentifier: id) else { return nil }
    let language = Locale(identifier: id).language.languageCode?.identifier
    for other in [Locale(identifier: "en"), Locale.current, Locale(identifier: interfaceLanguage)]
    where other.language.languageCode?.identifier != language {
        if other.localizedString(forIdentifier: id)?.caseInsensitiveCompare(own) == .orderedSame { return nil }
    }
    return own
}

/// An AI model is told the language in English and in the language itself: "Russian (русский)".
private func promptName(_ english: String, own: String?) -> String {
    guard let own, own.caseInsensitiveCompare(english) != .orderedSame else { return english }
    return english.contains("(") ? "\(english): \(own)" : "\(english) (\(own))"
}

/// Google's list is in the order of the English names; in another language, the order of its own.
private func inListOrder(_ list: [Target]) -> [Target] {
    guard interfaceLanguage != "en" else { return list }
    let locale = Locale(identifier: interfaceLanguage)
    return list.sorted { $0.name.compare($1.name, options: .caseInsensitive, range: nil, locale: locale) == .orderedAscending }
}

/// Every language Google Translate knows (Sources/Languages.swift), with Serbian in both alphabets.
let allTargets: [Target] = inListOrder(googleLanguages.flatMap { code, name -> [Target] in
    let own = ownName(code)
    switch code {
    case "sr":  // Google has one Serbian and writes it in Cyrillic
        return [Target(id: "sr-Latn", english: "Serbian (Latin)", inText: L("Serbian (Latin)"), google: "sr",
                       prompt: "Serbian written in the Latin alphabet (srpski, latinica)", latin: true, ownName: "srpski"),
                Target(id: "sr", english: "Serbian (Cyrillic)", inText: L("Serbian (Cyrillic)"), google: "sr",
                       prompt: "Serbian written in the Cyrillic alphabet (српски, ћирилица)", ownName: "српски")]
    case "zh-CN":
        return [Target(id: code, english: name, google: code, prompt: "Simplified Chinese (简体中文)", ownName: own)]
    case "zh-TW":
        return [Target(id: code, english: name, google: code, prompt: "Traditional Chinese (繁體中文)", ownName: own)]
    default:
        return [Target(id: code, english: name, google: code, prompt: promptName(name, own: own), ownName: own)]
    }
})

func target(id: String) -> Target? { allTargets.first { $0.id == id } }

/// The languages a text can be written in, for correcting a wrong detection: Google's list as
/// it is (one Serbian: the alphabet shows in the text itself).
let sourceLanguages: [Target] = inListOrder(googleLanguages.map { code, name in
    let own = ownName(code)
    return Target(id: code, english: name, google: code, prompt: promptName(name, own: own),
                  ownName: code == "sr" ? "srpski / српски" : own)
})

/// The picker's first row: go back to detecting the language.
let detectAutomatically = Target(id: "auto", english: "Detect automatically", inText: L("Detect automatically"),
                                 google: "auto", prompt: "", ownName: nil)

/// A language by its English name or its code, as typed on the command line; its name in
/// BTranslate's language does too.
func findTarget(_ text: String, in list: [Target] = allTargets) -> Target? {
    let wanted = text.lowercased()
    return list.first { $0.english.lowercased() == wanted || $0.id.lowercased() == wanted }
        ?? list.first { $0.name.lowercased() == wanted }
}

/// What a search finds in `list`: names that start with the text first, then names, own
/// names ("рус" finds Russian) and codes that contain it. The English names are searched
/// whatever BTranslate's language is.
func searchTargets(_ query: String, in list: [Target]) -> [Target] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "ё", with: "е")
    guard !q.isEmpty else { return list }
    func starts(_ t: Target) -> Bool { t.name.lowercased().hasPrefix(q) || t.english.lowercased().hasPrefix(q) }
    let first = list.filter(starts)
    let contains = list.filter { t in
        !starts(t) && (t.name.lowercased().contains(q) || t.english.lowercased().contains(q)
            || (t.ownName?.lowercased().contains(q) ?? false) || t.id.lowercased() == q)
    }
    return first + contains
}

/// The list a new install starts with: the Mac's own languages (System Settings → Language &
/// Region), in its order, and English.
func defaultLanguageIDs() -> [String] {
    var ids: [String] = []
    for identifier in macLanguages() {
        let language = Locale(identifier: identifier).language
        guard var code = language.languageCode?.identifier else { continue }
        let script = language.script?.identifier, region = language.region?.identifier
        switch code {
        case "he": code = "iw"
        case "jv": code = "jw"
        case "nb", "nn": code = "no"
        case "zh": code = (script == "Hant" || region == "TW" || region == "HK") ? "zh-TW" : "zh-CN"
        case "sr": code = script == "Latn" ? "sr-Latn" : "sr"
        case "pt": code = region == "PT" ? "pt-PT" : "pt"
        case "fr": code = region == "CA" ? "fr-CA" : "fr"
        default: break
        }
        if target(id: code) != nil, !ids.contains(code) { ids.append(code) }
    }
    if !ids.contains("en") { ids.append("en") }
    return ids
}

/// A language code's name in BTranslate's language: Google's own name for it, or else macOS's.
/// `inText`: as a sentence has it ("латышский"), not as a label shows it ("Латышский").
func languageName(_ code: String, inText: Bool = false) -> String {
    let lower = code.lowercased()
    let base = lower.split(separator: "-").first.map(String.init) ?? lower
    if let known = sourceLanguages.first(where: { $0.google.lowercased() == lower })
        ?? sourceLanguages.first(where: { $0.google == (base == "he" ? "iw" : base) }) {
        return inText ? known.inText : known.name
    }
    let name = Locale(identifier: interfaceLanguage).localizedString(forLanguageCode: base) ?? code
    return inText || interfaceLanguage == "en" ? name : capitalizedFirst(name)
}
