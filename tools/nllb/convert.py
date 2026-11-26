"""Converts NLLB-200 (distilled, 600M) to two Core ML models with 16-bit floats.

  venv/bin/python convert.py [LENGTH]   →  coreml/nllb-encoder-LENGTH.mlpackage
                                           coreml/nllb-decoder-LENGTH.mlpackage

LENGTH is the longest sentence, and the longest translation, in tokens (64 by default: a
long sentence). Every shape is fixed, as the Neural Engine wants it.
"""
import os
import sys
import time

import coremltools as ct
import numpy as np
import torch

from nllb import Decoder, Encoder, load


def main():
    length = int(sys.argv[1]) if len(sys.argv) > 1 else 64
    hf, _ = load()
    width = hf.config.d_model
    encoder, decoder = Encoder(hf, length).eval(), Decoder(hf, length).eval()
    ids, mask = torch.ones(1, length, dtype=torch.int32), torch.ones(1, length)
    at = torch.zeros(1, length)
    at[0, 0] = 1
    memory = torch.zeros(1, length, width)
    with torch.no_grad():
        traced_encoder = torch.jit.trace(encoder, (ids, mask))
        traced_decoder = torch.jit.trace(decoder, (ids, at, memory, mask))
    settings = dict(convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
                    compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_AND_NE)
    os.makedirs("coreml", exist_ok=True)

    started = time.time()
    model = ct.convert(traced_encoder, **settings,
                       inputs=[ct.TensorType("ids", shape=(1, length), dtype=np.int32),
                               ct.TensorType("mask", shape=(1, length), dtype=np.float32)],
                       outputs=[ct.TensorType("memory", dtype=np.float32)])
    model.save(f"coreml/nllb-encoder-{length}.mlpackage")
    print(f"encoder converted in {time.time() - started:.0f} s")

    started = time.time()
    model = ct.convert(traced_decoder, **settings,
                       inputs=[ct.TensorType("ids", shape=(1, length), dtype=np.int32),
                               ct.TensorType("at", shape=(1, length), dtype=np.float32),
                               ct.TensorType("memory", shape=(1, length, width), dtype=np.float32),
                               ct.TensorType("mask", shape=(1, length), dtype=np.float32)],
                       outputs=[ct.TensorType("scores", dtype=np.float32)])
    model.save(f"coreml/nllb-decoder-{length}.mlpackage")
    print(f"decoder converted in {time.time() - started:.0f} s")


if __name__ == "__main__":
    main()
