"""Measure an engine on this Mac with fixed public-domain passages.

Results are saved (perf.json) and seed every later time estimate, so the app
can say "on this Mac" instead of quoting someone else's hardware.
"""

from __future__ import annotations

import time

from .perf import save_rate
from .textproc.normalize import normalize_paragraph
from .textproc.segment import chunk_section
from .tts import VoiceChoice, get_engine

# Public domain: Austen, Pride and Prejudice (1813), ch. 1; Verne, Le Tour du monde (1872), ch. 1.
PASSAGES = {
    "en": (
        "It is a truth universally acknowledged, that a single man in possession of a good fortune must be in want "
        "of a wife. However little known the feelings or views of such a man may be on his first entering a "
        "neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered "
        "as the rightful property of some one or other of their daughters. My dear Mister Bennet, said his lady to "
        "him one day, have you heard that Netherfield Park is let at last? Mister Bennet replied that he had not. "
        "But it is, returned she; for Missus Long has just been here, and she told me all about it. Mister Bennet "
        "made no answer. Do not you want to know who has taken it? cried his wife impatiently. You want to tell me, "
        "and I have no objection to hearing it. This was invitation enough. Why, my dear, you must know, Missus Long "
        "says that Netherfield is taken by a young man of large fortune from the north of England; that he came down "
        "on Monday in a chaise and four to see the place, and was so much delighted with it that he agreed with "
        "Mister Morris immediately; that he is to take possession before Michaelmas, and some of his servants are to "
        "be in the house by the end of next week."
    ),
    "fr": (
        "En l'année mil huit cent soixante-douze, la maison portant le numéro sept de Saville-row, Burlington "
        "Gardens, maison dans laquelle Sheridan mourut en mil huit cent quatorze, était habitée par Phileas Fogg, "
        "esquire, l'un des membres les plus singuliers et les plus remarqués du Reform-Club de Londres, bien qu'il "
        "semblât prendre à tâche de ne rien faire qui pût attirer l'attention. À l'un des plus grands orateurs qui "
        "honorent l'Angleterre, succédait donc ce Phileas Fogg, personnage énigmatique, dont on ne savait rien, "
        "sinon que c'était un fort galant homme et l'un des plus beaux gentlemen de la haute société anglaise. On "
        "disait qu'il ressemblait à Byron, par la tête, car il était irréprochable quant aux pieds, mais un Byron à "
        "moustaches et à favoris, un Byron impassible, qui aurait vécu mille ans sans vieillir. Anglais, à coup sûr, "
        "Phileas Fogg n'était peut-être pas Londonner. On ne l'avait jamais vu ni à la Bourse, ni à la Banque, ni "
        "dans aucun des comptoirs de la Cité."
    ),
}


def run(engine_id: str, voice: VoiceChoice, lang: str, batch: int | None = None, repeats: int = 1, emit=None) -> dict:
    import mlx.core as mx

    engine = get_engine(engine_id)
    spec = engine.spec
    text = normalize_paragraph(PASSAGES[lang], lang)
    chunks = chunk_section(0, [text], spec.cap_for(lang), first_is_heading=False, min_chars=spec.min_chunk)
    texts = [c.text for c in chunks]
    bs = batch or spec.batch_size
    load_s = engine.load(voice)
    t = time.perf_counter()
    engine.synthesize(texts[:1], voice, lang)
    warm = time.perf_counter() - t
    mx.reset_peak_memory()
    queue = texts * repeats  # one long queue so large batches are actually full
    audio = 0.0
    t = time.perf_counter()
    for i in range(0, len(queue), bs):
        out = engine.synthesize(queue[i:i + bs], voice, lang)
        audio += sum(a.size for a in out) / engine.sample_rate
    wall = time.perf_counter() - t
    walls = [wall]
    chars = sum(len(x) for x in queue)
    result = {
        "event": "benchmark", "engine": spec.id, "voice": voice.label(), "lang": lang, "batch": bs,
        "chunks": len(queue), "chars": chars, "load_s": round(load_s, 2), "warmup_s": round(warm, 2),
        "wall_s": round(wall, 2), "audio_s": round(audio, 1), "chars_per_s": round(chars / wall, 1),
        "realtime_x": round(audio / wall, 2), "seconds_per_char": round(audio / chars, 4),
        "peak_memory_gb": round(mx.get_peak_memory() / 1e9, 2),
        "runs": [round(w, 2) for w in walls],
    }
    if batch is None or batch == spec.batch_size:
        save_rate(spec.id, voice.label(), chars, wall, audio, "benchmark")
    if emit:
        emit(result)
    return result
