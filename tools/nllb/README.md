# Making the language pack

The language pack BTranslate downloads is Meta AI's
[NLLB-200, distilled, 600M](https://huggingface.co/facebook/nllb-200-distilled-600M),
converted to Core ML so that it runs on the Neural Engine. These scripts make it from the
original. The model's licence, CC-BY-NC 4.0, carries over to the pack: non-commercial use only.

They need Python 3.13 with a few packages, about 1 GB, and 6 GB of disk for the work. The
`lab` folder is ignored by git.

```bash
mkdir -p lab && cd lab
python3.13 -m venv venv
venv/bin/pip install torch transformers sentencepiece coremltools huggingface_hub
venv/bin/python ../tools/nllb/download.py       # Meta's model, 2.5 GB, into nllb-600m/
venv/bin/python ../tools/nllb/nllb.py           # checks that the plain rewrite gives the original's numbers
venv/bin/python ../tools/nllb/convert.py 64     # two Core ML models, 16-bit, sentences of up to 64 tokens
venv/bin/python ../tools/nllb/quantize.py 64    # the same with 8-bit weights: half the size
venv/bin/python ../tools/nllb/vectors.py        # tests/nllb-tokens.json, for checking the app's tokenizer
```

Then the detector of a text's language (below), and last the pack itself:

```bash
venv/bin/python ../tools/nllb/export.py 64      # pack/: the files to publish, with a list of checksums
```

To try the result before it goes into the app:

```bash
NLLB_SUFFIX=-q8 venv/bin/python ../tools/nllb/run_coreml.py 64 plan   # what runs on the Neural Engine
NLLB_SUFFIX=-q8 venv/bin/python ../tools/nllb/run_coreml.py 64 ne 4   # translates the texts of quality.py there
venv/bin/python ../tools/nllb/quality.py                              # the original with PyTorch, to compare
```

The files of `pack/` go, as they are, where `LanguagePack.address` in `Sources/NLLB.swift`
points: the assets of the release `nllb-200-v1`. A changed model is a new version: raise
`VERSION` in `export.py` and the names in `Sources/NLLB.swift`.

## The detector of a text's language

The pack translates a text read as the wrong language into nonsense, and the Mac's own
recognizer knows 53 languages. So the pack has a detector of its own: Meta AI's
[language identification model for NLLB-200](https://huggingface.co/facebook/fasttext-language-identification)
(a fastText classifier, CC-BY-NC 4.0 like the translator), made small by `lid.py`. It needs the
model and, to measure the result, the sentences of [FLORES-200](https://github.com/facebookresearch/flores)
(CC-BY-SA 4.0):

```bash
mkdir -p lid/meta lid/flores lid/cache
curl -L -o lid/meta/model.bin https://huggingface.co/facebook/fasttext-language-identification/resolve/main/model.bin   # 1.18 GB
curl -L -o lid/flores/flores200_dataset.tar.gz https://dl.fbaipublicfiles.com/nllb/flores200_dataset.tar.gz              # 26 MB
tar -xzf lid/flores/flores200_dataset.tar.gz -C lid/flores
BTranslate --pack-languages > lid/app-languages.tsv   # which languages count as "the app's" in the reports
venv/bin/python -I ../tools/nllb/lid.py texts     # every test sentence, and two words of it, as table rows (cached)
venv/bin/python -I ../tools/nllb/lid.py measure   # the original: what there is to keep
venv/bin/python -I ../tools/nllb/lid.py shrink    # lid/detect.bin, 20 MB, and what it gives
venv/bin/python -I ../tools/nllb/lid.py vectors   # tests/detect-vectors.json, for checking the app's reading of the file
venv/bin/python -I ../tools/nllb/lid.py toy       # tests/detect-toy.bin and .json: a made-up file for tests/run.sh
```

The original is a table of 1,145,940 rows of 256 numbers (a row for each of 145,940 words and
for each of a million hash values of letter groups) and a second table that turns the average
of a text's rows into a score for each of 218 languages. `lid.py` reads the file itself: no
fastText is needed. Three steps make it small:

- **128 numbers a row instead of 256.** Only the differences between the languages' scores
  count, so the rows keep their place along the 128 directions that move those most, and the
  rest of the arithmetic is folded into a smaller second table.
- **Three bits a number** (-3…3 times a scale of the row's own). Rounding this coarsely cuts a
  row's largest numbers off and drops its smallest, and that helps short texts: 71% of
  two-word fragments are told right, against the original's 68%.
- **350,000 rows of 1,145,940:** the ones that move the scores most.

Measured on FLORES-200's 1,012 test sentences in each of the 164 languages the app offers:

| | Sentences | Two words from the middle of a sentence |
|---|---|---|
| Meta's original, 1.18 GB | 96.0% | 68.1% |
| `detect.bin`, 19.9 MB | 95.8% | 70.7% |

In the app the detector does not decide alone (`OnDevice.guesses`): its scores count for less on
a short text, where the Mac's own recognizer, a few letters and words of Latvian, Serbian and
their neighbours, and the user's own languages are heard too; a text in capitals is put in
small letters first (the detector takes "ZABRANJENO PUŠENJE" for Cantonese), and digits,
punctuation and emoji are left out. `BTranslate --detect-eval FILE` measures the whole of it on
lines of "language, kind, text". On 60 test sentences of each language, whole and cut down:

| Right, of 100 texts | Sentence | Five words | Two words | One word |
|---|---|---|---|---|
| The app with the pack, all 164 languages | 97 | 90 | 72 | 51 |
| The same, the 52 languages the Mac's recognizer knows | 99 | 98 | 93 | 80 |
| The same, the other 112 | 96 | 87 | 63 | 38 |
| Without the pack's detector, all 164 | 35 | 34 | 31 | 25 |
| Without it, the 52 the Mac knows | 100 | 99 | 93 | 76 |
| Without it, the other 112 | 5 | 4 | 3 | 1 |

It is not a model for the Neural Engine: a few thousand lookups in a table and one small
multiplication take a tenth of a millisecond on the CPU.

## What the conversion had to get around

- **Core ML's "top k" in a 16-bit model looks at the first 65,536 entries only.** The
  vocabulary has 256,206, so the model returns every token's score and the app picks the best.
- **Every shape is fixed** (one sentence, 64 tokens), and no shape is read from a tensor: the
  Neural Engine and the converter both want plain numbers.
- **The decoder has no memory between steps:** each step reads the translation so far again.
  That is what keeps it one plain function on the Neural Engine; a step takes about 5 ms.
- **"Do not look here" is -10,000,** not the original's -3.4e38, which 16-bit floats can't hold.
