"""Downloads Meta's NLLB-200 (distilled, 600M) from Hugging Face into nllb-600m/ (2.5 GB)."""
from huggingface_hub import snapshot_download

print(snapshot_download(
    "facebook/nllb-200-distilled-600M", local_dir="nllb-600m",
    allow_patterns=["pytorch_model.bin", "config.json", "generation_config.json", "sentencepiece.bpe.model",
                    "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"]))
