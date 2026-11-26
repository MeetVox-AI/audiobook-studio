"""Engine registry. Engines are imported lazily: loading MLX models is expensive."""

from __future__ import annotations

from .base import EngineError, EngineSpec, TTSEngine, Voice, VoiceChoice, check_preset, default_preset


def specs() -> dict[str, EngineSpec]:
    from . import fish, kokoro, qwen3, voxtral, voxcpm2, zonos3

    # Order is the app's preference when several engines are installed: ZONOS3 first (the default narrator),
    # Kokoro next (fast drafts), then the heavy and non-commercial ones, with VoxCPM2 last: it has no presets,
    # so it is an explicit "studio" pick, never an automatic fallback.
    return {s.id: s for s in (zonos3.SPEC, kokoro.SPEC, qwen3.SPEC, voxtral.SPEC, fish.SPEC, voxcpm2.SPEC)}


def get_engine(engine_id: str) -> TTSEngine:
    if engine_id == "zonos3":
        from .zonos3 import Zonos3Engine

        return Zonos3Engine()
    if engine_id == "kokoro":
        from .kokoro import KokoroEngine

        return KokoroEngine()
    if engine_id == "qwen3":
        from .qwen3 import Qwen3Engine

        return Qwen3Engine()
    if engine_id == "voxtral":
        from .voxtral import VoxtralEngine

        return VoxtralEngine()
    if engine_id == "fish":
        from .fish import FishEngine

        return FishEngine()
    if engine_id == "voxcpm2":
        from .voxcpm2 import VoxCPM2Engine

        return VoxCPM2Engine()
    raise EngineError(f"Unknown engine '{engine_id}'. Available: {', '.join(specs())}")


__all__ = ["EngineError", "EngineSpec", "TTSEngine", "Voice", "VoiceChoice", "check_preset", "default_preset",
           "get_engine", "specs"]
