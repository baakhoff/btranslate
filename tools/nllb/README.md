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
venv/bin/python ../tools/nllb/export.py 64      # pack/: the files to publish, with a list of checksums
venv/bin/python ../tools/nllb/vectors.py        # tests/nllb-tokens.json, for checking the app's tokenizer
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

What the conversion had to get around:

- **Core ML's "top k" in a 16-bit model looks at the first 65,536 entries only.** The
  vocabulary has 256,206, so the model returns every token's score and the app picks the best.
- **Every shape is fixed** (one sentence, 64 tokens), and no shape is read from a tensor: the
  Neural Engine and the converter both want plain numbers.
- **The decoder has no memory between steps:** each step reads the translation so far again.
  That is what keeps it one plain function on the Neural Engine; a step takes about 5 ms.
- **"Do not look here" is -10,000,** not the original's -3.4e38, which 16-bit floats can't hold.
