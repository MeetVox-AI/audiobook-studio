"""The language registry, language-aware CLI validation and the per-language strings used by the pipeline."""

from __future__ import annotations

import numpy as np
import pytest
from typer.testing import CliRunner

from audiobook_engine import benchmark, cli, languages, perf, pipeline
from audiobook_engine.audio.validate import check_chunk
from audiobook_engine.models import Book, Section
from audiobook_engine.pipeline import ConvertOptions

from .test_pipeline import FakeEngine, plain_paragraph, plain_section

ALL = ["en", "fr", "es", "de", "it", "pt", "ru", "zh", "ja", "ko", "hi", "ar", "nl"]


def test_registry_has_the_thirteen_languages_and_every_code_resolves():
    assert sorted(languages.codes()) == sorted(ALL)
    for code in ALL:
        lang = languages.get(code)
        assert lang.code == code and lang.warmup and lang.credits and lang.sec_per_char > 0


@pytest.mark.parametrize("spelling,code", [("pt-BR", "pt"), ("PT_br", "pt"), ("es-MX", "es"), (" FR ", "fr"),
                                           ("zh-CN", "zh"), ("zh_TW", "zh"), ("jp", "ja"), ("en-GB", "en")])
def test_normalize_code_spellings(spelling, code):
    assert languages.normalize_code(spelling) == code


@pytest.mark.parametrize("bad", [None, "", "xx", "klingon", "no"])
def test_normalize_code_unknown_is_none(bad):
    assert languages.normalize_code(bad) is None


@pytest.mark.parametrize("code", ALL)
def test_announce_formats_title_and_author(code):
    text = languages.announce(code, "TITLE", "AUTHOR")
    assert "TITLE" in text and "AUTHOR" in text and "{" not in text


def test_english_and_french_strings_are_unchanged():
    assert languages.announce("en", "T", "A") == "T. By A."
    assert languages.announce("fr", "T", "A") == "T, de A."
    assert languages.get("en").credits == "Opening credits" and languages.get("fr").credits == "Générique"
    assert languages.get("en").warmup == "This is a short warm up sentence."
    assert languages.get("fr").warmup == "Ceci est une courte phrase de préchauffage."


# ----------------------------------------------------------------------------- CLI

def test_lang_option_accepts_registry_codes_and_spellings():
    assert cli._lang_or_raise("pt-BR") == "pt" and cli._lang_or_raise("ZH") == "zh" and cli._lang_or_raise(None) is None


def test_unknown_language_lists_the_supported_codes():
    with pytest.raises(cli.OptionError) as err:
        cli._lang_or_raise("xx")
    for code in ALL:
        assert code in str(err.value)


def test_convert_with_unknown_language_fails_with_the_list(tmp_path):
    book = tmp_path / "b.epub"
    book.write_bytes(b"x")
    res = CliRunner().invoke(cli.app, ["convert", str(book), "--lang", "xx"])
    assert res.exit_code != 0 and "Supported: en, fr" in (res.stdout + res.stderr)


def test_options_normalise_lang():
    o = cli._options("kokoro", None, None, None, "pt-BR", 1.0, None, None, 64, False)
    assert o.lang == "pt"


# ----------------------------------------------------------------------------- benchmark / perf

@pytest.mark.parametrize("code", ALL)
def test_every_language_has_a_benchmark_passage(code):
    text = benchmark.passage(code)
    floor = {"zh": 150, "ja": 150, "ko": 250}.get(code, 400)  # denser scripts need fewer characters
    assert len(text) >= floor


def test_benchmark_falls_back_to_english_and_accepts_spellings():
    assert benchmark.passage("xx") == benchmark.PASSAGES["en"]
    assert benchmark.passage("pt-BR") == benchmark.PASSAGES["pt"]


def test_seconds_per_char_comes_from_the_registry():
    assert perf.seconds_per_char("en") == perf.seconds_per_char("fr") == perf.seconds_per_char(None) == 0.065
    for code in ALL:
        assert perf.seconds_per_char(code) == languages.get(code).sec_per_char
    assert perf.estimate_audio_seconds(1000, "zh", 2.0) == 1000 * languages.get("zh").sec_per_char / 2.0


# ----------------------------------------------------------------------------- pipeline strings

@pytest.fixture
def fake(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIOBOOK_STUDIO_HOME", str(tmp_path / "home"))
    monkeypatch.setattr(pipeline, "keep_awake", lambda: None)
    monkeypatch.setattr(pipeline, "power_source", lambda: None)
    monkeypatch.setattr(pipeline, "normalize_paragraph", plain_paragraph)
    monkeypatch.setattr(pipeline, "normalize_section", plain_section)
    eng = FakeEngine()
    monkeypatch.setattr(pipeline, "get_engine", lambda engine_id: eng)
    return eng


def _book(tmp_path, monkeypatch, lang):
    path = tmp_path / "book.epub"
    path.write_bytes(b"stand-in")
    secs = [Section(0, "Chapter 1", "chapter", ["A calm paragraph that is long enough to be narrated twice over."])]
    book = Book(str(path), "epub", "My Title", "Jane Doe", lang, "metadata", secs)
    monkeypatch.setattr(pipeline, "read_book", lambda p: book)
    return book, path


@pytest.mark.parametrize("code", ALL)
def test_intro_credits_and_warmup_use_the_registry(code, tmp_path, monkeypatch, fake):
    book, path = _book(tmp_path, monkeypatch, code)
    assert pipeline.intro_text(book, code) == languages.announce(code, "My Title", "Jane Doe")
    plans = pipeline.plan_book(book, ConvertOptions(engine="kokoro", lang=code), code, [0])
    assert plans[0].title == languages.get(code).credits
    seen = []
    real = fake.synthesize
    fake.synthesize = lambda texts, *a, **k: (seen.extend(texts), real(texts, *a, **k))[1]
    synth = pipeline.Synthesizer("kokoro", pipeline.VoiceChoice("x"), code, 1.0, lambda e: None)
    synth.ensure_loaded()
    assert seen == [languages.get(code).warmup]


def test_intro_without_author_is_just_the_title():
    book = Book("x", "epub", "Only Title", "Unknown", "de", "metadata", [])
    assert pipeline.intro_text(book, "de") == "Only Title."


def test_resolve_lang_normalises_spellings(tmp_path, monkeypatch):
    book = Book("x", "epub", "T", "A", "en", "metadata", [])
    assert pipeline.resolve_lang(book, ConvertOptions(engine="kokoro", lang="fr")) == "fr"
    with pytest.raises(pipeline.EngineError):
        pipeline.resolve_lang(book, ConvertOptions(engine="kokoro", lang="xx"))


def test_chinese_duration_check_uses_the_language_speed():
    sr = 24000
    tone = (0.1 * np.sin(np.arange(int(13 * sr)) * 0.05)).astype(np.float32)
    assert not any("short" in i for i in check_chunk(tone, sr, 45, 1.0, lang="zh"))
    assert any("short" in i for i in check_chunk(tone[: 2 * sr], sr, 45, 1.0, lang="zh"))


def test_pipeline_passes_the_language_to_the_duration_check(tmp_path, monkeypatch, fake):
    book, path = _book(tmp_path, monkeypatch, "en")
    langs = []
    real = pipeline.check_chunk
    monkeypatch.setattr(pipeline, "check_chunk", lambda *a, **k: (langs.append(k.get("lang")), real(*a, **k))[1])
    pipeline.convert(path, ConvertOptions(engine="kokoro", verify=False), lambda e: None, None)
    assert langs and set(langs) == {"en"}
