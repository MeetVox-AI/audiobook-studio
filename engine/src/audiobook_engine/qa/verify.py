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

# Per language overrides (cer, deletion run, insertion run). en and fr use the constants above. The CJK runs
# count characters (a dropped sentence is ~10+ characters), Korean's word runs are one longer because Korean
# spacing varies (a merged or split word looks like a short deletion plus insertion). These values were set
# from the structure of each script, NOT calibrated on audio: re-measure on real narration (see the report).
_PROFILES: dict[str, tuple[float, int, int]] = {
    "zh": (0.25, 10, 12),
    "ja": (0.25, 10, 12),
    "ko": (MAX_CER, 5, 6),
}
MAX_CER_VARIANT = 0.45   # Chinese: errors are only one-for-one substitutions (Traditional vs Simplified suspected)
VARIANT_MAX_INDEL = 0.03  # ... and at most this share of the characters is inserted or deleted


def _fold_word_fr(w: str) -> str:
    if len(w) > 4 and w.endswith("ent"):
        w = w[:-3]
    while len(w) > 2 and w[-1] in "sxtde":
        w = w[:-1]
    return w


# ---------------------------------------------------------------------------------------------- per language
#
# en and fr keep their original folding (ASCII letters and digits only). The other languages are folded by
# family, always the same way on the expected text and on what Whisper heard, so a harmless spelling choice
# of Whisper costs nothing:
#   Latin (es de it pt nl)  case, accents, punctuation; German umlauts/eszett spelled out (ae oe ue ss)
#   Russian                 case, yo -> ye, stress marks, punctuation (the letters are kept as Cyrillic)
#   Arabic                  tashkeel and tatweel removed; alef, yaa, taa marbuta, hamza carriers unified
#   Hindi                   nukta dropped, chandrabindu -> anusvara, nasal+virama -> anusvara
#   Korean                  Hangul syllables (NFKC recomposes jamo); words and characters both scored
#   Chinese, Japanese       no word spaces: every character is a unit (character error rate, character runs)
# Chinese: Whisper may answer in Traditional characters for a Simplified text. No conversion library is
# allowed, so ~90 very common pairs are folded to Simplified and, for the rest, a mismatch made only of
# one-for-one substitutions is judged with a looser threshold (see Score.bad).

CJK = frozenset({"zh", "ja"})

_LATIN_EXTRA = str.maketrans({"ß": "ss", "ø": "o", "ł": "l", "đ": "d", "ı": "i", "æ": "ae", "œ": "oe", "þ": "th",
                              "ð": "d"})
_DE_UMLAUT = str.maketrans({"ä": "ae", "ö": "oe", "ü": "ue"})

_TRAD_TO_SIMP = {
    "這": "这", "個": "个", "來": "来", "說": "说", "國": "国", "時": "时", "學": "学", "會": "会", "對": "对", "給": "给",
    "過": "过", "還": "还", "後": "后", "見": "见", "開": "开", "長": "长", "問": "问", "發": "发", "點": "点", "現": "现",
    "裡": "里", "馬": "马", "門": "门", "從": "从", "書": "书", "樣": "样", "間": "间", "頭": "头", "話": "话", "讓": "让",
    "沒": "没", "為": "为", "與": "与", "機": "机", "關": "关", "東": "东", "業": "业", "車": "车", "無": "无", "氣": "气",
    "親": "亲", "語": "语", "識": "识", "認": "认", "應": "应", "體": "体", "廣": "广", "電": "电", "歲": "岁", "帶": "带",
    "師": "师", "覺": "觉", "當": "当", "聽": "听", "愛": "爱", "麼": "么", "實": "实", "經": "经", "樂": "乐",
    "將": "将", "進": "进", "動": "动", "該": "该", "傳": "传", "轉": "转", "買": "买", "賣": "卖", "讀": "读", "寫": "写",
    "記": "记", "請": "请", "謝": "谢", "區": "区", "張": "张", "場": "场", "兒": "儿", "習": "习", "興": "兴", "並": "并",
    "邊": "边", "遠": "远", "運": "运", "達": "达", "歡": "欢", "難": "难", "題": "题", "計": "计", "劃": "划", "論": "论",
    "結": "结", "約": "约", "紅": "红", "綠": "绿", "節": "节", "筆": "笔", "紙": "纸", "萬": "万", "錢": "钱", "鐘": "钟",
    "雙": "双", "離": "离", "領": "领", "風": "风", "飛": "飞", "養": "养", "魚": "鱼", "鳥": "鸟", "龍": "龙", "黃": "黄",
    "黨": "党", "灣": "湾", "義": "义", "戰": "战", "護": "护", "產": "产", "隻": "只", "臺": "台", "號": "号", "處": "处",
    "變": "变",
}
_ZH_TABLE = str.maketrans(_TRAD_TO_SIMP)
_CJK_DIGITS = str.maketrans("〇零一二三四五六七八九", "00123456789")

_AR_MARKS = re.compile("[\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06ed\u0640]")
_AR_MAP = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ى": "ي", "ی": "ي", "ې": "ي", "ة": "ه", "ہ": "ه",
                         "ؤ": "و", "ئ": "ي", "ک": "ك", "ء": None})
_DIGITS_AR = str.maketrans("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹", "01234567890123456789")
_DIGITS_HI = str.maketrans("०१२३४५६७८९", "0123456789")
_HI_NASAL = {"ङ": "कखगघ", "ञ": "चछजझ", "ण": "टठडढ", "न": "तथदध", "म": "पफबभ"}
_HI_NASAL_OK = {n: set(cs) for n, cs in _HI_NASAL.items()}

_LATIN_OK = re.compile(r"[^a-z0-9 ]+")
_CYR_OK = re.compile(r"[^\u0430-\u044f0-9 ]+")
_AR_OK = re.compile(r"[^\u0621-\u063f\u0641-\u064a0-9 ]+")
_HI_OK = re.compile(r"[^\u0900-\u097f0-9 ]+|[\u0964\u0965\u0970]")  # drop the danda and abbreviation sign
_KO_OK = re.compile(r"[^\uac00-\ud7a30-9 ]+")
_CJK_OK = re.compile(r"[^\u3040-\u30ff\u3400-\u9fffー0-9]+")


def _fold_hi(t: str) -> str:
    t = t.translate(_DIGITS_HI)
    t = unicodedata.normalize("NFD", t)
    t = t.replace("\u093c", "").replace("\u0901", "\u0902").replace("\u200c", "").replace("\u200d", "")
    t = unicodedata.normalize("NFC", t)
    out, i = [], 0
    while i < len(t):
        c = t[i]
        if c in _HI_NASAL_OK and i + 2 < len(t) and t[i + 1] == "\u094d" and t[i + 2] in _HI_NASAL_OK[c]:
            out.append("\u0902")
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _kata_to_hira(t: str) -> str:
    return "".join(chr(ord(c) - 0x60) if "\u30a1" <= c <= "\u30f6" else c for c in t)


def fold_words(text: str, lang: str) -> list[str]:
    lang = _code(lang)
    t = normalize_paragraph(text, lang)  # same number/abbreviation expansion as the TTS input
    if lang in ("en", "fr"):
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
    t = unicodedata.normalize("NFKC", t).lower()
    if lang in CJK:
        t = t.translate(_CJK_DIGITS)
        if lang == "zh":
            t = t.translate(_ZH_TABLE)
        else:
            t = _kata_to_hira(t)
        return list(_CJK_OK.sub("", t))
    t = re.sub(r"(?<=\w)-(?=\w)", "", t)
    t = re.sub(r"['’ʼ`´]", " " if lang in ("it", "pt", "es", "nl") else "", t)
    if lang == "ru":
        t = unicodedata.normalize("NFD", t).replace("ё", "е").replace("е\u0308", "е")
        t = "".join(c for c in t if c != "\u0301" and c != "\u0300")
        t = unicodedata.normalize("NFC", t).replace("ё", "е")
        t = _CYR_OK.sub(" ", t)
    elif lang == "ar":
        t = _AR_MARKS.sub("", t.translate(_DIGITS_AR)).translate(_AR_MAP)
        t = _AR_OK.sub(" ", t)
    elif lang == "hi":
        t = _HI_OK.sub(" ", _fold_hi(t))
    elif lang == "ko":
        t = _KO_OK.sub(" ", t)
    else:  # es de it pt nl
        if lang == "de":
            t = t.translate(_DE_UMLAUT)
        t = t.translate(_LATIN_EXTRA)
        t = unicodedata.normalize("NFKD", t)
        t = "".join(c for c in t if not unicodedata.combining(c))
        t = _LATIN_OK.sub(" ", t)
    return t.split()


def _code(lang: str) -> str:
    from ..languages import normalize_code

    return normalize_code(lang) or lang


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
    lang: str = ""            # language code; selects the thresholds ("" = en/fr constants)
    variant_suspect: bool = False  # Chinese: looks like a script-variant mismatch, judged with a looser CER

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
        max_cer, del_run, ins_run = _PROFILES.get(self.lang, (MAX_CER, MAX_DELETION_RUN, MAX_INSERTION_RUN))
        if self.variant_suspect:
            max_cer = MAX_CER_VARIANT
        return self.cer > max_cer or self.max_deletion_run >= del_run or self.max_insertion_run >= ins_run

    def to_json(self) -> dict:
        d = asdict(self)
        d.pop("lang")
        if not d.pop("variant_suspect"):
            pass
        else:
            d["variant_suspect"] = True
        d["cer"] = round(self.cer, 3)
        d["bad"] = self.bad
        return d


def _score(char_ops: list[tuple[str, int]], chars: int, word_ops: list[tuple[str, int]], heard: str = "",
           lang: str = "") -> Score:
    s = sum(1 for o, _ in char_ops if o == "S")
    dl = sum(1 for o, _ in char_ops if o == "D")
    ins = sum(1 for o, _ in char_ops if o == "I")
    lang = lang if lang in _PROFILES else ""
    suspect = (lang == "zh" and chars >= MIN_CHARS_FOR_RATE and s > 0
               and (dl + ins) <= VARIANT_MAX_INDEL * chars)
    return Score(cer=(s + dl + ins) / max(chars, 1), chars=chars, substitutions=s, deletions=dl, insertions=ins,
                 max_deletion_run=_longest(word_ops, "D"), max_insertion_run=_longest(word_ops, "I"), heard=heard,
                 lang=lang, variant_suspect=suspect)


def score(expected: str, heard: str, lang: str) -> Score:
    rw, hw = fold_words(expected, lang), fold_words(heard, lang)
    ref, hyp = "".join(rw), "".join(hw)
    return _score(align(ref, hyp), len(ref), align_words(rw, hw), heard, _code(lang))


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
    code = _code(lang)
    return [_score(c, len(r), w, lang=code) for c, w, r in zip(char_per, word_per, refs)]


def to_16k(audio: np.ndarray, sr: int) -> np.ndarray:
    if sr == WHISPER_SR:
        return audio.astype(np.float32)
    from math import gcd

    from scipy.signal import resample_poly

    g = gcd(WHISPER_SR, sr)
    return resample_poly(audio, WHISPER_SR // g, sr // g).astype(np.float32)


# Whisper's Chinese output is Traditional or Simplified depending on the audio; a Simplified prompt steers it
# to Simplified (the usual trick). Only used for zh.
ZH_PROMPT = "以下是普通话的句子。"


class Verifier:
    def __init__(self, lang: str):
        self.lang = _code(lang)  # Whisper takes the bare ISO code: "pt-BR" -> "pt"
        self.model = None

    def load(self) -> None:
        if self.model is None:
            from mlx_audio.stt.utils import load

            self.model = load(WHISPER)

    def transcribe(self, audio16k: np.ndarray) -> str:
        self.load()
        extra = {"initial_prompt": ZH_PROMPT} if self.lang == "zh" else {}
        out = self.model.generate(audio16k, language=self.lang, verbose=False,
                                  condition_on_previous_text=False, temperature=0.0, **extra)
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
