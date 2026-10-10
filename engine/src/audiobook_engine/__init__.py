"""Audiobook Studio engine.

Privacy: the engine sends no telemetry of its own, and the libraries it uses are told not to either. The only
network use is an explicit download (models, reference voices, the installer); see PRIVACY.md.
"""

import os

# What this engine can do, as one number the app compares with the minimum it needs (AppModel.requiredEngineAPI).
# Raise it whenever the app starts using a new command or option, so an older engine is spotted and updated.
#   1: before this number existed (engines that do not report it)
#   2: voice clean-up (voices add --isolate/--enhance, models voice-isolation/voice-enhancer) and voices replace
API_VERSION = 2

# Hugging Face's download library sends anonymous usage information unless told otherwise; DO_NOT_TRACK is the
# cross-tool convention. setdefault: a person who set these on purpose keeps their choice.
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("DO_NOT_TRACK", "1")


def hello() -> str:
    return "Hello from audiobook-engine!"
