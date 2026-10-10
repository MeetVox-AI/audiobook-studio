"""The engine's API version, which the app reads to know whether the engine needs an update."""

from __future__ import annotations

import json
import re
from pathlib import Path

from audiobook_engine import API_VERSION


def test_engines_reports_the_api_version(capsys):
    from audiobook_engine import cli

    assert cli.run_cli(["engines"]) == 0
    out = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert out["api"] == API_VERSION


def test_the_app_never_needs_a_newer_engine_than_this_one():
    """The app's minimum must not exceed what the engine in the same commit provides, or every user would be told
    to update to an engine that does not exist yet."""
    swift = Path(__file__).resolve().parents[2] / "app/Sources/AudiobookStudio/State/AppModel+EngineUpdate.swift"
    m = re.search(r"static let requiredEngineAPI = (\d+)", swift.read_text(encoding="utf-8"))
    assert m, "requiredEngineAPI not found"
    assert int(m.group(1)) <= API_VERSION
