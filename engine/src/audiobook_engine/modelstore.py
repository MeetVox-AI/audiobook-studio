"""Install, inspect and remove local model files (Hugging Face cache).

Downloads happen only here, never during a conversion: conversions run with
HF_HUB_OFFLINE=1 so a missing file is an explicit error, not a silent download.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .tts import specs


@dataclass
class Asset:
    repo: str
    patterns: list[str] | None   # None = whole repository
    purpose: str


QA_ID = "whisper"  # speech-to-text model used for quality checks and transcribing reference clips


def all_ids() -> list[str]:
    return [*specs(), QA_ID]


def assets(engine_id: str) -> list[Asset]:
    if engine_id == QA_ID:
        from .qa.verify import WHISPER

        return [Asset(WHISPER, None, "speech-to-text for quality checks")]
    spec = specs()[engine_id]
    if engine_id == "kokoro":
        return [Asset(spec.checkpoint, ["*.json", "*.safetensors", "voices/*.safetensors"], "model + 54 voices")]
    if engine_id == "qwen3":
        from .tts.qwen3 import BASE, CUSTOM

        return [Asset(CUSTOM, None, "preset voices (CustomVoice)"), Asset(BASE, None, "voice cloning (Base)")]
    return [Asset(spec.checkpoint, None, "model")]


def _local_dir(asset: Asset) -> Path | None:
    from huggingface_hub import snapshot_download

    try:
        return Path(snapshot_download(asset.repo, allow_patterns=asset.patterns, local_files_only=True))
    except Exception:
        return None


def _size(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def status(engine_id: str) -> dict:
    if engine_id == QA_ID:
        a = assets(QA_ID)[0]
        d = _local_dir(a)
        return {"engine": QA_ID, "name": "Whisper large-v3-turbo (quality checks)", "installed": d is not None,
                "download_gb": 1.6, "license": "MIT", "noncommercial": False,
                "parts": [{"repo": a.repo, "purpose": a.purpose, "installed": d is not None,
                           "bytes": _size(d) if d else 0, "path": str(d) if d else None}]}
    spec = specs()[engine_id]
    parts = []
    for a in assets(engine_id):
        d = _local_dir(a)
        parts.append({"repo": a.repo, "purpose": a.purpose, "installed": d is not None,
                      "bytes": _size(d) if d else 0, "path": str(d) if d else None})
    installed = all(p["installed"] for p in parts)
    if installed and engine_id == "kokoro":
        voices_dir = Path(parts[0]["path"]) / "voices"
        missing = [v.id for v in spec.voices if not (voices_dir / f"{v.id}.safetensors").exists()]
        if missing:
            installed = False
            parts[0]["missing_voices"] = missing
    return {"engine": engine_id, "name": spec.name, "installed": installed, "download_gb": spec.download_gb,
            "license": spec.license, "noncommercial": spec.noncommercial, "parts": parts}


def download(engine_id: str, progress=None) -> dict:
    from huggingface_hub import snapshot_download

    for a in assets(engine_id):
        if progress:
            progress({"event": "download_start", "repo": a.repo, "purpose": a.purpose})
        snapshot_download(a.repo, allow_patterns=a.patterns)
        if progress:
            progress({"event": "download_done", "repo": a.repo})
    return status(engine_id)


def removal_plan(engine_id: str):
    """huggingface_hub >= 2 keeps file contents in a shared blob store; deleting a repo folder alone frees
    nothing. Its own delete strategy also sweeps the shared blobs, so always go through it."""
    from huggingface_hub import CacheNotFound, scan_cache_dir

    try:
        cache = scan_cache_dir()
    except CacheNotFound:
        return None  # no Hugging Face cache at all: nothing is installed, nothing to remove
    repos = {a.repo for a in assets(engine_id)}
    hashes = [rev.commit_hash for repo in cache.repos if repo.repo_id in repos for rev in repo.revisions]
    return cache.delete_revisions(*hashes) if hashes else None


def remove(engine_id: str, dry_run: bool = False) -> dict:
    plan = removal_plan(engine_id)
    if plan is None:
        return {"engine": engine_id, "freed_bytes": 0, "removed": False}
    expected = plan.expected_freed_size
    if not dry_run:
        plan.execute()
    return {"engine": engine_id, "freed_bytes": expected, "removed": not dry_run, "installed": status(engine_id)["installed"]}
