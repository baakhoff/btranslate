"""Stores the converted models' weights in 8 bits instead of 16, to halve the download.

  venv/bin/python quantize.py [LENGTH]   coreml/nllb-*-LENGTH.mlpackage → coreml/nllb-*-LENGTH-q8.mlpackage
"""
import sys
import time

import coremltools as ct
import coremltools.optimize.coreml as cto

length = int(sys.argv[1]) if len(sys.argv) > 1 else 64
config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel"))
for part in ("encoder", "decoder"):
    started = time.time()
    model = ct.models.MLModel(f"coreml/nllb-{part}-{length}.mlpackage", compute_units=ct.ComputeUnit.CPU_ONLY, skip_model_load=True)
    cto.linear_quantize_weights(model, config).save(f"coreml/nllb-{part}-{length}-q8.mlpackage")
    print(f"{part}: 8-bit weights in {time.time() - started:.0f} s")
