import Foundation

// Telling a text's language with the language pack: one more file of the pack, `detect.bin`.
//
// It is Meta's language detector for NLLB-200's languages (a fastText model), made small:
// tools/nllb/lid.py says how, and has the file's layout (with `Small`). Every word of the
// text, and every group of 2 to 5 letters in it, may have a row of 128 small numbers in a
// table; the rows found are added up, and one more table turns the sum into a score for each
// of 218 languages. That is a few thousand lookups and one small multiplication: well under a
// millisecond on the CPU, so there is nothing here for the Neural Engine to do. The file is
// read through the system's file cache and let go with the detector: nothing stays loaded.

final class PackDetector {
    static var file: URL { LanguagePack.folder.appendingPathComponent("detect.bin") }

    /// The installed pack's detector; nil if the pack is not installed, or is one without it.
    static func installed() -> PackDetector? {
        guard LanguagePack.isInstalled else { return nil }
        return PackDetector(file: file)
    }

    let labels: [String]  // NLLB's codes, "lvs_Latn"
    private let data: Data
    private let width, words, groups, buckets, shortest, longest, top: Int
    private let outputAt, startsAt, lettersAt, groupsAt, scalesAt, rowsAt: Int
    private var rowBytes: Int { width * 3 / 8 }

    init?(file: URL) {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped), data.count > 40,
              data.prefix(4).elementsEqual("BTLD".utf8) else { return nil }
        func number(_ at: Int) -> Int { Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }.littleEndian) }
        guard number(4) == 1 else { return nil }
        width = number(8); words = number(16); groups = number(20); buckets = number(24)
        shortest = number(28); longest = number(32); top = number(36)
        let count = number(12)
        guard width > 0, width % 8 == 0, count > 0, buckets > 0, shortest > 0, longest >= shortest, top == 3 else { return nil }
        let labelsAt = 40
        outputAt = labelsAt + 8 * count
        startsAt = outputAt + 4 * count * width
        lettersAt = startsAt + 4 * (words + 1)
        guard data.count > lettersAt else { return nil }
        let letters = number(lettersAt - 4)
        groupsAt = lettersAt + letters + (4 - letters % 4) % 4
        scalesAt = groupsAt + 4 * groups
        rowsAt = scalesAt + 4 * (words + groups)
        guard data.count == rowsAt + (words + groups) * (width * 3 / 8) else { return nil }
        labels = (0..<count).map { String(decoding: data[(labelsAt + 8 * $0)..<(labelsAt + 8 * $0 + 8)], as: UTF8.self) }
        self.data = data
    }

    /// What fastText takes for the gap between two words.
    private static func isGap(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x0B || byte == 0x0C || byte == 0
    }

    /// Each language's share for a text, as it is (see `OnDevice.prepared` for how a text is
    /// prepared): the `count` likeliest, the best first.
    func chances(of text: String, count: Int = 5) -> [(label: String, chance: Double)] {
        let scores = rawScores(of: text).scores
        let most = scores.max() ?? 0
        let raised = scores.map { exp($0 - most) }
        let sum = raised.reduce(0, +)
        return raised.indices.sorted { raised[$0] > raised[$1] }.prefix(count).map { (labels[$0], raised[$0] / sum) }
    }

    /// A text's score for every language (not yet shares), and how many rows it had: its
    /// letter groups (in the table or not), its known words and one for its end. The fewer
    /// the rows, the less the scores can be trusted.
    func rawScores(of string: String) -> (scores: [Double], rows: Int) {
        let text = Array(string.utf8)
        var total = [Float](repeating: 0, count: width)
        var rows = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)

            func add(row: Int) {
                let scale = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: scalesAt + 4 * row, as: UInt32.self)))
                var at = rowsAt + row * rowBytes
                var column = 0
                while column < width {  // eight numbers of three bits in three bytes
                    var packed = UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16
                    for _ in 0..<8 {
                        total[column] += scale * Float(Int(packed & 7) - top)
                        packed >>= 3
                        column += 1
                    }
                    at += 3
                }
            }

            /// The row of a word, found by halving: the words are in byte order.
            func row(ofWord word: ArraySlice<UInt8>) -> Int? {
                var low = 0, high = words - 1
                while low <= high {
                    let middle = (low + high) / 2
                    let from = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: startsAt + 4 * middle, as: UInt32.self)))
                    let to = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: startsAt + 4 * middle + 4, as: UInt32.self)))
                    var order = 0, i = 0
                    while order == 0, i < word.count, i < to - from {
                        order = Int(word[word.startIndex + i]) - Int(bytes[lettersAt + from + i])
                        i += 1
                    }
                    if order == 0 { order = word.count - (to - from) }
                    if order == 0 { return middle }
                    if order < 0 { high = middle - 1 } else { low = middle + 1 }
                }
                return nil
            }

            func row(ofGroup group: UInt32) -> Int? {
                var low = 0, high = groups - 1
                while low <= high {
                    let middle = (low + high) / 2
                    let there = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: groupsAt + 4 * middle, as: UInt32.self))
                    if there == group { return words + middle }
                    if group < there { high = middle - 1 } else { low = middle + 1 }
                }
                return nil
            }

            var start = 0
            var framed: [UInt8] = []
            var letterStarts: [Int] = []
            for end in 0...text.count where end == text.count || PackDetector.isGap(text[end]) {
                defer { start = end + 1 }
                guard end > start else { continue }
                if let own = row(ofWord: text[start..<end]) {
                    add(row: own)
                    rows += 1
                }
                // Every group of `shortest`…`longest` letters of "<word>", by fastText's hash
                // (which takes a byte as a signed number: the rows depend on it).
                framed.removeAll(keepingCapacity: true)
                framed.append(0x3C)
                framed.append(contentsOf: text[start..<end])
                framed.append(0x3E)
                letterStarts.removeAll(keepingCapacity: true)
                for i in framed.indices where framed[i] & 0xC0 != 0x80 { letterStarts.append(i) }
                letterStarts.append(framed.count)
                let letters = letterStarts.count - 1
                for first in 0..<letters {
                    var hash: UInt32 = 2166136261
                    var at = letterStarts[first]
                    var length = 1
                    while length <= longest, first + length <= letters {
                        let stop = letterStarts[first + length]
                        while at < stop {
                            hash = (hash ^ UInt32(bitPattern: Int32(Int8(bitPattern: framed[at])))) &* 16777619
                            at += 1
                        }
                        if length >= shortest, !(length == 1 && (first == 0 || stop == framed.count)) {
                            rows += 1
                            if let found = row(ofGroup: hash % UInt32(buckets)) { add(row: found) }
                        }
                        length += 1
                    }
                }
            }
            if let last = row(ofWord: ArraySlice("</s>".utf8)) { add(row: last) }  // fastText's "end of line" word
            rows += 1

            let scores: [Double] = labels.indices.map { label in
                var sum: Float = 0
                let at = outputAt + 4 * label * width
                for column in 0..<width {
                    sum += Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at + 4 * column, as: UInt32.self))) * total[column]
                }
                return Double(sum) / Double(rows)
            }
            return (scores, rows)
        }
    }
}
