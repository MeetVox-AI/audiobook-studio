# Audiobook Studio — macOS app specification (v1)

Native SwiftUI app (macOS 15+, Swift 6, Swift Package at `/Users/me/Code/audiobook/app`).
It is a thin front end over the local Python engine CLI `audiobook-engine` (path from Info.plist key
`AudiobookEnginePath`, overridable in Settings; default for `swift run`:
`/Users/me/Code/audiobook/engine/.venv/bin/audiobook-engine`).
Everything runs locally. The app never talks to the network itself.

## Engine contract (source of truth: real outputs in `Tests/AudiobookStudioTests/Fixtures/*.json[l]`)

Every engine command prints JSON on stdout, one object per line. Errors are `{"event":"error","message":...}`
with a non-zero exit code. stderr is free-form log text (show the tail in a disclosure on failure).

One-shot commands (run with `Process`, read all stdout lines, decode the last line unless noted):
- `inspect <book> [--cover-out <png>] [--paragraphs]` → Book JSON: title, author, language, language_source,
  cover{media_type,bytes,source,written_to}, sections[{index,title,kind(chapter|front|back),include,chars,
  est_seconds,paragraphs,first_words,reasons[]}], included_chars, included_est_seconds, warnings[], metadata{}.
- `engines` → {engines:[{id,name,checkpoint,languages[],license,noncommercial,batch_size,supports_presets,
  supports_cloning,supports_speed,download_gb,notes,voices:[{id,name,lang,gender,accent,note}]}], measured:{"<engine>|<voice>":{chars_per_s,realtime_x,seconds_per_char,chars,source,updated}}}
- `models list` → {models:[{engine,name,installed,download_gb,license,noncommercial,parts:[{repo,purpose,installed,bytes,path}]}]}
- `models download <id>` → streams {event:download_start|download_done} then final {event:done, ...status}
- `voices list` → library + installed voices (see engine; fields id,name,lang,gender,description,license,commercial_ok,attribution,installed,transcript,transcript_source,duration_s,path)
- `voices download <id>` / `voices add <file> --name N --lang fr|en [--transcript T]` / `voices remove <id>`
- `jobs list` → {jobs:[status]} ; `jobs status <id>` → status ; `jobs cancel <id>` → {cancelled,pid,stopped|reason}
  status = {job_id,book,title,author,lang,engine,voice,speed,state(queued|running|done|done_with_problems|failed|cancelled|interrupted),pid,started,finished?,output?,error?,job_dir,last_progress{progress event},last_error,result{done event}}
- `benchmark --engine E [--voice V | --ref-voice ID] --lang en|fr` → {event:benchmark, engine,voice,lang,batch,chunks,chars,load_s,warmup_s,wall_s,audio_s,chars_per_s,realtime_x,seconds_per_char,peak_memory_gb}

Streaming commands (read stdout line by line while running):
- `sample <book> --engine E (--voice V | --ref-voice ID) --section N --seconds 60 --out <file.m4a>` →
  events model_loading, model_loaded{load_s,warmup_s}, queued?, then sample_done{output,section,title,audio_s,
  synth_wall_s,chars_synthesized,rate_cps,realtime_x,book_chars,book_est_audio_s,book_est_wall_s,note}.
- `convert <book> ... --detach` → prints ONE line {event:detached,job_id,job_dir,pid,events}; the job then runs
  in its own process. The app tails `<job_dir>/events.jsonl` (append-only JSON lines; the last line may be partial —
  only parse complete lines). Event kinds: job_start{title,author,lang,engine,engine_name,voice,license,
  noncommercial,sections[{index,title,chars,chunks}],total_chars,chars_to_synthesize,cached_chars,est_audio_s,
  saved_rate_cps,est_wall_s,warnings[]}, queued{message}, model_loading, model_loaded, section_start{section,n,of,
  title,chunks,chars}, section_skip, progress{section,n,of,chunk,chunks,chars_done,total_chars,percent,rate_cps,
  run_rate_cps,realtime_x,eta_s,eta_low_s,eta_high_s,eta_basis(measured|saved|calibrating),elapsed_s},
  chunk_flagged{section,chunk,issues[],text}, assembling, encoding{percent,output?,encoder?}, done{output,
  duration_s,chapters,wall_s,synth_chars,synth_wall_s,realtime_x,flagged_chunks,verification_problems[],size_mb},
  cancelled{message}, error{message}. Every event has `t` (seconds since job start).
  QA events (when verification is on) are documented in the fixtures if present.
- Cancel = `jobs cancel <job_id>`. Resume = run the same convert again (same options → same job_id; finished
  chunks/chapters are reused automatically).

## Screens (single main window with a sidebar)

Sidebar: "New audiobook" (drop zone), "Jobs" (list with live state, progress ring, ETA), "Voices", "Models",
"Benchmark", and Settings (standard Settings scene, ⌘,).

1. **Drop / open** — drag an .epub/.pdf onto the window or use Open (⌘O). Runs `inspect` (with `--cover-out`
   into a temp file). Errors shown inline (e.g. scanned PDF needs OCR).
2. **Book** — cover, editable title/author (passed through later; v1 may display only), language picker
   (defaults to detected; show "detected"/"from metadata"), warnings list. **Section list**: checkbox, kind badge
   (Chapter / Front / Back), title, first words, estimated listening time, and the reason a section was unticked
   (e.g. "Project Gutenberg license text"). Front/back matter unticked by default. Totals bar: selected sections,
   characters, estimated audio length, and **estimated conversion time for the chosen engine** using the measured
   rate from `engines.measured` ("On this Mac: ≈ 41 min"; if no measurement: "Run a benchmark or make a sample to
   get an estimate").
3. **Voice** — engine picker (cards: name, licence badge with NON-COMMERCIAL warning, languages, speed on this
   Mac if measured, installed or "Download 6.2 GB"). Voice browser: filter by language/gender/engine/licence;
   presets from `engines`, cloned voices from `voices list` (library + user clips). Speed slider 0.75–1.5.
   **Preview on this book**: makes a ~20 s `sample` of the selected section with this voice and plays it.
   **A/B compare**: pick two voices, generate both samples for the same paragraph, play A / play B.
   **Add my voice**: file picker → consent checkbox ("I have the right to use this voice") → `voices add`.
   Licence sheet before first use of a non-commercial engine (Voxtral, Fish): must acknowledge.
4. **Sample** — "Make a 2-minute sample" → progress → player + measured speed + projected full-book time
   ("Projection from this sample; long jobs run warmer, expect it to be a little optimistic").
5. **Convert / progress** (per job, also reachable from Jobs): big progress bar (percent of characters), current
   chapter "Chapter 12 of 38 — 'XII'", chunk x/y, **ETA as a range** ("about 23 min (20–27)", or "calibrating…"),
   elapsed, speed now vs average (chars/s and × real time), a small Swift Charts line of rate over time,
   flagged chunks count (expandable list with text and issue), machine status: thermal state
   (ProcessInfo.thermalState) and power source (warn on battery), "Keeping your Mac awake" indicator.
   Cancel button (confirm). Closing the window does NOT stop the job; reopening the app re-attaches by tailing
   events.jsonl for jobs in state running/queued (from `jobs list`).
6. **Done** — summary (duration, chapters, size, total time, × real time, flagged chunks), verification problems if
   any, buttons: Play, Reveal in Finder, Open in Books (`open -a Books <m4b>`), Convert again with other settings.
7. **Models** — list from `models list`: name, licence (non-commercial badge), size, installed state, Download /
   Remove buttons with progress (stream events).
8. **Benchmark** — choose engine+voice+language → run → table of results history from `engines.measured`.
9. **Settings** — engine path (with "Test" button running `engines`), output folder (default: next to the book),
   AAC bitrate (64/96/128 kbps), default engine/voice per language, pacing (sentence/paragraph/chapter pauses —
   v1 may store only), notifications on/off.

## Behaviour requirements

- Never block the main thread: all engine calls are async (`Process` + `AsyncStream`/`async` wrappers).
- Keep the Mac awake while a job runs in the app's view: `ProcessInfo.processInfo.beginActivity(options:
  [.idleSystemSleepDisabled, .userInitiated], reason:)`; end it when the job finishes. (The engine also runs
  `caffeinate` itself, so detached jobs stay awake even if the app quits.)
- Notifications (UNUserNotificationCenter) on job done / failed. Only when running as a bundled app
  (`Bundle.main.bundleIdentifier != nil`); `swift run` must not crash.
- Honest numbers only: show what the engine reports; never invent ETAs. If eta_basis is "calibrating", say so.
- Accessibility: all controls labelled; works in light and dark mode; no fixed colours except system ones.
- Errors: show the engine's message, plus a disclosure with the stderr tail.
- No third-party Swift packages.

## Tests

`swift test` must pass: decode every fixture file (real engine outputs) into the Codable models; ETA/duration
formatting; job-state mapping; partial-last-line handling in the events tailer.

## Contract additions (engine as of this build; fixtures in Tests/AudiobookStudioTests/Fixtures are authoritative)

- Voice choice for `convert` / `sample` / `benchmark`: exactly one of `--voice <preset>` (from `engines`),
  `--ref-voice <installed voice id>` (from `voices list`, cloning engines only: qwen3, fish) or `--ref <file>`.
  Fish has no presets (clone only). Kokoro and Voxtral cannot clone. The engine rejects invalid combinations with
  an error event whose message is user-facing: show it as is.
- `--verify/--no-verify` on `convert` and `sample`: Whisper speech check. Default: on for sampling engines
  (qwen3, voxtral, fish), off for kokoro. Show it as a toggle "Check every sentence with speech recognition"
  with the note "about +15% time".
- `--keep-work` on `convert` (advanced; default off: chapter files are deleted after success to save disk).
- New events: `qa_model_loaded{load_s}`, `qa_redo{section,chunk,before_cer,after_cer,fixed}`,
  `notice{message}` (show as an info banner), `progress.qa{checked,redone,flagged}`, `done.qa{...}`,
  `done.freed_work_mb`. The convert may fail early with an error "Not enough disk space ..." — show it prominently.
- `voices list` → {voices:[{id,name,lang,gender,description,license,commercial_ok,attribution,source_page,
  audio_url,transcript,duration_s,installed, (when installed) path,transcript_source}]}. User clips have ids
  starting with `user-`. `voices download <id>`, `voices add <file> --name N --lang en|fr [--transcript T]
  --i-have-rights` (the app must show a consent checkbox and only pass --i-have-rights when it is ticked),
  `voices remove <id>`, `voices transcript <id> "<corrected text>"` (offer an editable transcript field: Whisper
  can mishear names; cloning quality depends on the transcript).
- `cache info` → {chunks_bytes, jobs_bytes, path}; `cache clear [--jobs]` → {event:done, freed_bytes}. Show
  cache size in Settings with a "Free space" button (refused by the engine while a job runs).
- Measured on the author's M4 Pro (for UI copy and sanity checks only; always display the engine's own
  measurements): Kokoro ≈ 14× real time, Qwen3 ≈ 3–5× (batch 8, including speech check), Voxtral ≈ 1.7–1.9×,
  Fish S2 Pro ≈ 0.56× (slower than real time: warn before starting a full book with it).
