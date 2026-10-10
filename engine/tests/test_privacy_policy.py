"""The privacy policy (PRIVACY.md) must name every host the engine can contact, and say what it must say."""

import json
import re
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
POLICY = (ROOT / "PRIVACY.md").read_text(encoding="utf-8")


def test_every_voice_download_host_is_named_in_the_policy():
    library = json.loads((ROOT / "engine/src/audiobook_engine/voices/library.json").read_text(encoding="utf-8"))
    hosts = {urllib.parse.urlparse(v["audio_url"]).netloc for v in library["voices"]}
    assert hosts, "no voice hosts found"
    for host in hosts:
        assert host in POLICY, f"{host} is downloaded from but not named in PRIVACY.md"


def test_every_url_in_the_project_files_is_covered_by_the_policy():
    covered = {"github.com", "raw.githubusercontent.com", "huggingface.co", "archive.org", "pypi.org",
               "files.pythonhosted.org", "brew.sh", "ghcr.io"}
    for rel in ("engine/pyproject.toml", "scripts/install-engine.sh", "app/Sources/AudiobookStudio/Support/EngineInstaller.swift"):
        text = (ROOT / rel).read_text(encoding="utf-8")
        for host in {urllib.parse.urlparse(u).netloc for u in re.findall(r"https?://[A-Za-z0-9.-]+[A-Za-z0-9]", text)}:
            assert host in covered or host.endswith(".githubusercontent.com") or host == "docs.brew.sh", \
                f"{rel} contacts {host}: add it to PRIVACY.md and to this list"


def test_the_policy_makes_the_promises_the_app_keeps():
    for phrase in ("We collect nothing", "no telemetry", "Narration works offline", "HF_HUB_DISABLE_TELEMETRY",
                   "not liable", "Version 2"):
        assert phrase.lower() in POLICY.lower(), phrase
    assert "GitHub" in POLICY and "Hugging Face" in POLICY and "Internet Archive" in POLICY


def test_the_app_ships_with_telemetry_off_settings():
    bundle = (ROOT / "app/scripts/bundle.sh").read_text(encoding="utf-8")
    assert "SUSendProfileInfo" in bundle
    installer = (ROOT / "scripts/install-engine.sh").read_text(encoding="utf-8")
    assert "HOMEBREW_NO_ANALYTICS=1" in installer and "HF_HUB_DISABLE_TELEMETRY=1" in installer
