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

    static var isSetUp: Bool { UserDefaults.standard.bool(forKey: "setupDone") }

    static func load() -> Config {
        let d = UserDefaults.standard
        d.register(defaults: ["googleEnabled": true])
        var c = Config()
        c.googleEnabled = d.bool(forKey: "googleEnabled")
        c.aiEnabled = d.bool(forKey: "aiEnabled")
        c.providerID = d.string(forKey: "aiProvider") ?? c.providerID
        c.model = d.string(forKey: "aiModel") ?? c.model
        c.customURL = d.string(forKey: "aiBaseURL") ?? ""
        c.defaultEngine = Engine(rawValue: d.string(forKey: "defaultEngine") ?? "") ?? .google
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
    let name: String    // shown in the menu
    let google: String  // Google's language code
    let prompt: String  // how an AI model is told the language
    var latin = false   // Google writes Serbian in Cyrillic: convert it to Latin

    init(_ name: String, _ google: String, prompt: String? = nil, latin: Bool = false) {
        self.name = name
        self.google = google
        self.prompt = prompt ?? name
        self.latin = latin
    }
}

private let allTargets: [Target] = [
    Target("Arabic", "ar"), Target("Bulgarian", "bg"),
    Target("Chinese (Simplified)", "zh-CN", prompt: "Simplified Chinese"),
    Target("Chinese (Traditional)", "zh-TW", prompt: "Traditional Chinese"),
    Target("Croatian", "hr"), Target("Czech", "cs"), Target("Danish", "da"), Target("Dutch", "nl"),
    Target("English", "en"), Target("Estonian", "et"), Target("Finnish", "fi"), Target("French", "fr"),
    Target("German", "de"), Target("Greek", "el"), Target("Hebrew", "iw"), Target("Hindi", "hi"),
    Target("Hungarian", "hu"), Target("Indonesian", "id"), Target("Italian", "it"), Target("Japanese", "ja"),
    Target("Korean", "ko"), Target("Latvian", "lv"), Target("Lithuanian", "lt"), Target("Norwegian", "no"),
    Target("Polish", "pl"), Target("Portuguese", "pt"), Target("Romanian", "ro"), Target("Russian", "ru"),
    Target("Serbian (Latin)", "sr", prompt: "Serbian, written in the Latin script", latin: true),
    Target("Serbian (Cyrillic)", "sr", prompt: "Serbian, written in the Cyrillic script"),
    Target("Slovak", "sk"), Target("Slovenian", "sl"), Target("Spanish", "es"), Target("Swedish", "sv"),
    Target("Thai", "th"), Target("Turkish", "tr"), Target("Ukrainian", "uk"), Target("Vietnamese", "vi"),
]

/// The Mac's own languages (System Settings → Language & Region), in its order; the menu lists them first.
let preferredTargets: [Target] = {
    var out: [Target] = []
    for id in Locale.preferredLanguages {
        var code = Locale(identifier: id).language.languageCode?.identifier ?? ""
        if code == "he" { code = "iw" }
        if code == "nb" || code == "nn" { code = "no" }
        for t in allTargets where t.google.split(separator: "-")[0] == code && !out.contains(t) {
            if code == "zh" {  // pick the script the Mac uses
                let traditional = id.contains("Hant") || id.hasSuffix("TW") || id.hasSuffix("HK")
                if traditional != (t.google == "zh-TW") { continue }
            }
            out.append(t)
        }
    }
    return out
}()

let otherTargets: [Target] = allTargets.filter { !preferredTargets.contains($0) }
let targets: [Target] = preferredTargets + otherTargets

/// The language the last popup translated into; at first, the Mac's own language.
var lastTarget: Target {
    get {
        let name = UserDefaults.standard.string(forKey: "target")
        return targets.first { $0.name == name } ?? targets.first { $0.name == "English" && preferredTargets.isEmpty } ?? targets[0]
    }
    set { UserDefaults.standard.set(newValue.name, forKey: "target") }
}

func languageName(_ code: String) -> String {
    var base = code.split(separator: "-").first.map(String.init) ?? code
    if base == "iw" { base = "he" }
    return Locale(identifier: "en").localizedString(forLanguageCode: base) ?? code
}
