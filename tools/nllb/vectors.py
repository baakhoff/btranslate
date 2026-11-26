"""Writes ../tests/nllb-tokens.json: texts with the token numbers Meta's tokenizer gives them,
for checking BTranslate's own tokenizer (BTranslate --pack-check)."""
import json

from transformers import AutoTokenizer

from quality import TEXTS

EXTRA = [
    "Hello, world!", "Привет, мир!", "Labdien! Kā jums klājas?", "Sveiki", "ok", "A", "3D модель и 3MF-файл (STL, OBJ).",
    "Rīt  es būšu\tbirojā.", "  spaces   everywhere", "non breaking space", "zero​width", "tab\tand\nnewline",
    "«Кавычки» и “quotes” and ‘single’ — тире – dash - hyphen…", "Цена: 1 234,56 € (≈ $1,300.00) + 20% НДС", "https://example.com/path?q=1&x=y_z",
    "user@example.com", "C++ and C# vs. F#", "naïve café résumé", "naïve café", "ＡＢＣ１２３ ｆｕｌｌ ｗｉｄｔｈ", "ﬁnal ﬂight", "x² + y³ = ½",
    "Ђорђе Џаја љуби њиву ћирилицом.", "Đorđe Džaja ljubi njivu latinicom.", "Šī ir ļoti gara teikuma daļa, kas turpinās.",
    "ąčęėįšųūž ĄČĘĖĮŠŲŪŽ", "õäöü ÕÄÖÜ ß", "Ελληνικά κείμενο", "עברית טקסט", "نص عربي ١٢٣", "हिन्दी पाठ", "ไทย ข้อความ", "中文文本，标点。", "日本語のテキスト。",
    "한국어 텍스트", "😀 emoji 👍🏽 test", "ALL CAPITALS HERE", "MiXeD CaSe WoRdS", "a-b-c d_e_f g/h/i", "1.2.3 10:30 2026-11-26", "...", "?!", "",
    "Supercalifragilisticexpialidocious pneumonoultramicroscopicsilicovolcanoconiosis",
    "Ова реченица има ћирилицу и latinicu заједно.", "Tas ir tests: vai 'apostrofi' un \"pēdiņas\" strādā?",
    "Line one\nLine two",
]
tokenizer = AutoTokenizer.from_pretrained("nllb-600m")
cases = []
for text in [t[3] for t in TEXTS] + EXTRA:
    ids = tokenizer(text, add_special_tokens=False)["input_ids"]
    cases.append({"text": text, "ids": ids, "back": tokenizer.decode(ids, skip_special_tokens=True)})
with open("../tests/nllb-tokens.json", "w", encoding="utf-8") as f:
    json.dump(cases, f, ensure_ascii=False, indent=0)
print(len(cases), "texts,", sum(len(c["ids"]) for c in cases), "tokens; longest", max(len(c["ids"]) for c in cases))
print([ (c["text"], c["ids"]) for c in cases if c["text"] in ("zero​width", "ﬁnal ﬂight", "😀 emoji 👍🏽 test", "", "...") ])
