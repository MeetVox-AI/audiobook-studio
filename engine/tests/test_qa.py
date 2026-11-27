from __future__ import annotations

import types

import numpy as np

from audiobook_engine.qa import verify
from audiobook_engine.qa.verify import align, fold, fold_words, score, score_packed, to_16k


def test_fold_numbers_accents_hyphens_and_french_endings():
    assert fold_words("L'été 1873 !", "fr")[0] == "l" and fold("L'été", "fr") == fold("l'ete", "fr")
    assert fold("Il n'était ni industriel, ni négociant.", "fr") == fold("Ils n'étaient ni industriels, ni négociants.", "fr")
    assert fold("passe-partout", "fr") == fold("passepartout", "fr")
    assert fold("Mr. Bennet paid $5.", "en") == fold("Mister Bennet paid five dollars", "en")


def test_align_matches_reference_edit_distance():
    def lev(a, b):
        d = list(range(len(b) + 1))
        for i, ca in enumerate(a, 1):
            prev, d[0] = d[0], i
            for j, cb in enumerate(b, 1):
                prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (ca != cb))
        return d[-1]
    rng = np.random.default_rng(3)
    for _ in range(50):
        a = "".join(rng.choice(list("abcde"), rng.integers(0, 30)))
        b = "".join(rng.choice(list("abcde"), rng.integers(0, 30)))
        ops = align(a, b)
        assert sum(o != "=" for o, _ in ops) == lev(a, b)


def test_spelling_variants_and_homophones_pass():
    assert not score("Mister Bennet made no answer.", "Mr. Bennett made no answer.", "en").bad
    assert not score("Il n'était ni industriel, ni négociant, ni marchand, ni agriculteur.",
                     "Ils n'étaient ni industriels, ni négociants, ni marchands, ni agriculteurs.", "fr").bad
    assert not score("the experience of three-and-twenty years", "the experience of three and 20 years", "en").bad


def test_dropped_phrase_is_bad():
    exp = "The old man walked to the window and looked at the sea which was grey and calm today."
    s = score(exp, "The old man walked to the window today.", "en")
    assert s.max_deletion_run >= 4 and s.bad


# --- which recogniser checks a language -------------------------------------------------------------------------

def test_the_speech_check_uses_qwen3_for_multilingual_and_whisper_for_english(monkeypatch):
    """Whisper keeps en/fr (the only calibrated languages); Qwen3-ASR takes the other eleven."""
    monkeypatch.delenv("AUDIOBOOK_ASR", raising=False)
    monkeypatch.setattr(verify, "_model_installed", lambda repo: repo == verify.QWEN3_ASR)
    assert verify.Verifier("en").backend == "whisper"
    assert verify.Verifier("fr").backend == "whisper"
    for lang in ("de", "es", "it", "pt", "ru", "zh", "ja", "ko", "hi", "ar", "nl"):
        assert verify.Verifier(lang).backend == "qwen3", lang


def test_a_missing_qwen3_model_falls_back_to_whisper(monkeypatch):
    monkeypatch.delenv("AUDIOBOOK_ASR", raising=False)
    monkeypatch.setattr(verify, "_model_installed", lambda repo: False)
    assert verify.Verifier("de").backend == "whisper"


def test_the_asr_backend_can_be_forced_for_ab(monkeypatch):
    monkeypatch.setenv("AUDIOBOOK_ASR", "qwen3")
    assert verify.Verifier("en").backend == "qwen3"
    monkeypatch.setenv("AUDIOBOOK_ASR", "whisper")
    assert verify.Verifier("de").backend == "whisper"


def test_qwen3_transcribes_the_non_empty_chunks_in_one_call(monkeypatch):
    calls = []

    class FakeASR:
        def generate(self, audio, language=None):
            calls.append({"clips": len(audio) if isinstance(audio, list) else 1, "lang": language})
            if isinstance(audio, list):
                return [types.SimpleNamespace(text=f"heard {i}") for i in range(len(audio))]
            return types.SimpleNamespace(text="heard")

    verifier = verify.Verifier("de", backend="qwen3")
    verifier.model = FakeASR()
    sr = 24000
    audios = [np.ones(sr // 2, np.float32), np.zeros(0, np.float32), np.ones(sr // 3, np.float32)]
    out = verifier.check_many(["eins zwei", "leer", "drei vier"], audios, sr)
    assert calls == [{"clips": 2, "lang": "de"}]
    assert len(out) == 3


def test_hallucinated_tail_is_bad():
    exp = "She closed the door and sat down by the fire to read her letter quietly."
    s = score(exp, exp + " And then the wind began to howl across the empty moors all night long.", "en")
    assert s.max_insertion_run >= 5 and s.bad


def test_garbled_is_bad_and_tiny_chunks_only_fail_grossly():
    assert score("A perfectly ordinary sentence about the weather today.", "Banana purple seventeen horses.", "en").bad
    assert not score("Deux.", "D", "fr").bad          # whisper mishears tiny chunks; not a TTS failure
    assert score("Chapter one.", "", "en").bad          # nothing at all was said


def test_packed_scoring_attributes_errors_to_the_right_chunk():
    texts = ["The first sentence is fine.", "The second one loses most of its words entirely here.", "The third is fine too."]
    heard = "The first sentence is fine. The second one. The third is fine too."
    s = score_packed(texts, heard, "en")
    assert not s[0].bad and s[1].bad and not s[2].bad


def test_resample_to_16k_lengths():
    assert to_16k(np.zeros(24000, np.float32), 24000).size == 16000
    assert to_16k(np.zeros(44100, np.float32), 44100).size == 16000


def test_long_chunk_with_one_dropped_clause_is_caught_by_word_runs():
    exp = ("It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of "
           "foolishness, it was the epoch of belief, it was the epoch of incredulity, it was the season of Light.")
    heard = exp.replace("it was the age of foolishness, ", "")
    s = score(exp, heard, "en")
    assert s.cer < 0.2 and s.max_deletion_run >= 5 and s.bad


def test_text_with_nothing_comparable_gets_no_verdict():
    """A Greek quotation folds to nothing: whatever Whisper hears cannot be compared with it."""
    s = score("Ἐν ἀρχῇ ἦν ὁ λόγος.", "En arche en ho logos", "en")
    assert s.chars == 0 and not s.bad
    assert score("Chapter one.", "", "en").bad  # comparable text with nothing heard is still bad
