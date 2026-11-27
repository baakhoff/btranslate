import Foundation

// BTranslate's own texts. English is the text in the source: L("Save"). Every other language
// is a Resources/<code>.lproj/Localizable.strings with the English text as the key
// (tools/check-strings.py checks them). macOS picks the language of a run: the first of the
// Mac's languages that the app comes in, or the one chosen for this app alone, in System
// Settings or in BTranslate's own: both store it as AppleLanguages in the app's preferences.

/// The languages BTranslate comes in, each named in itself. The first is the fallback.
let interfaceLanguages: [(code: String, name: String)] = [("en", "English"), ("ru", "Русский")]

/// The language of this run's texts: "en" or "ru". (For tests, BTRANSLATE_LANGUAGE sets it.)
let interfaceLanguage: String = {
    func known(_ code: String?) -> String? {
        guard let code else { return nil }
        let language = Locale(identifier: code).language.languageCode?.identifier ?? code
        return interfaceLanguages.contains { $0.code == language } ? language : nil
    }
    return known(ProcessInfo.processInfo.environment["BTRANSLATE_LANGUAGE"])
        ?? known(Bundle.main.preferredLocalizations.first)
        ?? interfaceLanguages[0].code
}()

/// The folder with that language's texts. English has none to look up.
private let translations: Bundle? = {
    guard interfaceLanguage != "en" else { return nil }
    return Bundle.main.path(forResource: interfaceLanguage, ofType: "lproj").flatMap(Bundle.init(path:))
}()

/// `english` in the language of this run.
func L(_ english: String) -> String {
    translations?.localizedString(forKey: english, value: english, table: nil) ?? english
}

/// The same for a text with %@ (a text) or %ld (a number) in it. A translation that needs
/// them in another order writes %1$@, %2$@.
func L(_ english: String, _ arguments: CVarArg...) -> String {
    String(format: L(english), arguments: arguments)
}

/// With a capital first letter, as a list or a menu shows a name ("латышский" → "Латышский").
func capitalizedFirst(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
}

// MARK: - The language chosen in BTranslate's settings

private let appDomain = Bundle.main.bundleIdentifier ?? "io.github.baakhoff.btranslate"

/// The language set for this app alone: "en", "ru", or "" when it follows the Mac.
func chosenInterfaceLanguage() -> String {
    let own = UserDefaults.standard.persistentDomain(forName: appDomain)?["AppleLanguages"] as? [String]
    guard let first = own?.first else { return "" }
    let language = Locale(identifier: first).language.languageCode?.identifier ?? first
    return interfaceLanguages.contains { $0.code == language } ? language : ""
}

/// Stores the choice; "" goes back to following the Mac. It holds from the app's next start.
func chooseInterfaceLanguage(_ code: String) {
    if code.isEmpty {
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    } else {
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
    }
}

/// The Mac's own languages, in its order (System Settings → Language & Region). Not
/// Locale.preferredLanguages: that follows a language chosen for this app alone.
func macLanguages() -> [String] {
    let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
    if let global, !global.isEmpty { return global }
    return Locale.preferredLanguages
}
