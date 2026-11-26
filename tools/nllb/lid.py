"""Language detection for the pack: Meta's detector for NLLB's languages, made small.

Meta's model (https://huggingface.co/facebook/fasttext-language-identification, CC-BY-NC 4.0)
is a fastText classifier: every word of a text, and every group of 2 to 5 letters in it, has a
row of 256 numbers in a table of 1.1 million rows; the rows are averaged, and one more table
turns the average into a score for each of 218 languages. It is 1.18 GB. This script reads
that file as it is (no fastText needed), measures it on FLORES-200's sentences, and writes
the small file the app reads: fewer numbers a row, a byte each, and only the rows that matter.

  venv/bin/python -I ../tools/nllb/lid.py texts              the test texts, as row numbers (cached)
  venv/bin/python -I ../tools/nllb/lid.py measure            the original model on them
  venv/bin/python -I ../tools/nllb/lid.py try WIDTH ROWS…    what a smaller table would cost
  venv/bin/python -I ../tools/nllb/lid.py shrink WIDTH ROWS  → lid/detect.bin, and measures it
  venv/bin/python -I ../tools/nllb/lid.py vectors            → ../tests/detect-vectors.json
  venv/bin/python -I ../tools/nllb/lid.py toy                → ../tests/detect-toy.bin and .json: a
                                                                made-up file of a few rows, for the
                                                                app's tests (needs no download)

Run it from `lab`, with the downloads in lid/meta/model.bin and lid/flores/ (see README.md).
"""
import json
import os
import re
import struct
import sys
import time

import numpy as np

MODEL = "lid/meta/model.bin"
FLORES = "lid/flores/flores200_dataset"
CACHE = "lid/cache"
OUT = "lid/detect.bin"
SPACES = re.compile(rb"[ \n\r\t\v\f\0]+")  # what fastText takes for the gap between two words
END = b"</s>"                               # its "end of line" word


# ---------------------------------------------------------------- the original file

class Original:
    """A fastText model file (version 12, not compressed), read without loading the table."""

    def __init__(self, path=MODEL):
        with open(path, "rb") as f:
            head = f.read(64 << 20)  # the settings and the dictionary are well inside this
        magic, version = struct.unpack_from("<ii", head, 0)
        assert magic == 793712314 and version == 12, "not a fastText model of version 12"
        (self.dim, _, _, _, _, self.word_ngrams, self.loss, self.kind, self.bucket, self.minn, self.maxn,
         _) = struct.unpack_from("<12i", head, 8)
        at = 8 + 48 + 8  # the twelve settings and a double
        size, self.nwords, self.nlabels, _, pruned = struct.unpack_from("<iiiqq", head, at)
        at += 28
        assert pruned == -1, "a pruned model"
        self.words, self.labels, self.counts = [], [], []
        for _ in range(size):
            end = head.index(b"\0", at)
            word = head[at:end]
            count, kind = struct.unpack_from("<qb", head, end + 1)
            at = end + 10
            if kind == 0:
                self.words.append(word)
                self.counts.append(count)
            else:
                self.labels.append(word.decode().replace("__label__", ""))
        assert len(self.words) == self.nwords and len(self.labels) == self.nlabels
        assert head[at] == 0, "a compressed table"
        rows, width = struct.unpack_from("<qq", head, at + 1)
        assert rows == self.nwords + self.bucket and width == self.dim
        self.table_at = at + 17
        self.rows = rows
        after = self.table_at + rows * width * 4
        with open(path, "rb") as f:
            f.seek(after)
            tail = f.read()
        assert tail[0] == 0
        out_rows, out_width = struct.unpack_from("<qq", tail, 1)
        assert out_rows == self.nlabels and out_width == self.dim
        self.output = np.frombuffer(tail, dtype="<f4", count=out_rows * out_width, offset=17).reshape(out_rows, out_width).copy()
        self.path = path
        self.number = {word: i for i, word in enumerate(self.words)}

    def table(self):
        """Every row: (words + letter groups) x dim, 1.2 GB in memory."""
        return np.fromfile(self.path, dtype="<f4", count=self.rows * self.dim, offset=self.table_at).reshape(self.rows, self.dim)


def letter_groups(word, minn, maxn, bucket):
    """fastText's numbers for the groups of minn…maxn letters of "<word>" (a letter may be
    several bytes). Its hash takes each byte as a signed number: kept, the rows depend on it."""
    w = b"<" + word + b">"
    starts = [i for i in range(len(w)) if (w[i] & 0xC0) != 0x80]
    starts.append(len(w))
    letters = len(starts) - 1
    out = []
    for a in range(letters):
        h, at = 2166136261, starts[a]
        for n in range(1, maxn + 1):
            if a + n > letters:
                break
            end = starts[a + n]
            while at < end:
                b = w[at]
                h = ((h ^ (b | 0xFFFFFF00 if b >= 128 else b)) * 16777619) & 0xFFFFFFFF
                at += 1
            if n >= minn and not (n == 1 and (a == 0 or end == len(w))):
                out.append(h % bucket)
    return out


def rows_of(text, model, seen):
    """The table rows fastText averages for a text: each known word's own row, every word's
    letter groups, and the "end of line" word."""
    rows = []
    for word in SPACES.split(text):
        if not word:
            continue
        groups = seen.get(word)
        if groups is None:
            groups = seen[word] = [model.nwords + g for g in letter_groups(word, model.minn, model.maxn, model.bucket)]
        number = model.number.get(word)
        if number is not None:
            rows.append(number)
        rows.extend(groups)
    rows.append(model.number[END])
    return rows


# ---------------------------------------------------------------- the test texts

def fragment(sentence):
    """Two neighbouring words from the middle of a sentence; of a text without spaces between
    its words (Chinese, Thai…), ten letters from the middle. What a quick selection looks like."""
    words = sentence.split()
    if len(words) >= 6:
        middle = len(words) // 2
        return " ".join(words[middle:middle + 2])
    middle = len(sentence) // 2
    return sentence[max(0, middle - 5):middle + 5].strip() or sentence


def one_language(job):
    split, code = job
    model = one_language.model
    seen = {}
    with open(f"{FLORES}/{split}/{code}.{split}", encoding="utf-8") as f:
        sentences = [line.strip() for line in f if line.strip()]
    whole = [rows_of(s.encode(), model, seen) for s in sentences]
    parts = [rows_of(fragment(s).encode(), model, seen) for s in sentences]
    return code, whole, parts


def make_texts(model):
    """Every FLORES sentence, and a fragment of it, as table rows: lid/cache/SPLIT-KIND.npz."""
    import multiprocessing
    os.makedirs(CACHE, exist_ok=True)
    one_language.model = model
    for split in ("dev", "devtest"):
        codes = sorted(name.split(".")[0] for name in os.listdir(f"{FLORES}/{split}"))
        started = time.time()
        with multiprocessing.get_context("fork").Pool(10) as pool:
            done = pool.map(one_language, [(split, code) for code in codes], chunksize=4)
        for kind, which in (("whole", 1), ("parts", 2)):
            rows, starts, labels = [], [0], []
            for item in done:
                for text in item[which]:
                    rows.extend(text)
                    starts.append(len(rows))
                    labels.append(codes.index(item[0]))
            np.savez(f"{CACHE}/{split}-{kind}.npz", rows=np.array(rows, dtype=np.int64), starts=np.array(starts, dtype=np.int64),
                     labels=np.array(labels, dtype=np.int16), codes=np.array(codes))
        print(f"{split}: {len(codes)} languages, {len(labels)} sentences, {time.time() - started:.0f} s")


def texts(split, kind):
    data = np.load(f"{CACHE}/{split}-{kind}.npz")
    return data["rows"], data["starts"], data["labels"], [str(c) for c in data["codes"]]


# ---------------------------------------------------------------- measuring

def averages(table, rows, starts, mode="mean", block=20000):
    """The average row of each text (or, with mode "sum", the sum of its rows)."""
    import torch
    weight = torch.from_numpy(np.ascontiguousarray(table, dtype=np.float32))
    out = []
    for a in range(0, len(starts) - 1, block):
        b = min(a + block, len(starts) - 1)
        ids = torch.from_numpy(rows[starts[a]:starts[b]])
        offsets = torch.from_numpy(starts[a:b] - starts[a])
        out.append(torch.nn.functional.embedding_bag(ids, weight, offsets, mode=mode).numpy())
    return np.concatenate(out)


def app_languages(path="lid/app-languages.tsv"):
    """NLLB's codes of the languages BTranslate offers (`BTranslate --pack-languages`)."""
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return {line.split("\t")[1] for line in f if line.split("\t")[1] != "-"}


def report(name, scores, labels, codes, model_labels, quiet=False):
    """How often the best-scored language is the right one: over every language of the test,
    and over the app's. Returns the two shares."""
    best = scores.argmax(axis=1)
    said = np.array([codes.index(l) if l in codes else -1 for l in model_labels])[best]
    right = said == labels
    app = app_languages()
    mine = np.array([codes[l] in app for l in labels]) if app else np.ones(len(labels), bool)
    if not quiet:
        print(f"{name}: {100 * right.mean():.2f}% of {len(labels)} texts; the app's languages: {100 * right[mine].mean():.2f}% of {mine.sum()}")
    return right.mean(), right[mine].mean()


def worst(scores, labels, codes, model_labels, count=12):
    best = scores.argmax(axis=1)
    said = np.array([codes.index(l) if l in codes else -1 for l in model_labels])[best]
    lines = []
    for i, code in enumerate(codes):
        mask = labels == i
        share = (said[mask] == i).mean()
        others = np.bincount(said[mask][said[mask] != i] + 1, minlength=len(codes) + 1)
        taken = codes[others.argmax() - 1] if others.max() and others.argmax() else "another"
        lines.append((share, f"{code} {100 * share:.0f}% (most often taken for {taken})"))
    lines.sort()
    print("   the weakest: " + "; ".join(text for _, text in lines[:count]))


def measure():
    model = Original()
    print(f"{model.nwords} words, {model.bucket} letter-group rows, {model.nlabels} languages, {model.dim} numbers a row; "
          f"groups of {model.minn}-{model.maxn} letters, word pairs: {model.word_ngrams}, loss {model.loss}")
    table = model.table()
    for split, kind in (("devtest", "whole"), ("devtest", "parts")):
        rows, starts, labels, codes = texts(split, kind)
        scores = averages(table, rows, starts) @ model.output.T
        report(f"the original, {split} {kind}", scores, labels, codes, model.labels)
        worst(scores, labels, codes, model.labels)


# ---------------------------------------------------------------- making it small

WIDTH = 128       # numbers a row, of the original's 256
ROWS = 350000     # rows kept, of 1,145,940
TOP = 3           # each number is -3…3: three bits
CLIPS = (1.0, 0.85, 0.7, 0.55, 0.4)


def narrowed(table, output, width):
    """The same scores from `width` numbers a row instead of 256.

    A text's scores are output x (the average row), and only their differences between
    languages count. So take the `width` directions in which the rows, seen through `output`,
    differ most (a reduced-rank fit, weighted by how the table's rows are spread), keep each
    row's place along those, and fold the rest of the arithmetic into a new, smaller output table.
    Returns (rows x width, languages x width)."""
    centred = (output - output.mean(axis=0)).astype(np.float64)
    spread = np.zeros((table.shape[1], table.shape[1]))
    for a in range(0, len(table), 100000):
        block = table[a:a + 100000].astype(np.float64)
        spread += block.T @ block
    values, vectors = np.linalg.eigh(spread / len(table))
    values = np.maximum(values, values.max() * 1e-12)
    root = (vectors * np.sqrt(values)) @ vectors.T
    back = (vectors / np.sqrt(values)) @ vectors.T
    u, s, vt = np.linalg.svd(centred @ root, full_matrices=False)
    project = vt[:width] @ back                       # width x 256
    small = np.empty((len(table), width), dtype=np.float32)
    for a in range(0, len(table), 100000):
        small[a:a + 100000] = table[a:a + 100000].astype(np.float64) @ project.T
    return small, (u[:, :width] * s[:width]).astype(np.float32)


def rounded(small):
    """Each row as numbers from -TOP to TOP and one scale: row ≈ numbers x scale. The scale
    is the one of CLIPS (shares of the row's largest number) that leaves the smallest error.
    Cutting off a row's largest numbers and dropping its smallest turns out to help short
    texts: a row then speaks for a few languages, at a limited strength."""
    peak = np.abs(small).max(axis=1)
    peak[peak == 0] = 1
    best = np.zeros(small.shape, dtype=np.int8)
    best_scale = np.ones(len(small), dtype=np.float32)
    best_error = np.full(len(small), np.inf)
    for a in range(0, len(small), 200000):
        block = small[a:a + 200000]
        for share in CLIPS:
            scale = (peak[a:a + 200000] * share / TOP).astype(np.float32)
            coded = np.clip(np.rint(block / scale[:, None]), -TOP, TOP)
            error = ((coded * scale[:, None] - block) ** 2).sum(axis=1)
            better = error < best_error[a:a + 200000]
            best[a:a + 200000][better] = coded[better]
            best_scale[a:a + 200000][better] = scale[better]
            best_error[a:a + 200000][better] = error[better]
    return best, best_scale


def weight_of_rows(numbers, scale, output):
    """How much each row can move the scores: the length of what it adds to them."""
    weight = np.empty(len(numbers), dtype=np.float32)
    gram = (output.T @ output).astype(np.float32)
    for a in range(0, len(numbers), 200000):
        block = numbers[a:a + 200000].astype(np.float32) * scale[a:a + 200000, None]
        weight[a:a + 200000] = np.sqrt(np.einsum("ij,jk,ik->i", block, gram, block))
    return weight


def small_model(model, width, count):
    """(numbers, scale, output, keep) for `count` kept rows of `width` numbers."""
    small, output = narrowed(model.table(), model.output, width)
    numbers, scale = rounded(small)
    weight = weight_of_rows(numbers, scale, output)
    weight[model.number[END]] = np.inf
    keep = np.zeros(len(numbers), dtype=bool)
    keep[np.argsort(-weight)[:count]] = True
    return numbers, scale, output, keep


def scores_of(model, numbers, scale, output, keep, rows, starts):
    """Every text's scores as the app works them out: the kept rows' sum, divided by the
    number of the text's letter groups (kept or not) and of its kept words."""
    counted = keep.copy()
    counted[model.nwords:] = True
    marked = np.concatenate([numbers.astype(np.float32) * (scale * keep)[:, None], counted[:, None].astype(np.float32)], axis=1)
    total = averages(marked, rows, starts, mode="sum")
    return (total[:, :-1] / np.maximum(total[:, -1:], 1)) @ output.T


def megabytes_of(model, width, keep):
    words = int(keep[:model.nwords].sum())
    letters = sum(len(model.words[i]) for i in np.flatnonzero(keep[:model.nwords]))
    return (int(keep.sum()) * (width * 3 // 8 + 4) + (int(keep.sum()) - words) * 4 + words * 4 + letters) / 1e6


def try_sizes(arguments):
    """Accuracy for a width and several numbers of kept rows."""
    width, counts = int(arguments[0]), [int(a) for a in arguments[1:]]
    model = Original()
    sets = [texts("devtest", kind) for kind in ("whole", "parts")]
    for count in counts:
        numbers, scale, output, keep = small_model(model, width, count)
        line = f"{width} numbers a row, {count} rows, about {megabytes_of(model, width, keep):.1f} MB:"
        for name, (rows, starts, labels, codes) in zip(("sentences", "two words"), sets):
            all_, app = report("", scores_of(model, numbers, scale, output, keep, rows, starts), labels, codes, model.labels, quiet=True)
            line += f" {name} {100 * all_:.2f}% (the app's languages {100 * app:.2f}%)"
        print(line, flush=True)


# ---------------------------------------------------------------- the app's file

MAGIC = b"BTLD"


def packed(numbers):
    """Rows of numbers -3…3 as three bits each: eight numbers in three bytes, the first in
    the lowest bits."""
    groups = (numbers.astype(np.int32) + TOP).astype(np.uint32).reshape(len(numbers), -1, 8)
    joined = sum(groups[:, :, i] << (3 * i) for i in range(8))
    return np.stack([joined & 0xFF, (joined >> 8) & 0xFF, (joined >> 16) & 0xFF], axis=2).astype(np.uint8).reshape(len(numbers), -1)


def padded(data):
    return data + b"\0" * (-len(data) % 4)


def shrink(width=WIDTH, count=ROWS):
    """Writes lid/detect.bin (see `Small` for its layout) and measures what it gives."""
    assert width % 8 == 0
    model = Original()
    numbers, scale, output, keep = small_model(model, width, count)
    words = sorted(model.words[i] for i in np.flatnonzero(keep[:model.nwords]))  # by bytes: the app looks a word up by halving
    word_rows = [model.number[w] for w in words]
    group_rows = np.flatnonzero(keep[model.nwords:]) + model.nwords
    order = np.concatenate([np.array(word_rows, dtype=np.int64), group_rows])
    write(OUT, model.labels, output, words, group_rows - model.nwords, scale[order], numbers[order], model.bucket, model.minn, model.maxn)
    print(f"{OUT}: {os.path.getsize(OUT) / 1e6:.1f} MB; {len(words)} words and {len(group_rows)} letter groups of {width} numbers, {len(model.labels)} languages")
    check(model)


def write(path, labels, output, words, groups, scale, numbers, bucket, minn, maxn):
    """The app's file (its layout is with `Small`): `words` in byte order, `groups` rising,
    and a scale and a row of numbers for each word and then each group."""
    assert all(len(label) == 8 and label.isascii() for label in labels) and numbers.shape[1] % 8 == 0
    starts = np.cumsum([0] + [len(w) for w in words]).astype("<u4")
    parts = [
        MAGIC, struct.pack("<9I", 1, numbers.shape[1], len(labels), len(words), len(groups), bucket, minn, maxn, TOP),
        "".join(labels).encode(),
        np.asarray(output).astype("<f4").tobytes(),
        starts.tobytes(), padded(b"".join(words)),
        np.asarray(groups).astype("<u4").tobytes(),
        np.asarray(scale).astype("<f4").tobytes(),
        packed(numbers).tobytes(),
    ]
    with open(path, "wb") as f:
        for part in parts:
            f.write(part)


def answers(small, picked, out):
    items = []
    for text in picked:
        chances = small.chances(text)
        order = np.argsort(-chances, kind="stable")[:3]
        items.append({"text": text, "best": [[small.labels[int(i)], round(float(chances[i]), 4)] for i in order]})
    with open(out, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=1)
    print(f"{len(items)} texts → {out}")


def toy(out="../tests/detect-toy"):
    """A made-up file of four languages and a few dozen rows, with its answers: enough to
    check every step of the app's reading (words, letter groups, the packed numbers)."""
    rng = np.random.default_rng(7)
    picked = ["hello world", "Привет, мир", "Rīgas dome ir skaista", "ћирилица и latinica", "a", "naïve café\tword\nnew line",
              "日本語のテキスト", "the same the same the same", ""]
    bucket, minn, maxn, width = 1000, 2, 5, 8
    every_word = sorted({w for t in picked for w in SPACES.split(t.encode()) if w})
    words = sorted({w for w in every_word if rng.random() < 0.6} | {END})
    every_group = sorted({g for w in every_word for g in letter_groups(w, minn, maxn, bucket)})
    groups = [g for g in every_group if rng.random() < 0.7]
    rows = len(words) + len(groups)
    write(out + ".bin", ["eng_Latn", "rus_Cyrl", "lvs_Latn", "srp_Cyrl"], rng.normal(size=(4, width)), words, groups,
          rng.uniform(0.05, 0.6, size=rows), rng.integers(-TOP, TOP + 1, size=(rows, width)), bucket, minn, maxn)
    print(f"{out}.bin: {os.path.getsize(out + '.bin')} bytes, {len(words)} words and {len(groups)} letter groups")
    answers(Small(out + ".bin"), picked, out + ".json")


class Small:
    """The app's file, read and used the way the app does it (Sources/Detect.swift).

      "BTLD", then nine 32-bit numbers: the version (1), numbers a row, languages, words,
      letter groups, the original's number of letter-group rows, the shortest and the longest
      group, and the largest number a row holds (3)
      the languages: NLLB's code of each, 8 letters
      the output table: languages x numbers a row, 32-bit floats
      the words: where each starts in the bytes that follow (words + 1 numbers), then their
      bytes, in byte order, filled up to a multiple of 4
      the letter groups kept: their numbers, rising
      a scale for each row (32-bit floats): the words' rows first, then the letter groups'
      the rows: three bits a number, eight numbers in three bytes
    """

    def __init__(self, path=OUT):
        with open(path, "rb") as f:
            data = f.read()
        assert data[:4] == MAGIC
        version, self.width, labels, words, groups, self.bucket, self.minn, self.maxn, self.top = struct.unpack_from("<9I", data, 4)
        assert version == 1
        at = 40
        self.labels = [data[at + 8 * i:at + 8 * i + 8].decode() for i in range(labels)]
        at += 8 * labels
        self.output = np.frombuffer(data, "<f4", labels * self.width, at).reshape(labels, self.width)
        at += 4 * labels * self.width
        starts = np.frombuffer(data, "<u4", words + 1, at)
        at += 4 * (words + 1)
        self.words = {data[at + starts[i]:at + starts[i + 1]]: i for i in range(words)}
        at += int(starts[-1]) + (-int(starts[-1]) % 4)
        self.groups = {int(g): words + i for i, g in enumerate(np.frombuffer(data, "<u4", groups, at))}
        at += 4 * groups
        scale = np.frombuffer(data, "<f4", words + groups, at)
        at += 4 * (words + groups)
        raw = np.frombuffer(data, np.uint8, (words + groups) * self.width * 3 // 8, at).reshape(words + groups, -1, 3).astype(np.uint32)
        assert at + raw.size == len(data)
        joined = raw[:, :, 0] | (raw[:, :, 1] << 8) | (raw[:, :, 2] << 16)
        numbers = np.stack([(joined >> (3 * i)) & 7 for i in range(8)], axis=2).reshape(words + groups, self.width).astype(np.float32) - self.top
        self.table = numbers * scale[:, None]

    def scores(self, text):
        """A text's score for each language; `chances` turns them into shares of 1."""
        total, count = np.zeros(self.width, dtype=np.float64), 0
        for word in SPACES.split(text.encode()):
            if not word:
                continue
            row = self.words.get(word)
            if row is not None:
                total += self.table[row]
                count += 1
            for group in letter_groups(word, self.minn, self.maxn, self.bucket):
                count += 1
                row = self.groups.get(group)
                if row is not None:
                    total += self.table[row]
        total += self.table[self.words[END]]
        return self.output.astype(np.float64) @ (total / (count + 1))

    def chances(self, text):
        scores = self.scores(text)
        scores = np.exp(scores - scores.max())
        return scores / scores.sum()

    def best(self, text):
        chances = self.chances(text)
        return self.labels[int(chances.argmax())], float(chances.max())


def check(model=None):
    """The file's accuracy; and that reading a text straight from the file gives what the
    sums over the original's rows gave."""
    model = model or Original()
    small = Small()
    old_row = np.full(model.rows, -1, dtype=np.int64)  # the file's row for each of the original's
    for word, row in small.words.items():
        old_row[model.number[word]] = row
    for group, row in small.groups.items():
        old_row[model.nwords + group] = row
    keep = old_row >= 0
    counted = keep.copy()
    counted[model.nwords:] = True
    marked = np.zeros((model.rows, small.width + 1), dtype=np.float32)
    marked[keep, :-1] = small.table[old_row[keep]]
    marked[:, -1] = counted
    for name, kind in (("sentences", "whole"), ("two words", "parts")):
        rows, starts, labels, codes = texts("devtest", kind)
        total = averages(marked, rows, starts, mode="sum")
        scores = (total[:, :-1] / np.maximum(total[:, -1:], 1)) @ small.output.T
        report(f"  {name}", scores, labels, codes, small.labels)
        if kind == "parts":
            worst(scores, labels, codes, small.labels)
    with open(f"{FLORES}/devtest/lvs_Latn.devtest", encoding="utf-8") as f:
        lines = [line.strip() for line in f][:200]
    rows, starts, labels, codes = texts("devtest", "whole")
    first = codes.index("lvs_Latn") * 1012
    total = averages(marked, rows[starts[first]:starts[first + 200]], starts[first:first + 201] - starts[first], mode="sum")
    by_rows = (total[:, :-1] / np.maximum(total[:, -1:], 1)) @ small.output.T
    by_text = np.array([small.scores(line) for line in lines])
    print(f"  read from the file as the app reads it: largest difference in a score {np.abs(by_rows - by_text).max():.1e}")


def vectors(out="../tests/detect-vectors.json"):
    """Texts with the file's answer for each, for checking the app's own reading of it
    (`BTranslate --pack-check`)."""
    small = Small()
    picked = []
    for code in ("lvs_Latn", "srp_Cyrl", "hrv_Latn", "rus_Cyrl", "eng_Latn", "pes_Arab", "zho_Hans", "jpn_Jpan", "tha_Thai", "hin_Deva",
                 "kat_Geor", "ell_Grek", "heb_Hebr", "kor_Hang", "tgk_Cyrl", "afr_Latn", "vie_Latn", "tur_Latn", "amh_Ethi", "deu_Latn"):
        with open(f"{FLORES}/dev/{code}.dev", encoding="utf-8") as f:
            lines = [line.strip() for line in f]
        picked += [lines[3], fragment(lines[7]), lines[11].upper()]
    picked += ["Paldies, labi.", "Hvala, dobro.", "ok", "12345 !!!", "naïve café\tword\nnew line", "ǅ ﬁ Å ｆｕｌｌ", "🙂 emoji 👍🏽", " ", ""]
    answers(small, picked, out)


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "texts":
        make_texts(Original())
    elif command == "measure":
        measure()
    elif command == "try":
        try_sizes(sys.argv[2:])
    elif command == "shrink":
        shrink(*(int(a) for a in sys.argv[2:4]))
    elif command == "check":
        check()
    elif command == "vectors":
        vectors()
    elif command == "toy":
        toy()
    else:
        print(__doc__)
