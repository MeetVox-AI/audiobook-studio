# Contributing to Audiobook Studio

Thanks for helping. This repository ships two programs that work together:

- **`engine/`** — a Python CLI that turns an EPUB or PDF into a narrated `.m4b`. It prints one JSON object per
  line on stdout, so the app can follow a conversion live.
- **`app/`** — a native SwiftUI front end (macOS 26+) that runs the engine as a subprocess and draws the
  Book, Voices, Jobs and Settings screens.

Everything runs on the Mac. Please keep it that way: no change may upload a book, a voice clip or audio anywhere.

## Where to start

| You want to change… | Start in |
|---|---|
| How a book is parsed (chapters, front matter, PDF outlines) | `engine/src/audiobook_engine/ingest/` |
| Numbers, abbreviations, punctuation, sentence splitting | `engine/src/audiobook_engine/textproc/` |
| A narration engine or voice handling | `engine/src/audiobook_engine/tts/` |
| Loudness, stitching, chapters, the `.m4b` itself | `engine/src/audiobook_engine/audio/` |
| The speech check (Whisper) | `engine/src/audiobook_engine/qa/` |
| Screens, design tokens, window behaviour | `app/Sources/AudiobookStudio/` |
| App state and engine calls | `app/Sources/AudiobookStudio/State/` |

## Setting up

Requirements: an Apple Silicon Mac, macOS 26 or later, Xcode 26 (Swift 6.2 or newer), Homebrew and `uv`.

```bash
git clone https://github.com/MeetVox-AI/audiobook-studio.git
cd audiobook-studio
make engine        # creates engine/.venv (no models)
make app           # builds app/build/AudiobookStudio.app
```

`make setup` also downloads the ~12 GB of models and reference voices. You only need that to actually convert a
book; the tests fake the models.

## Running the tests

```bash
make test                      # engine lint + engine tests + app tests
cd engine && uv run pytest -q  # engine only (about a minute)
cd app && swift test           # app only
```

Notes on the engine tests:

- They do **not** download or load model weights, and they do not need a GPU. Tests that use real weights skip
  themselves unless you have downloaded those models and the Mac has a Metal device.
- The audio tests render real `.m4b` files, so they need `ffmpeg` (`brew install ffmpeg`).
- To check the real app end to end on one of your books: `make app-check BOOK=path/to/book.epub`. It drives the
  bundled app with the engine and writes screenshots and a report to `app/build/check/`.

CI (`.github/workflows/ci.yml`) runs the same commands on macOS. A pull request should be green before review.

## Conventions

**The engine/app contract.** The app parses the engine's JSON. When you add a command, option, event or field
that the app reads:

1. Bump `API_VERSION` in `engine/src/audiobook_engine/__init__.py`, with a one-line comment saying what changed.
   An older engine that does not know the new thing is then spotted and updated instead of misbehaving.
2. Raise `AppModel.requiredEngineAPI` in `app/Sources/AudiobookStudio/State/AppModel+EngineUpdate.swift` only
   when the app starts *needing* it. A test fails if the app ever requires more than the engine in the same commit
   provides.
3. Add the real engine output as a fixture in `app/Tests/AudiobookStudioTests/Fixtures/` so decoding stays tested.

**Text and languages.** Numbers, dates, currency, abbreviations and sentence splitting are per language. When you
touch them, add a case to the matching test in `engine/tests/test_normalize_languages.py`,
`test_segment_languages.py` or `test_qa_languages.py` — for every language you change.

**The interface.** Follow `app/DESIGN.md` (tokens, the two layers, glass only on floating controls, the 8-point
grid) and `app/SPEC.md` (what each screen does). Every control keeps an accessibility label, contrast holds in
light and dark mode, and nothing relies on hover alone.

**Privacy.** `engine/tests/test_privacy_policy.py` checks the policy and the telemetry opt-outs. New network use
must be an explicit download (a model, a voice, an update) and must be described in `PRIVACY.md`.

**Voices.** Reference clips must be licence-checked and credited. Never add a voice clip without a source and a
licence in `engine/src/audiobook_engine/voices/library.json`.

## Pull requests

- Keep a pull request to one change; small ones are reviewed and merged faster.
- Include tests for behaviour changes, and note the commands you ran.
- User-visible changes get a line in the next release note under `docs/release-notes/`.
- UI changes: attach a screenshot in light and dark mode.
- Do not bump the version or publish a release in a feature pull request; that is done with `scripts/release.sh`.

## Reporting bugs

Please include your Mac model and macOS version, the engine and voice you used, what you expected, and what
happened. If a conversion failed, the engine's last JSON line (or the error text shown in the app) is the most
useful thing you can paste. A short book or page range that reproduces it helps a lot.
