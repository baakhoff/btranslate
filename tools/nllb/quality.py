"""How well does NLLB-200 (distilled, 600M) translate the texts BTranslate is used for?

Runs Meta's original model with PyTorch on the CPU: this is about the quality of the model,
not about where it runs. One sentence at a time, as the model was trained.

  venv/bin/python quality.py            every text, with greedy decoding and with a beam of 4
"""
import re
import sys
import time

import torch
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

MODEL = "nllb-600m"

# (what it is, NLLB's code of the text's language, NLLB's code of the language to translate into, the text)
TEXTS = [
    ("Serbian, Latin letters, read as Croatian → Russian", "hrv_Latn", "rus_Cyrl",
     "Manyfold je veb aplikacija otvorenog koda (open-source) za samostalno hostovanje (self-hosted) i upravljanje kolekcijama 3D modela i fajlova za 3D štampu (poput STL, 3MF i OBJ formata)."),
    ("the same, read as Bosnian → Russian", "bos_Latn", "rus_Cyrl",
     "Manyfold je veb aplikacija otvorenog koda (open-source) za samostalno hostovanje (self-hosted) i upravljanje kolekcijama 3D modela i fajlova za 3D štampu (poput STL, 3MF i OBJ formata)."),
    ("the same turned into Cyrillic, read as Serbian → Russian", "srp_Cyrl", "rus_Cyrl",
     "Manyfold је веб апликација отвореног кода (open-source) за самостално хостовање (self-hosted) и управљање колекцијама 3D модела и фајлова за 3D штампу (попут STL, 3MF и OBJ формата)."),
    ("Serbian, Latin letters, everyday → Russian", "hrv_Latn", "rus_Cyrl",
     "Dobar dan, kako ste? Sutra ću biti u kancelariji od devet do pet, pa možemo da se vidimo posle posla ako vam odgovara."),
    ("the same in Cyrillic → Russian", "srp_Cyrl", "rus_Cyrl",
     "Добар дан, како сте? Сутра ћу бити у канцеларији од девет до пет, па можемо да се видимо после посла ако вам одговара."),
    ("Serbian, Cyrillic → English", "srp_Cyrl", "eng_Latn",
     "Јуче смо били на пијаци и купили свеже воће, сир и домаћи хлеб. Цене су ове године доста више него прошле."),
    ("Serbian, Latin letters, a notice → Russian", "hrv_Latn", "rus_Cyrl",
     "Poštovani stanari, zbog radova na vodovodnoj mreži u četvrtak od 9 do 14 časova neće biti vode. Molimo vas da na vreme obezbedite zalihe."),
    ("Latvian → Russian", "lvs_Latn", "rus_Cyrl",
     "Labdien! Kā jums klājas? Rīt es būšu birojā no deviņiem līdz pieciem. Lūdzu, atsūtiet man līguma projektu līdz piektdienai."),
    ("Latvian, news → English", "lvs_Latn", "eng_Latn",
     "Rīgas dome ir apstiprinājusi jaunu sabiedriskā transporta biļešu cenu, kas stāsies spēkā no nākamā gada janvāra."),
    ("Latvian, news → Russian", "lvs_Latn", "rus_Cyrl",
     "Rīgas dome ir apstiprinājusi jaunu sabiedriskā transporta biļešu cenu, kas stāsies spēkā no nākamā gada janvāra."),
    ("Latvian, a short message → Russian", "lvs_Latn", "rus_Cyrl",
     "Sveiki! Vai jūs varētu pateikt, cikos rīt sākas sapulce?"),
    ("Russian → Serbian (Cyrillic)", "rus_Cyrl", "srp_Cyrl",
     "Здравствуйте! Подскажите, пожалуйста, до скольки сегодня работает аптека и можно ли оплатить картой?"),
    ("English → Latvian", "eng_Latn", "lvs_Latn",
     "Please send me the draft contract by Friday so that I can review it over the weekend."),
]


def sentences(text):
    """One sentence at a time: the model drops sentences when it is given several at once."""
    return [s for s in re.split(r"(?<=[.!?…])\s+", text.strip()) if s]


def translate(model, tokenizer, text, source, target, beams):
    tokenizer.src_lang = source
    out = []
    for sentence in sentences(text):
        inputs = tokenizer(sentence, return_tensors="pt")
        with torch.no_grad():
            ids = model.generate(**inputs, forced_bos_token_id=tokenizer.convert_tokens_to_ids(target),
                                 num_beams=beams, max_new_tokens=200)
        out.append(tokenizer.batch_decode(ids, skip_special_tokens=True)[0])
    return " ".join(out)


def main():
    tokenizer = AutoTokenizer.from_pretrained(MODEL)
    model = AutoModelForSeq2SeqLM.from_pretrained(MODEL).eval()
    print(f"parameters: {sum(p.numel() for p in model.parameters()) / 1e6:.0f} M; vocabulary: {model.config.vocab_size}")
    for name, source, target, text in TEXTS:
        print(f"\n== {name}\n   {text}")
        for beams in (1, 4):
            started = time.time()
            result = translate(model, tokenizer, text, source, target, beams)
            print(f"   {'greedy' if beams == 1 else 'beam 4'} ({time.time() - started:.1f} s): {result}")


if __name__ == "__main__":
    sys.exit(main())
