import Foundation

// MARK: - Translation methods and AI providers

enum Engine: String { case google, ai }

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
             keyHelp: "Get a key at platform.claude.com → API keys."),
    Provider(id: "openai", name: "OpenAI", api: .openAI,
             baseURL: "https://api.openai.com/v1",
             models: ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.2-sol"],
             keyHelp: "Get a key at platform.openai.com → API keys."),
    Provider(id: "gemini", name: "Google Gemini", api: .openAI,
             baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
             models: ["gemini-3.8-flash"],
             keyHelp: "Get a key at aistudio.google.com → Get API key."),
    Provider(id: "deepseek", name: "DeepSeek", api: .openAI,
             baseURL: "https://api.deepseek.com",
             models: ["deepseek-chat"],
             keyHelp: "Get a key at platform.deepseek.com → API keys."),
    Provider(id: "openrouter", name: "OpenRouter", api: .openAI,
             baseURL: "https://openrouter.ai/api/v1",
             models: ["anthropic/claude-haiku-5.5", "deepseek/deepseek-v4.1-flash", "google/gemini-3.8-flash", "openai/gpt-6-luna"],
             keyHelp: "Get a key at openrouter.ai/keys. One key reaches models from many providers."),
    Provider(id: "custom", name: "Custom (OpenAI-compatible)", api: .openAI,
             baseURL: "",
             models: [],
             keyHelp: "Any server with /chat/completions, such as Ollama, LM Studio or oMLX. The key is optional."),
]

// MARK: - Settings

struct Config {
    var googleEnabled = true
    var aiEnabled = false
    var providerID = "anthropic"
    var model = "claude-haiku-5-5"
    var customURL = ""
    var defaultEngine: Engine = .google
    var languageIDs: [String] = []  // the languages in the popup's menu, in order
    var googleVoice = true          // read aloud with Google's voice where the Mac has none

    var provider: Provider { providers.first { $0.id == providerID } ?? providers[0] }

    /// The API's base address, without a trailing slash.
    var baseURL: String {
        if let override = ProcessInfo.processInfo.environment["BTRANSLATE_BASE_URL"], !override.isEmpty { return override }
        var url = (provider.baseURL.isEmpty ? customURL : provider.baseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// The methods that are turned on. Never empty.
    var engines: [Engine] {
        let list: [Engine] = (googleEnabled ? [.google] : []) + (aiEnabled ? [.ai] : [])
        return list.isEmpty ? [.google] : list
    }

    /// The method a new popup opens with.
    var startEngine: Engine { engines.contains(defaultEngine) ? defaultEngine : engines[0] }

    /// The languages the popup offers. Never empty.
    var targets: [Target] {
        let list = languageIDs.compactMap(target(id:))
        return list.isEmpty ? defaultLanguageIDs().compactMap(target(id:)) : list
    }

    /// The language a new popup translates into: the one used last, if it is still in the list.
    var startTarget: Target {
        let saved = UserDefaults.standard.string(forKey: "target")  // an id; a name in settings from 1.0 drafts
        return targets.first { $0.id == saved || $0.name == saved } ?? targets[0]
    }

    static func remember(_ target: Target) { UserDefaults.standard.set(target.id, forKey: "target") }

    static var isSetUp: Bool { UserDefaults.standard.bool(forKey: "setupDone") }

    static func load() -> Config {
        let d = UserDefaults.standard
        d.register(defaults: ["googleEnabled": true, "googleVoice": true])
        var c = Config()
        c.googleEnabled = d.bool(forKey: "googleEnabled")
        c.aiEnabled = d.bool(forKey: "aiEnabled")
        c.providerID = d.string(forKey: "aiProvider") ?? c.providerID
        c.model = d.string(forKey: "aiModel") ?? c.model
        c.customURL = d.string(forKey: "aiBaseURL") ?? ""
        c.defaultEngine = Engine(rawValue: d.string(forKey: "defaultEngine") ?? "") ?? .google
        c.languageIDs = d.stringArray(forKey: "languages") ?? defaultLanguageIDs()
        c.googleVoice = d.bool(forKey: "googleVoice")
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
        d.set(providerID, forKey: "aiProvider")
        d.set(model, forKey: "aiModel")
        d.set(customURL, forKey: "aiBaseURL")
        d.set(defaultEngine.rawValue, forKey: "defaultEngine")
        d.set(languageIDs, forKey: "languages")
        d.set(googleVoice, forKey: "googleVoice")
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

    static func read(_ account: String) -> String? {
        if let k = ProcessInfo.processInfo.environment["BTRANSLATE_API_KEY"], !k.isEmpty { return k }
        guard let out = run(["find-generic-password", "-a", account, "-s", service, "-w"]) else { return nil }
        let key = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func isValid(_ key: String) -> Bool {
        !key.isEmpty && !key.contains { $0.isWhitespace || $0 == "\"" || $0 == "\\" || $0 == "'" }
    }

    @discardableResult
    static func save(_ key: String, account: String) -> Bool {
        guard isValid(key) else { return false }
        return run(["-i"], input: "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -w \"\(key)\"\n") != nil
            && read(account) == key
    }

    static func delete(_ account: String) {
        _ = run(["delete-generic-password", "-a", account, "-s", service])
    }

    /// Runs /usr/bin/security; returns its output, or nil if it failed.
    private static func run(_ arguments: [String], input: String? = nil) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = arguments
        let out = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if input != nil { p.standardInput = inPipe }
        do { try p.run() } catch { return nil }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

// MARK: - Languages to translate into

struct Target: Equatable {
    let id: String        // what the settings store: Google's code, or "sr-Latn"
    let name: String      // shown in menus
    let google: String    // Google's language code
    let prompt: String    // how an AI model is told the language
    let latin: Bool       // Google writes Serbian in Cyrillic: convert it to Latin
    let ownName: String?  // the language's name in the language itself

    init(id: String, name: String, google: String, prompt: String, latin: Bool = false, ownName: String?) {
        self.id = id
        self.name = name
        self.google = google
        self.prompt = prompt
        self.latin = latin
        self.ownName = ownName
    }

    static func == (a: Target, b: Target) -> Bool { a.id == b.id }
}

/// Google's codes that macOS knows under another name.
private let appleCode = ["iw": "he", "jw": "jv", "zh-CN": "zh-Hans", "zh-TW": "zh-Hant", "pt": "pt-BR"]

private func ownName(_ code: String, english: String) -> String? {
    let id = appleCode[code] ?? code
    guard let own = Locale(identifier: id).localizedString(forIdentifier: id),
          own.caseInsensitiveCompare(english) != .orderedSame else { return nil }
    return own
}

/// Every language Google Translate knows (Sources/Languages.swift), with Serbian in both alphabets.
let allTargets: [Target] = googleLanguages.flatMap { code, name -> [Target] in
    let own = ownName(code, english: name)
    switch code {
    case "sr":  // Google has one Serbian and writes it in Cyrillic
        return [Target(id: "sr-Latn", name: "Serbian (Latin)", google: "sr",
                       prompt: "Serbian written in the Latin alphabet (srpski, latinica)", latin: true, ownName: "srpski"),
                Target(id: "sr", name: "Serbian (Cyrillic)", google: "sr",
                       prompt: "Serbian written in the Cyrillic alphabet (српски, ћирилица)", ownName: "српски")]
    case "zh-CN":
        return [Target(id: code, name: name, google: code, prompt: "Simplified Chinese (简体中文)", ownName: own)]
    case "zh-TW":
        return [Target(id: code, name: name, google: code, prompt: "Traditional Chinese (繁體中文)", ownName: own)]
    default:
        // An AI model is told the language in English and in the language itself: "Russian (русский)".
        let prompt = own.map { name.contains("(") ? "\(name): \($0)" : "\(name) (\($0))" } ?? name
        return [Target(id: code, name: name, google: code, prompt: prompt, ownName: own)]
    }
}

func target(id: String) -> Target? { allTargets.first { $0.id == id } }

/// The languages a text can be written in, for correcting a wrong detection: Google's list as
/// it is (one Serbian: the alphabet shows in the text itself).
let sourceLanguages: [Target] = googleLanguages.map { code, name in
    let own = code == "sr" ? "srpski / српски" : ownName(code, english: name)
    let prompt = own.map { name.contains("(") ? "\(name): \($0)" : "\(name) (\($0))" } ?? name
    return Target(id: code, name: name, google: code, prompt: prompt, ownName: own)
}

/// The picker's first row: go back to detecting the language.
let detectAutomatically = Target(id: "auto", name: "Detect automatically", google: "auto", prompt: "", ownName: nil)

/// A language by its name or code, as typed on the command line.
func findTarget(_ text: String, in list: [Target] = allTargets) -> Target? {
    let wanted = text.lowercased()
    return list.first { $0.name.lowercased() == wanted || $0.id.lowercased() == wanted }
}

/// What a search finds in `list`: names that start with the text first, then names, own
/// names ("рус" finds Russian) and codes that contain it.
func searchTargets(_ query: String, in list: [Target]) -> [Target] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return list }
    let starts = list.filter { $0.name.lowercased().hasPrefix(q) }
    let contains = list.filter { t in
        !t.name.lowercased().hasPrefix(q)
            && (t.name.lowercased().contains(q) || (t.ownName?.lowercased().contains(q) ?? false) || t.id.lowercased() == q)
    }
    return starts + contains
}

/// The list a new install starts with: the Mac's own languages (System Settings → Language &
/// Region), in its order, and English.
func defaultLanguageIDs() -> [String] {
    var ids: [String] = []
    for identifier in Locale.preferredLanguages {
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

/// A language code's English name: Google's own name for it, or else macOS's.
func languageName(_ code: String) -> String {
    let lower = code.lowercased()
    if let known = googleLanguages.first(where: { $0.code.lowercased() == lower }) { return known.name }
    let base = lower.split(separator: "-").first.map(String.init) ?? lower
    if let known = googleLanguages.first(where: { $0.code == (base == "he" ? "iw" : base) }) { return known.name }
    return Locale(identifier: "en").localizedString(forLanguageCode: base) ?? code
}
