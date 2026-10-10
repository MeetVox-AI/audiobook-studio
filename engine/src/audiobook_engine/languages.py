"""The languages Audiobook Studio can narrate, and the facts about each that the rest of the engine needs.

One registry, read by text processing, segmentation, ingest, speech check, voices and the app. A language is
*supported* when at least one engine can speak it (see `tts/*.py` SPEC.languages); this file only describes
the language itself. Names and phrases below were written by the developers and should be reviewed by native
speakers; the `announce` and `credits` strings are what the audiobook says before chapter 1.
"""

from __future__ import annotations

from dataclasses import dataclass, replace


@dataclass(frozen=True)
class Language:
    code: str                  # ISO 639-1, lower case: "es"
    name: str                  # English name
    native: str                # name in the language itself
    num2words: str | None      # num2words language code, None when the library cannot spell numbers
    qwen3: str | None          # Qwen3-TTS language name, None when Qwen3 cannot speak it
    announce: str              # spoken before chapter 1: {title} {author}
    credits: str               # title of the opening-credits section
    sentence_end: str          # characters that end a sentence (besides . ! ? and the ellipsis)
    cjk: bool = False          # no spaces between words (Chinese, Japanese): count characters, not words
    rtl: bool = False          # written right to left (Arabic)
    sec_per_char: float = 0.065  # audio seconds per source character (listening-time estimates)
    chunk_scale: float = 1.0   # multiplier on an engine's chunk cap (dense scripts need smaller chunks)
    warmup: str = ""           # one short natural sentence used to warm up a TTS engine


_LANGUAGES = [
    Language("en", "English", "English", "en", "english", "{title}. By {author}.", "Opening credits", ""),
    Language("fr", "French", "Français", "fr", "french", "{title}, de {author}.", "Générique", ""),
    Language("es", "Spanish", "Español", "es", "spanish", "{title}, de {author}.", "Créditos iniciales", "¿¡", sec_per_char=0.095),
    Language("de", "German", "Deutsch", "de", "german", "{title}, von {author}.", "Vorspann", "", sec_per_char=0.081),
    Language("it", "Italian", "Italiano", "it", "italian", "{title}, di {author}.", "Titoli di apertura", "", sec_per_char=0.069),
    Language("pt", "Portuguese", "Português", "pt_BR", "portuguese", "{title}, de {author}.",
             "Créditos iniciais", "", sec_per_char=0.077),
    Language("ru", "Russian", "Русский", "ru", "russian", "{title}. Автор — {author}.",
             "Начальные титры", "", sec_per_char=0.086),
    Language("zh", "Chinese", "中文", None, "chinese", "{title}，作者：{author}。", "片头", "。！？；",
             cjk=True, sec_per_char=0.285, chunk_scale=0.35),
    Language("ja", "Japanese", "日本語", "ja", "japanese", "{title}、{author}著。", "オープニングクレジット",
             "。！？", cjk=True, sec_per_char=0.194, chunk_scale=0.4),
    Language("ko", "Korean", "한국어", "ko", "korean", "{title}, {author} 지음.", "오프닝 크레딧", "",
             sec_per_char=0.163, chunk_scale=0.6),
    Language("hi", "Hindi", "हिन्दी", None, None, "{title}, लेखक {author}।", "शुरुआती क्रेडिट", "।",
             sec_per_char=0.084),
    Language("ar", "Arabic", "العربية", "ar", None, "{title}، تأليف {author}.", "العناوين الافتتاحية",
             "؟۔", rtl=True, sec_per_char=0.105),
    Language("nl", "Dutch", "Nederlands", "nl", None, "{title}, door {author}.", "Openingstitels", "", sec_per_char=0.06),
]

_WARMUP = {'en': 'This is a short warm up sentence.', 'fr': 'Ceci est une courte phrase de préchauffage.', 'es': 'Esta es una breve frase de calentamiento.', 'de': 'Dies ist ein kurzer Satz zum Aufwärmen.', 'it': 'Questa è una breve frase di riscaldamento.', 'pt': 'Esta é uma frase curta de aquecimento.', 'ru': 'Это короткое предложение для разогрева.', 'zh': '这是一句简短的热身句子。', 'ja': 'これは短いウォームアップ用の文です。', 'ko': '이것은 짧은 준비 운동용 문장입니다.', 'hi': 'यह एक छोटा सा परीक्षण वाक्य है।', 'ar': 'هذه جملة قصيرة للإحماء.', 'nl': 'Dit is een korte opwarmzin.'}
_LANGUAGES = [replace(lang, warmup=_WARMUP[lang.code]) for lang in _LANGUAGES]
LANGUAGES: dict[str, Language] = {lang.code: lang for lang in _LANGUAGES}

# Regional spellings and common aliases -> registry code ("pt-BR" and "pt_br" are Portuguese).
_ALIASES = {"zh-cn": "zh", "zh-tw": "zh", "zh-hans": "zh", "zh-hant": "zh", "cmn": "zh", "jp": "ja",
            "pt-br": "pt", "pt-pt": "pt", "no": None}


def normalize_code(code: str | None) -> str | None:
    """'pt-BR', 'PT_br', 'es-MX', ' FR ' -> 'pt', 'pt', 'es', 'fr'. None when the language is not supported."""
    if not code:
        return None
    c = code.strip().lower().replace("_", "-")
    if c in _ALIASES:
        return _ALIASES[c]
    if c in LANGUAGES:
        return c
    base = c.split("-")[0]
    return base if base in LANGUAGES else None


def get(code: str) -> Language:
    """The language for `code` (any spelling `normalize_code` accepts). Raises KeyError for unsupported ones."""
    norm = normalize_code(code)
    if norm is None:
        raise KeyError(f"Unsupported language: {code!r}")
    return LANGUAGES[norm]


def announce(code: str, title: str, author: str) -> str:
    """What the audiobook says before chapter 1."""
    return get(code).announce.format(title=title, author=author)


def codes() -> list[str]:
    return [lang.code for lang in _LANGUAGES]
