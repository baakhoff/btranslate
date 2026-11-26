import Cocoa
import ServiceManagement

/// Opening BTranslate when you log in. The Services menu starts the app by itself when it is
/// needed; the shortcut can't: it works only while BTranslate runs.
@MainActor
enum LoginItem {
    /// For tests: BTRANSLATE_LOGIN=on|off stands for macOS's list of login items, which is then left alone.
    private static let mock = ProcessInfo.processInfo.environment["BTRANSLATE_LOGIN"]
    private static var mocked = mock == "on"

    static var isOn: Bool {
        if mock != nil { return mocked }
        return SMAppService.mainApp.status == .enabled
    }

    /// Adds BTranslate to the login items, or takes it off. nil: done; otherwise why not.
    static func set(_ on: Bool) -> String? {
        if mock != nil {
            mocked = on
            return nil
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Whether macOS started this run at login, and not you: then no settings window is due.
    /// macOS says so with the event that opens the app; where it doesn't, a start within a
    /// minute and a half of logging in, with the login item on, is taken for one.
    private(set) static var startedThisRun = false

    /// To be called while the app is starting (the opening event is at hand only then).
    static func noteStart() {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventID == AEEventID(kAEOpenApplication),
           event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            startedThisRun = true
        } else if let since = secondsSinceLogin(), since < 90, isOn {
            startedThisRun = true
        }
    }

    private static func secondsSinceLogin() -> Double? {
        setutxent()
        defer { endutxent() }
        var login: Double?
        while let entry = getutxent() {
            guard entry.pointee.ut_type == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: entry.pointee.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if line == "console" { login = Double(entry.pointee.ut_tv.tv_sec) }
        }
        return login.map { Date().timeIntervalSince1970 - $0 }
    }
}
