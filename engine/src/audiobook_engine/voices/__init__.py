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
import tarfile
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
MAX_DOWNLOAD_BYTES = 20 * 1024 * 1024
MAX_ARCHIVE_STREAM_BYTES = 64 * 1024 * 1024  # how far into a corpus archive we read to reach one member


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


class VoiceProblem(ValueError):
    """A problem with a voice or a clip, worded for the user: the CLI shows the message as it is."""


class VoiceNotFound(KeyError):
    """No installed (or library) voice has this id; worded for the user."""

    def __str__(self) -> str:  # KeyError would quote the message
        return str(self.args[0]) if self.args else "Voice not found."


_VOICE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,99}")


def _check_id(voice_id: str) -> str:
    """Voice ids name files in voices_dir(): never a path ('../x') or a hidden name."""
    if not isinstance(voice_id, str) or not _VOICE_ID.fullmatch(voice_id) or ".." in voice_id:
        raise VoiceProblem(f"Invalid voice id '{voice_id}'.")
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


_SILENCE = "silenceremove=start_periods=1:start_threshold=-45dB:stop_periods=-1:stop_threshold=-45dB:stop_duration=0.6"
SOURCE_S = 60.0  # how much of the user's recording is kept (and read) for clean-up and later reprocessing


def _ffmpeg(args: list[str]) -> None:
    proc = subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", *args], capture_output=True, text=True)
    if proc.returncode != 0:
        detail = proc.stderr.strip().splitlines()[-1:] or ["ffmpeg failed"]
        raise VoiceProblem(f"Could not read this audio clip: {detail[0]}")


def _level(audio: np.ndarray, sr: int, dst: Path) -> float:
    """Check the length, peak-normalise to -3 dBFS and write a 16-bit WAV; returns the duration."""
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    dur = audio.size / sr
    if dur < MIN_CLIP_S:
        raise VoiceProblem(f"Clip too short after trimming silence ({dur:.1f}s); need at least {MIN_CLIP_S:.0f}s of speech.")
    peak = float(np.max(np.abs(audio))) or 1.0
    audio = audio * (10 ** (-3 / 20) / peak)
    sf.write(str(dst), audio, sr, subtype="PCM_16")
    return dur


def _prepare_clip(src: Path, dst: Path, start_s: float | None = None, end_s: float | None = None,
                  isolate: bool = False, enhance: bool = False) -> float:
    """Mono 24 kHz WAV, trimmed silence, at most MAX_CLIP_S, peak-normalised to -3 dBFS.

    `start_s`/`end_s` cut one segment out of a longer recording (a library clip that is a stretch of an
    audiobook chapter); without them the whole file is used. `isolate` / `enhance` clean the user's recording
    first (see `_prepare_cleaned`).
    """
    if isolate or enhance:
        return _prepare_cleaned(src, dst, isolate, enhance)
    tmp = dst.with_suffix(".tmp.wav")
    window = min(MAX_CLIP_S, end_s - start_s) if start_s is not None and end_s is not None else MAX_CLIP_S
    seek = ["-ss", f"{start_s:.3f}"] if start_s else []
    try:
        _ffmpeg([*seek, "-i", str(src), "-ac", "1", "-ar", str(CLIP_SR), "-af", _SILENCE, "-t", f"{window:.3f}", str(tmp)])
        audio, sr = sf.read(str(tmp), dtype="float32")
    finally:
        tmp.unlink(missing_ok=True)
    return _level(audio, sr, dst)


def _prepare_cleaned(src: Path, dst: Path, isolate: bool, enhance: bool) -> float:
    """Clean-up path: the first SOURCE_S at 48 kHz -> isolation -> silence trim and MAX_CLIP_S cap -> enhancer on
    the kept part only (the slow step) -> 24 kHz, -3 dBFS."""
    from . import cleanup

    cleanup.check_installed(isolate, enhance)  # a missing model fails before any work
    work = dst.with_name(f"{dst.stem}.clean")
    work.mkdir(exist_ok=True)
    try:
        raw, trimmed, out = work / "raw.wav", work / "trimmed.wav", work / "out.wav"
        _ffmpeg(["-i", str(src), "-ac", "1", "-ar", str(cleanup.SR), "-t", f"{SOURCE_S:.0f}", str(raw)])
        if isolate:
            audio, _ = sf.read(str(raw), dtype="float32")
            sf.write(str(raw), cleanup.isolate(audio), cleanup.SR, subtype="FLOAT")
        _ffmpeg(["-i", str(raw), "-af", _SILENCE, "-t", f"{MAX_CLIP_S:.3f}", str(trimmed)])
        if enhance:
            audio, _ = sf.read(str(trimmed), dtype="float32")
            if audio.size / cleanup.SR >= MIN_CLIP_S:  # too short: _level below reports it
                sf.write(str(trimmed), cleanup.enhance(audio), cleanup.SR, subtype="FLOAT")
        _ffmpeg(["-i", str(trimmed), "-ar", str(CLIP_SR), str(out)])
        audio, sr = sf.read(str(out), dtype="float32")
        return _level(audio, sr, dst)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def originals_dir() -> Path:
    """The start of each user recording (mono 48 kHz FLAC), kept so the voice can be reprocessed later."""
    p = voices_dir() / "originals"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _keep_source(src: Path, dst: Path) -> None:
    _ffmpeg(["-i", str(src), "-ac", "1", "-ar", "48000", "-t", f"{SOURCE_S:.0f}", "-c:a", "flac", str(dst)])


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


def _fetch(entry: dict, raw: Path) -> None:
    """Save the entry's source audio to `raw`: the file at audio_url, or one member of the archive there.

    An entry with `archive_member` names a file inside a (possibly multi-GB) .tar/.tar.gz corpus archive. The
    archive is streamed, never stored, and reading stops at that member, so the member must sit near its start.
    """
    req = urllib.request.Request(entry["audio_url"], headers={"User-Agent": "AudiobookStudio/0.1"})
    member = entry.get("archive_member")
    limit = MAX_ARCHIVE_STREAM_BYTES if member else MAX_DOWNLOAD_BYTES
    with urllib.request.urlopen(req, timeout=60) as r:
        if not member:
            with open(raw, "wb") as f:
                size = 0
                while chunk := r.read(1 << 16):
                    size += len(chunk)
                    if size > MAX_DOWNLOAD_BYTES:
                        raise VoiceProblem("Download larger than 20 MB; refusing.")
                    f.write(chunk)
            return

        class Capped:  # counts what the archive reader pulls from the network
            n = 0

            def read(self, size=-1):
                data = r.read(size if size and size > 0 else 1 << 16)
                self.n += len(data)
                if self.n > limit:
                    raise VoiceProblem(f"'{member}' is not within the first {limit >> 20} MB of the archive; refusing.")
                return data

        with tarfile.open(fileobj=Capped(), mode="r|*") as tar:
            for info in tar:
                if info.name == member and info.isfile():
                    if info.size > MAX_DOWNLOAD_BYTES:
                        raise VoiceProblem("Download larger than 20 MB; refusing.")
                    src = tar.extractfile(info)
                    assert src is not None
                    raw.write_bytes(src.read())
                    return
    raise VoiceProblem(f"'{member}' was not found in the archive.")


def download(voice_id: str, transcribe: bool = True) -> InstalledVoice:
    entry = next((v for v in library() if v["id"] == voice_id), None)
    if entry is None:
        raise VoiceNotFound(f"There is no library voice '{voice_id}'.")
    _check_id(voice_id)
    work = voices_dir() / f".{voice_id}.download"
    work.mkdir(exist_ok=True)
    try:
        raw = work / "source"
        _fetch(entry, raw)
        digest = hashlib.sha256(raw.read_bytes()).hexdigest()
        if entry.get("source_sha256") and digest != entry["source_sha256"]:
            raise VoiceProblem("The downloaded audio is not the file this library entry was checked against "
                             "(its checksum differs); refusing to install it.")
        staged = work / "clip.wav"
        dur = _prepare_clip(raw, staged, entry.get("start_s"), entry.get("end_s"))
        transcript, source = entry.get("transcript", ""), "published"
        if dur < (entry.get("duration_s") or 0) - 0.5:
            # we trimmed the clip, so the published transcript may no longer match
            transcript, source = "", ""
        if not transcript and transcribe:
            transcript, source = _transcribe(staged, entry["lang"]), "whisper"
        meta = {**{k: entry[k] for k in ("id", "name", "lang", "gender", "description", "license", "commercial_ok",
                                         "attribution", "source_page", "audio_url")},
                "transcript": transcript, "transcript_source": source, "duration_s": round(dur, 2),
                "sha256": digest}
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


def add_user_clip(src: Path, name: str, lang: str, transcript: str | None = None,
                  isolate: bool = False, enhance: bool = False) -> InstalledVoice:
    """Import the user's own clip. The user must have the right to use this voice.

    The start of the recording is kept (`originals_dir()`) so the voice can be reprocessed later with other
    clean-up settings (`replace_user_clip`).
    """
    voice_id = _free_user_id(name)
    staged = voices_dir() / f".{voice_id}.new.wav"
    staged_src = originals_dir() / f".{voice_id}.new.flac"
    try:
        _keep_source(Path(src), staged_src)
        dur = _prepare_clip(Path(src), staged, isolate=isolate, enhance=enhance)
        if transcript:
            source = "user"
        else:
            transcript, source = _transcribe(staged, lang), "whisper"
        meta = {"id": voice_id, "name": name, "lang": lang, "gender": "", "description": "Your own reference clip",
                "license": "user-provided", "commercial_ok": None, "attribution": "", "source_page": "",
                "audio_url": "", "transcript": transcript, "transcript_source": source, "duration_s": round(dur, 2),
                "consent": "User confirmed they have the right to use this voice.",
                "isolate": isolate, "enhance": enhance, "original": f"{voice_id}.flac",
                "original_name": Path(src).name}
        staged_src.replace(_source_path(voice_id))
        return _install(voice_id, staged, meta)
    finally:
        staged.unlink(missing_ok=True)  # moved into place on success; leftovers of a failure go
        staged_src.unlink(missing_ok=True)


def _source_path(voice_id: str) -> Path:
    return originals_dir() / f"{_check_id(voice_id)}.flac"


def replace_user_clip(voice_id: str, src: Path | None = None, isolate: bool | None = None,
                      enhance: bool | None = None, transcript: str | None = None) -> InstalledVoice:
    """Change the recording of one of the user's voices, keeping its id, name, language and settings.

    With `src`: a new recording replaces the old one (transcript: the given one, else Whisper). Without it: the
    kept start of the recording is processed again, e.g. with isolation turned on. The transcript is kept only
    when the prepared clip is about as long as before (clean-up can change where silence is trimmed, and so
    which words the 20 s clip holds); otherwise Whisper transcribes it again. `None` keeps a clean-up setting.
    """
    voice_id = _check_id(voice_id)
    iv = get(voice_id)
    if iv is None:
        raise VoiceNotFound(f"Voice '{voice_id}' is not installed.")
    if not voice_id.startswith("user-"):
        raise VoiceProblem("Only voices you added yourself can change their recording.")
    busy = jobs_using(voice_id)
    if busy:
        title = busy[0].get("title") or "a book"
        raise VoiceInUse(f"This voice is narrating \"{title}\" right now. Stop that conversion or wait for it "
                         "to finish, then change the recording.")
    kept = _source_path(voice_id)
    if src is None and not kept.exists():
        raise VoiceProblem("This voice has no saved original. Choose the recording again.")
    meta = json.loads(_meta_path(voice_id).read_text(encoding="utf-8"))
    isolate = bool(meta.get("isolate", False)) if isolate is None else isolate
    enhance = bool(meta.get("enhance", False)) if enhance is None else enhance
    staged = voices_dir() / f".{voice_id}.new.wav"
    staged_src = originals_dir() / f".{voice_id}.new.flac"
    try:
        if src is not None:
            _keep_source(Path(src), staged_src)
            dur = _prepare_clip(Path(src), staged, isolate=isolate, enhance=enhance)
            meta["original_name"] = Path(src).name
            same_words = False
        else:
            dur = _prepare_clip(kept, staged, isolate=isolate, enhance=enhance)
            same_words = abs(dur - float(meta.get("duration_s") or 0)) <= 0.5
        if transcript:
            meta["transcript"], meta["transcript_source"] = transcript.strip(), "user"
        elif not same_words:
            meta["transcript"], meta["transcript_source"] = _transcribe(staged, iv.lang), "whisper"
        meta.update({"isolate": isolate, "enhance": enhance, "original": kept.name, "duration_s": round(dur, 2)})
        if staged_src.exists():
            staged_src.replace(kept)
        return _install(voice_id, staged, meta)
    finally:
        staged.unlink(missing_ok=True)
        staged_src.unlink(missing_ok=True)


class VoiceInUse(RuntimeError):
    """The voice is narrating a queued or running conversion."""


def jobs_using(voice_id: str) -> list[dict]:
    """Queued or running jobs that clone this voice (their engine reads the clip during the run)."""
    from .. import jobs

    using = []
    for j in jobs.list_jobs():  # a job whose process died is reported as "interrupted", not running
        if j.get("state") not in {"running", "queued"}:
            continue
        argv = [str(a) for a in (j.get("argv") or [])]
        by_flag = any(a == voice_id and i > 0 and argv[i - 1] == "--ref-voice" for i, a in enumerate(argv))
        by_flag = by_flag or f"--ref-voice={voice_id}" in argv
        if by_flag or j.get("voice") == voice_id:
            using.append(j)
    return using


def remove(voice_id: str) -> bool:
    """Delete an installed voice (its prepared clip and metadata). The user's original file is not touched.

    Refuses while a queued or running conversion uses the voice: the engine re-reads the clip
    during the run, so deleting it would break that audiobook.
    """
    voice_id = _check_id(voice_id)
    busy = jobs_using(voice_id)
    if busy:
        title = busy[0].get("title") or "a book"
        raise VoiceInUse(f"This voice is narrating \"{title}\" right now. Stop that conversion or wait for it "
                         "to finish, then delete the voice.")
    found = False
    for p in (voices_dir() / f"{voice_id}.wav", _meta_path(voice_id)):
        if p.exists():
            p.unlink()
            found = True
    (voices_dir() / "originals" / f"{voice_id}.flac").unlink(missing_ok=True)  # our kept copy, not the user's file
    return found


def set_transcript(voice_id: str, text: str) -> InstalledVoice:
    """Correct a clip's transcript (Whisper can mishear names); cloning quality depends on it."""
    mp = _meta_path(voice_id)
    if not mp.exists() or get(voice_id) is None:
        raise VoiceNotFound(f"Voice '{voice_id}' is not installed.")
    meta = json.loads(mp.read_text(encoding="utf-8"))
    meta["transcript"], meta["transcript_source"] = text.strip(), "user"
    tmp = mp.with_name(f".{mp.name}.tmp")
    tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(mp)
    return get(voice_id)  # type: ignore[return-value]
