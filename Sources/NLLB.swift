import Accelerate
import CoreML
import CryptoKit
import Foundation
import NaturalLanguage

// The language pack: an optional download that lets the Offline method translate about 200
// languages, Latvian and Serbian among them, which the translation built into macOS has not got.
//
// It is NLLB-200 ("No Language Left Behind", distilled, 600M parameters) by Meta AI, converted
// to Core ML with 8-bit weights (tools/nllb has the recipe): 886 MB. Core ML runs it on the
// Neural Engine, never on the GPU; a vocabulary lookup and the search for the best words run
// on the CPU. Its licence is CC-BY-NC 4.0: non-commercial use only. With it comes a detector
// of a text's language (Detect.swift), 20 MB: the Mac's recognizer knows a quarter of the
// pack's languages.
//
// The model is loaded for a translation and let go right after it. Loading takes a tenth of
// a second, because macOS keeps the form of the model it prepared for the Neural Engine, a
// gigabyte among the app's caches. That preparation takes a quarter of a minute and leaves a
// gigabyte and a half in the process that did it, so it is done in a process of its own: when
// the pack is installed, and again after an update of macOS, which prepares anew.
//
// The model has to be told the language of the text. Told a wrong one it writes nonsense, so
// the Offline method only uses it when it is sure of the language (OnDevice.swift). It
// translates one sentence at a time, of up to 64 tokens; a longer one is cut at a comma.

// MARK: - The pack on disk

enum LanguagePack {
    /// The files are release assets with flat names; `nllb200-v1-pack.json` lists them.
    static let manifestName = "nllb200-v1-pack.json"
    static var address: String {
        ProcessInfo.processInfo.environment["BTRANSLATE_PACK_URL"] ?? "https://github.com/baakhoff/btranslate/releases/download/nllb-200-v1"
    }
    /// The size of the download, for the text in Settings before the manifest is fetched.
    static let megabytes = 906

    static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["BTRANSLATE_PACK_DIR"], !override.isEmpty { return URL(fileURLWithPath: override) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("BTranslate/NLLB-200")
    }

    struct File: Decodable {
        let name: String    // the file's name at `address`
        let path: String    // where it goes inside `folder`
        let size: Int
        let sha256: String
    }

    struct Manifest: Decodable {
        let version: Int
        let length: Int           // the longest sentence, and translation, in tokens
        let pad: Int32, end: Int32, unknown: Int32
        let languages: [String]   // NLLB's codes, "lvs_Latn"
        let files: [File]
    }

    private static var cached: (written: Date?, manifest: Manifest?)?
    private static let lock = NSLock()  // it is asked about from several threads at once

    /// The installed pack's manifest: written last, when everything else is in place. It is
    /// read again when the file is another one (the installer, or a second BTranslate, put it there).
    static func installed() -> Manifest? {
        let file = folder.appendingPathComponent("pack.json")
        let written = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        return lock.withLock {
            if let cached, cached.written == written { return cached.manifest }
            let manifest = written == nil ? nil : (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            cached = (written, manifest)
            return manifest
        }
    }

    static var isInstalled: Bool { installed() != nil }

    /// Looks at the disk again (after an install or a removal).
    static func refresh() { lock.withLock { cached = nil } }

    static func remove() {
        try? FileManager.default.removeItem(at: folder)
        forgetPrepared()
        refresh()
    }

    /// Where macOS keeps what it made of the models for the Neural Engine: about 1 GB that no
    /// removal or reinstall of the pack takes away by itself. nil while a test keeps the pack
    /// in a folder of its own: the real pack's is then left alone.
    private static var prepared: URL? {
        guard ProcessInfo.processInfo.environment["BTRANSLATE_PACK_DIR"] == nil, let id = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent(id).appendingPathComponent("com.apple.e5rt.e5bundlecache")
    }

    /// Takes away what macOS prepared of the pack's models, and all it prepared under an
    /// earlier macOS. Not the rest of what it keeps there for this app under the macOS that
    /// runs now: the pieces of its reader of pictures (Sources/Picture.swift), a few megabytes
    /// that take a minute to make again. The names there say nothing; the pack's are told by
    /// their size, half a gigabyte each.
    static func forgetPrepared() {
        guard let prepared else { return }
        forget(in: prepared, system: system)
        UserDefaults.standard.removeObject(forKey: "packPreparedFor")
    }

    /// The same for any such folder, and whatever the macOS (a check has one of its own).
    static func forget(in prepared: URL, system: String) {
        let files = FileManager.default
        for build in (try? files.contentsOfDirectory(at: prepared, includingPropertiesForKeys: nil)) ?? [] {
            guard build.lastPathComponent == system else {
                try? files.removeItem(at: build)
                continue
            }
            for piece in (try? files.contentsOfDirectory(at: build, includingPropertiesForKeys: nil)) ?? [] where isLarge(piece) {
                try? files.removeItem(at: piece)
            }
        }
    }

    /// Whether a folder holds more than 50 MB.
    private static func isLarge(_ folder: URL) -> Bool {
        var bytes = 0
        for case let file as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) ?? .init() {
            bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if bytes > 50_000_000 { return true }
        }
        return false
    }

    /// The build of macOS that runs now ("26B8132"): it prepares the models anew after every
    /// update of itself, and keeps what it prepared for the one before.
    private static var system: String {
        var build = [CChar](repeating: 0, count: 64)
        var size = build.count
        return sysctlbyname("kern.osversion", &build, &size, nil, 0) == 0 ? String(cString: build) : ""
    }

    /// Whether the models were prepared under this macOS, and what it made of them is still
    /// there. True where that is not kept track of (a test's own pack).
    static var isPrepared: Bool {
        guard let prepared else { return true }
        return UserDefaults.standard.string(forKey: "packPreparedFor") == system
            && !((try? FileManager.default.contentsOfDirectory(atPath: prepared.path)) ?? []).isEmpty
    }

    static func notePrepared() {
        if prepared != nil { UserDefaults.standard.set(system, forKey: "packPreparedFor") }
    }
}

// MARK: - Its languages

/// NLLB-200's languages by its own codes: a language's three-letter code and its script.
let nllbLanguages: Set<String> = [
    "ace_Arab", "ace_Latn", "acm_Arab", "acq_Arab", "aeb_Arab", "afr_Latn", "ajp_Arab", "aka_Latn", "amh_Ethi", "apc_Arab",
    "arb_Arab", "ars_Arab", "ary_Arab", "arz_Arab", "asm_Beng", "ast_Latn", "awa_Deva", "ayr_Latn", "azb_Arab", "azj_Latn",
    "bak_Cyrl", "bam_Latn", "ban_Latn", "bel_Cyrl", "bem_Latn", "ben_Beng", "bho_Deva", "bjn_Arab", "bjn_Latn", "bod_Tibt",
    "bos_Latn", "bug_Latn", "bul_Cyrl", "cat_Latn", "ceb_Latn", "ces_Latn", "cjk_Latn", "ckb_Arab", "crh_Latn", "cym_Latn",
    "dan_Latn", "deu_Latn", "dik_Latn", "dyu_Latn", "dzo_Tibt", "ell_Grek", "eng_Latn", "epo_Latn", "est_Latn", "eus_Latn",
    "ewe_Latn", "fao_Latn", "pes_Arab", "fij_Latn", "fin_Latn", "fon_Latn", "fra_Latn", "fur_Latn", "fuv_Latn", "gla_Latn",
    "gle_Latn", "glg_Latn", "grn_Latn", "guj_Gujr", "hat_Latn", "hau_Latn", "heb_Hebr", "hin_Deva", "hne_Deva", "hrv_Latn",
    "hun_Latn", "hye_Armn", "ibo_Latn", "ilo_Latn", "ind_Latn", "isl_Latn", "ita_Latn", "jav_Latn", "jpn_Jpan", "kab_Latn",
    "kac_Latn", "kam_Latn", "kan_Knda", "kas_Arab", "kas_Deva", "kat_Geor", "knc_Arab", "knc_Latn", "kaz_Cyrl", "kbp_Latn",
    "kea_Latn", "khm_Khmr", "kik_Latn", "kin_Latn", "kir_Cyrl", "kmb_Latn", "kon_Latn", "kor_Hang", "kmr_Latn", "lao_Laoo",
    "lvs_Latn", "lij_Latn", "lim_Latn", "lin_Latn", "lit_Latn", "lmo_Latn", "ltg_Latn", "ltz_Latn", "lua_Latn", "lug_Latn",
    "luo_Latn", "lus_Latn", "mag_Deva", "mai_Deva", "mal_Mlym", "mar_Deva", "min_Latn", "mkd_Cyrl", "plt_Latn", "mlt_Latn",
    "mni_Beng", "khk_Cyrl", "mos_Latn", "mri_Latn", "zsm_Latn", "mya_Mymr", "nld_Latn", "nno_Latn", "nob_Latn", "npi_Deva",
    "nso_Latn", "nus_Latn", "nya_Latn", "oci_Latn", "gaz_Latn", "ory_Orya", "pag_Latn", "pan_Guru", "pap_Latn", "pol_Latn",
    "por_Latn", "prs_Arab", "pbt_Arab", "quy_Latn", "ron_Latn", "run_Latn", "rus_Cyrl", "sag_Latn", "san_Deva", "sat_Beng",
    "scn_Latn", "shn_Mymr", "sin_Sinh", "slk_Latn", "slv_Latn", "smo_Latn", "sna_Latn", "snd_Arab", "som_Latn", "sot_Latn",
    "spa_Latn", "als_Latn", "srd_Latn", "srp_Cyrl", "ssw_Latn", "sun_Latn", "swe_Latn", "swh_Latn", "szl_Latn", "tam_Taml",
    "tat_Cyrl", "tel_Telu", "tgk_Cyrl", "tgl_Latn", "tha_Thai", "tir_Ethi", "taq_Latn", "taq_Tfng", "tpi_Latn", "tsn_Latn",
    "tso_Latn", "tuk_Latn", "tum_Latn", "tur_Latn", "twi_Latn", "tzm_Tfng", "uig_Arab", "ukr_Cyrl", "umb_Latn", "urd_Arab",
    "uzn_Latn", "vec_Latn", "vie_Latn", "war_Latn", "wol_Latn", "xho_Latn", "ydd_Hebr", "yor_Latn", "yue_Hant", "zho_Hans",
    "zho_Hant", "zul_Latn",
]

enum NLLBLanguage {
    /// Google's codes that do not follow from the three-letter code: mostly languages NLLB has
    /// under the code of their main variety (Latvian is "lvs", Standard Latvian).
    private static let named: [String: String] = [
        "sr": "srp_Cyrl", "sr-Latn": "srp_Cyrl", "zh-CN": "zho_Hans", "zh-TW": "zho_Hant", "iw": "heb_Hebr", "jw": "jav_Latn",
        "no": "nob_Latn", "lv": "lvs_Latn", "ms": "zsm_Latn", "ar": "arb_Arab", "fa": "pes_Arab", "sw": "swh_Latn", "uz": "uzn_Latn",
        "sq": "als_Latn", "az": "azj_Latn", "ku": "kmr_Latn", "om": "gaz_Latn", "ne": "npi_Deva", "or": "ory_Orya", "ps": "pbt_Arab",
        "mg": "plt_Latn", "qu": "quy_Latn", "yi": "ydd_Hebr", "mn": "khk_Cyrl", "ay": "ayr_Latn", "tl": "tgl_Latn", "pt-PT": "por_Latn",
        "fr-CA": "fra_Latn", "yue": "yue_Hant", "ff": "fuv_Latn", "pa": "pan_Guru", "sd": "snd_Arab", "ks": "kas_Arab", "kg": "kon_Latn",
        "fa-AF": "prs_Arab", "tk": "tuk_Latn", "ak": "aka_Latn", "ht": "hat_Latn", "ilo": "ilo_Latn", "lg": "lug_Latn",
    ]

    /// Google's languages that NLLB only has in another script than Google's.
    private static let otherScript: Set<String> = ["crh", "bm-Nkoo", "pa-Arab", "sat", "sat-Latn", "mni-Mtei"]

    /// Worked out once for every language of Google's list (and never changed after: it is
    /// read from several threads).
    private static let byGoogleCode: [String: String] = {
        var table: [String: String] = [:]
        for google in googleLanguages.map(\.code) + ["sr-Latn"] where !otherScript.contains(google) {
            var code = named[google]
            if code == nil {
                let language = Locale.Language(identifier: google)
                if let three = language.languageCode?.identifier(.alpha3) {
                    let same = nllbLanguages.filter { $0.hasPrefix(three + "_") }.sorted()
                    let script = Locale.Language(identifier: language.maximalIdentifier).script?.identifier
                    code = same.count == 1 ? same[0] : same.first { $0.hasSuffix("_" + (script ?? "")) }
                }
            }
            if let code, nllbLanguages.contains(code) { table[google] = code }
        }
        return table
    }()

    /// NLLB's code for a language by Google's code; nil if the pack has not got the language.
    static func code(_ google: String) -> String? { byGoogleCode[google] }

    /// The other way round, for the pack's detector: of Google's codes that lead to one of
    /// NLLB's, the shortest ("fr", not "fr-CA"). Nynorsk, which the detector tells from
    /// Bokmål, is Norwegian here.
    private static let byNLLBCode: [String: String] = {
        var table = ["nno_Latn": "no"]
        for (google, code) in byGoogleCode.sorted(by: { ($0.key.count, $0.key) < ($1.key.count, $1.key) }) where table[code] == nil {
            table[code] = google
        }
        return table
    }()

    /// Google's code for one of NLLB's; nil for a language BTranslate has not got.
    static func google(_ code: String) -> String? { byNLLBCode[code] }

    /// The code to read a text as. Serbian in Latin letters is read as Croatian: the model
    /// knows Serbian in Cyrillic only, and Croatian is the same language to it in Latin letters.
    static func source(_ google: String, text: String) -> String? {
        if google == "sr" || google == "sr-Latn", isMostlyLatin(text) { return "hrv_Latn" }
        return code(google)
    }
}

// MARK: - The tokenizer

/// SentencePiece's "BPE" as NLLB uses it: a word starts as single characters behind a "▁", and
/// the two neighbours whose union is the highest-ranked token of the vocabulary are joined,
/// again and again. The vocabulary file has one token a line, in the order of the model's
/// token numbers, which is also the order of rank.
final class NLLBTokenizer {
    private var numbers: [String: Int32] = [:]
    private var tokens: [String] = []
    private var joinable: Int32 = 0  // tokens below this number are made by joining; the special ones after them are not
    private var known: [String: [Int32]] = [:]
    private let unknown: Int32

    init(file: URL, unknown: Int32) throws {
        self.unknown = unknown
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        tokens.reserveCapacity(260_000)
        numbers.reserveCapacity(260_000)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var start = 0
            for i in 0..<bytes.count where bytes[i] == 10 {  // one line: token, a tab, its score (none for a special token)
                var tab = start
                while tab < i, bytes[tab] != 9 { tab += 1 }
                let token = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<tab]), as: UTF8.self)
                let number = Int32(tokens.count)
                if tab + 1 < i { joinable = number + 1 }
                tokens.append(token)
                numbers[token] = number
                start = i + 1
            }
        }
    }

    var count: Int { tokens.count }

    func number(of token: String) -> Int32? { numbers[token] }

    /// The text as SentencePiece sees it: compatibility forms folded (ﬁ → fi, ² → 2), invisible
    /// and control characters gone, every kind of white space a plain space.
    static func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0C, 0x0D, 0x1680, 0x200B...0x200F, 0x2028, 0x2029, 0x2581, 0xFEFF, 0xFFFD:
                out.append(" ")
            case 0x00...0x1F, 0x7F...0x9F:
                continue
            default:
                out.append(scalar.properties.isWhitespace ? " " : scalar)
            }
        }
        return String(out)
    }

    /// The token numbers of a text (without a language code or an end mark).
    func encode(_ text: String) -> [Int32] {
        var out: [Int32] = []
        for word in NLLBTokenizer.normalize(text).split(separator: " ") {
            out += encode(word: String(word))
        }
        return out
    }

    private func encode(word: String) -> [Int32] {
        if let done = known[word] { return done }
        // An endless "word" (an address, a line of code) in pieces: the pairing below takes
        // the square of a word's length in time.
        let letters = Array(word.unicodeScalars)
        if letters.count > 200 {
            return stride(from: 0, to: letters.count, by: 200).flatMap { start in
                encode(word: String(String.UnicodeScalarView(letters[start..<min(start + 200, letters.count)])))
            }
        }
        var parts = ["▁"] + letters.map { String($0) }
        while parts.count > 1 {
            var best = Int32.max, at = -1
            for i in 0..<(parts.count - 1) {
                if let number = numbers[parts[i] + parts[i + 1]], number < joinable, number < best {
                    best = number
                    at = i
                }
            }
            if at < 0 { break }
            parts[at] += parts[at + 1]
            parts.remove(at: at + 1)
        }
        var out: [Int32] = []
        for part in parts {
            let number = numbers[part].flatMap { $0 < joinable ? $0 : nil } ?? unknown
            if number == unknown, out.last == unknown { continue }  // several unknown characters in a row are one
            out.append(number)
        }
        known[word] = out
        return out
    }

    /// The text of token numbers; the special tokens among them are left out.
    func decode(_ numbers: [Int32]) -> String {
        var text = ""
        for number in numbers where number > 3 && number < joinable {
            text += tokens[Int(number)]
        }
        return text.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Translating

enum NLLBError: Error {
    case notInstalled
    case broken(String)
}

/// Text cut into pieces the model takes: sentences, and a long sentence at its commas.
enum NLLBText {
    static func sentences(_ line: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = line
        let found = tokenizer.tokens(for: line.startIndex..<line.endIndex).map { line[$0].trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return found.isEmpty ? [line] : found
    }

    /// `text` in two, cut at the comma, semicolon, colon, dash or bracket nearest to its
    /// middle, or else at the space nearest to it; nil for one word.
    static func halves(_ text: String) -> (String, String)? {
        let characters = Array(text)
        let middle = characters.count / 2
        var best: (distance: Int, at: Int, weak: Bool)?
        for i in 1..<max(characters.count - 1, 1) where characters[i] == " " {
            let before = characters[i - 1], after = characters[i + 1]
            let strong = ",;:".contains(before) || "–—(".contains(after) || "–—".contains(before)
            let distance = abs(i - middle)
            if best == nil || (strong && best!.weak) || (strong == !best!.weak && distance < best!.distance) {
                best = (distance, i, !strong)
            }
        }
        guard let cut = best?.at else { return nil }
        return (String(characters[..<cut]), String(characters[(cut + 1)...]))
    }
}

/// The best few of a model's scores, as log-probabilities: what the search goes by.
func bestTokens(_ scores: UnsafeBufferPointer<Float>, count: Int, scratch: inout [Float]) -> [(token: Int32, score: Float)] {
    guard let base = scores.baseAddress, !scores.isEmpty else { return [] }
    let n = vDSP_Length(scores.count)
    var highest: Float = 0
    vDSP_maxv(base, 1, &highest, n)
    // log of the sum of e^score, with the highest score taken out first so that nothing overflows
    if scratch.count != scores.count { scratch = [Float](repeating: 0, count: scores.count) }
    var minus = -highest, total: Float = 0
    var length = Int32(scores.count)
    scratch.withUnsafeMutableBufferPointer { work in
        vDSP_vsadd(base, 1, &minus, work.baseAddress!, 1, n)
        vvexpf(work.baseAddress!, work.baseAddress!, &length)
        vDSP_sve(work.baseAddress!, 1, &total, n)
    }
    let all = highest + log(total)
    var best: [(token: Int32, score: Float)] = []
    var lowest = -Float.infinity
    for i in 0..<scores.count where scores[i] > lowest {
        best.append((Int32(i), scores[i] - all))
        best.sort { $0.score > $1.score }
        if best.count > count { best.removeLast() }
        if best.count == count { lowest = best[count - 1].score + all }
    }
    return best
}

/// Runs the model. One translation at a time: the Neural Engine does one thing at a time anyway.
final class NLLBEngine: @unchecked Sendable {
    static let shared = NLLBEngine()
    static let beams = 4  // how many translations stay in the running at each step

    private let queue = DispatchQueue(label: "io.github.baakhoff.btranslate.nllb")
    private let lock = NSLock()
    private var waiting = 0  // translations asked for and not done: with none left, the model is let go
    private var checked = false  // whether macOS has the models prepared has been looked into, this run
    // Used on `queue` only:
    private var manifest: LanguagePack.Manifest?
    private var encoder: MLModel?, decoder: MLModel?
    private var tokenizer: NLLBTokenizer?
    private var scratch: [Float] = []

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// Whether the model is in memory now (for the check that it is let go).
    var isLoaded: Bool { queue.sync { encoder != nil } }

    /// Translates `text` from one of NLLB's languages into another (its codes). `partial` gets
    /// the translation so far after each sentence. The model is loaded if it is not, and let
    /// go when no other translation is waiting for it.
    func translate(_ text: String, from source: String, to target: String, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        // After an update of macOS the models are prepared anew: apart (see the top of this
        // file), and what was prepared for the macOS before, a gigabyte of no more use, goes first.
        if !lock.withLock({ checked }) {
            if !LanguagePack.isPrepared {
                LanguagePack.forgetPrepared()
                if (try? await NLLBEngine.prepareApart()) != nil { LanguagePack.notePrepared() }
            }
            lock.withLock { checked = true }
        }
        lock.withLock { waiting += 1 }
        let stop = Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<String, Error>) in
                queue.async {
                    let result = Result { try autoreleasepool { try self.run(text, from: source, to: target, stop: stop, partial: partial) } }
                    let last = self.lock.withLock { () -> Bool in
                        self.waiting -= 1
                        return self.waiting == 0
                    }
                    if last { autoreleasepool { self.unload() } }
                    done.resume(with: result)
                }
            }
        } onCancel: {
            stop.raise()
        }
    }

    /// Keeps the model in memory over several translations in a row (the texts of a window's
    /// picture): it is then let go after the last of them, not loaded anew for each. Every
    /// `keep` has its `letGo`.
    func keep() { lock.withLock { waiting += 1 } }

    func letGo() {
        let last = lock.withLock { () -> Bool in
            waiting -= 1
            return waiting == 0
        }
        guard last else { return }
        queue.async {
            // Not if a translation was asked for meanwhile: it would only load the model again.
            guard self.lock.withLock({ self.waiting == 0 }) else { return }
            autoreleasepool { self.unload() }
        }
    }

    /// Loads the model and lets it go again: the first time after an install this is when
    /// macOS prepares it for the Neural Engine, which takes a while.
    func prepare() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                let result = Result { try autoreleasepool { try self.load() } }
                autoreleasepool { self.unload() }
                done.resume(with: result)
            }
        }
    }

    /// The same in a process of its own (this program again, as `--pack-prepare`): what the
    /// preparation leaves in memory goes with that process.
    static func prepareApart() async throws {
        guard Bundle.main.executableURL != nil else { return try await shared.prepare() }
        try await apart(["--pack-prepare"])
    }

    /// Compiles the model packages in `folder` (encoder.mlpackage → encoder.mlmodelc, and the
    /// decoder's), where a pack has just been downloaded to.
    static func compile(in folder: URL) async throws {
        for part in ["encoder", "decoder"] where FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(part).mlpackage").path) {
            let compiled = try await MLModel.compileModel(at: folder.appendingPathComponent("\(part).mlpackage"))
            let target = folder.appendingPathComponent("\(part).mlmodelc")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: compiled, to: target)
        }
    }

    /// That, too, in a process of its own (`--pack-compile FOLDER`): it takes two gigabytes while it lasts.
    static func compileApart(in folder: URL) async throws {
        guard Bundle.main.executableURL != nil else { return try await compile(in: folder) }
        try await apart(["--pack-compile", folder.path])
    }

    /// Runs this program again with `arguments` and waits for it; throws what it printed if it failed.
    private static func apart(_ arguments: [String]) async throws {
        let helper = Process(), said = Pipe()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = arguments
        helper.standardOutput = said
        helper.standardError = FileHandle.nullDevice
        helper.qualityOfService = .userInitiated  // wanted now, though the app waits in the background
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            helper.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do {
                try helper.run()
            } catch {
                helper.terminationHandler = nil
                done.resume(throwing: error)
            }
        }
        guard status != 0 else { return }
        let why = String(decoding: said.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw NSError(domain: "BTranslate", code: Int(status), userInfo: [NSLocalizedDescriptionKey: why.isEmpty ? "\(status)" : why])
    }

    private func load() throws {
        if encoder != nil { return }
        guard let manifest = LanguagePack.installed() else { throw NLLBError.notInstalled }
        let folder = LanguagePack.folder
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine  // never the GPU
        let tokenizer = try NLLBTokenizer(file: folder.appendingPathComponent("tokens.tsv"), unknown: manifest.unknown)
        let encoder = try MLModel(contentsOf: folder.appendingPathComponent("encoder.mlmodelc"), configuration: configuration)
        let decoder = try MLModel(contentsOf: folder.appendingPathComponent("decoder.mlmodelc"), configuration: configuration)
        (self.manifest, self.tokenizer, self.encoder, self.decoder) = (manifest, tokenizer, encoder, decoder)
    }

    private func unload() {
        (manifest, tokenizer, encoder, decoder) = (nil, nil, nil, nil)
        scratch = []
    }

    private func run(_ text: String, from source: String, to target: String, stop: Flag, partial: (String) -> Void) throws -> String {
        try load()
        guard let tokenizer, let from = tokenizer.number(of: source), let to = tokenizer.number(of: target) else {
            throw NLLBError.broken(L("it has not got one of the two languages (%@, %@)", source, target))
        }
        var lines = text.components(separatedBy: "\n")  // line by line, so that the line breaks stay
        for i in lines.indices where !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            var translated: [String] = []
            for sentence in NLLBText.sentences(lines[i]) {
                if stop.isRaised { throw CancellationError() }
                translated.append(try translate(sentence: sentence, from: from, to: to, stop: stop, depth: 0))
                var soFar = Array(lines[...i])
                soFar[i] = translated.joined(separator: " ")
                partial(soFar.joined(separator: "\n"))
            }
            lines[i] = translated.joined(separator: " ")
        }
        return lines.joined(separator: "\n")
    }

    /// One sentence. If it has more tokens than the model takes, or its translation does not
    /// fit, it is cut in two at a comma and the halves are translated one after the other.
    private func translate(sentence: String, from: Int32, to: Int32, stop: Flag, depth: Int) throws -> String {
        guard let tokenizer, let manifest else { throw NLLBError.notInstalled }
        let numbers = tokenizer.encode(sentence)
        if numbers.isEmpty { return sentence }
        let room = manifest.length - 2  // a language code and an end mark go with the text
        if numbers.count <= room {
            let (translation, complete) = try search(numbers, from: from, to: to, stop: stop)
            if complete || depth >= 6 { return tokenizer.decode(translation) }
        }
        guard depth < 6, let (first, second) = NLLBText.halves(sentence) else {
            // Nothing to cut it at (no spaces: Chinese, Japanese): as many tokens at a time as fit, to its end.
            return try stride(from: 0, to: numbers.count, by: room).map { start in
                tokenizer.decode(try search(Array(numbers[start..<min(start + room, numbers.count)]), from: from, to: to, stop: stop).tokens)
            }.joined(separator: " ")
        }
        return try translate(sentence: first, from: from, to: to, stop: stop, depth: depth + 1) + " "
            + translate(sentence: second, from: from, to: to, stop: stop, depth: depth + 1)
    }

    private func array(_ shape: [Int], _ type: MLMultiArrayDataType) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
    }

    /// The translation's tokens for a sentence's tokens, found by beam search: at every step
    /// each translation in the running is tried with its most likely next tokens, and the
    /// best few of all of those stay. `complete` is false if it ran out of room before its end.
    private func search(_ text: [Int32], from: Int32, to: Int32, stop: Flag) throws -> (tokens: [Int32], complete: Bool) {
        guard let encoder, let decoder, let manifest else { throw NLLBError.notInstalled }
        let length = manifest.length
        let ids = try array([1, length], .int32), mask = try array([1, length], .float32)
        let input = [from] + text + [manifest.end]
        let idNumbers = ids.dataPointer.bindMemory(to: Int32.self, capacity: length)
        let maskNumbers = mask.dataPointer.bindMemory(to: Float.self, capacity: length)
        for i in 0..<length {
            idNumbers[i] = i < input.count ? input[i] : manifest.pad
            maskNumbers[i] = i < input.count ? 1 : 0
        }
        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["ids": ids, "mask": mask]))
        guard let memory = encoded.featureValue(for: "memory")?.multiArrayValue else { throw NLLBError.broken(L("the model gave no answer")) }

        let soFar = try array([1, length], .int32), at = try array([1, length], .float32)
        let soFarNumbers = soFar.dataPointer.bindMemory(to: Int32.self, capacity: length)
        let atNumbers = at.dataPointer.bindMemory(to: Float.self, capacity: length)
        var live: [(score: Float, tokens: [Int32])] = [(0, [manifest.end, to])]  // how the model starts a translation
        var finished: [(score: Float, tokens: [Int32])] = []
        while let longest = live.first?.tokens.count, longest < length {
            var grown: [(score: Float, tokens: [Int32])] = []
            for (score, tokens) in live {
                if stop.isRaised { throw CancellationError() }
                for i in 0..<length {
                    soFarNumbers[i] = i < tokens.count ? tokens[i] : manifest.pad
                    atNumbers[i] = i == tokens.count - 1 ? 1 : 0
                }
                let step = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["ids": soFar, "at": at, "memory": memory, "mask": mask]))
                guard let scores = step.featureValue(for: "scores")?.multiArrayValue, scores.dataType == .float32 else {
                    throw NLLBError.broken(L("the model gave no answer"))
                }
                let next = scores.withUnsafeBufferPointer(ofType: Float.self) { bestTokens($0, count: NLLBEngine.beams, scratch: &scratch) }
                for (token, tokenScore) in next { grown.append((score + tokenScore, tokens + [token])) }
            }
            grown.sort { $0.score > $1.score }
            live = []
            for candidate in grown.prefix(NLLBEngine.beams) {
                if candidate.tokens.last == manifest.end {
                    finished.append((candidate.score / Float(candidate.tokens.count), candidate.tokens))  // per token: length is not punished
                } else {
                    live.append(candidate)
                }
            }
            if finished.count >= NLLBEngine.beams { break }
        }
        if let best = finished.max(by: { $0.score < $1.score }) { return (Array(best.tokens.dropFirst(2)), true) }
        return (Array((live.first?.tokens ?? []).dropFirst(2)), false)
    }
}

// MARK: - Installing the pack

/// Downloads one file, going on from where an earlier try stopped.
private final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: URL
    private let progress: @Sendable (Int) -> Void  // bytes of this file on disk so far
    private var handle: FileHandle?
    private var written = 0
    private var reported = 0
    private var failure: Error?
    private var done: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(to file: URL, progress: @escaping @Sendable (Int) -> Void) {
        self.file = file
        self.progress = progress
    }

    func run(from url: URL) async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        written = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if written > 0 { request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range") }
        reported = written
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                self.done = done
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
                if Task.isCancelled { task.cancel() }  // cancelled before there was a task to cancel
            }
        } onCancel: {
            self.task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 206:  // the rest of the file
            break
        case 200:  // the whole file: start it anew
            try? Data().write(to: file)
            written = 0
        case 416:  // nothing left to send: the file is whole already
            completionHandler(.cancel)
            failure = nil
            finish(with: nil)
            return
        default:
            failure = TranslateError.http(status, "")
            completionHandler(.cancel)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: file) else {
            failure = CocoaError(.fileWriteUnknown)  // nowhere to put it: not a download into nothing
            completionHandler(.cancel)
            return
        }
        _ = try? handle.seekToEnd()
        self.handle = handle
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += data.count
            // Said by the megabyte: every change is shown, and there are hundreds of pieces a second.
            if written - reported >= 1_000_000 {
                reported = written
                progress(written)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(with: failure ?? error)
    }

    private func finish(with error: Error?) {
        try? handle?.close()
        handle = nil
        guard let done else { return }
        self.done = nil
        if let error { done.resume(throwing: error) } else { done.resume() }
    }
}

/// A file's SHA-256, as lowercase hexadecimal.
func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    var more = true
    while more {
        try autoreleasepool {  // or every block read stays in memory until the end
            guard let block = try handle.read(upToCount: 4 << 20), !block.isEmpty else { more = false; return }
            hasher.update(data: block)
        }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Downloads and installs the pack, or removes it. Settings shows its state; the download
/// goes on when the settings window is closed.
@MainActor
final class PackInstaller {
    static let shared = PackInstaller()

    enum State: Equatable {
        case absent
        case waiting                             // for an internet connection: the download starts when there is one
        case downloading(done: Int, total: Int)  // bytes
        case preparing                           // macOS is getting the model ready for the Neural Engine
        case installed
        case failed(String)
    }

    private(set) var state: State = LanguagePack.isInstalled ? .installed : .absent {
        didSet {
            onChange?()
            NotificationCenter.default.post(name: PackInstaller.changed, object: nil)
        }
    }
    var onChange: (() -> Void)?  // the settings window's
    /// Posted whenever `state` changes: a popup that offers the download follows it.
    static let changed = Notification.Name("io.github.baakhoff.btranslate.pack-installer-changed")
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch state {
        case .downloading, .preparing: return true
        default: return false
        }
    }

    func start() {
        guard !isBusy, state != .installed else { return }
        state = .downloading(done: 0, total: LanguagePack.megabytes * 1_000_000)
        task = Task { [weak self] in
            do {
                try await self?.install()
                self?.state = .installed
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self?.state = .absent  // what is on disk stays: the next try goes on from there
                } else {
                    self?.state = .failed(PackInstaller.explain(error))
                }
            }
        }
    }

    /// Starts the download; without an internet connection, as soon as there is one again.
    func startWhenPossible() {
        guard !isBusy, state != .installed, state != .waiting else { return }
        guard !Connection.shared.isOnline else { start(); return }
        state = .waiting
        Connection.shared.whenBack { [weak self] in
            if self?.state == .waiting { self?.start() }
        }
    }

    func cancel() {
        if state == .waiting { state = .absent }
        task?.cancel()
    }

    func remove() {
        guard !isBusy else { return }
        LanguagePack.remove()
        state = .absent
    }

    /// The pack may have come or gone by another hand (the installer, a terminal): what is on disk counts.
    func lookAgain() {
        guard !isBusy, state != .waiting else { return }
        if (state == .installed) != LanguagePack.isInstalled { state = LanguagePack.isInstalled ? .installed : .absent }
    }

    static func explain(_ error: Error) -> String {
        switch error {
        case TranslateError.http(404, _): return L("The language pack is not at its address (HTTP 404). It may not be published yet.")
        case NLLBError.broken(let what): return L("The language pack could not be installed: %@", what)
        default: return describe(error)
        }
    }

    private func install() async throws {
        let files = FileManager.default
        let folder = LanguagePack.folder, incoming = folder.appendingPathComponent("incoming")
        guard let base = URL(string: LanguagePack.address) else { throw TranslateError.noServer }
        try files.createDirectory(at: incoming, withIntermediateDirectories: true)
        // One download at a time, also between two BTranslates (the installer's and the app).
        let only = open(folder.appendingPathComponent("installing").path, O_CREAT | O_RDWR, 0o600)
        defer { if only >= 0 { close(only) } }
        if only >= 0, flock(only, LOCK_EX | LOCK_NB) != 0 { throw NLLBError.broken(L("another BTranslate is downloading it right now")) }

        var request = URLRequest(url: base.appendingPathComponent(LanguagePack.manifestName))
        request.timeoutInterval = 30
        let (data, response) = try await net.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TranslateError.http(status, "") }
        guard let manifest = try? JSONDecoder().decode(LanguagePack.Manifest.self, from: data), !manifest.files.isEmpty else {
            throw NLLBError.broken(L("its list of files can't be read"))
        }
        let total = manifest.files.reduce(0) { $0 + $1.size }

        // Each file, checked against the list: a wrong one is fetched once more.
        var before = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let target = incoming.appendingPathComponent(file.path)
            for attempt in 1...2 {
                let size = ((try? files.attributesOfItem(atPath: target.path))?[.size] as? Int) ?? 0
                if size < file.size {
                    let start = before
                    try await FileDownload(to: target) { [weak self] written in
                        Task { @MainActor in
                            if case .downloading = self?.state { self?.state = .downloading(done: start + written, total: total) }
                        }
                    }.run(from: base.appendingPathComponent(file.name))
                }
                // (Not on the main thread: half a gigabyte is read.)
                if await Task.detached(operation: { try? sha256(of: target) }).value == file.sha256 { break }
                try? files.removeItem(at: target)
                if attempt == 2 { throw NLLBError.broken(L("the file %@ arrived damaged", file.name)) }
            }
            before += file.size
            state = .downloading(done: before, total: total)
        }

        // Everything is here and whole. The models are compiled where they arrived: until all
        // of this is done, what is on disk is a download that can be gone on with.
        state = .preparing
        try Task.checkCancellation()
        let parts = ["encoder", "decoder"].filter { files.fileExists(atPath: incoming.appendingPathComponent("\($0).mlpackage").path) }
        do {
            try await NLLBEngine.compileApart(in: incoming)
        } catch {
            throw NLLBError.broken(L("macOS could not load the model (%@)", error.localizedDescription))
        }
        // Into place: the compiled models (the ones in use), and every file that is not a part of a model's package.
        LanguagePack.forgetPrepared()  // what macOS prepared of an earlier install is of no use to this one
        let loose = manifest.files.map(\.path).filter { !$0.contains(".mlpackage/") }
        for name in parts.map({ "\($0).mlmodelc" }) + loose {
            let target = folder.appendingPathComponent(name)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.removeItem(at: target)
            try files.moveItem(at: incoming.appendingPathComponent(name), to: target)
        }
        try data.write(to: folder.appendingPathComponent("pack.json"))  // last: this is what says "installed"
        try? files.removeItem(at: incoming)
        LanguagePack.refresh()
        if !parts.isEmpty {
            do {
                try await NLLBEngine.prepareApart()
                LanguagePack.notePrepared()
            } catch {
                LanguagePack.remove()
                throw NLLBError.broken(L("macOS could not load the model (%@)", error.localizedDescription))
            }
        }
    }
}
