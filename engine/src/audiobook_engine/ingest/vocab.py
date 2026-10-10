"""Per-language words for book ingest: front/back-matter titles, chapter labels, number words.

English and French keep their original patterns in classify.py (their behaviour is frozen); this
module adds the other eleven languages of the registry (es de it pt ru zh ja ko hi ar nl). Everything
here is matched on *folded* text: Unicode-normalised, case-folded, accents and Arabic vowel marks
removed, punctuation and bidirectional controls dropped, so "Índice", "INDICE" and "indice" are one
key and a right-to-left title carrying invisible direction marks equals the same title without them.

The phrases were written by the developers and should be reviewed by native speakers; ones we were
not sure of were left out rather than guessed.
"""

from __future__ import annotations

import re
import unicodedata

# --------------------------------------------------------------------------- folding

_APOSTROPHES = str.maketrans({"’": "'", "ʼ": "'", "‘": "'", "´": "'", "`": "'"})
# Arabic: tatweel and vowel marks are dropped; alef/yeh/teh-marbuta variants are unified.
_AR_DROP = set(range(0x064B, 0x0660)) | {0x0670, 0x0640} | set(range(0x06D6, 0x06EE))
_AR_MAP = {"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ى": "ي", "ة": "ه", "ؤ": "و", "ئ": "ي"}


def _fold_chars(text: str) -> list[tuple[str, bool]]:
    """(folded char, source char was lower case) pairs; separators are " "."""
    out: list[tuple[str, bool]] = []
    for ch in unicodedata.normalize("NFKC", text or "").translate(_APOSTROPHES):
        lower = ch.islower()
        for c in ch.casefold():
            o = ord(c)
            if o in _AR_DROP:
                continue
            if c in _AR_MAP:
                c = _AR_MAP[c]
            elif o < 0x250 or 0x400 <= o < 0x530:
                c = "".join(x for x in unicodedata.normalize("NFD", c) if not unicodedata.combining(x))
            cat = unicodedata.category(c[:1]) if c else "Zs"
            if cat == "Cf":  # zero-width joiners, bidirectional marks and embeddings
                continue
            out.append((c if (c.isalnum() or cat[0] == "M") else " ", lower))
    return out


def fold(text: str) -> str:
    """Words of `text`, case-folded and stripped of accents and punctuation, joined by single spaces."""
    return " ".join("".join(c for c, _ in _fold_chars(text)).split())


def fold_tokens(text: str) -> list[tuple[str, bool]]:
    """(folded word, starts with a lower-case letter) for each word of `text`."""
    tokens: list[tuple[str, bool]] = []
    cur: list[str] = []
    lower = False
    for c, low in _fold_chars(text):
        if c == " ":
            if cur:
                tokens.append(("".join(cur), lower))
                cur = []
            continue
        if not cur:
            lower = low
        cur.append(c)
    if cur:
        tokens.append(("".join(cur), lower))
    return tokens


CJK_RE = _CJK = re.compile(r"[぀-ヿ㐀-䶿一-鿿豈-﫿가-힯]")


def _compact(key: str) -> str | None:
    """`key` without spaces when it holds CJK/Hangul characters ("目 录" is "目录"), else None."""
    return key.replace(" ", "") if _CJK.search(key) else None


# --------------------------------------------------------------------------- front/back matter titles

# role -> (kind, {language: [titles]}). Titles are whole headings; digits after them are ignored.
# Words English and French already use as plain words ("Note", "Index", "Copyright") are not repeated:
# English and French titles keep their own patterns in classify.py.
_MATTER: dict[str, tuple[str, dict[str, list[str]]]] = {
    "cover": ("front", {
        "es": ["Portada", "Cubierta"], "de": ["Umschlag", "Einband"], "it": ["Copertina"],
        "pt": ["Capa"], "nl": ["Omslag"], "ru": ["Обложка"], "zh": ["封面"], "ja": ["表紙"],
        "ko": ["표지"], "ar": ["الغلاف"], "hi": ["आवरण", "मुखपृष्ठ"],
    }),
    "titlepage": ("front", {
        "es": ["Portadilla", "Página de título", "Anteportada"],
        "de": ["Titelseite", "Titelblatt", "Schmutztitel"],
        "it": ["Frontespizio", "Pagina del titolo"],
        "pt": ["Folha de rosto", "Página de título", "Anterrosto"],
        "nl": ["Titelpagina"], "ru": ["Титульный лист"], "zh": ["书名页", "扉页", "書名頁"],
        "ja": ["扉", "タイトルページ"], "ko": ["속표지"], "ar": ["صفحة العنوان"], "hi": ["शीर्षक पृष्ठ"],
    }),
    "toc": ("front", {
        "es": ["Índice", "Contenido", "Tabla de contenido", "Tabla de contenidos", "Índice de contenido"],
        "de": ["Inhaltsverzeichnis", "Inhalt", "Inhaltsübersicht"],
        "it": ["Indice", "Sommario", "Indice dei contenuti"],
        "pt": ["Índice", "Sumário", "Conteúdo", "Tabela de conteúdo"],
        "nl": ["Inhoudsopgave", "Inhoud"],
        "ru": ["Оглавление", "Содержание"],
        "zh": ["目录", "目錄"], "ja": ["目次"], "ko": ["목차", "차례"],
        "ar": ["فهرس", "فهرس المحتويات", "المحتويات", "قائمة المحتويات", "الفهرس"],
        "hi": ["विषय सूची", "विषय-सूची", "विषयसूची", "अनुक्रमणिका"],
    }),
    "copyright": ("front", {
        "es": ["Derechos de autor", "Derechos reservados", "Todos los derechos reservados", "Aviso legal",
               "Página de derechos de autor"],
        "de": ["Impressum", "Urheberrecht", "Rechtliche Hinweise", "Rechtshinweis", "Copyright-Hinweis"],
        "it": ["Diritti d'autore", "Diritti riservati", "Tutti i diritti riservati", "Note legali",
               "Nota legale"],
        "pt": ["Direitos autorais", "Direitos de autor", "Direitos reservados", "Todos os direitos reservados",
               "Ficha catalográfica", "Aviso legal"],
        "nl": ["Auteursrecht", "Colofon", "Alle rechten voorbehouden"],
        "ru": ["Авторские права", "Правовая информация", "Выходные данные", "Все права защищены"],
        "zh": ["版权", "版權", "版权页", "版權頁", "版权声明", "版權聲明", "版权信息", "版权所有"],
        "ja": ["著作権", "著作権表示", "版権", "奥付"],
        "ko": ["저작권", "판권", "판권 페이지", "저작권 페이지"],
        "ar": ["حقوق النشر", "حقوق الطبع", "حقوق الطبع والنشر", "حقوق الملكية", "جميع الحقوق محفوظة",
               "حقوق التأليف والنشر"],
        "hi": ["कॉपीराइट", "प्रतिलिप्यधिकार", "सर्वाधिकार सुरक्षित", "कॉपीराइट पृष्ठ"],
    }),
    "dedication": ("front", {
        "es": ["Dedicatoria"], "de": ["Widmung", "Zueignung"], "it": ["Dedica"], "pt": ["Dedicatória"],
        "nl": ["Opdracht"], "ru": ["Посвящение"], "zh": ["献词", "献辞"],
        "ja": ["献辞"], "ko": ["헌정", "헌사", "헌정사"], "ar": ["إهداء", "الإهداء", "اهداء"],
        "hi": ["समर्पण"],
    }),
    "epigraph": ("front", {
        "es": ["Epígrafe"], "it": ["Epigrafe"], "pt": ["Epígrafe"], "nl": ["Epigraaf"], "ru": ["Эпиграф"],
        "zh": ["题记", "題記"], "ja": ["エピグラフ", "題辞"], "ko": ["에피그래프"],
    }),
    "alsoby": ("front", {
        "es": ["Del mismo autor", "Otras obras del autor", "Obras del autor"],
        "it": ["Dello stesso autore"], "pt": ["Do mesmo autor", "Obras do autor", "Livros do autor"],
        "nl": ["Eerder verschenen", "Van dezelfde auteur"],
        "ru": ["Другие книги автора", "Книги автора"],
        "zh": ["作者其他作品", "作者的其他作品"], "hi": ["लेखक की अन्य पुस्तकें"],
    }),
    "illustrations": ("front", {
        "es": ["Lista de ilustraciones", "Índice de ilustraciones"],
        "de": ["Abbildungsverzeichnis", "Tabellenverzeichnis"],
        "it": ["Elenco delle illustrazioni", "Indice delle illustrazioni"],
        "pt": ["Lista de ilustrações", "Lista de figuras", "Lista de tabelas"],
        "nl": ["Lijst van afbeeldingen", "Lijst van illustraties"], "ru": ["Список иллюстраций"],
        "zh": ["插图目录", "图目录", "表目录"], "ja": ["図版一覧", "図表一覧"], "ko": ["그림 목차", "표 목차"],
        "ar": ["قائمة الصور", "قائمة الأشكال", "قائمة الجداول"], "hi": ["चित्र सूची", "तालिका सूची"],
    }),
    "index": ("back", {
        "es": ["Índice analítico", "Índice alfabético", "Índice onomástico", "Índice temático"],
        "de": ["Register", "Stichwortverzeichnis", "Sachregister", "Personenregister", "Namensregister"],
        "it": ["Indice analitico", "Indice dei nomi", "Indice alfabetico"],
        "pt": ["Índice remissivo", "Índice onomástico", "Índice alfabético"],
        "nl": ["Register", "Trefwoordenregister", "Personenregister", "Namenregister"],
        "ru": ["Указатель", "Алфавитный указатель", "Именной указатель", "Предметный указатель"],
        "zh": ["索引"], "ja": ["索引", "さくいん"], "ko": ["색인", "찾아보기"], "ar": ["كشاف"],
    }),
    "notes": ("back", {
        "es": ["Notas", "Notas finales", "Notas al pie"],
        "de": ["Anmerkungen", "Fußnoten", "Endnoten"],
        "it": ["Note finali", "Note a piè di pagina"],
        "pt": ["Notas", "Notas finais", "Notas de rodapé"],
        "nl": ["Noten", "Eindnoten", "Voetnoten", "Aantekeningen"],
        "ru": ["Примечания", "Примечание", "Сноски"],
        "zh": ["注释", "註釋", "注解", "註解", "脚注", "腳註", "尾注"],
        "ja": ["注", "注釈", "脚注", "尾注", "原注", "訳注"],
        "ko": ["주", "주석", "각주", "미주"],
        "ar": ["هوامش", "الهوامش", "حواشي", "الحواشي"],
        "hi": ["टिप्पणियाँ", "टिप्पणियां", "टिप्पणी", "पाद टिप्पणियाँ", "पादटिप्पणी"],
    }),
    "glossary": ("back", {
        "es": ["Glosario"], "de": ["Glossar"], "it": ["Glossario"], "pt": ["Glossário"],
        "nl": ["Woordenlijst", "Verklarende woordenlijst", "Glossarium"],
        "ru": ["Глоссарий", "Словарик"],
        "zh": ["词汇表", "詞彙表", "术语表", "術語表", "名词解释", "名詞解釋"],
        "ja": ["用語集", "用語解説"], "ko": ["용어집", "용어 해설"],
        "ar": ["المسرد", "مسرد المصطلحات", "معجم المصطلحات"], "hi": ["शब्दावली"],
    }),
    "bibliography": ("back", {
        "es": ["Bibliografía", "Referencias", "Obras citadas", "Fuentes", "Lecturas recomendadas",
               "Lecturas adicionales"],
        "de": ["Literaturverzeichnis", "Literatur", "Bibliographie", "Quellenverzeichnis", "Quellen",
               "Weiterführende Literatur", "Literaturhinweise"],
        "it": ["Bibliografia", "Riferimenti", "Fonti", "Letture consigliate"],
        "pt": ["Bibliografia", "Referências", "Referências bibliográficas", "Fontes", "Leituras adicionais"],
        "nl": ["Bibliografie", "Literatuur", "Literatuurlijst", "Bronnen", "Bronnenlijst", "Verder lezen"],
        "ru": ["Библиография", "Литература", "Список литературы", "Источники", "Рекомендуемая литература"],
        "zh": ["参考文献", "參考文獻", "参考书目", "參考書目", "参考资料", "參考資料"],
        "ja": ["参考文献", "参考資料", "文献目録"],
        "ko": ["참고문헌", "참고 문헌", "참고 자료"],
        "ar": ["المراجع", "قائمة المراجع", "المصادر", "المصادر والمراجع", "ثبت المراجع", "ببليوغرافيا"],
        "hi": ["संदर्भ", "संदर्भ सूची", "ग्रंथ सूची", "ग्रंथसूची", "संदर्भ ग्रंथ"],
    }),
    "acknowledgements": ("back", {
        "es": ["Agradecimientos", "Reconocimientos"],
        "de": ["Danksagung", "Danksagungen", "Dank"],
        "it": ["Ringraziamenti"], "pt": ["Agradecimentos"],
        "nl": ["Dankwoord", "Woord van dank", "Dankbetuiging"],
        "ru": ["Благодарности", "Благодарность"],
        "zh": ["致谢", "致謝", "鸣谢", "鳴謝", "谢辞", "謝辭"],
        "ja": ["謝辞"], "ko": ["감사의 글", "감사의 말"],
        "ar": ["شكر وتقدير", "شكر وعرفان", "كلمة شكر"], "hi": ["आभार", "आभार प्रदर्शन"],
    }),
    "about_author": ("back", {
        "es": ["Sobre el autor", "Acerca del autor", "Sobre la autora", "Acerca de la autora", "El autor",
               "La autora", "Sobre los autores"],
        "de": ["Über den Autor", "Über die Autorin", "Über die Autoren", "Über den Verfasser", "Zum Autor",
               "Zur Autorin", "Der Autor", "Die Autorin"],
        "it": ["L'autore", "L'autrice", "Sull'autore", "Sull'autrice", "Informazioni sull'autore",
               "Informazioni sull'autrice", "Note sull'autore", "Biografia dell'autore"],
        "pt": ["Sobre o autor", "Sobre a autora", "Sobre os autores", "Acerca do autor", "O autor", "A autora",
               "Biografia do autor"],
        "nl": ["Over de auteur", "Over de schrijver", "Over de schrijfster", "Over de auteurs", "De auteur"],
        "ru": ["Об авторе", "Об авторах", "Об авторе книги", "Биография автора", "Сведения об авторе"],
        "zh": ["关于作者", "關於作者", "作者简介", "作者簡介", "作者介绍", "作者介紹"],
        "ja": ["著者紹介", "著者略歴", "作者紹介", "著者について", "作者について", "著者プロフィール"],
        "ko": ["저자 소개", "작가 소개", "지은이 소개", "저자 약력", "작가에 대하여"],
        "ar": ["نبذة عن المؤلف", "عن المؤلف", "نبذة عن الكاتب", "عن الكاتب", "حول المؤلف", "نبذة عن المؤلفة",
               "عن المؤلفة", "تعريف بالمؤلف", "سيرة المؤلف"],
        "hi": ["लेखक परिचय", "लेखक के बारे में", "लेखक का परिचय", "लेखिका परिचय"],
    }),
    "about_publisher": ("back", {
        "es": ["Sobre la editorial", "Acerca de la editorial"], "de": ["Über den Verlag"],
        "it": ["Sull'editore", "Informazioni sull'editore"], "pt": ["Sobre a editora"],
        "nl": ["Over de uitgever", "Over de uitgeverij"], "ru": ["Об издательстве"],
        "zh": ["关于出版社", "關於出版社", "出版社简介", "出版社介绍"], "ja": ["出版社について"],
        "ko": ["출판사 소개"], "ar": ["عن الناشر", "نبذة عن الناشر", "عن دار النشر"],
        "hi": ["प्रकाशक के बारे में", "प्रकाशक परिचय"],
    }),
    "credits": ("back", {
        "es": ["Créditos"], "it": ["Crediti"], "pt": ["Créditos"], "ru": ["Над книгой работали"],
        "ja": ["クレジット"],
    }),
}

# folded title -> (kind, role); the compact (space-free) key is used for CJK/Hangul titles
_TITLES: dict[str, tuple[str, str]] = {}
_TITLES_COMPACT: dict[str, tuple[str, str]] = {}
# role -> set of folded titles (for "is this a notes heading", "is this a contents heading")
_BY_ROLE: dict[str, set[str]] = {}
for _role, (_kind, _langs) in _MATTER.items():
    for _titles in _langs.values():
        for _t in _titles:
            _k = fold(_t)
            _TITLES.setdefault(_k, (_kind, _role))
            _BY_ROLE.setdefault(_role, set()).add(_k)
            _c = _compact(_k)
            if _c:
                _TITLES_COMPACT.setdefault(_c, (_kind, _role))
                _BY_ROLE[_role].add(_c)


def matter_role(title: str) -> tuple[str, str] | None:
    """(kind, role) when a whole heading names front or back matter in one of the added languages."""
    words = fold(title).split()
    while words and words[-1].isdigit():
        words.pop()
    if not words:
        return None
    key = " ".join(words)
    hit = _TITLES.get(key)
    if hit:
        return hit
    c = _compact(key)
    return _TITLES_COMPACT.get(c) if c else None


def is_role_title(title: str, role: str) -> bool:
    words = fold(title).split()
    while words and words[-1].isdigit():
        words.pop()
    key = " ".join(words)
    keys = _BY_ROLE.get(role, set())
    if key in keys:
        return True
    c = _compact(key)
    return bool(c) and c in keys


_TOC_PHRASES = sorted(
    {tuple(k.split()) for k in _BY_ROLE["toc"] if " " in k or k},
    key=len, reverse=True,
)


def contents_heading(paragraph: str) -> bool:
    """A paragraph that opens with a contents heading in one of the added languages, then entries or nothing.

    Prose that merely starts with the word ("Contenido de la caja...") is not a heading: after the
    phrase there must be nothing, a number, or a word that does not start in lower case.
    """
    toks = fold_tokens(paragraph[:200])
    if not toks:
        return False
    words = tuple(w for w, _ in toks)
    for phrase in _TOC_PHRASES:
        n = len(phrase)
        if words[:n] == phrase:
            if len(toks) == n:
                return True
            w, low = toks[n]
            return w.isdigit() or not low
    # CJK titles can be glued to their first entry or spaced out ("目 录")
    head = "".join(words)
    for c in (k for k in _BY_ROLE["toc"] if _CJK.search(k)):
        if head == c.replace(" ", ""):
            return True
    return False


# Rights notices inside a short opening section (the text of the copyright page, not its title).
COPYRIGHT_PHRASES = [
    "todos los derechos reservados", "reservados todos los derechos", "derechos reservados",
    "alle rechte vorbehalten", "tutti i diritti riservati", "todos os direitos reservados",
    "alle rechten voorbehouden", "все права защищены", "版权所有", "版權所有", "無断転載", "無断複製",
    "無断で複写", "무단 전재", "무단 복제", "모든 권리 보유", "جميع الحقوق محفوظة", "جميع الحقوق محفوظه",
    "सर्वाधिकार सुरक्षित", "depósito legal",
]


# --------------------------------------------------------------------------- chapter labels

# Words that label a heading when followed by a number ("Capítulo 3", "Kapitel IV", "Глава 5").
CHAPTER_WORDS = {
    "es": ["capítulo", "capitulo"], "de": ["kapitel"], "it": ["capitolo"], "pt": ["capítulo", "capitulo", "cap."],
    "nl": ["hoofdstuk"], "ru": ["глава", "гл."], "ar": ["الفصل", "فصل"], "hi": ["अध्याय", "प्रकरण"],
}
PART_WORDS = {
    "es": ["parte", "libro", "tomo", "volumen"], "de": ["teil", "buch"],
    "it": ["parte", "libro", "volume"], "pt": ["parte", "livro", "tomo", "volume"], "nl": ["deel", "boek"],
    "ru": ["часть", "книга", "том"], "ar": ["الجزء", "جزء", "الباب", "باب", "القسم", "الكتاب"],
    "hi": ["भाग", "खंड", "खण्ड", "पर्व"],
}
OTHER_LABEL_WORDS = {
    "es": ["prólogo", "prologo", "epílogo", "epilogo", "acto", "escena", "sección", "seccion", "apéndice",
           "apendice"],
    "de": ["prolog", "epilog", "akt", "szene", "abschnitt", "anhang", "aufzug"],
    "it": ["prologo", "epilogo", "atto", "scena", "sezione", "appendice"],
    "pt": ["prólogo", "prologo", "epílogo", "epilogo", "ato", "cena", "seção", "secção", "apêndice", "apendice"],
    "nl": ["proloog", "epiloog", "bedrijf", "scène", "scene", "afdeling", "bijlage"],
    "ru": ["пролог", "эпилог", "действие", "сцена", "раздел", "приложение"],
}


def _words(table: dict[str, list[str]]) -> set[str]:
    return {fold(w) for ws in table.values() for w in ws} | {w.casefold() for ws in table.values() for w in ws}


LABEL_WORDS: set[str] = _words(CHAPTER_WORDS) | _words(PART_WORDS) | _words(OTHER_LABEL_WORDS)
_PART_FOLDED = {fold(w) for ws in PART_WORDS.values() for w in ws}
_CHAPTER_FOLDED = {fold(w) for ws in CHAPTER_WORDS.values() for w in ws}

NUMBER_WORDS: set[str] = set(
    # Spanish
    "uno tres cuatro cinco seis siete ocho nueve diez doce trece catorce quince dieciséis diecisiete "
    "dieciocho diecinueve veinte treinta cuarenta cincuenta sesenta setenta ochenta noventa cien ciento "
    "primero primer segundo tercero tercer cuarto quinto sexto séptimo octavo noveno décimo "
    # German
    "eins zwei drei vier fünf sechs sieben acht neun zehn zwölf dreizehn vierzehn fünfzehn sechzehn "
    "siebzehn achtzehn neunzehn zwanzig dreißig vierzig fünfzig hundert "
    "erstes zweites drittes viertes fünftes sechstes siebtes achtes neuntes zehntes "
    "erster zweiter dritter vierter fünfter sechster siebter achter neunter zehnter "
    # Italian
    "uno due tre quattro cinque sei sette otto nove dieci undici dodici tredici quattordici quindici sedici "
    "diciassette diciotto diciannove venti trenta quaranta cinquanta sessanta settanta ottanta novanta cento "
    "primo secondo terzo quarto quinto sesto settimo ottavo nono decimo "
    # Portuguese
    "uma dois duas três quatro cinco seis sete oito nove dez onze doze treze catorze quatorze quinze "
    "dezesseis dezasseis dezessete dezassete dezoito dezenove vinte trinta quarenta cinquenta sessenta setenta "
    "oitenta noventa cem "
    "primeiro segunda terceiro quarta quinta sexta sétimo oitavo nono décimo "
    # Dutch
    "een twee drie vier vijf zes zeven acht negen tien twaalf dertien veertien vijftien zestien zeventien "
    "achttien negentien twintig dertig veertig vijftig zestig zeventig tachtig negentig honderd "
    "eerste tweede derde vierde vijfde zesde zevende achtste negende tiende "
    # Russian
    "один одна одно два две три четыре пять шесть семь восемь девять десять одиннадцать двенадцать "
    "тринадцать четырнадцать пятнадцать шестнадцать семнадцать восемнадцать девятнадцать двадцать тридцать "
    "первая вторая третья четвёртая четвертая пятая шестая седьмая восьмая девятая десятая "
    "первый второй третий четвёртый четвертый пятый шестой седьмой восьмой девятый десятый".split()
)
NUMBER_WORDS |= {fold(w) for w in NUMBER_WORDS}
# Numbers that are also ordinary words of English or French ("once", "elf", "um", "dos"): accepted only
# straight after a chapter label ("Capítulo dos"), never as a bare number.
AFTER_LABEL_NUMBERS = {"dos", "once", "elf", "um"}

# --- numerals of the CJK and Hangul scripts, Arabic ordinals, Hindi numbers

_CJK_DIGITS = {
    "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "两": 2,
    "兩": 2, "壹": 1, "贰": 2, "貳": 2, "叁": 3, "參": 3, "肆": 4, "伍": 5, "陆": 6, "陸": 6, "柒": 7, "捌": 8,
    "玖": 9,
    # Korean Sino numerals
    "일": 1, "이": 2, "삼": 3, "사": 4, "오": 5, "육": 6, "칠": 7, "팔": 8, "구": 9, "영": 0, "공": 0,
}
_CJK_UNITS = {"十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1000, "仟": 1000, "万": 10000, "萬": 10000,
              "십": 10, "백": 100, "천": 1000, "만": 10000}


def cjk_int(token: str) -> int | None:
    """二十三 -> 23, 十二 -> 12, 一百零五 -> 105, 三 -> 3, 二〇 -> 20; None when it is not a numeral."""
    token = unicodedata.normalize("NFKC", token or "").strip()
    if not token or not all(c in _CJK_DIGITS or c in _CJK_UNITS for c in token):
        return None
    if all(c in _CJK_DIGITS for c in token):  # positional: 二〇 -> 20, 一二 -> 12
        return int("".join(str(_CJK_DIGITS[c]) for c in token))
    total, section, number = 0, 0, 0
    for c in token:
        if c in _CJK_DIGITS:
            number = _CJK_DIGITS[c]
        else:
            unit = _CJK_UNITS[c]
            if unit == 10000:
                total += (section + number) * unit
                section = number = 0
            else:
                section += (number or 1) * unit  # "十二" has an implicit one
                number = 0
    return total + section + number or None


_AR_ORDINALS = {
    "الاول": 1, "الاولي": 1, "الثاني": 2, "الثانيه": 2, "الثالث": 3, "الثالثه": 3, "الرابع": 4, "الرابعه": 4,
    "الخامس": 5, "الخامسه": 5, "السادس": 6, "السادسه": 6, "السابع": 7, "السابعه": 7, "الثامن": 8,
    "الثامنه": 8, "التاسع": 9, "التاسعه": 9, "العاشر": 10, "العاشره": 10,
}
_HI_WORDS = {
    "एक": 1, "दो": 2, "तीन": 3, "चार": 4, "पाँच": 5, "पांच": 5, "छह": 6, "छः": 6, "छ": 6, "सात": 7, "आठ": 8,
    "नौ": 9, "दस": 10, "ग्यारह": 11, "बारह": 12,
    "पहला": 1, "पहली": 1, "दूसरा": 2, "दूसरी": 2, "तीसरा": 3, "तीसरी": 3, "चौथा": 4, "चौथी": 4,
    "पाँचवाँ": 5, "पांचवां": 5, "पाँचवीं": 5, "पांचवीं": 5,
}
_HI_ORDINAL_FIRST = {"पहला", "पहली", "दूसरा", "दूसरी", "तीसरा", "तीसरी", "चौथा", "चौथी", "पाँचवाँ", "पांचवां",
                     "पाँचवीं", "पांचवीं"}


def _ar_ordinal(token: str) -> int | None:
    t = fold(token)
    if t in _AR_ORDINALS:
        return _AR_ORDINALS[t]
    return None


def _number_value(token: str) -> int | None:
    """A heading number written as digits, a CJK/Hangul numeral, an Arabic ordinal or a Hindi number word."""
    token = unicodedata.normalize("NFKC", token or "").strip()
    if not token:
        return None
    if token.isdecimal():
        return int(token)
    v = cjk_int(token)
    if v is not None:
        return v
    v = _ar_ordinal(token)
    if v is not None:
        return v
    return _HI_WORDS.get(token)


def is_number_word(word: str) -> bool:
    """A number in any of the added languages (digits excluded): "tres", "drei", "三", "الثالث", "तीन"."""
    w = fold(word)
    if not w:
        return False
    if w in NUMBER_WORDS:
        return True
    return cjk_int(word) is not None or _ar_ordinal(word) is not None or word.strip() in _HI_WORDS


# "第三章", "第3話", "第12回": a Chinese/Japanese counter after 第 (章 chapter, 節/节 section, 話/话 episode,
# 回 round/chapter, 部 part, 卷/巻 volume, 篇/編 part, 幕 act, 場/场 scene, 課/课 lesson, 集 collection).
_CJK_LABEL = re.compile(
    r"^\s*第\s*([0-9一二三四五六七八九十百千万零〇两兩壹贰叁肆伍陆柒捌玖拾]+)\s*(章|節|节|話|话|回|部|卷|巻|篇|編|编|幕|場|场|課|课|集)"
)
_CJK_PART_COUNTERS = {"部", "卷", "巻", "篇", "編", "编", "集"}
# Korean: "제3장", "1장", "제2부"
_KO_LABEL = re.compile(
    r"^\s*(?:제\s*([0-9]+|[일이삼사오육칠팔구십백]+)|([0-9]+))\s*(장|부|권|편|화|회|절|막)(?![가-힣])"
)
_KO_PART_COUNTERS = {"부", "권", "편"}
_AR_LABEL = re.compile(r"^\s*(الفصل|فصل|الباب|باب|الجزء|جزء|القسم|الكتاب|الحلقة)\s+(\S+)")
_AR_PART = {"الباب", "باب", "الجزء", "جزء", "القسم", "الكتاب"}
_HI_LABEL = re.compile(r"^\s*(अध्याय|प्रकरण|भाग|खंड|खण्ड|पर्व)\s*[:\-–]?\s*(\S+)")
_HI_LABEL_AFTER = re.compile(r"^\s*(\S+)\s+(अध्याय|प्रकरण|भाग|खंड|खण्ड|पर्व)(?!\S)")
_HI_PART = {"भाग", "खंड", "खण्ड", "पर्व"}
_LATIN_LABEL = re.compile(
    r"^\s*(?i:(" + "|".join(sorted((re.escape(w) for w in LABEL_WORDS), key=len, reverse=True))
    + r"))(?:\s*(\d{1,4})|\s+((?=[IVXLCDM])M{0,3}(?:CM|CD|D?C{0,3})(?:XC|XL|L?X{0,3})(?:IX|IV|V?I{0,3})))(?![^\W\d_])"
)
_BARE_CJK = re.compile(r"^\s*([一二三四五六七八九十百千零〇]+)\s*[、．.]\s*\S")


def _labelled(title: str) -> tuple[str, str, int, int] | None:
    """(group, counter, number, end offset) of the label at the start of the (NFKC, mark-free) title."""
    text = "".join(c for c in unicodedata.normalize("NFKC", title or "") if unicodedata.category(c) != "Cf").strip()
    if not text:
        return None
    m = _CJK_LABEL.match(text)
    if m:
        n = _number_value(m.group(1))
        if n:
            return ("part" if m.group(2) in _CJK_PART_COUNTERS else "chapter", m.group(2), n, m.end()), text
    m = _KO_LABEL.match(text)
    if m:
        n = _number_value(m.group(1) or m.group(2))
        if n:
            return ("part" if m.group(3) in _KO_PART_COUNTERS else "chapter", m.group(3), n, m.end()), text
    m = _AR_LABEL.match(text)
    if m:
        # "الفصل الحادي عشر" (eleventh) is two words; its first word alone is not a number
        n = _number_value(m.group(2).rstrip(".:،-"))
        if n:
            return ("part" if m.group(1) in _AR_PART else "chapter", fold(m.group(1)), n, m.end()), text
    m = _HI_LABEL.match(text)
    if m:
        n = _number_value(m.group(2).rstrip(".:।"))
        if n:
            return ("part" if m.group(1) in _HI_PART else "chapter", m.group(1), n, m.end()), text
    m = _HI_LABEL_AFTER.match(text)
    if m and m.group(1) in _HI_WORDS:
        return ("part" if m.group(2) in _HI_PART else "chapter", m.group(2), _HI_WORDS[m.group(1)], m.end()), text
    m = _LATIN_LABEL.match(text)
    if m:
        n = int(m.group(2)) if m.group(2) else _roman(m.group(3))
        if n:
            return ("part" if fold(m.group(1)) in _PART_FOLDED else "chapter", fold(m.group(1)), n, m.end()), text
    return None


def labelled_number(title: str) -> tuple[str, str, int] | None:
    """(group, counter, number) for a heading like "第三章", "제2장", "الفصل الأول", "अध्याय 4", "Capítulo 3".

    group is "chapter" or "part"; counter is the label itself so that sequences can be compared
    ("章" with "章"). Only the headings of the added languages: English and French labels are
    handled by the callers' own patterns.
    """
    hit = _labelled(title)
    return hit[0][:3] if hit else None


def label_only(title: str) -> bool:
    """The whole heading is a label and its number ("第三章", "الفصل الأول.", "Capítulo 3:"), nothing after."""
    hit = _labelled(title)
    if not hit:
        return False
    (_g, _c, _n, end), text = hit
    return not fold(text[end:])


_ROMAN_VALUES = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}


def _roman(token: str) -> int | None:
    token = token.upper()
    if not token or not all(c in _ROMAN_VALUES for c in token):
        return None
    total = 0
    for a, b in zip(token, token[1:] + " "):
        v = _ROMAN_VALUES[a]
        total += -v if b != " " and _ROMAN_VALUES[b] > v else v
    return total


def heading_group(title: str) -> str | None:
    """"chapter" or "part" when the heading starts with a chapter/part label of the added languages."""
    hit = labelled_number(title)
    return hit[0] if hit else None


def bare_cjk_number(title: str) -> int | None:
    """"一、概述" or "二．方法": a Chinese numeral heading prefix, as its number."""
    m = _BARE_CJK.match(unicodedata.normalize("NFKC", title or ""))
    return cjk_int(m.group(1)) if m else None
