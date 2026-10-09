"""Engine registry. Engines are imported lazily: loading MLX models is expensive."""

from __future__ import annotations

from .base import EngineError, EngineSpec, TTSEngine, Voice, VoiceChoice, check_preset, default_preset


def specs() -> dict[str, EngineSpec]:
    from . import fish, kokoro, qwen3, voxtral

    return {s.id: s for s in (qwen3.SPEC, voxtral.SPEC, fish.SPEC, kokoro.SPEC)}


def get_engine(engine_id: str) -> TTSEngine:
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
    raise EngineError(f"Unknown engine '{engine_id}'. Available: {', '.join(specs())}")


__all__ = ["EngineError", "EngineSpec", "TTSEngine", "Voice", "VoiceChoice", "check_preset", "default_preset",
           "get_engine", "specs"]
