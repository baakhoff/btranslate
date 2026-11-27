import AVFoundation
import Foundation

// Reading a text aloud. A voice of this Mac does it where there is one for the language:
// offline, and nothing leaves the Mac. Where macOS has none (Latvian and Serbian among them),
// Google Translate's voice can read the text, online, if that is turned on in Settings.

// MARK: - Which voice reads a language

enum SpeechPlan: Equatable {
    case mac(voice: String, latinize: Bool)  // a voice of this Mac, by its language tag, such as "hr-HR"
    case google(code: String)                // Google Translate's voice, by Google's language code
    case none
}

/// Languages that a related Mac voice reads well when the Mac has no voice of their own.
/// The Croatian voice reads Serbian and Bosnian, once Cyrillic is turned into Latin letters.
private let standInVoice = ["sr": "hr", "bs": "hr"]

/// A language code from Google or from an AI model → the start of a Mac voice's language tag.
func voicePrefix(_ code: String) -> String {
    switch code.lowercased() {
    case "iw": return "he"
    case "jw": return "jv"
    case "no": return "nb"
    case "zh", "zh-cn": return "zh-CN"
    case "zh-tw": return "zh-TW"
    case "pt": return "pt-BR"
    case "sr-latn": return "sr"
    default: return code
    }
}

/// The same code as Google's voice wants it.
func googleSpeechCode(_ code: String) -> String {
    switch code.lowercased() {
    case "he": return "iw"
    case "jv": return "jw"
    case "nb", "nn": return "no"
    case "zh": return "zh-CN"
    case "sr-latn": return "sr"
    default: return code
    }
}

/// How to read a text in the language `code` aloud. `voiceLanguages` are the language tags of
/// the Mac's voices ("en-US", "hr-HR", …); `preferred` the Mac's own languages.
func speechPlan(for code: String, voiceLanguages: [String], preferred: [String] = macLanguages(),
                googleVoice: Bool) -> SpeechPlan {
    func voice(_ prefix: String) -> String? {
        let p = prefix.lowercased()
        let matches = voiceLanguages.filter { $0.lowercased() == p || $0.lowercased().hasPrefix(p + "-") }
        if matches.isEmpty { return nil }
        // The region the Mac itself uses for this language, then the language's usual one, then any.
        for own in preferred {
            if let m = matches.first(where: { $0.caseInsensitiveCompare(own) == .orderedSame }) { return m }
        }
        let language = prefix.split(separator: "-").first.map(String.init) ?? prefix
        let maximal = Locale.Language(identifier: prefix).maximalIdentifier  // "ru" → "ru-Cyrl-RU"
        if let region = Locale.Language(identifier: maximal).region?.identifier,
           let m = matches.first(where: { $0.caseInsensitiveCompare("\(language)-\(region)") == .orderedSame }) {
            return m
        }
        return matches.sorted().first
    }

    let prefix = voicePrefix(code)
    if let v = voice(prefix) { return .mac(voice: v, latinize: false) }
    let language = (prefix.split(separator: "-").first.map(String.init) ?? prefix).lowercased()
    if language != prefix.lowercased(), let v = voice(language) {  // no Canadian French voice: any French one
        return .mac(voice: v, latinize: false)
    }
    if let standIn = standInVoice[language], let v = voice(standIn) { return .mac(voice: v, latinize: true) }
    return googleVoice ? .google(code: googleSpeechCode(code)) : .none
}

// MARK: - Google Translate's voice

/// Splits a text into pieces Google's voice accepts, at sentence ends, else at spaces.
func speechChunks(_ text: String, limit: Int = 180) -> [String] {
    var out: [String] = []
    func add(_ piece: String) {
        var rest = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        while rest.count > limit {  // no space to cut at: cut anywhere
            out.append(String(rest.prefix(limit)))
            rest = String(rest.dropFirst(limit))
        }
        if !rest.isEmpty { out.append(rest) }
    }
    var sentences: [String] = []
    var sentence = ""
    for ch in text {
        sentence.append(ch)
        if ".!?…;:\n。！？".contains(ch) { sentences.append(sentence); sentence = "" }
    }
    if !sentence.isEmpty { sentences.append(sentence) }

    var current = ""
    for s in sentences {
        if current.count + s.count <= limit { current += s; continue }
        add(current)
        current = ""
        if s.count <= limit { current = s; continue }
        for word in s.split(separator: " ") {  // one long sentence: fill pieces word by word
            if current.count + word.count + 1 > limit { add(current); current = "" }
            current += (current.isEmpty ? "" : " ") + word
        }
    }
    add(current)
    return out
}

/// The MP3 in the answer of Google Translate's own page request for speech.
func parseGoogleSpeech(_ raw: String) -> Data? {
    for line in raw.split(separator: "\n") where line.contains("\"jQ1olc\"") {
        guard let outer = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any],
              let call = outer.first as? [Any], call.count > 2, let payload = call[2] as? String,
              let inner = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [Any],
              let base64 = inner.first as? String else { continue }
        return Data(base64Encoded: base64)
    }
    return nil
}

/// One piece of text as an MP3 from Google Translate's voice. Like the translation endpoints,
/// this is what Google's own page uses, not an official API. The text goes in the request body.
func googleSpeech(_ text: String, code: String) async throws -> Data {
    func json(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), as: UTF8.self)
    }
    let call = json([[["jQ1olc", json([text, code, NSNull(), "null"]), NSNull(), "generic"]]])
    let base = ProcessInfo.processInfo.environment["BTRANSLATE_GOOGLE_SPEECH_URL"] ?? "https://translate.google.com"
    var req = URLRequest(url: URL(string: base + "/_/TranslateWebserverUi/data/batchexecute")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 20
    req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data(("f.req=" + (call.addingPercentEncoding(withAllowedCharacters: formSafe) ?? "")).utf8)
    let (data, response) = try await net.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw TranslateError.http(status, String(decoding: data, as: UTF8.self)) }
    guard let audio = parseGoogleSpeech(String(decoding: data, as: UTF8.self)), !audio.isEmpty else {
        throw TranslateError.other(L("Google has no voice for %@.", languageName(code, inText: true)))
    }
    return audio
}

// MARK: - Playing

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = Speaker()

    /// What is being read now: the name its button gave to `toggle`, or nil.
    private(set) var playing: String?
    var onChange: (() -> Void)?                // playing started or ended
    var onError: ((String, String) -> Void)?   // (the button's name, what went wrong)
    var volume: Float = 1                      // 0 in the check that plays without sound

    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var player: AVAudioPlayer?
    private var playerFinished: CheckedContinuation<Void, Never>?
    private var task: Task<Void, Never>?
    private lazy var voiceLanguages = AVSpeechSynthesisVoice.speechVoices().map(\.language)

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func plan(for code: String, googleVoice: Bool) -> SpeechPlan {
        speechPlan(for: code, voiceLanguages: voiceLanguages, googleVoice: googleVoice)
    }

    /// Starts reading `text`, or stops if this same text is being read.
    func toggle(_ name: String, text: String, code: String, googleVoice: Bool) {
        let wasPlaying = playing == name
        stop()
        if wasPlaying || text.isEmpty { return }
        switch plan(for: code, googleVoice: googleVoice) {
        case .none:
            return
        case .mac(let voice, let latin):
            let u = AVSpeechUtterance(string: latin ? latinize(text) : text)
            u.voice = AVSpeechSynthesisVoice(language: voice)
            u.volume = volume
            utterance = u
            playing = name
            synthesizer.speak(u)
        case .google(let googleCode):
            let offline = L("No internet connection: this text can't be read aloud now. This Mac has no voice for %@, and Google's voice needs internet.",
                            languageName(code, inText: true))
            guard Connection.shared.isOnline else {
                onError?(name, offline)
                return
            }
            playing = name
            task = Task { [weak self] in
                // Fetch one piece ahead of the one playing, never the whole text at once.
                let chunks = speechChunks(text)
                var next: Task<Data, Error>? = chunks.first.map { c in Task { try await googleSpeech(c, code: googleCode) } }
                do {
                    for i in chunks.indices {
                        guard let fetch = next else { break }
                        // (A fetch is a task of its own: stopping has to reach it too.)
                        let audio = try await withTaskCancellationHandler { try await fetch.value } onCancel: { fetch.cancel() }
                        next = i + 1 < chunks.count ? Task { try await googleSpeech(chunks[i + 1], code: googleCode) } : nil
                        try Task.checkCancellation()
                        await self?.play(audio)
                        try Task.checkCancellation()
                    }
                } catch {
                    next?.cancel()
                    if Task.isCancelled || error is CancellationError { return }
                    self?.onError?(name, isConnectionError(error) ? offline : describe(error))
                }
                if !Task.isCancelled { self?.ended(name) }
            }
        }
        onChange?()
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        playerFinished?.resume()
        playerFinished = nil
        utterance = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if playing != nil {
            playing = nil
            onChange?()
        }
    }

    private func ended(_ name: String) {
        guard playing == name else { return }
        playing = nil
        onChange?()
    }

    private func play(_ audio: Data) async {
        guard let p = try? AVAudioPlayer(data: audio) else { return }
        p.delegate = self
        p.volume = volume
        player = p
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            playerFinished = done
            if !p.play() {
                playerFinished = nil
                done.resume()
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.playerFinished?.resume()
            self.playerFinished = nil
        }
    }

    /// Audio that can't be played ends the piece too, or its button would stay "playing".
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finished = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.utterance, ObjectIdentifier(current) == finished else { return }
            self.utterance = nil
            if let name = self.playing { self.ended(name) }
        }
    }
}

// MARK: - Checks without sound (BTranslate --speech-check CODE "text")

/// Reads `text` the way a speaker button does, at volume zero, and waits for it to end:
/// returns a line such as "played to the end without sound: 2.4 s".
@MainActor
func playSilently(_ text: String, code: String, googleVoice: Bool) async -> String {
    let speaker = Speaker.shared
    speaker.volume = 0
    var failure: String?
    speaker.onError = { _, message in failure = message }
    let started = Date()
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        var ended = false
        speaker.onChange = {
            if speaker.playing == nil && !ended { ended = true; done.resume() }
        }
        speaker.toggle("check", text: text, code: code, googleVoice: googleVoice)
        if speaker.playing == nil && !ended { ended = true; done.resume() }  // nothing to read
    }
    speaker.onChange = nil
    speaker.onError = nil
    if let failure { return "playing: ERROR \(failure)" }
    return String(format: "played to the end without sound: %.1f s", Date().timeIntervalSince(started))
}

/// Says how `text` in the language `code` would be read, and makes the audio without playing
/// it: returns a line such as "mac voice hr-HR (Latin letters): 2.1 s".
@MainActor
func speechCheck(_ text: String, code: String, googleVoice: Bool) async -> String {
    switch Speaker.shared.plan(for: code, googleVoice: googleVoice) {
    case .none:
        return "no voice for \(languageName(code))"
    case .google(let googleCode):
        do {
            let chunks = speechChunks(text)
            let audio = try await googleSpeech(chunks.first ?? "", code: googleCode)
            let seconds = (try? AVAudioPlayer(data: audio))?.duration ?? 0
            return String(format: "google voice %@: %d piece(s), first %.1f s", googleCode, chunks.count, seconds)
        } catch {
            return "google voice \(googleCode): ERROR \(describe(error))"
        }
    case .mac(let voice, let latin):
        let u = AVSpeechUtterance(string: latin ? latinize(text) : text)
        u.voice = AVSpeechSynthesisVoice(language: voice)
        let synthesizer = AVSpeechSynthesizer()
        let seconds: Double = await withCheckedContinuation { done in
            var frames = 0.0, rate = 22050.0, finished = false
            synthesizer.write(u) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    if !finished { finished = true; done.resume(returning: frames / rate) }
                    return
                }
                frames += Double(pcm.frameLength)
                rate = pcm.format.sampleRate
            }
        }
        return String(format: "mac voice %@%@: %.1f s", voice, latin ? " (Latin letters)" : "", seconds)
    }
}
