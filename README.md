# Audiobook Studio

Turn EPUB and PDF books into M4B audiobooks on your Mac, narrated by AI voices that run entirely on your machine.
Chapters, cover art and metadata are kept. Nothing is sent to the cloud: models are downloaded once, then every
conversion runs offline on the Apple Silicon GPU (MLX).

Two parts, one simple bridge:

```
AudiobookStudio.app (SwiftUI)  ──runs──▶  audiobook-engine (Python CLI, JSON lines on stdout)
                                          ├─ ingest: EPUB (TOC-anchored chapters) / PDF (outline, headings)
                                          ├─ text: en/fr normalisation (numbers, dates, currency, abbreviations)
                                          ├─ TTS: Kokoro · Qwen3-TTS · Voxtral · Fish S2 Pro (mlx-audio)
                                          ├─ QA: Whisper speech check, regenerates mismatched sentences
                                          └─ ffmpeg: loudness (−20 LUFS), AAC, chapters, cover → .m4b
```

The engine works on its own from the terminal; the app is a thin front end over it.

## Install

Requirements: Apple Silicon Mac, macOS 15 or later, Xcode command-line tools, Homebrew, and about **12 GB free**
for the default models (more for the optional ones).

```bash
make setup
```

This installs `uv`, `ffmpeg` and `espeak-ng` if missing, creates the Python environment, downloads Kokoro,
Qwen3-TTS and Whisper, installs four reference voices, and builds `app/build/AudiobookStudio.app`.
`make models-all` adds the optional non-commercial engines (Voxtral, Fish S2 Pro).

## Use the app

Open `app/build/AudiobookStudio.app`, drop an EPUB or PDF on the window, check the chapters (front and back matter
are unticked for you, with the reason), pick a narrator (preview it on your own book, or compare two voices), make a
short sample to hear it and see how long the whole book will take on your Mac, then press Convert. Conversions run in
the background: you can close the window or quit the app, and the progress screen picks them up again.

`make app-check BOOK=path/to/book.epub` runs a self-test of the real app and engine together: it opens the book,
makes a sample, converts the first chapter and saves screenshots of every screen to `app/build/check/`.

## Use it from the terminal

```bash
E=engine/.venv/bin/audiobook-engine
$E inspect book.epub                                   # chapters, front/back matter, estimates
$E sample book.epub --engine qwen3 --voice ryan        # 60 s sample + projected time for the whole book
$E convert book.epub --engine qwen3 --voice ryan       # full audiobook, progress as JSON lines
$E convert livre.epub --engine qwen3 --ref-voice fr_siwis_female_book   # French, cloned narrator
$E convert book.epub --detach                          # background job; follow it with: $E jobs list
```

Every command prints JSON (one object per line). Re-running an interrupted conversion resumes where it stopped.

## Engines

| Engine | Languages | Voices | Licence | Speed on an M4 Pro* |
|---|---|---|---|---|
| Kokoro 82M | en, fr | 20 English presets, 1 French (draft quality) | Apache-2.0 | ≈ 14–18× real time |
| Qwen3-TTS 1.7B (default) | en, fr (+8) | Ryan, Aiden (English); any voice by cloning | Apache-2.0 | ≈ 3–5× presets, ≈ 2.4× cloning |
| Voxtral 4B | en, fr (+7) | French and English presets | CC BY-NC 4.0 (personal use) | ≈ 1.7–1.9× real time |
| Fish S2 Pro | en, fr (+78) | cloning only | Fish Audio Research Licence (non-commercial) | ≈ 0.56× (slower than real time) |

\* Measured on the author's machine with the speech check on. Your Mac measures itself: run `make bench`, or make
a sample; every time estimate in the app uses those measurements.

## Reference voices (for cloning)

A small library of licence-checked clips is included (`audiobook-engine voices list`). Clips are downloaded on
demand with their attribution. You can also add your own clip; you must have the right to use that voice.

| Voice | Language | Licence | Source |
|---|---|---|---|
| SIWIS studio narrator (F) | fr | CC BY 4.0 | SIWIS French Speech Synthesis Database, Univ. of Edinburgh |
| LibriVox readers 12205 (F), 7142 (M) | fr | CC BY 4.0 | CML-TTS via kyutai/tts-voices |
| Estelle (F), Fabieng (M) | fr | CC0 | kyutai/tts-voices (real, identifiable people: personal use) |
| Linda Johnson (F, US) | en | Public domain | LJSpeech |
| Bill Boerst (M, US), Laura Caldwell (F, US) | en | CC BY 4.0 | LibriTTS-R |
| VCTK p225 (F, UK), p226 (M, UK) | en | CC BY 4.0 | CSTR VCTK Corpus |
| Stuart Bell (M, UK) | en | CC0 | Voice-Zero |

## Quality safeguards

- **Speech check**: every sentence produced by a sampling engine is transcribed with Whisper and compared with
  the text; dropped or invented words trigger regeneration, and anything still wrong is listed in the report.
- **Chunk checks**: silent, truncated or runaway audio is detected and redone.
- **Structure**: front and back matter (copyright, table of contents, licences) are unticked automatically, with
  the reason shown; footnote markers, page numbers and captions are not read aloud.
- **Loudness**: each chapter is normalised to −20 LUFS with peaks below −3 dB.
- **Verification**: the finished M4B is checked with ffprobe (chapters, duration, cover, audiobook type).

## Disk space

Downloaded models live in the Hugging Face cache (`~/.cache/huggingface`). Conversion work files live in
`~/Library/Application Support/AudiobookStudio`. Chapter files are deleted after a successful conversion;
the sentence cache is kept so a re-run is fast. Free it with `audiobook-engine cache clear`.
Remove a model with `audiobook-engine models remove <engine>`.

## Limitations

- Scanned PDFs (images without a text layer) need OCR first; they are rejected with a clear message.
- English and French only. Other languages are detected and reported as unsupported.
- No speaker casting (one narrator per book) in this version.
- Kokoro's single French voice is draft quality; prefer Qwen3 with a French reference voice.

## Licences

This project's code is released under the MIT licence (see `LICENSE`). Third-party components keep their own
licences: PyMuPDF is AGPL-3.0 (this matters if you redistribute the engine with it), mlx-audio is MIT, and the model
weights and reference voices are licensed as listed above. Audio made with Voxtral or Fish S2 Pro is for
non-commercial use only. Audiobooks made from books you do not hold the rights to are for personal use only.
