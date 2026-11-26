"""Translates with the converted Core ML models and says where the work runs.

  venv/bin/python run_coreml.py [LENGTH] [ne|cpu|gpu] [BEAMS]   every text of quality.py; "ne"
                                                                (the default) is Neural Engine
                                                                + CPU, never GPU; BEAMS is how
                                                                many translations are kept in
                                                                the running (4 by default, 1
                                                                is the quick, greedy way)
  venv/bin/python run_coreml.py [LENGTH] plan                   which part of each model Core
                                                                ML gives to the Neural Engine
"""
import os
import sys
import time
from collections import Counter

import coremltools as ct
import numpy as np
from transformers import AutoTokenizer

from quality import TEXTS, sentences

PAD, END = 1, 2
SUFFIX = os.environ.get("NLLB_SUFFIX", "")  # "-q8": the copy with 8-bit weights
UNITS = {"ne": ct.ComputeUnit.CPU_AND_NE, "cpu": ct.ComputeUnit.CPU_ONLY, "gpu": ct.ComputeUnit.CPU_AND_GPU}


class Translator:
    def __init__(self, length, where, beams):
        self.length, self.beams = length, beams
        started = time.time()
        self.encoder = ct.models.MLModel(f"coreml/nllb-encoder-{length}{SUFFIX}.mlpackage", compute_units=UNITS[where])
        self.decoder = ct.models.MLModel(f"coreml/nllb-decoder-{length}{SUFFIX}.mlpackage", compute_units=UNITS[where])
        self.load_seconds = time.time() - started
        self.tokenizer = AutoTokenizer.from_pretrained("nllb-600m")
        self.steps, self.encode_seconds, self.decode_seconds, self.sentences = 0, 0.0, 0.0, 0

    def next_scores(self, tokens, memory, mask):
        """The log-probability of every token as the one after `tokens`."""
        so_far = np.full((1, self.length), PAD, np.int32)
        so_far[0, :len(tokens)] = tokens
        at = np.zeros((1, self.length), np.float32)
        at[0, len(tokens) - 1] = 1
        started = time.time()
        raw = self.decoder.predict({"ids": so_far, "at": at, "memory": memory, "mask": mask})["scores"][0].astype(np.float64)
        self.decode_seconds += time.time() - started
        self.steps += 1
        raw -= raw.max()
        return raw - np.log(np.exp(raw).sum())

    def sentence(self, text, source, target):
        self.tokenizer.src_lang = source
        ids = self.tokenizer(text)["input_ids"][:self.length]
        padded = np.full((1, self.length), PAD, np.int32)
        padded[0, :len(ids)] = ids
        mask = np.zeros((1, self.length), np.float32)
        mask[0, :len(ids)] = 1
        started = time.time()
        memory = self.encoder.predict({"ids": padded, "mask": mask})["memory"]
        self.encode_seconds += time.time() - started
        self.sentences += 1

        # Beam search: keep the `beams` best unfinished translations, one token longer each step.
        start = [END, self.tokenizer.convert_tokens_to_ids(target)]  # how the model starts a translation
        live, finished = [(0.0, start)], []
        while live and len(live[0][1]) < self.length:
            grown = []
            for total, tokens in live:
                scores = self.next_scores(tokens, memory, mask)
                for token in np.argpartition(-scores, self.beams)[:self.beams]:
                    grown.append((total + float(scores[token]), tokens + [int(token)]))
            grown.sort(key=lambda item: -item[0])
            live = []
            for total, tokens in grown[:self.beams]:
                if tokens[-1] == END:
                    finished.append((total / len(tokens), tokens))  # per token: a longer translation is not punished
                else:
                    live.append((total, tokens))
            if len(finished) >= self.beams:
                break
        best = max(finished, key=lambda item: item[0])[1] if finished else live[0][1]
        return self.tokenizer.decode(best[2:], skip_special_tokens=True)

    def translate(self, text, source, target):
        return " ".join(self.sentence(s, source, target) for s in sentences(text))


def plan(length):
    """Counts each model's operations by the device Core ML prefers for them."""
    from coremltools.models.compute_plan import MLComputePlan
    for part in ("encoder", "decoder"):
        model = ct.models.MLModel(f"coreml/nllb-{part}-{length}{SUFFIX}.mlpackage", compute_units=UNITS["ne"])  # kept: its compiled copy goes with it
        compute_plan = MLComputePlan.load_from_path(path=model.get_compiled_model_path(), compute_units=UNITS["ne"])
        count, elsewhere = Counter(), Counter()
        for operation in compute_plan.model_structure.program.functions["main"].block.operations:
            usage = compute_plan.get_compute_device_usage_for_mlprogram_operation(operation)
            if usage is None:  # a constant: nothing to run
                continue
            device = type(usage.preferred_compute_device).__name__.replace("ML", "").replace("ComputeDevice", "")
            count[device] += 1
            if device != "NeuralEngine":
                elsewhere[operation.operator_name] += 1
        print(f"{part}: " + ", ".join(f"{device} {count[device]} operations" for device in sorted(count))
              + f"; not on the Neural Engine: {dict(elsewhere)}")


def main():
    arguments = sys.argv[1:]
    numbers = [int(a) for a in arguments if a.isdigit()]
    length = numbers[0] if numbers else 64
    beams = numbers[1] if len(numbers) > 1 else 4
    where = next((a for a in arguments if a in UNITS or a == "plan"), "ne")
    if where == "plan":
        return plan(length)
    translator = Translator(length, where, beams)
    print(f"models loaded in {translator.load_seconds:.1f} s ({where}, {beams} beam(s))")
    for name, source, target, text in TEXTS:
        started = time.time()
        result = translator.translate(text, source, target)
        print(f"\n== {name} ({time.time() - started:.1f} s)\n   {result}")
    print(f"\n{where}: {translator.steps} decoder steps, {1000 * translator.decode_seconds / max(translator.steps, 1):.1f} ms each; "
          f"encoder {1000 * translator.encode_seconds / max(translator.sentences, 1):.1f} ms a sentence")


if __name__ == "__main__":
    main()
