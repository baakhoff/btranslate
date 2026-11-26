#!/usr/bin/env python3
"""Checks BTranslate's translations against the texts in the source.

Every text the app shows is written in English in Sources/ as L("…"). Each other language
has a Resources/<code>.lproj/Localizable.strings with the English text as the key. This
checks, for each of them, that every text has a translation, that no translation is left
over from a text that is gone, and that a translation has the same %@ and %ld as its text
and ends the same way (":" or "…").

  python3 tools/check-strings.py          check; exits with 1 if something is wrong
  python3 tools/check-strings.py --keys   print the texts in the source, one per line
"""
import glob
import json
import re
import subprocess
import sys

CALL = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"')
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(@|ld|d)")
ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}


def texts_in_source():
    found = {}
    for path in sorted(glob.glob("Sources/*.swift")):
        with open(path, encoding="utf-8") as f:
            for number, line in enumerate(f, 1):
                if line.lstrip().startswith("//"):  # a comment may show how L("…") is written
                    continue
                for raw in CALL.findall(line):
                    if "\\(" in raw:
                        sys.exit(f'{path}:{number}: L("…") with \\( ) in it: use %@ and pass the value.')
                    text = re.sub(r"\\(.)", lambda m: ESCAPES.get(m.group(1), m.group(0)), raw)
                    found.setdefault(text, f"{path}:{number}")
    return found


def placeholders(text):
    return sorted(PLACEHOLDER.findall(text))


def ending(text):
    for mark in (":", "…", "."):
        if text.endswith(mark):
            return mark
    return ""


source = texts_in_source()
if "--keys" in sys.argv:
    print("\n".join(source))
    sys.exit(0)

problems = []
files = sorted(glob.glob("Resources/*.lproj/Localizable.strings"))
for path in files:
    converted = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True)
    if converted.returncode != 0:
        problems.append(f"{path}: not a strings file: {converted.stdout.strip() or converted.stderr.strip()}")
        continue
    translations = json.loads(converted.stdout)
    if path.startswith("Resources/en.lproj/"):
        problems += [f"{path}: English is the text in the source, but this has: {key}" for key in translations]
        continue
    for text, where in source.items():
        translation = translations.get(text)
        if translation is None:
            problems.append(f"{path}: no translation for the text at {where}: {text}")
        elif not translation.strip():
            problems.append(f"{path}: empty translation: {text}")
        elif placeholders(translation) != placeholders(text):
            problems.append(f"{path}: other placeholders than its text: {text}")
        elif ending(translation) != ending(text) and ending(text) in (":", "…"):
            problems.append(f"{path}: ends otherwise than its text: {text}")
    problems += [f"{path}: translation of a text that is not in the source: {key}" for key in translations if key not in source]

if not any(not p.startswith("Resources/en.lproj/") for p in files):
    problems.append("No Resources/<code>.lproj/Localizable.strings found: run this from the repository's top folder.")
if problems:
    print("\n".join(problems))
    sys.exit(1)
print(f"strings: ok ({len(source)} texts, {len(files) - 1} translation(s))")
