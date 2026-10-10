"""Finding ffmpeg when the app is launched from Finder (minimal PATH without Homebrew)."""

from __future__ import annotations

import os
import stat

import pytest

from audiobook_engine import tools


def fake_tool(folder, name):
    p = folder / name
    p.write_text("#!/bin/sh\nexit 0\n")
    p.chmod(p.stat().st_mode | stat.S_IXUSR)
    return p


def test_found_on_path(tmp_path, monkeypatch):
    fake_tool(tmp_path, "ffmpeg")
    monkeypatch.setenv("PATH", str(tmp_path))
    monkeypatch.delenv("AUDIOBOOK_FFMPEG", raising=False)
    assert tools.find_tool("ffmpeg") == str(tmp_path / "ffmpeg")


def test_found_in_homebrew_dir_when_path_is_minimal(tmp_path, monkeypatch):
    brew = tmp_path / "brew"
    brew.mkdir()
    fake_tool(brew, "ffmpeg")
    monkeypatch.setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")  # what Finder gives an app
    monkeypatch.delenv("AUDIOBOOK_FFMPEG", raising=False)
    monkeypatch.setattr(tools, "FALLBACK_DIRS", (str(tmp_path / "missing"), str(brew)))
    assert tools.find_tool("ffmpeg") == str(brew / "ffmpeg")


def test_env_override_wins_and_must_be_executable(tmp_path, monkeypatch):
    p = fake_tool(tmp_path, "my-ffmpeg")
    monkeypatch.setenv("AUDIOBOOK_FFMPEG", str(p))
    assert tools.find_tool("ffmpeg") == str(p)
    monkeypatch.setenv("AUDIOBOOK_FFMPEG", str(tmp_path / "nope"))
    assert tools.find_tool("ffmpeg") is None


def test_missing_tool_message(tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", str(tmp_path))
    monkeypatch.delenv("AUDIOBOOK_FFMPEG", raising=False)
    monkeypatch.setattr(tools, "FALLBACK_DIRS", ())
    assert tools.find_tool("ffmpeg") is None
    with pytest.raises(tools.ToolMissing, match="brew install ffmpeg"):
        tools.require_tool("ffmpeg")


def test_real_homebrew_ffmpeg_is_found_with_finder_path(monkeypatch):
    if not os.path.exists("/opt/homebrew/bin/ffmpeg"):
        pytest.skip("Homebrew ffmpeg not installed here")
    monkeypatch.setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    monkeypatch.delenv("AUDIOBOOK_FFMPEG", raising=False)
    assert tools.find_tool("ffmpeg") == "/opt/homebrew/bin/ffmpeg"
