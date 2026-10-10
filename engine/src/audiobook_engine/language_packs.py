"""Languages on demand: which languages are switched on, and what each one needs on disk.

Almost nothing is language specific on disk. The voice models are shared (Qwen3-TTS speaks ten languages with
the same 6 GB, Voxtral nine, Kokoro six), so turning a language on downloads only its small reference voices
(a few MB) from the voice library. If none of the engines installed on this Mac can speak the language, the
result says which engine is needed and how large it is; this module never downloads a model by itself.
Turning a language off deletes the library voices it downloaded (never the user's own clips); the shared
models stay, because other languages use them.

State: `languages.json` in the engine home folder. Only English is on by default; every other language,
French included, is added on demand. A Mac that already has voices for another language when this file does
not exist yet (an install from before languages were on demand) keeps those languages on.
"""

from __future__ import annotations

import json
from collections.abc import Callable

from . import languages, paths

DEFAULT_ENABLED = ("en",)
# Preference when several engines could speak a language: best quality and permissive licence first.
_ENGINE_ORDER = ("qwen3", "kokoro", "voxtral", "fish")
_BYTES_PER_SECOND = 48_000  # 24 kHz mono 16-bit: an estimate of a library clip's size from its duration


class LanguageError(ValueError):
    pass


def _state_file():
    return paths.home() / "languages.json"


def enabled() -> list[str]:
    """Codes of the languages that are switched on, in registry order."""
    try:
        data = json.loads(_state_file().read_text(encoding="utf-8"))
        raw = data["enabled"]
        chosen = {c for c in (languages.normalize_code(x) for x in raw) if c}
        if not chosen:
            raise ValueError("empty")
    except Exception:
        chosen = set(DEFAULT_ENABLED) | _languages_with_installed_voices()
        if chosen != set(DEFAULT_ENABLED) and not _state_file().exists():
            _save([c for c in languages.codes() if c in chosen])  # migrate once: they keep what they use
    return [c for c in languages.codes() if c in chosen]


def _save(codes: list[str]) -> None:
    tmp = _state_file().with_suffix(".tmp")
    tmp.write_text(json.dumps({"enabled": codes}, indent=1), encoding="utf-8")
    tmp.replace(_state_file())


def _languages_with_installed_voices() -> set[str]:
    """Languages of the reference voices already on this Mac (library voices or the user's own clips)."""
    try:
        from . import voices

        return {c for c in (languages.normalize_code(v.lang) for v in voices.installed()) if c}
    except Exception:
        return set()


def is_enabled(code: str) -> bool:
    return languages.get(code).code in enabled()


def _engine_rows(code: str) -> list[dict]:
    from . import modelstore
    from .tts import specs

    rows = []
    for spec in specs().values():
        if code not in spec.languages:
            continue
        try:
            installed = bool(modelstore.status(spec.id)["installed"])
        except Exception:
            installed = False
        rows.append({"id": spec.id, "name": spec.name, "installed": installed, "download_gb": spec.download_gb,
                     "noncommercial": spec.noncommercial, "native_presets": any(v.lang == code for v in spec.voices),
                     "cloning": spec.supports_cloning})
    rows.sort(key=lambda r: _ENGINE_ORDER.index(r["id"]) if r["id"] in _ENGINE_ORDER else 99)
    return rows


def _voice_counts(code: str) -> dict:
    from . import voices

    library = [v for v in voices.library() if v.get("lang") == code]
    ids = {v["id"] for v in library}
    got = {v.id: v for v in voices.installed() if v.id in ids}
    missing = [v for v in library if v["id"] not in got]
    return {"available": len(library), "installed": len(got),
            "bytes": sum(v.path.stat().st_size for v in got.values() if v.path.exists()),
            "download_mb": round(sum(float(v.get("duration_s", 10)) for v in missing) * _BYTES_PER_SECOND / 1e6, 1)}


def info(code: str) -> dict:
    lang = languages.get(code)
    engines = _engine_rows(lang.code)
    ready = any(e["installed"] for e in engines)
    recommended = next((e["id"] for e in engines if e["installed"]), engines[0]["id"] if engines else None)
    return {"code": lang.code, "name": lang.name, "native": lang.native, "rtl": lang.rtl,
            "enabled": lang.code in enabled(), "ready": ready, "recommended": recommended,
            "engines": engines, "voices": _voice_counts(lang.code)}


def list_all() -> list[dict]:
    return [info(c) for c in languages.codes()]


def add(code: str, emit: Callable[[dict], None] = lambda _e: None) -> dict:
    """Switch a language on and download its library voices that are not on this Mac yet."""
    from . import voices

    lang = languages.get(code)
    entries = [v for v in voices.library() if v.get("lang") == lang.code]
    have = {v.id for v in voices.installed()}
    errors = []
    for entry in entries:
        if entry["id"] in have:
            continue
        emit({"event": "language_voice", "code": lang.code, "id": entry["id"], "name": entry["name"]})
        try:
            voices.download(entry["id"])
        except Exception as exc:  # network, checksum...: the language still works with the user's own clips
            errors.append({"id": entry["id"], "error": f"{type(exc).__name__}: {exc}"})
    _save(sorted({*enabled(), lang.code}, key=languages.codes().index))
    result = info(lang.code)
    return {"event": "language_done", "code": lang.code, "enabled": True, "ready": result["ready"],
            "needs": None if result["ready"] else result["recommended"], "voice_errors": errors,
            "voices_installed": result["voices"]["installed"]}


def remove(code: str, emit: Callable[[dict], None] = lambda _e: None) -> dict:
    """Switch a language off and delete the library voices it downloaded. Models are shared and stay."""
    from . import voices

    lang = languages.get(code)
    current = enabled()
    if lang.code not in current:
        return {"event": "language_done", "code": lang.code, "enabled": False, "removed_voices": [], "kept_voices": []}
    if current == [lang.code]:
        raise LanguageError("At least one language must stay on.")
    library_ids = {v["id"] for v in voices.library() if v.get("lang") == lang.code}
    removed, kept = [], []
    for v in voices.installed():
        if v.id not in library_ids:
            continue  # the user's own clips are never deleted here
        try:
            if voices.remove(v.id):
                removed.append(v.id)
        except voices.VoiceInUse as exc:
            kept.append({"id": v.id, "reason": str(exc)})
    _save([c for c in current if c != lang.code])
    return {"event": "language_done", "code": lang.code, "enabled": False, "removed_voices": removed,
            "kept_voices": kept}
