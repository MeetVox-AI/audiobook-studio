"""Reference voices for cloning: a curated, licence-checked library plus the user's own clips.

Library clips are downloaded on demand (the only network use besides models),
converted to mono 24 kHz WAV, loudness-levelled, and stored with a transcript.
Clips without a published transcript are transcribed locally with Whisper,
because batched voice cloning (Qwen3 ICL) needs the clip's exact words.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import urllib.request
from dataclasses import dataclass
from importlib import resources
from pathlib import Path

import numpy as np
import soundfile as sf

from .. import paths
from ..audio.m4b import FFMPEG
from ..tts.base import VoiceChoice

CLIP_SR = 24000
MAX_CLIP_S = 20.0
MIN_CLIP_S = 3.0


def voices_dir() -> Path:
    p = paths.home() / "voices"
    p.mkdir(parents=True, exist_ok=True)
    return p


def library() -> list[dict]:
    data = json.loads(resources.files(__package__).joinpath("library.json").read_text(encoding="utf-8"))
    return data["voices"]


@dataclass
class InstalledVoice:
    id: str
    name: str
    lang: str
    path: Path
    transcript: str
    transcript_source: str  # "published", "whisper", "user"
    meta: dict

    def choice(self) -> VoiceChoice:
        return VoiceChoice(ref_audio=str(self.path), ref_text=self.transcript or None)

    def to_json(self) -> dict:
        return {"id": self.id, "name": self.name, "lang": self.lang, "path": str(self.path),
                "transcript": self.transcript, "transcript_source": self.transcript_source, **self.meta}


_VOICE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,99}")


def _check_id(voice_id: str) -> str:
    """Voice ids name files in voices_dir(): never a path ('../x') or a hidden name."""
    if not isinstance(voice_id, str) or not _VOICE_ID.fullmatch(voice_id) or ".." in voice_id:
        raise ValueError(f"Invalid voice id '{voice_id}'.")
    return voice_id


def _meta_path(voice_id: str) -> Path:
    return voices_dir() / f"{_check_id(voice_id)}.json"


def installed() -> list[InstalledVoice]:
    out = []
    for m in sorted(voices_dir().glob("*.json")):
        try:
            info = json.loads(m.read_text(encoding="utf-8"))
            voice_id, name, lang = info["id"], info["name"], info["lang"]
        except Exception:
            continue  # unreadable or incomplete note: skip it rather than break every voice command
        wav = m.with_suffix(".wav")
        if wav.exists():
            out.append(InstalledVoice(voice_id, name, lang, wav, info.get("transcript", ""),
                                      info.get("transcript_source", ""),
                                      {k: v for k, v in info.items() if k not in {"id", "name", "lang", "transcript", "transcript_source"}}))
    return out


def get(voice_id: str) -> InstalledVoice | None:
    return next((v for v in installed() if v.id == voice_id), None)


def _prepare_clip(src: Path, dst: Path) -> float:
    """Mono 24 kHz WAV, trimmed silence, at most MAX_CLIP_S, peak-normalised to -3 dBFS."""
    tmp = dst.with_suffix(".tmp.wav")
    try:
        proc = subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", str(src), "-ac", "1",
                               "-ar", str(CLIP_SR), "-af",
                               "silenceremove=start_periods=1:start_threshold=-45dB:stop_periods=-1:stop_threshold=-45dB:stop_duration=0.6",
                               "-t", str(MAX_CLIP_S), str(tmp)], capture_output=True, text=True)
        if proc.returncode != 0:
            detail = proc.stderr.strip().splitlines()[-1:] or ["ffmpeg failed"]
            raise ValueError(f"Could not read this audio clip: {detail[0]}")
        audio, sr = sf.read(str(tmp), dtype="float32")
    finally:
        tmp.unlink(missing_ok=True)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    dur = audio.size / sr
    if dur < MIN_CLIP_S:
        raise ValueError(f"Clip too short after trimming silence ({dur:.1f}s); need at least {MIN_CLIP_S:.0f}s of speech.")
    peak = float(np.max(np.abs(audio))) or 1.0
    audio = audio * (10 ** (-3 / 20) / peak)
    sf.write(str(dst), audio, sr, subtype="PCM_16")
    return dur


def _transcribe(path: Path, lang: str) -> str:
    from ..qa.verify import Verifier, to_16k

    audio, sr = sf.read(str(path), dtype="float32")
    v = Verifier(lang)
    return v.transcribe(to_16k(audio, sr))


def _install(voice_id: str, staged_wav: Path, meta: dict) -> InstalledVoice:
    """Put a prepared clip and its note in place together (the clip last: it makes the voice visible)."""
    _meta_path(voice_id).write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    staged_wav.replace(voices_dir() / f"{voice_id}.wav")
    return get(voice_id)  # type: ignore[return-value]


def download(voice_id: str, transcribe: bool = True) -> InstalledVoice:
    entry = next((v for v in library() if v["id"] == voice_id), None)
    if entry is None:
        raise KeyError(f"Unknown library voice '{voice_id}'")
    _check_id(voice_id)
    work = voices_dir() / f".{voice_id}.download"
    work.mkdir(exist_ok=True)
    try:
        raw = work / "source"
        req = urllib.request.Request(entry["audio_url"], headers={"User-Agent": "AudiobookStudio/0.1"})
        with urllib.request.urlopen(req, timeout=60) as r, open(raw, "wb") as f:
            size = 0
            while chunk := r.read(1 << 16):
                size += len(chunk)
                if size > 20 * 1024 * 1024:
                    raise ValueError("Download larger than 20 MB; refusing.")
                f.write(chunk)
        staged = work / "clip.wav"
        dur = _prepare_clip(raw, staged)
        transcript, source = entry.get("transcript", ""), "published"
        if dur < (entry.get("duration_s") or 0) - 0.5:
            # we trimmed the clip, so the published transcript may no longer match
            transcript, source = "", ""
        if not transcript and transcribe:
            transcript, source = _transcribe(staged, entry["lang"]), "whisper"
        meta = {**{k: entry[k] for k in ("id", "name", "lang", "gender", "description", "license", "commercial_ok",
                                         "attribution", "source_page", "audio_url")},
                "transcript": transcript, "transcript_source": source, "duration_s": round(dur, 2),
                "sha256": hashlib.sha256(raw.read_bytes()).hexdigest()}
        return _install(voice_id, staged, meta)
    finally:
        shutil.rmtree(work, ignore_errors=True)  # also after a failed or refused download


def _free_user_id(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:40] or "voice"
    base = f"user-{slug}"
    taken = lambda v: _meta_path(v).exists() or (voices_dir() / f"{v}.wav").exists()  # noqa: E731
    voice_id, n = base, 1
    while taken(voice_id):  # never replace a clip the user added earlier under the same name
        n += 1
        voice_id = f"{base}-{n}"
    return voice_id


def add_user_clip(src: Path, name: str, lang: str, transcript: str | None = None) -> InstalledVoice:
    """Import the user's own clip. The user must have the right to use this voice."""
    voice_id = _free_user_id(name)
    staged = voices_dir() / f".{voice_id}.new.wav"
    try:
        dur = _prepare_clip(Path(src), staged)
        if transcript:
            source = "user"
        else:
            transcript, source = _transcribe(staged, lang), "whisper"
        meta = {"id": voice_id, "name": name, "lang": lang, "gender": "", "description": "Your own reference clip",
                "license": "user-provided", "commercial_ok": None, "attribution": "", "source_page": "",
                "audio_url": "", "transcript": transcript, "transcript_source": source, "duration_s": round(dur, 2),
                "consent": "User confirmed they have the right to use this voice."}
        return _install(voice_id, staged, meta)
    finally:
        staged.unlink(missing_ok=True)  # moved into place on success; leftovers of a failure go


def remove(voice_id: str) -> bool:
    found = False
    for p in (voices_dir() / f"{_check_id(voice_id)}.wav", _meta_path(voice_id)):
        if p.exists():
            p.unlink()
            found = True
    return found


def set_transcript(voice_id: str, text: str) -> InstalledVoice:
    """Correct a clip's transcript (Whisper can mishear names); cloning quality depends on it."""
    mp = _meta_path(voice_id)
    if not mp.exists() or get(voice_id) is None:
        raise KeyError(f"Voice '{voice_id}' is not installed")
    meta = json.loads(mp.read_text(encoding="utf-8"))
    meta["transcript"], meta["transcript_source"] = text.strip(), "user"
    tmp = mp.with_name(f".{mp.name}.tmp")
    tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(mp)
    return get(voice_id)  # type: ignore[return-value]
