"""Puts together the language pack BTranslate downloads: the two Core ML models with 8-bit
weights, the vocabulary, and a manifest with every file's size and checksum.

  venv/bin/python export.py [LENGTH]   →  pack/   (upload its files as they are: flat names)

The app asks for pack.json first, then for the files it lists, and rebuilds the two
.mlpackage folders from them (a folder can't be downloaded as one file).
"""
import hashlib
import json
import os
import shutil
import sys

import sentencepiece
from transformers import AutoTokenizer

VERSION = 1
length = int(sys.argv[1]) if len(sys.argv) > 1 else 64
out = "pack"
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)
prefix = f"nllb200-v{VERSION}-"
files = []


def add(source, name, path):
    """Copies `source` into the pack under the flat name `name`; the app stores it at `path`."""
    target = os.path.join(out, prefix + name)
    shutil.copyfile(source, target)
    digest = hashlib.sha256()
    with open(target, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    files.append({"name": prefix + name, "path": path, "size": os.path.getsize(target), "sha256": digest.hexdigest()})


for part in ("encoder", "decoder"):
    package = f"coreml/nllb-{part}-{length}-q8.mlpackage"
    add(f"{package}/Manifest.json", f"{part}-Manifest.json", f"{part}.mlpackage/Manifest.json")
    add(f"{package}/Data/com.apple.CoreML/model.mlmodel", f"{part}-model.mlmodel", f"{part}.mlpackage/Data/com.apple.CoreML/model.mlmodel")
    add(f"{package}/Data/com.apple.CoreML/weights/weight.bin", f"{part}-weight.bin", f"{part}.mlpackage/Data/com.apple.CoreML/weights/weight.bin")

# The vocabulary: one token per line, in the order of the model's token numbers, with the
# score the tokenizer merges by (SentencePiece's; empty for the special tokens and the
# language codes, which are never made by merging).
tokenizer = AutoTokenizer.from_pretrained("nllb-600m")
pieces = sentencepiece.SentencePieceProcessor(model_file="nllb-600m/sentencepiece.bpe.model")
score = {pieces.id_to_piece(i): pieces.get_score(i) for i in range(pieces.get_piece_size())}
by_id = sorted(tokenizer.get_vocab().items(), key=lambda item: item[1])
assert [i for _, i in by_id] == list(range(len(by_id))), "token numbers are not 0, 1, 2, …"
special = set(tokenizer.all_special_tokens)
languages = [token for token, _ in by_id if len(token) == 8 and token[3] == "_" and token in special]
with open("tokens.tsv", "w", encoding="utf-8") as f:
    for token, _ in by_id:
        assert "\t" not in token and "\n" not in token
        f.write(token + "\t" + ("" if token in special or token not in score else repr(score[token])) + "\n")
add("tokens.tsv", "tokens.tsv", "tokens.tsv")
os.remove("tokens.tsv")

manifest = {
    "id": "nllb-200", "version": VERSION, "length": length,
    "model": "NLLB-200 (distilled, 600M) by Meta AI, converted to Core ML with 8-bit weights",
    "license": "CC-BY-NC-4.0", "source": "https://huggingface.co/facebook/nllb-200-distilled-600M",
    "pad": tokenizer.pad_token_id, "end": tokenizer.eos_token_id, "unknown": tokenizer.unk_token_id,
    "languages": languages, "files": files,
}
with open(os.path.join(out, prefix + "pack.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=1)
total = sum(item["size"] for item in files)
print(f"{len(files)} files, {total / 1e6:.0f} MB, {len(languages)} languages, {len(by_id)} tokens → {out}/")
for item in files:
    print(f"  {item['size'] / 1e6:8.1f} MB  {item['name']}")
