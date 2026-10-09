# Audiobook Studio — local EPUB/PDF to M4B audiobooks on Apple Silicon.
#   make setup    install engine + default models (Kokoro, Qwen3-TTS, Whisper) + default voices
#   make models-all   also install the optional non-commercial engines (Voxtral, Fish S2 Pro)
#   make test     engine tests + lint + app tests
#   make app      build app/build/AudiobookStudio.app
#   make bench    measure engines on this Mac (results feed every time estimate)
#   make app-check BOOK=path/to/book.epub   end-to-end self-test of the real app + engine (screenshots in app/build/check)

ENGINE      := engine
CLI         := $(ENGINE)/.venv/bin/audiobook-engine
MIN_FREE_GB := 12

.PHONY: setup engine models models-all voices test test-engine test-app app app-check bench check-disk clean-cache

setup: check-disk engine models voices app
	@echo "Done. Open app/build/AudiobookStudio.app (or run: $(CLI) --help)"

check-disk:
	@free=$$(df -g "$$HOME" | awk 'NR==2 {print $$4}'); \
	if [ "$$free" -lt $(MIN_FREE_GB) ]; then echo "Only $${free} GB free; need at least $(MIN_FREE_GB) GB for the default models."; exit 1; fi; \
	echo "Disk: $${free} GB free"

engine:
	@command -v uv >/dev/null || brew install uv
	@command -v ffmpeg >/dev/null || brew install ffmpeg
	@command -v espeak-ng >/dev/null || brew install espeak-ng
	cd $(ENGINE) && uv sync

models: engine
	$(CLI) models download kokoro
	$(CLI) models download qwen3
	$(CLI) models download whisper

models-all: models
	$(CLI) models download voxtral
	$(CLI) models download fish

voices: engine
	$(CLI) voices download fr_siwis_female_book
	$(CLI) voices download fr_cmltts_7142_male
	$(CLI) voices download en_librittsr_laura_caldwell_female_us
	$(CLI) voices download en_librittsr_bill_boerst_male_us

test: test-engine test-app

test-engine:
	cd $(ENGINE) && uv run ruff check --select F src tests && uv run pytest -q

test-app:
	cd app && swift test

app:
	cd app && ./scripts/bundle.sh

app-check: app
	@test -n "$(BOOK)" || (echo "Usage: make app-check BOOK=path/to/book.epub"; exit 1)
	rm -rf app/build/check && mkdir -p app/build/check
	AUDIOBOOK_STUDIO_SNAPSHOT_DIR="$(CURDIR)/app/build/check" AUDIOBOOK_STUDIO_SNAPSHOT_BOOK="$(abspath $(BOOK))" \
	AUDIOBOOK_STUDIO_SNAPSHOT_ACTION=convert app/build/AudiobookStudio.app/Contents/MacOS/AudiobookStudio
	@cat app/build/check/report.json

bench:
	$(CLI) benchmark --engine kokoro --voice af_heart --lang en
	$(CLI) benchmark --engine kokoro --voice ff_siwis --lang fr
	$(CLI) benchmark --engine qwen3 --voice ryan --lang en

clean-cache:
	$(CLI) cache clear
