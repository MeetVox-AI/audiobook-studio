"""Speech-to-text QA: did the narrator say what the text says?

Chunks are transcribed with Whisper (mlx-audio, on-device) and compared with
the text that was synthesised.

Scoring is character-based on a "folded" form of both texts (same number and
abbreviation expansion as the TTS input, no accents, no punctuation, no
spaces; French silent endings removed). This makes spacing, hyphenation,
spelling variants (Bennet/Bennett) and French homophones (il était / ils
étaient) cost little, while dropped or hallucinated phrases show up as long
runs of deleted or inserted characters. Thresholds were calibrated on clean
narration (see CALIBRATION below).

Speed: Whisper always processes a 30 s window, so short chunks are packed
together (with silence between them) into one window; errors are mapped back
to individual chunks through the alignment.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import asdict, dataclass

import numpy as np

from ..textproc.normalize import normalize_paragraph

WHISPER = "mlx-community/whisper-large-v3-turbo-asr-fp16"
WHISPER_SR = 16000  # mlx-audio's Whisper assumes 16 kHz arrays and does not resample
WINDOW_S = 27.0     # pack chunks up to this much audio per Whisper call
GAP_S = 0.6

# Pass/fail thresholds (characters of the folded text).
MAX_CER = 0.15
MAX_DELETION_RUN = 4    # words dropped in a row
MAX_INSERTION_RUN = 5   # extra words in a row
MIN_CHARS_FOR_RATE = 20  # below this, judge by absolute errors only
MAX_ABS_ERRORS_SHORT = 6


def _fold_word_fr(w: str) -> str:
    if len(w) > 4 and w.endswith("ent"):
        w = w[:-3]
    while len(w) > 2 and w[-1] in "sxtde":
        w = w[:-1]
    return w


def fold_words(text: str, lang: str) -> list[str]:
    t = normalize_paragraph(text, lang)  # same number/abbreviation expansion as the TTS input
    t = unicodedata.normalize("NFKD", t.lower())
    t = "".join(c for c in t if not unicodedata.combining(c))
    t = t.replace("œ", "oe").replace("æ", "ae")
    t = re.sub(r"(?<=\w)-(?=\w)", "", t)
    t = re.sub(r"['’]", " ", t)
    t = re.sub(r"[^a-z0-9 ]+", " ", t)
    ws = t.split()
    if lang == "fr":
        ws = [_fold_word_fr(w) for w in ws]
    return ws


def fold(text: str, lang: str) -> str:
    return "".join(fold_words(text, lang))


def _align_ids(r: np.ndarray, h: np.ndarray) -> list[tuple[str, int]]:
    """Levenshtein alignment of two integer sequences; ops ('=', 'S', 'D', 'I') with the ref index touched."""
    n, m = r.size, h.size
    d = np.zeros((n + 1, m + 1), dtype=np.int32)
    d[0] = np.arange(m + 1)
    ar = np.arange(m + 1, dtype=np.int32)
    for i in range(1, n + 1):
        sub = d[i - 1, :-1] + (h != r[i - 1])
        cand = np.empty(m + 1, dtype=np.int32)
        cand[0] = i
        cand[1:] = np.minimum(d[i - 1, 1:] + 1, sub)
        # insertions run left to right: row[j] = min_k(cand[k] + j - k)
        d[i] = np.minimum.accumulate(cand - ar) + ar
    ops: list[tuple[str, int]] = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i, j] == d[i - 1, j - 1] + (0 if r[i - 1] == h[j - 1] else 1):
            ops.append(("=" if r[i - 1] == h[j - 1] else "S", i - 1))
            i, j = i - 1, j - 1
        elif i > 0 and d[i, j] == d[i - 1, j] + 1:
            ops.append(("D", i - 1))
            i -= 1
        else:
            ops.append(("I", max(i - 1, 0)))
            j -= 1
    ops.reverse()
    return ops


def align(ref: str, hyp: str) -> list[tuple[str, int]]:
    """Character-level alignment of two strings."""
    to = lambda x: np.frombuffer(x.encode("utf-32-le"), dtype=np.uint32) if x else np.zeros(0, np.uint32)  # noqa: E731
    return _align_ids(to(ref), to(hyp))


def align_words(ref: list[str], hyp: list[str]) -> list[tuple[str, int]]:
    vocab: dict[str, int] = {}
    ids = lambda ws: np.array([vocab.setdefault(w, len(vocab)) for w in ws], dtype=np.int64)  # noqa: E731
    return _align_ids(ids(ref), ids(hyp))


def _longest(ops: list[tuple[str, int]], op: str) -> int:
    best = run = 0
    for o, _ in ops:
        run = run + 1 if o == op else 0
        best = max(best, run)
    return best


@dataclass
class Score:
    cer: float
    chars: int
    substitutions: int
    deletions: int
    insertions: int
    max_deletion_run: int
    max_insertion_run: int
    heard: str = ""

    @property
    def errors(self) -> int:
        return self.substitutions + self.deletions + self.insertions

    @property
    def bad(self) -> bool:
        if self.chars == 0:
            # Nothing comparable in the text (e.g. a Greek or Cyrillic quotation folds to nothing):
            # any transcription would count as "inserted", so no verdict.
            return False
        if self.chars < MIN_CHARS_FOR_RATE:
            return self.errors >= max(MAX_ABS_ERRORS_SHORT, self.chars)  # tiny chunks: only gross failures
        return (self.cer > MAX_CER or self.max_deletion_run >= MAX_DELETION_RUN
                or self.max_insertion_run >= MAX_INSERTION_RUN)

    def to_json(self) -> dict:
        d = asdict(self)
        d["cer"] = round(self.cer, 3)
        d["bad"] = self.bad
        return d


def _score(char_ops: list[tuple[str, int]], chars: int, word_ops: list[tuple[str, int]], heard: str = "") -> Score:
    s = sum(1 for o, _ in char_ops if o == "S")
    dl = sum(1 for o, _ in char_ops if o == "D")
    ins = sum(1 for o, _ in char_ops if o == "I")
    return Score(cer=(s + dl + ins) / max(chars, 1), chars=chars, substitutions=s, deletions=dl, insertions=ins,
                 max_deletion_run=_longest(word_ops, "D"), max_insertion_run=_longest(word_ops, "I"), heard=heard)


def score(expected: str, heard: str, lang: str) -> Score:
    rw, hw = fold_words(expected, lang), fold_words(heard, lang)
    ref, hyp = "".join(rw), "".join(hw)
    return _score(align(ref, hyp), len(ref), align_words(rw, hw), heard)


def _split_by_ref(ops: list[tuple[str, int]], bounds: np.ndarray, k: int) -> list[list[tuple[str, int]]]:
    per: list[list[tuple[str, int]]] = [[] for _ in range(k)]
    for op, ri in ops:
        idx = int(np.searchsorted(bounds, ri, side="right") - 1)
        per[min(max(idx, 0), k - 1)].append((op, ri))
    return per


def score_packed(expected_texts: list[str], heard: str, lang: str) -> list[Score]:
    """Score several consecutive chunks transcribed together; errors are attributed via the alignment."""
    ref_words = [fold_words(t, lang) for t in expected_texts]
    refs = ["".join(w) for w in ref_words]
    hw = fold_words(heard, lang)
    k = len(refs)
    char_per = _split_by_ref(align("".join(refs), "".join(hw)), np.cumsum([0] + [len(r) for r in refs]), k)
    word_per = _split_by_ref(align_words([w for ws in ref_words for w in ws], hw),
                             np.cumsum([0] + [len(w) for w in ref_words]), k)
    return [_score(c, len(r), w) for c, w, r in zip(char_per, word_per, refs)]


def to_16k(audio: np.ndarray, sr: int) -> np.ndarray:
    if sr == WHISPER_SR:
        return audio.astype(np.float32)
    from math import gcd

    from scipy.signal import resample_poly

    g = gcd(WHISPER_SR, sr)
    return resample_poly(audio, WHISPER_SR // g, sr // g).astype(np.float32)


class Verifier:
    def __init__(self, lang: str):
        self.lang = lang
        self.model = None

    def load(self) -> None:
        if self.model is None:
            from mlx_audio.stt.utils import load

            self.model = load(WHISPER)

    def transcribe(self, audio16k: np.ndarray) -> str:
        self.load()
        out = self.model.generate(audio16k, language=self.lang, verbose=False,
                                  condition_on_previous_text=False, temperature=0.0)
        return (getattr(out, "text", None) or "").strip()

    def check(self, expected: str, audio: np.ndarray, sr: int) -> Score:
        if audio.size == 0:
            return score(expected, "", self.lang)
        return score(expected, self.transcribe(to_16k(audio, sr)), self.lang)

    def check_many(self, texts: list[str], audios: list[np.ndarray], sr: int) -> list[Score]:
        """Pack consecutive chunks into ~27 s windows, one Whisper call per window."""
        results: list[Score | None] = [None] * len(texts)
        gap = np.zeros(int(GAP_S * WHISPER_SR), np.float32)
        i = 0
        while i < len(texts):
            group, total = [], 0.0
            while i < len(texts):
                a16 = to_16k(audios[i], sr)
                dur = a16.size / WHISPER_SR
                if group and total + dur + GAP_S > WINDOW_S:
                    break
                group.append((i, a16))
                total += dur + GAP_S
                i += 1
            if len(group) == 1:
                k, a16 = group[0]
                results[k] = score(texts[k], self.transcribe(a16) if a16.size else "", self.lang)
                continue
            packed = np.concatenate([x for _, a in group for x in (a, gap)])
            heard = self.transcribe(packed)
            for (k, _), sc in zip(group, score_packed([texts[k] for k, _ in group], heard, self.lang)):
                results[k] = sc
        return results  # type: ignore[return-value]
