import pytest

from audiobook_engine import language_packs, languages, paths, voices


@pytest.fixture(autouse=True)
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIOBOOK_STUDIO_HOME", str(tmp_path))
    monkeypatch.setattr("audiobook_engine.modelstore.status", lambda e: {"installed": e == "qwen3"})
    return tmp_path


FAKE_LIBRARY = [
    {"id": "es_test_f", "name": "Es F", "lang": "es", "duration_s": 10},
    {"id": "es_test_m", "name": "Es M", "lang": "es", "duration_s": 12},
    {"id": "fr_test", "name": "Fr", "lang": "fr", "duration_s": 10},
]


def fake_installed(tmp_path, ids, monkeypatch):
    class V:
        def __init__(self, i, path):
            self.id, self.path = i, path

    items = []
    for i in ids:
        p = tmp_path / f"{i}.wav"
        p.write_bytes(b"x" * 1000)
        items.append(V(i, p))
    monkeypatch.setattr(voices, "installed", lambda: items)


def test_default_is_english_and_french_only():
    assert language_packs.enabled() == ["en", "fr"]
    assert not language_packs.is_enabled("es")


def test_info_reports_engines_and_readiness():
    es = language_packs.info("es")
    assert es["ready"] and es["recommended"] == "qwen3" and not es["enabled"]
    assert {e["id"] for e in es["engines"]} >= {"qwen3", "voxtral", "kokoro"}
    hi = language_packs.info("hi")          # only Voxtral and Kokoro speak Hindi; neither is installed here
    assert not hi["ready"] and hi["recommended"] == "kokoro"
    assert language_packs.info("zh")["engines"][0]["native_presets"]


def test_add_downloads_missing_voices_enables_and_is_idempotent(monkeypatch, tmp_path):
    monkeypatch.setattr(voices, "library", lambda: FAKE_LIBRARY)
    fake_installed(tmp_path, [], monkeypatch)
    got = []
    monkeypatch.setattr(voices, "download", lambda i: got.append(i))
    res = language_packs.add("es")
    assert got == ["es_test_f", "es_test_m"] and res["enabled"] and res["ready"] and res["needs"] is None
    assert language_packs.enabled() == ["en", "fr", "es"]
    fake_installed(tmp_path, ["es_test_f", "es_test_m"], monkeypatch)
    got.clear()
    language_packs.add("es")
    assert got == []                         # nothing left to download
    assert language_packs.enabled() == ["en", "fr", "es"]


def test_add_reports_the_engine_needed_and_never_downloads_a_model(monkeypatch, tmp_path):
    monkeypatch.setattr(voices, "library", lambda: [])
    fake_installed(tmp_path, [], monkeypatch)
    res = language_packs.add("hi")
    assert res["enabled"] and not res["ready"] and res["needs"] == "kokoro"


def test_voice_download_failure_is_reported_but_language_is_on(monkeypatch, tmp_path):
    monkeypatch.setattr(voices, "library", lambda: FAKE_LIBRARY)
    fake_installed(tmp_path, [], monkeypatch)

    def boom(i):
        raise OSError("no network")

    monkeypatch.setattr(voices, "download", boom)
    res = language_packs.add("es")
    assert res["enabled"] and len(res["voice_errors"]) == 2 and "no network" in res["voice_errors"][0]["error"]


def test_remove_deletes_library_voices_only_and_keeps_models(monkeypatch, tmp_path):
    monkeypatch.setattr(voices, "library", lambda: FAKE_LIBRARY)
    fake_installed(tmp_path, ["es_test_f", "my_own_spanish_clip"], monkeypatch)
    removed = []
    monkeypatch.setattr(voices, "remove", lambda i: removed.append(i) or True)
    language_packs._save(["en", "fr", "es"])
    res = language_packs.remove("es")
    assert removed == ["es_test_f"] and res["removed_voices"] == ["es_test_f"]
    assert language_packs.enabled() == ["en", "fr"]


def test_remove_keeps_a_voice_that_is_narrating(monkeypatch, tmp_path):
    monkeypatch.setattr(voices, "library", lambda: FAKE_LIBRARY)
    fake_installed(tmp_path, ["es_test_f"], monkeypatch)

    def busy(i):
        raise voices.VoiceInUse("narrating")

    monkeypatch.setattr(voices, "remove", busy)
    language_packs._save(["en", "es"])
    res = language_packs.remove("es")
    assert res["kept_voices"][0]["id"] == "es_test_f" and not language_packs.is_enabled("es")


def test_the_last_language_cannot_be_removed():
    language_packs._save(["en"])
    with pytest.raises(language_packs.LanguageError):
        language_packs.remove("en")


def test_a_corrupt_state_file_falls_back_to_the_defaults(tmp_path):
    (tmp_path / "languages.json").write_text("not json")
    assert language_packs.enabled() == ["en", "fr"]
    assert languages.codes()[:2] == ["en", "fr"]
    assert paths.home() == tmp_path


def test_cli_languages_list_add_remove(monkeypatch, capsys, tmp_path):
    import json

    from audiobook_engine import cli

    def last():
        return json.loads(capsys.readouterr().out.strip().splitlines()[-1])

    monkeypatch.setattr(voices, "library", lambda: [])
    monkeypatch.setattr(voices, "installed", lambda: [])
    assert cli.run_cli(["languages", "list"]) == 0
    got = last()["languages"]
    assert [x["code"] for x in got] == languages.codes() and [x["code"] for x in got if x["enabled"]] == ["en", "fr"]
    assert cli.run_cli(["languages", "add", "pt-BR"]) == 0
    assert last()["code"] == "pt" and language_packs.is_enabled("pt")
    assert cli.run_cli(["languages", "remove", "pt"]) == 0
    assert not language_packs.is_enabled("pt")
    assert cli.run_cli(["languages", "add", "xx"]) == 2 and "Unsupported language" in last()["message"]
    language_packs._save(["en"])
    assert cli.run_cli(["languages", "remove", "en"]) == 1 and "At least one language" in last()["message"]
