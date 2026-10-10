"""Audiobook Studio engine.

Privacy: the engine sends no telemetry of its own, and the libraries it uses are told not to either. The only
network use is an explicit download (models, reference voices, the installer); see PRIVACY.md.
"""

import os

# Hugging Face's download library sends anonymous usage information unless told otherwise; DO_NOT_TRACK is the
# cross-tool convention. setdefault: a person who set these on purpose keeps their choice.
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("DO_NOT_TRACK", "1")


def hello() -> str:
    return "Hello from audiobook-engine!"
