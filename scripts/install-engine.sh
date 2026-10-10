#!/bin/bash
# Installs the Audiobook Studio engine (the local AI narration engine the app drives) for people who
# downloaded the app from the DMG. It lives in ~/Library/Application Support/AudiobookStudio/source.
#   curl -fsSL https://raw.githubusercontent.com/antoine-debroye/audiobook-converter/main/scripts/install-engine.sh | bash
# Environment (for testing): AUDIOBOOK_PREFIX (install folder), AUDIOBOOK_REPO (git URL or path), NO_MODELS=1.
set -euo pipefail
# The app runs this with a minimal PATH: make Homebrew's folders visible, and keep brew quiet and non-interactive.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 NONINTERACTIVE=1 \
  HOMEBREW_NO_ANALYTICS=1 HF_HUB_DISABLE_TELEMETRY=1 DO_NOT_TRACK=1

PREFIX="${AUDIOBOOK_PREFIX:-$HOME/Library/Application Support/AudiobookStudio}"
REPO="${AUDIOBOOK_REPO:-https://github.com/antoine-debroye/audiobook-converter.git}"
SRC="$PREFIX/source"
MIN_FREE_GB=12

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || die "Audiobook Studio needs a Mac with Apple Silicon (M1 or later)."
command -v git >/dev/null || die "git is missing. Run: xcode-select --install"
command -v brew >/dev/null || die "Homebrew is missing. Install it from https://brew.sh, then run this again."

free=$(df -g "$HOME" | awk 'NR==2 {print $4}')
[[ "${NO_MODELS:-}" == "1" || "$free" -ge "$MIN_FREE_GB" ]] || die "Only ${free} GB free; the voice models need about ${MIN_FREE_GB} GB."

say "Installing tools (uv, ffmpeg, espeak-ng) if missing"
for tool in uv ffmpeg espeak-ng; do
  command -v "$tool" >/dev/null || brew install "$tool"
done

say "Getting the engine into $SRC"
mkdir -p "$PREFIX"
if [[ -d "$SRC/.git" ]]; then git -C "$SRC" pull --ff-only; else git clone --depth 1 "$REPO" "$SRC"; fi

say "Setting up the Python environment"
(cd "$SRC/engine" && uv sync)

CLI="$SRC/engine/.venv/bin/audiobook-engine"
if [[ "${NO_MODELS:-}" != "1" ]]; then
  say "Downloading the voice models (several GB, once)"
  for m in kokoro qwen3 whisper; do "$CLI" models download "$m"; done
  say "Downloading the reference voices"
  for v in fr_siwis_female_book fr_cmltts_7142_male en_librittsr_laura_caldwell_female_us en_librittsr_bill_boerst_male_us; do
    "$CLI" voices download "$v"
  done
fi

say "Done. Open Audiobook Studio."
echo "Engine: $CLI"
