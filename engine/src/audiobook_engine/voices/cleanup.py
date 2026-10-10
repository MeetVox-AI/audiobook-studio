"""Optional clean-up of a reference clip before it is used for cloning ("Add My Voice").

- isolation: DeepFilterNet3 (MIT) removes background noise and music and keeps the voice;
- enhancer: MossFormer2-SE 48 kHz (Apache-2.0) restores speech clarity.

Both run through mlx-audio at 48 kHz on mono float audio in [-1, 1] and return audio of the same length. The
weights are read from the local Hugging Face cache only: `voices add` is not run offline, and the libraries'
`from_pretrained` would otherwise download silently. `models download voice-isolation` / `voice-enhancer`
installs them (the app does that first, saying so).
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from .. import modelstore

SR = 48000

_MISSING = {
    modelstore.ISOLATION_ID: "Voice isolation needs DeepFilterNet3 (8.7 MB). Download it in Models.",
    modelstore.ENHANCER_ID: "The voice enhancer needs MossFormer2-SE (111 MB). Download it in Models.",
}
_loaded: dict[str, object] = {}


class CleanupModelMissing(RuntimeError):
    """A clean-up model is not downloaded (the message says which and how to get it)."""


def _local(model_id: str) -> Path:
    d = modelstore._local_dir(modelstore.assets(model_id)[0])
    if d is None:
        raise CleanupModelMissing(_MISSING[model_id])
    return d


def _model(model_id: str):
    if model_id not in _loaded:
        d = _local(model_id)
        if model_id == modelstore.ISOLATION_ID:
            from mlx_audio.sts.models.deepfilternet import DeepFilterNetModel

            _loaded[model_id] = DeepFilterNetModel.from_pretrained(str(d), subfolder="v3")
        else:
            from mlx_audio.sts.models.mossformer2_se import MossFormer2SEModel

            _loaded[model_id] = MossFormer2SEModel.from_pretrained(str(d))
    return _loaded[model_id]


def _fit(out: np.ndarray, n: int) -> np.ndarray:
    out = np.asarray(out, dtype=np.float32).reshape(-1)[:n]
    if out.size < n:
        out = np.pad(out, (0, n - out.size))
    return np.clip(out, -1.0, 1.0)


def isolate(audio: np.ndarray) -> np.ndarray:
    """Keep the voice, drop background noise and music (mono 48 kHz in and out)."""
    return _fit(_model(modelstore.ISOLATION_ID).enhance_array(audio.astype(np.float32)), audio.size)


def enhance(audio: np.ndarray) -> np.ndarray:
    """Restore speech clarity (mono 48 kHz in and out)."""
    return _fit(_model(modelstore.ENHANCER_ID).enhance(audio.astype(np.float32)), audio.size)


def check_installed(isolation: bool, enhancer: bool) -> None:
    """Raise CleanupModelMissing before any work when a requested model is not downloaded."""
    for wanted, model_id in ((isolation, modelstore.ISOLATION_ID), (enhancer, modelstore.ENHANCER_ID)):
        if wanted:
            _local(model_id)
