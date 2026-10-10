"""audiobook-engine command line. Every command prints JSON on stdout."""

from __future__ import annotations

import json
import sys
import traceback
from pathlib import Path
from typing import Optional

import typer

from .models import IngestError

app = typer.Typer(add_completion=False, no_args_is_help=True, help="Local EPUB/PDF to audiobook engine.")


@app.callback()
def _root() -> None:
    """Local EPUB/PDF to audiobook engine. All output is JSON."""


_JSON_OUT = None  # private copy of the original stdout, reserved for JSON events


def _protect_stdout() -> None:
    """Reserve stdout for JSON. Libraries (mlx-audio, phonemizer) print chatter to
    stdout, even at the C level; route file descriptor 1 to stderr for everyone else."""
    global _JSON_OUT
    if _JSON_OUT is not None:
        return
    import os

    sys.stdout.flush()
    fd = os.dup(1)
    os.dup2(2, 1)
    _JSON_OUT = os.fdopen(fd, "w", encoding="utf-8", buffering=1)
    sys.stdout = sys.stderr


def _emit(obj) -> None:
    out = _JSON_OUT or sys.stdout
    out.write(json.dumps(obj, ensure_ascii=False) + "\n")
    out.flush()


def _fail(message: str, code: int = 2) -> None:
    _emit({"event": "error", "message": message})
    raise typer.Exit(code)


@app.command()
def inspect(
    book: Path = typer.Argument(..., help="Path to an .epub or .pdf"),
    cover_out: Optional[Path] = typer.Option(None, help="Write the cover image to this path"),
    paragraphs: bool = typer.Option(False, help="Include full paragraph text per section"),
) -> None:
    """Parse a book and print its structure (sections, kinds, sizes, estimates)."""
    from .ingest import read_book

    try:
        b = read_book(book)
    except IngestError as exc:
        _fail(str(exc))
        return
    out = b.to_json()
    if paragraphs:
        for sj, s in zip(out["sections"], b.sections):
            sj["text"] = s.paragraphs
    if cover_out and b.cover:
        cover_out.write_bytes(b.cover.data)
        out["cover"]["written_to"] = str(cover_out)
    _emit(out)


class OptionError(ValueError):
    """An invalid command-line value, with a message for the user."""


# Far more sections than any book has; bounds the list built from ranges like '0-999999999'.
MAX_SECTION_INDEXES = 10_000


def _parse_sections(spec: Optional[str]) -> Optional[list[int]]:
    if not spec:
        return None
    out: list[int] = []
    for part in spec.split(","):
        part = part.strip()
        try:
            if "-" in part:
                a, b = part.split("-", 1)
                lo, hi = int(a), int(b)
                if lo > hi:
                    raise OptionError(f"Invalid --sections range '{part}': the start is after the end.")
                if len(out) + (hi - lo + 1) > MAX_SECTION_INDEXES:
                    raise OptionError(f"Invalid --sections value '{spec}': more than {MAX_SECTION_INDEXES} "
                                      "section indexes. Use 'inspect' to list the book's sections.")
                out.extend(range(lo, hi + 1))
            elif part:
                out.append(int(part))
        except OptionError:
            raise
        except ValueError:
            raise OptionError(f"Invalid --sections value '{spec}': use section indexes like '2-14,20'.") from None
    if not out:
        raise OptionError(f"Invalid --sections value '{spec}': no section index given.")
    return out


def _voice_choice(spec, voice: Optional[str], ref: Optional[Path], ref_text: Optional[str], ref_voice: Optional[str]):
    """Resolve --voice / --ref / --ref-voice into a VoiceChoice the engine can use.

    None when no voice is given: the default preset depends on the book language, which is
    known only once the book is read (pipeline.resolve_voice).
    """
    from . import voices
    from .tts import VoiceChoice

    if sum(x is not None for x in (voice, ref, ref_voice)) > 1:
        raise OptionError("Use only one of --voice, --ref and --ref-voice.")
    if ref is not None or ref_voice is not None:
        if not spec.supports_cloning:
            raise OptionError(f"{spec.name} cannot clone voices; choose a preset with --voice.")
        if ref_voice is not None:
            iv = voices.get(ref_voice)
            if iv is None:
                known = {v["id"] for v in voices.library()}
                hint = f"audiobook-engine voices download {ref_voice}" if ref_voice in known else "audiobook-engine voices list"
                raise OptionError(f"Voice '{ref_voice}' is not installed. Run: {hint}")
            return iv.choice() if not ref_text else VoiceChoice(ref_audio=str(iv.path), ref_text=ref_text)
        if not ref.exists():
            raise OptionError(f"Reference clip not found: {ref}")
        return VoiceChoice(ref_audio=str(ref.resolve()), ref_text=ref_text)
    if not spec.supports_presets:
        raise OptionError(f"{spec.name} has no preset voices: give a reference clip with --ref-voice or --ref.")
    return VoiceChoice(voice) if voice is not None else None


def _lang_or_raise(lang: Optional[str]) -> Optional[str]:
    """Registry code for any accepted spelling ("pt-BR" -> "pt"); None stays None (use the book's language)."""
    from .languages import codes, normalize_code

    if lang is None:
        return None
    code = normalize_code(lang)
    if code is None:
        raise OptionError(f"Unsupported language '{lang}'. Supported: {', '.join(codes())}.")
    return code


def _options(engine: str, voice: Optional[str], ref: Optional[Path], ref_text: Optional[str], lang: Optional[str],
             speed: float, sections: Optional[str], out_dir: Optional[Path], bitrate: int, intro: bool, *,
             ref_voice: Optional[str] = None, verify: Optional[bool] = None, keep_work: bool = False):
    """Build ConvertOptions; raises OptionError for invalid values."""
    from .pipeline import ConvertOptions
    from .tts import specs

    spec = specs().get(engine)
    if spec is None:
        raise OptionError(f"Unknown engine '{engine}'. Available: {', '.join(specs())}")
    lang = _lang_or_raise(lang)
    choice = _voice_choice(spec, voice, ref, ref_text, ref_voice)
    return ConvertOptions(engine=engine, voice=choice, lang=lang, speed=speed, sections=_parse_sections(sections),
                          out_dir=out_dir, bitrate_k=bitrate, intro=intro, verify=verify, keep_work=keep_work)


def _options_or_fail(*args, **kwargs):
    try:
        return _options(*args, **kwargs)
    except OptionError as exc:
        _fail(str(exc))


@app.command()
def convert(
    book: Path = typer.Argument(..., help="Path to an .epub or .pdf"),
    engine: str = typer.Option("kokoro", help="TTS engine id (see 'engines')"),
    voice: Optional[str] = typer.Option(None, help="Preset voice id (see 'engines')"),
    ref: Optional[Path] = typer.Option(None, help="Reference clip to clone (engines that support cloning)"),
    ref_text: Optional[str] = typer.Option(None, help="Exact transcript of the reference clip"),
    ref_voice: Optional[str] = typer.Option(None, help="Installed reference voice id to clone (see 'voices list')"),
    verify: Optional[bool] = typer.Option(None, "--verify/--no-verify",
                                          help="Speech check with Whisper (default: on for sampling engines)"),
    keep_work: bool = typer.Option(False, help="Keep chapter audio files in the job folder after success"),
    lang: Optional[str] = typer.Option(None, help="Override the book language (any supported code, e.g. en, fr, es, de, zh)"),
    speed: float = typer.Option(1.0, min=0.5, max=2.0),
    sections: Optional[str] = typer.Option(None, help="Section indexes, e.g. '2-14,20' (default: auto-selected)"),
    out_dir: Optional[Path] = typer.Option(None, help="Output folder (default: next to the book)"),
    bitrate: int = typer.Option(64, help="AAC bitrate in kbps (mono)"),
    intro: bool = typer.Option(True, help="Speak 'Title. By Author.' as an opening chapter"),
    job_dir: Optional[Path] = typer.Option(None, help="Job folder (default: Application Support)"),
    detach: bool = typer.Option(False, help="Run in the background; print the job folder and exit"),
) -> None:
    """Convert a book into an M4B audiobook. Prints JSON progress events, one per line."""
    if job_dir is not None:
        job_dir = job_dir.expanduser().absolute()
    # With --job-dir (always the case for a detached child, whose stdout goes nowhere) every
    # failure is also written to the job folder: job.json, events.jsonl and stderr.log.
    report_to_job = job_dir is not None and not detach
    try:
        from .pipeline import Cancelled, JobBusy, convert as run

        opts = _options(engine, voice, ref, ref_text, lang, speed, sections, out_dir, bitrate, intro,
                        ref_voice=ref_voice, verify=verify, keep_work=keep_work)
    except Exception as exc:
        message = str(exc) if isinstance(exc, OptionError) else f"{type(exc).__name__}: {exc}"
        if report_to_job:
            _record_job_failure(job_dir, message, book)
        _fail(message, 2 if isinstance(exc, OptionError) else 1)
        return
    if detach:
        _detach(book, opts, job_dir)
        return
    try:
        run(book, opts, _emit, job_dir)  # records its own failures in the job folder
    except Cancelled:
        raise typer.Exit(130)
    except Exception as exc:  # report every failure as a JSON event
        # JobBusy: a duplicate launch; its stderr.log belongs to the job that is running.
        if report_to_job and not isinstance(exc, JobBusy):
            traceback.print_exc()
        _fail(f"{type(exc).__name__}: {exc}", 1)


def _record_job_failure(job_dir: Path, message: str, book: Path) -> None:
    from . import jobs

    traceback.print_exc()  # -> stderr.log for a detached child
    jobs.record_failure(job_dir, message, book=str(book))


def _child_args(argv: list[str]) -> list[str]:
    """The parent's arguments without --detach and --job-dir (the child gets its own --job-dir)."""
    out: list[str] = []
    skip = False
    for a in argv:
        if skip:
            skip = False
        elif a in {"--detach", "--no-detach"} or a.startswith("--job-dir="):
            continue
        elif a == "--job-dir":
            skip = True
        else:
            out.append(a)
    return out


def _detach(book: Path, opts, job_dir: Optional[Path]) -> None:
    from . import jobs, paths
    from .pipeline import prepare

    try:
        # Exactly the checks the child runs before it can log anything: a request that cannot
        # start is reported here, on stdout, instead of vanishing in a background process.
        prep = prepare(book, opts)
    except Exception as exc:
        _fail(f"{type(exc).__name__}: {exc}", 1)
        return
    jd = job_dir or paths.jobs_dir() / prep.job_id
    # Parents launching the same job folder take turns: each sees the child the other started,
    # even before that child holds job.lock (it takes it only after its own start-up).
    with jobs.launch_lock(jd):
        holder = jobs.lock_holder(jd)
        running_job = jobs.read_state(jd).get("job_id", prep.job_id) if holder is not None else None
        if holder is None:
            starting = jobs.starting_child(jd)
            if starting:
                holder, running_job = starting["pid"], starting.get("job_id") or prep.job_id
        if holder is not None:
            if running_job != prep.job_id:
                _fail(f"Job folder {jd} is in use by another running job (job {running_job}).", 1)
                return
            # Same book, same settings, already running (double launch): report that job instead
            # of starting a second process that would fight over job.json.
            _emit({"event": "detached", "job_id": prep.job_id, "job_dir": str(jd),
                   "pid": holder or jobs.read_state(jd).get("pid"), "events": str(jd / "events.jsonl"),
                   "already_running": True})
            return
        pid = jobs.spawn_detached(_child_args(sys.argv[1:]), jd)
        jobs.note_launch(jd, pid, prep.job_id)
    _emit({"event": "detached", "job_id": prep.job_id, "job_dir": str(jd), "pid": pid,
           "events": str(jd / "events.jsonl")})


@app.command()
def sample(
    book: Path = typer.Argument(...),
    engine: str = typer.Option("kokoro"),
    voice: Optional[str] = typer.Option(None),
    ref: Optional[Path] = typer.Option(None),
    ref_text: Optional[str] = typer.Option(None),
    ref_voice: Optional[str] = typer.Option(None, help="Installed reference voice id to clone"),
    verify: Optional[bool] = typer.Option(None, "--verify/--no-verify"),
    lang: Optional[str] = typer.Option(None),
    speed: float = typer.Option(1.0, min=0.5, max=2.0),
    section: Optional[int] = typer.Option(None, help="Section index (default: first chapter)"),
    seconds: float = typer.Option(60.0, help="Approximate sample length"),
    out: Path = typer.Option(Path("sample.m4a"), help="Output audio file (.m4a, .wav, .mp3)"),
) -> None:
    """Narrate a short sample of the book and project how long the full book will take."""
    from .pipeline import sample as run

    opts = _options_or_fail(engine, voice, ref, ref_text, lang, speed, None, None, 64, False,
                            ref_voice=ref_voice, verify=verify)
    try:
        run(book, opts, section, seconds, out, _emit)
    except Exception as exc:
        _fail(f"{type(exc).__name__}: {exc}", 1)


@app.command()
def benchmark(
    engine: str = typer.Option("kokoro"),
    voice: Optional[str] = typer.Option(None),
    ref: Optional[Path] = typer.Option(None),
    ref_text: Optional[str] = typer.Option(None),
    ref_voice: Optional[str] = typer.Option(None, help="Installed reference voice id to clone"),
    lang: str = typer.Option("en", help="Language code (en, fr, es, de, it, pt, ru, zh, ja, ko, hi, ar, nl)"),
    batch: Optional[int] = typer.Option(None, min=1, help="Override batch size (experiments; not saved)"),
    repeats: int = typer.Option(1, min=1, max=10),
) -> None:
    """Measure an engine's speed and memory on this Mac with a fixed passage."""
    from . import jobs
    from .benchmark import run

    opts = _options_or_fail(engine, voice, ref, ref_text, lang, 1.0, None, None, 64, False, ref_voice=ref_voice)
    lang = opts.lang  # normalised registry code
    try:
        from .pipeline import resolve_voice

        choice = resolve_voice(opts, lang)  # no --voice: the engine's first preset for this language
        with jobs.gpu_lock(on_wait=lambda: _emit({"event": "queued", "message": "Waiting for the GPU"})):
            run(engine, choice, lang, batch, repeats, _emit)
    except Exception as exc:
        _fail(f"{type(exc).__name__}: {exc}", 1)


@app.command()
def engines() -> None:
    """List installed engines with their voices, licenses and saved speed measurements."""
    from . import API_VERSION
    from .perf import load_rates
    from .tts import specs

    _emit({"engines": [s.to_json() for s in specs().values()], "measured": load_rates(), "api": API_VERSION})


@app.command()
def models(
    action: str = typer.Argument("list", help="list | download | remove"),
    engine: Optional[str] = typer.Argument(None, help="Engine id (required for download/remove)"),
) -> None:
    """Install or inspect local model files. The only command that uses the network."""
    from . import modelstore as m

    if action == "list":
        _emit({"models": [m.status(e) for e in m.all_ids()]})
        return
    if engine not in m.all_ids():
        _fail(f"Specify one of: {', '.join(m.all_ids())}")
    if action == "download":
        try:
            _emit({"event": "done", **m.download(engine, _emit)})
        except Exception as exc:
            _fail(f"Download failed: {exc}", 1)
    elif action == "remove":
        try:
            _emit({"event": "done", **m.remove(engine)})
        except Exception as exc:
            _fail(f"Remove failed: {type(exc).__name__}: {exc}", 1)
    else:
        _fail("action must be list, download or remove")


@app.command("voices")
def voices_cmd(
    action: str = typer.Argument("list", help="list | download | add | replace | remove | transcript"),
    target: Optional[str] = typer.Argument(None, help="Voice id, or a clip file for 'add'"),
    text: Optional[str] = typer.Argument(None, help="New transcript for 'transcript'"),
    name: Optional[str] = typer.Option(None, help="Display name for 'add'"),
    lang: Optional[str] = typer.Option(None, help="Language of the clip for 'add' (any supported code)"),
    transcript: Optional[str] = typer.Option(None, help="Exact words spoken in the clip ('add'; else Whisper)"),
    i_have_rights: bool = typer.Option(False, "--i-have-rights",
                                       help="Confirm you have the right to use this voice (required for 'add', "
                                            "and for 'replace' with --file)"),
    isolate: Optional[bool] = typer.Option(None, "--isolate/--no-isolate",
                                           help="Remove background noise and music first (DeepFilterNet3)"),
    enhance: Optional[bool] = typer.Option(None, "--enhance/--no-enhance",
                                           help="Restore speech clarity first (MossFormer2-SE)"),
    file: Optional[Path] = typer.Option(None, help="New recording for 'replace' (else the kept original is reused)"),
) -> None:
    """Reference voices for cloning: a licence-checked library plus your own clips."""
    from . import voices
    from .voices.cleanup import CleanupModelMissing

    if action == "list":
        installed = {v.id: v for v in voices.installed()}
        out = []
        for entry in voices.library():
            iv = installed.pop(entry["id"], None)
            out.append({**{k: v for k, v in entry.items() if k not in {"verified", "license_detail"}},
                        "installed": iv is not None, **(iv.to_json() if iv else {})})
        out += [{**v.to_json(), "installed": True} for v in installed.values()]  # user clips
        _emit({"voices": out})
        return
    if not target:
        _fail("Specify a voice id (or a clip file for 'add').")
    try:
        if action == "download":
            iv = voices.download(target)
            _emit({"event": "done", **iv.to_json(), "installed": True})
        elif action == "add":
            if not i_have_rights:
                _fail("Adding a voice requires --i-have-rights: only use voices you are allowed to clone.")
            try:
                lang = _lang_or_raise(lang)
            except OptionError as exc:
                _fail(str(exc))
            if lang is None:
                _fail("Give the clip language with --lang (e.g. --lang en).")
            iv = voices.add_user_clip(Path(target), name or Path(target).stem, lang, transcript,
                                      isolate=bool(isolate), enhance=bool(enhance))
            _emit({"event": "done", **iv.to_json(), "installed": True})
        elif action == "replace":
            if file is not None and not i_have_rights:
                _fail("A new recording requires --i-have-rights: only use voices you are allowed to clone.")
            iv = voices.replace_user_clip(target, file, isolate=isolate, enhance=enhance, transcript=transcript)
            _emit({"event": "done", **iv.to_json(), "installed": True})
        elif action == "remove":
            if not voices.remove(target):
                _fail(f"Voice '{target}' is not installed.")
            _emit({"event": "done", "id": target, "removed": True})
        elif action == "transcript":
            if not text:
                _fail("Give the corrected transcript as the third argument.")
            _emit({"event": "done", **voices.set_transcript(target, text).to_json()})
        else:
            _fail("action must be list, download, add, replace, remove or transcript")
    except typer.Exit:
        raise
    except (voices.VoiceInUse, voices.VoiceProblem, voices.VoiceNotFound, CleanupModelMissing) as exc:
        _fail(str(exc), 1)  # already a sentence for the user
    except Exception as exc:
        _fail(f"{type(exc).__name__}: {exc}", 1)


@app.command("languages")
def languages_cmd(
    action: str = typer.Argument("list", help="list | add | remove"),
    code: Optional[str] = typer.Argument(None, help="Language code (es, de, zh...)"),
) -> None:
    """Languages on demand: list them, switch one on (downloads its small reference voices) or off."""
    from . import language_packs, languages as registry

    if action == "list":
        _emit({"languages": language_packs.list_all()})
        return
    if action not in {"add", "remove"}:
        _fail("action must be list, add or remove")
    if not code:
        _fail("Give a language code, for example: languages add es")
    try:
        lang = registry.get(code)
    except KeyError:
        _fail(f"Unsupported language '{code}'. Supported: {', '.join(registry.codes())}.")
    try:
        if action == "add":
            _emit(language_packs.add(lang.code, emit=_emit))
        else:
            _emit(language_packs.remove(lang.code))
    except language_packs.LanguageError as exc:
        _fail(str(exc), 1)
    except Exception as exc:
        _fail(f"{type(exc).__name__}: {exc}", 1)


@app.command("cache")
def cache_cmd(
    action: str = typer.Argument("info", help="info | clear"),
    jobs_too: bool = typer.Option(False, "--jobs", help="Also delete finished job folders"),
) -> None:
    """Show or free the disk space used by cached audio (finished audiobooks are never touched)."""
    from . import jobs, paths
    from .cache import ChunkCache, tree_bytes

    cache = ChunkCache(paths.home() / "cache" / "chunks")
    if action == "info":
        # A running job renames files while they are counted: tree_bytes skips those.
        _emit({"chunks_bytes": cache.size_bytes(), "jobs_bytes": tree_bytes(paths.jobs_dir()),
               "path": str(paths.home())})
        return
    if action != "clear":
        _fail("action must be info or clear")
    if any(j.get("state") in {"running", "queued"} for j in jobs.list_jobs()):
        _fail("A conversion is running; clear the cache after it finishes.")
    freed = cache.clear()
    if jobs_too:
        import shutil

        for j in jobs.list_jobs():
            if j.get("state") not in {"running", "queued"}:
                d = Path(j["job_dir"])
                freed += tree_bytes(d)
                shutil.rmtree(d, ignore_errors=True)
    _emit({"event": "done", "freed_bytes": freed})


@app.command("jobs")
def jobs_cmd(
    action: str = typer.Argument("list", help="list | status | cancel"),
    job: Optional[str] = typer.Argument(None, help="Job id or job folder"),
) -> None:
    """List, inspect or cancel conversion jobs."""
    from . import jobs, paths

    if action == "list":
        _emit({"jobs": jobs.list_jobs()})
        return
    if not job:
        _fail("Specify a job id")
    jd = Path(job) if "/" in job else paths.jobs_dir() / job
    if not (jd / "job.json").exists():
        _fail(f"No such job: {job}")
    if action == "status":
        _emit(jobs.status(jd))
    elif action == "cancel":
        _emit(jobs.cancel(jd))
    else:
        _fail("action must be list, status or cancel")


def run_cli(argv: Optional[list[str]] = None) -> int:
    """Run a command and return its exit code. Errors Click/Typer reports itself (unknown
    command or option, out-of-range --speed, missing argument) and unexpected crashes are
    printed as a JSON error event too, so stdout always carries JSON."""
    try:
        rv = app(args=argv, prog_name="audiobook-engine", standalone_mode=False)
    except typer.TyperException as exc:  # Typer's own Click: UsageError, BadParameter, NoSuchOption, ...
        if type(exc).__name__ == "NoArgsIsHelpError":
            print(exc.format_message(), file=sys.stderr)  # the help text
            _emit({"event": "error", "message": "No command given. Run 'audiobook-engine --help'."})
        else:
            _emit({"event": "error", "message": exc.format_message()})
        return exc.exit_code
    except typer.Abort:
        _emit({"event": "error", "message": "Aborted."})
        return 1
    except Exception as exc:  # a bug: keep the traceback for stderr.log, still answer in JSON
        traceback.print_exc()
        _emit({"event": "error", "message": f"{type(exc).__name__}: {exc}"})
        return 1
    return rv if isinstance(rv, int) else 0


def main() -> None:  # pragma: no cover
    import os

    _protect_stdout()
    if len(sys.argv) > 1 and sys.argv[1] in {"convert", "sample", "benchmark"}:
        os.environ.setdefault("HF_HUB_OFFLINE", "1")  # never download mid-conversion
    sys.exit(run_cli())


if __name__ == "__main__":  # pragma: no cover
    main()
