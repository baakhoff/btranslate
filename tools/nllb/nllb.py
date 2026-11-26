"""NLLB-200 (distilled, 600M) written out plainly, for conversion to Core ML.

The same network as Meta's (M2M100 in the transformers library), with the same weights, but
with fixed text lengths and nothing a converter can't follow: Core ML's Neural Engine wants
every shape known beforehand. `check()` compares it with the original.

  Encoder   token ids of the sentence (padded to SOURCE tokens)  →  one vector per token
  Decoder   the translation so far (padded to TARGET tokens), those vectors
            →  a score for every token of the vocabulary as the next one, for the position asked for

Picking the best tokens is left to the caller: Core ML's own "top k" looks only at the first
65,536 entries when the model is in 16-bit floats (lab/headtest.py shows it), and the
vocabulary has 256,206.

The decoder has no memory between steps: each step reads the whole translation so far again.
That costs time, and keeps the model one plain function, which is what the Neural Engine runs.
"""
import torch
import torch.nn as nn

MODEL = "nllb-600m"
PAD = 1
MASKED = -1e4  # "do not look here", small enough for 16-bit floats (the original's -3.4e38 is not)


class Attention(nn.Module):
    def __init__(self, original):
        super().__init__()
        self.heads, self.width = original.num_heads, original.embed_dim
        self.q, self.k, self.v, self.out = original.q_proj, original.k_proj, original.v_proj, original.out_proj

    def forward(self, x, source, mask):
        """x: (1, T, D) asks, source: (1, S, D) is asked; mask is added to the (1, heads, T, S) scores.
        (No shape is read from a tensor here: the converter wants them as plain numbers.)"""
        per_head = self.width // self.heads
        q = self.q(x).view(1, -1, self.heads, per_head).transpose(1, 2)
        k = self.k(source).view(1, -1, self.heads, per_head).transpose(1, 2)
        v = self.v(source).view(1, -1, self.heads, per_head).transpose(1, 2)
        scores = torch.matmul(q, k.transpose(2, 3)) * (per_head ** -0.5) + mask
        mixed = torch.matmul(scores.softmax(dim=-1), v)
        return self.out(mixed.transpose(1, 2).reshape(1, -1, self.width))


class EncoderLayer(nn.Module):
    def __init__(self, original):
        super().__init__()
        self.attention, self.norm1 = Attention(original.self_attn), original.self_attn_layer_norm
        self.fc1, self.fc2, self.norm2 = original.fc1, original.fc2, original.final_layer_norm

    def forward(self, x, mask):
        y = self.norm1(x)
        x = x + self.attention(y, y, mask)
        return x + self.fc2(torch.relu(self.fc1(self.norm2(x))))


class DecoderLayer(nn.Module):
    def __init__(self, original):
        super().__init__()
        self.attention, self.norm1 = Attention(original.self_attn), original.self_attn_layer_norm
        self.cross, self.norm2 = Attention(original.encoder_attn), original.encoder_attn_layer_norm
        self.fc1, self.fc2, self.norm3 = original.fc1, original.fc2, original.final_layer_norm

    def forward(self, x, causal, memory, memory_mask):
        y = self.norm1(x)
        x = x + self.attention(y, y, causal)
        x = x + self.cross(self.norm2(x), memory, memory_mask)
        return x + self.fc2(torch.relu(self.fc1(self.norm3(x))))


def positions(original, length):
    """The position vectors of a text's first `length` tokens (the original counts from 2)."""
    table = original.embed_positions.weights
    return table[2:2 + length].clone().unsqueeze(0)


class Encoder(nn.Module):
    def __init__(self, hf, length):
        super().__init__()
        original = hf.model.encoder
        self.embed = original.embed_tokens  # it multiplies by 32 (the square root of the width) itself
        self.register_buffer("positions", positions(original, length))
        self.layers = nn.ModuleList(EncoderLayer(layer) for layer in original.layers)
        self.norm = original.layer_norm

    def forward(self, ids, mask):
        """ids: (1, S) token ids, padded; mask: (1, S), 1 for a token and 0 for padding."""
        x = self.embed(ids) + self.positions
        hidden = (1.0 - mask.view(1, 1, 1, -1)) * MASKED
        for layer in self.layers:
            x = layer(x, hidden)
        return self.norm(x)


class Decoder(nn.Module):
    def __init__(self, hf, length):
        super().__init__()
        original = hf.model.decoder
        self.embed = original.embed_tokens
        self.register_buffer("positions", positions(original, length))
        self.register_buffer("causal", torch.triu(torch.full((length, length), MASKED), diagonal=1).view(1, 1, length, length))
        self.layers = nn.ModuleList(DecoderLayer(layer) for layer in original.layers)
        self.norm, self.head = original.layer_norm, hf.lm_head

    def hidden(self, ids, memory, memory_mask):
        x = self.embed(ids) + self.positions
        hidden = (1.0 - memory_mask.view(1, 1, 1, -1)) * MASKED
        for layer in self.layers:
            x = layer(x, self.causal, memory, hidden)
        return self.norm(x)

    def forward(self, ids, at, memory, memory_mask):
        """ids: (1, T) the translation so far, padded; at: (1, T), 1 at its last token and 0
        elsewhere. Returns (1, vocabulary): each token's score as the next one (not yet probabilities)."""
        x = self.hidden(ids, memory, memory_mask)
        last = (x * at.view(1, -1, 1)).sum(dim=1)  # (1, D): the vector at that position
        return self.head(last)


def load():
    from transformers import AutoModelForSeq2SeqLM, AutoTokenizer
    return AutoModelForSeq2SeqLM.from_pretrained(MODEL).eval(), AutoTokenizer.from_pretrained(MODEL)


def padded(ids, length):
    """(ids padded to `length`, mask) as (1, length) tensors."""
    ids = list(ids)[:length]
    mask = [1.0] * len(ids) + [0.0] * (length - len(ids))
    return torch.tensor([ids + [PAD] * (length - len(ids))], dtype=torch.int32), torch.tensor([mask])


def check(length=64):
    """Compares this network with the original on one sentence: the numbers must agree."""
    hf, tokenizer = load()
    tokenizer.src_lang = "lvs_Latn"
    source = tokenizer("Rīt es būšu birojā no deviņiem līdz pieciem.")["input_ids"]
    start = [2, tokenizer.convert_tokens_to_ids("rus_Cyrl")]
    with torch.no_grad():
        theirs = hf(input_ids=torch.tensor([source]), decoder_input_ids=torch.tensor([start]))
        ids, mask = padded(source, length)
        memory = Encoder(hf, length)(ids, mask)
        encoder_gap = (memory[0, :len(source)] - theirs.encoder_last_hidden_state[0]).abs().max().item()
        target, _ = padded(start, length)
        at = torch.zeros(1, length)
        at[0, len(start) - 1] = 1
        values, tokens = torch.log_softmax(Decoder(hf, length)(target, at, memory, mask), dim=-1).topk(8)
        expected = torch.log_softmax(theirs.logits[0, -1], dim=-1).topk(8)
    print(f"encoder: largest difference from the original {encoder_gap:.2e}")
    print(f"decoder: next tokens {tokens[0].tolist()[:4]} (original {expected.indices.tolist()[:4]}), "
          f"largest difference in their scores {(values[0] - expected.values).abs().max().item():.2e}")
    print("first word:", tokenizer.convert_ids_to_tokens(tokens[0, :4].tolist()))


if __name__ == "__main__":
    check()
