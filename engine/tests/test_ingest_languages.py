"""Book ingest in the 13 languages: detection, metadata spellings, front/back matter, chapter headings,
listening-time estimates, and synthetic EPUBs and PDFs per language.

The paragraphs below were written for these tests (no published text). They are ordinary narrative sentences,
long enough to be detected on their own.
"""

from __future__ import annotations

import textwrap
from pathlib import Path

import pymupdf
import pytest
from ebooklib import epub

from audiobook_engine import languages
from audiobook_engine.ingest import read_book
from audiobook_engine.ingest import vocab
from audiobook_engine.ingest.classify import (
    classify_section,
    detect_language,
    front_matter_signals,
    is_supported_language,
    looks_like_title,
    matter_title,
    normalize_language,
    unsupported_language_message,
)
from audiobook_engine.ingest.epub import _number_of
from audiobook_engine.ingest.estimate import LangSection, apply_language, estimate_seconds, seconds_per_char
from audiobook_engine.models import SECONDS_PER_CHAR, Section

from . import fixtures as fx

# --------------------------------------------------------------------------- text of the tests

P = {
    "en": "The morning train was late again, and the passengers stood on the platform with their collars turned up against the wind. Nobody spoke. A boy with a red scarf kept looking at the clock above the ticket office, as if staring at it might make the hands move faster. When the train finally arrived, it was so crowded that they all had to squeeze together near the doors. She had been thinking about the letter all week and had not yet decided what she would say to him.",
    "fr": "Le matin, le train avait encore du retard, et les voyageurs attendaient sur le quai, le col relevé à cause du vent. Personne ne parlait. Un garçon à l'écharpe rouge regardait sans cesse l'horloge au-dessus du guichet, comme si cela pouvait faire avancer les aiguilles. Quand le train est enfin arrivé, il était si plein que tout le monde a dû se serrer près des portes. Elle pensait à cette lettre depuis une semaine et n'avait pas encore décidé ce qu'elle lui dirait.",
    "es": "Aquella mañana el tren llegó tarde otra vez, y los pasajeros esperaban en el andén con el cuello del abrigo levantado por el viento. Nadie hablaba. Un niño con una bufanda roja miraba el reloj sobre la taquilla, como si mirarlo fuera a mover las agujas más rápido. Cuando por fin llegó el tren, estaba tan lleno que todos tuvieron que apretarse junto a las puertas. Ella llevaba toda la semana pensando en la carta y todavía no había decidido qué le diría. Sabía que, si no hablaba pronto, ya sería demasiado tarde para todo.",
    "de": "Der Morgenzug hatte wieder einmal Verspätung, und die Fahrgäste standen mit hochgeschlagenen Kragen auf dem Bahnsteig, weil der Wind so kalt war. Niemand sprach. Ein Junge mit einem roten Schal sah immer wieder zu der Uhr über dem Fahrkartenschalter, als würden sich die Zeiger schneller bewegen, wenn er sie nur lange genug anstarrte. Als der Zug endlich kam, war er so voll, dass sich alle an den Türen zusammendrängen mussten. Sie dachte schon die ganze Woche an den Brief und hatte noch nicht entschieden, was sie ihm sagen würde.",
    "it": "Quella mattina il treno era di nuovo in ritardo, e i passeggeri aspettavano sulla banchina con il bavero alzato per il vento. Nessuno parlava. Un ragazzo con una sciarpa rossa guardava in continuazione l'orologio sopra la biglietteria, come se guardarlo potesse far muovere più in fretta le lancette. Quando il treno arrivò finalmente, era così pieno che tutti dovettero stringersi vicino alle porte. Lei pensava alla lettera da tutta la settimana e non aveva ancora deciso che cosa gli avrebbe detto.",
    "pt": "Naquela manhã o trem atrasou outra vez, e os passageiros esperavam na plataforma com a gola do casaco levantada por causa do vento. Ninguém falava. Um menino com um cachecol vermelho olhava o tempo todo para o relógio em cima da bilheteria, como se olhar para ele pudesse fazer os ponteiros andarem mais depressa. Quando o trem finalmente chegou, estava tão cheio que todos tiveram de se apertar perto das portas. Ela vinha pensando na carta a semana inteira e ainda não tinha decidido o que diria a ele.",
    "nl": "De ochtendtrein had weer eens vertraging, en de reizigers stonden op het perron met opgeslagen kragen vanwege de wind. Niemand zei iets. Een jongen met een rode sjaal keek steeds naar de klok boven het loket, alsof de wijzers sneller zouden gaan als hij er maar lang genoeg naar staarde. Toen de trein eindelijk kwam, was hij zo vol dat iedereen zich bij de deuren moest samenpersen. Ze dacht al de hele week aan de brief en had nog niet besloten wat ze tegen hem zou zeggen.",
    "ru": "Утренний поезд снова опаздывал, и пассажиры стояли на платформе, подняв воротники из-за холодного ветра. Никто не разговаривал. Мальчик в красном шарфе всё время поглядывал на часы над кассой, словно от этого стрелки могли пойти быстрее. Когда поезд наконец пришёл, он оказался так набит, что всем пришлось тесниться у дверей. Она думала об этом письме всю неделю и всё ещё не решила, что скажет ему.",
    "zh": "早晨的火车又晚点了，乘客们站在站台上，顶着寒风把衣领竖了起来。没有人说话。一个戴着红围巾的男孩不停地望着售票处上方的时钟，仿佛只要盯得够久，指针就会走得快一些。火车终于进站时，车厢里挤得满满的，大家只好紧紧地挤在车门附近。她整个星期都在想那封信，却还没有决定该对他说些什么。",
    "ja": "朝の電車はまた遅れていて、乗客たちは風が冷たいので襟を立てたままホームに立っていた。誰も口をきかなかった。赤いマフラーをした男の子が、切符売り場の上の時計を何度も見上げていた。見つめていれば針が早く進むとでも思っているようだった。やっと電車が着いたとき、中はひどく混んでいて、みんなドアのそばに身を寄せ合うしかなかった。彼女は一週間ずっとあの手紙のことを考えていたが、彼に何と言うかはまだ決めていなかった。",
    "ko": "아침 기차가 또 늦어서 승객들은 찬 바람 때문에 옷깃을 세운 채 승강장에 서 있었다. 아무도 말을 하지 않았다. 빨간 목도리를 두른 남자아이가 매표소 위의 시계를 계속 올려다보았다. 오래 쳐다보면 시곗바늘이 더 빨리 움직일 것처럼 말이다. 기차가 마침내 도착했을 때는 너무 붐벼서 모두가 문 근처에 몸을 바싹 붙여야 했다. 그녀는 일주일 내내 그 편지를 생각했지만 그에게 무슨 말을 할지 아직 정하지 못했다.",
    "hi": "सुबह की गाड़ी फिर से देर से आई, और यात्री ठंडी हवा के कारण कॉलर ऊपर उठाए हुए प्लेटफ़ॉर्म पर खड़े थे। कोई कुछ नहीं बोला। लाल मफ़लर पहने एक लड़का बार-बार टिकट खिड़की के ऊपर लगी घड़ी की ओर देख रहा था, मानो देखते रहने से सुइयाँ तेज़ चलने लगेंगी। जब गाड़ी आख़िर आई तो वह इतनी भरी हुई थी कि सबको दरवाज़ों के पास सटकर खड़ा होना पड़ा। वह पूरे हफ़्ते उस चिट्ठी के बारे में सोचती रही थी और अब तक यह तय नहीं कर पाई थी कि उससे क्या कहेगी।",
    "ar": "تأخر قطار الصباح مرة أخرى، وكان الركاب يقفون على الرصيف وقد رفعوا ياقات معاطفهم بسبب الريح الباردة. لم يتكلم أحد. كان صبي يلف حول عنقه وشاحاً أحمر ينظر مراراً إلى الساعة المعلقة فوق شباك التذاكر، كأن النظر إليها سيجعل العقارب تتحرك أسرع. وعندما وصل القطار أخيراً كان مزدحماً إلى درجة أن الجميع اضطروا إلى التزاحم قرب الأبواب. كانت تفكر في تلك الرسالة طوال الأسبوع ولم تقرر بعد ما الذي ستقوله له.",
}
OTHER = {  # languages outside the 13, told apart by their script or letters
    "fa": "قطار صبح دوباره دیر کرد و مسافران در حالی که یقه‌ی پالتوهایشان را از سرمای باد بالا کشیده بودند روی سکو ایستاده بودند. هیچ‌کس حرفی نمی‌زد. پسری با شال قرمز مدام به ساعت بالای باجه نگاه می‌کرد. وقتی قطار بالاخره رسید آن‌قدر شلوغ بود که همه مجبور شدند کنار درها به هم بچسبند. او تمام هفته به آن نامه فکر کرده بود و هنوز تصمیم نگرفته بود که به او چه بگوید.",
    "ur": "صبح کی گاڑی پھر دیر سے آئی اور مسافر ٹھنڈی ہوا کی وجہ سے کالر اٹھائے پلیٹ فارم پر کھڑے تھے۔ کوئی کچھ نہیں بولا۔ سرخ مفلر والا ایک لڑکا بار بار ٹکٹ گھر کے اوپر لگی گھڑی کی طرف دیکھ رہا تھا۔ جب گاڑی آخر کار آئی تو اتنی بھری ہوئی تھی کہ سب کو دروازوں کے پاس سمٹ کر کھڑا ہونا پڑا۔",
    "uk": "Ранковий потяг знову запізнювався, і пасажири стояли на пероні, піднявши коміри через холодний вітер. Ніхто не розмовляв. Хлопчик у червоному шарфі раз у раз поглядав на годинник над касою, ніби від цього стрілки могли піти швидше. Коли потяг нарешті прибув, він був такий переповнений, що всім довелося тіснитися біля дверей. Вона думала про той лист цілий тиждень і досі не вирішила, що йому скаже.",
    "el": "Το πρωινό τρένο άργησε ξανά, και οι επιβάτες στέκονταν στην αποβάθρα με σηκωμένους γιακάδες εξαιτίας του κρύου ανέμου. Κανείς δεν μιλούσε. Ένα αγόρι με κόκκινο κασκόλ κοιτούσε συνεχώς το ρολόι πάνω από το εκδοτήριο, σαν να μπορούσε να κινήσει τους δείκτες πιο γρήγορα.",
    "pl": "Poranny pociąg znowu się spóźniał, a pasażerowie stali na peronie z podniesionymi kołnierzami z powodu zimnego wiatru. Nikt nie rozmawiał. Chłopiec w czerwonym szaliku co chwilę spoglądał na zegar nad kasą, jakby od tego wskazówki mogły poruszać się szybciej. Kiedy pociąg wreszcie przyjechał, był tak zatłoczony, że wszyscy musieli się ścisnąć przy drzwiach. Przez cały tydzień myślała o tym liście i nadal nie wiedziała, co mu powie.",
}
ALL = list(P)  # the 13 codes
NEW = [c for c in ALL if c not in ("en", "fr")]
ESTIMATE_BY_LANGUAGE = {c: languages.get(c).sec_per_char for c in ALL}


# --------------------------------------------------------------------------- 1. detection

@pytest.mark.parametrize("lang", ALL)
def test_detect_language_each_of_the_13(lang):
    assert detect_language(P[lang]) == lang
    assert detect_language(P[lang] * 4) == lang


@pytest.mark.parametrize("code, text", [(c, t) for c, t in OTHER.items() if c in ("fa", "ur", "uk", "el", "pl")])
def test_detect_language_other_languages_are_not_forced_into_the_13(code, text):
    # told apart where the script or its letters allow it; Polish (Latin script, no list) is not guessed
    expected = None if code == "pl" else code
    assert detect_language(text * 2) == expected


@pytest.mark.parametrize("lang", ALL)
def test_detect_language_tiny_texts_return_none(lang):
    assert detect_language(P[lang].split(".")[0][:25]) is None


@pytest.mark.parametrize("text", ["", "   ", "12345 67890 ...", "!!! ??? ***", "Hello world.", "你好。", "はい。", "Привет!"])
def test_detect_language_empty_and_tiny_inputs(text):
    assert detect_language(text) is None


def test_detect_language_works_on_text_without_whitespace():
    zh = P["zh"].replace(" ", "")
    assert " " not in zh and detect_language(zh) == "zh"
    assert detect_language(P["ja"].replace("、", "")) == "ja"


def test_detect_language_han_only_is_chinese_and_any_kana_is_japanese():
    han_only = "东京都内的企业开发了一项新技术。国内外的市场都在关注这件事。政府也决定提供支持，推动研究工作继续进行。"
    assert detect_language(han_only) == "zh"
    kanji_heavy = "東京都内の企業が新技術を開発した。国内外の市場への展開を目指す。政府の支援も受けて研究を進める方針だ。"
    assert detect_language(kanji_heavy) == "ja"  # mostly kanji, but the particles are kana
    assert detect_language(han_only * 4 + "ありがとう。") == "zh"  # one stray kana word does not make it Japanese
    assert detect_language(han_only + "ありがとうございます、よろしくお願いします。" * 3) == "ja"


def test_detect_language_mixed_scripts():
    ru = P["ru"].replace("Мальчик", "Peter Smith и Мальчик") + " Anna Karenina, London, Paris, New York Times."
    assert detect_language(ru) == "ru"  # a Russian book with Latin names
    assert detect_language(P["en"] * 3 + " 你好，世界。 こんにちは。") == "en"  # an English book with a phrase
    assert detect_language(P["zh"] + " Apple Inc. and Google, iPhone 15.") == "zh"
    assert detect_language(P["ko"] + " Seoul, KTX, Busan.") == "ko"
    assert detect_language(P["ar"] + " Paris, London, 2024.") == "ar"
    assert detect_language(P["hi"] + " Delhi, Mumbai, WhatsApp.") == "hi"


def test_detect_language_arabic_script_tells_persian_and_urdu_from_arabic():
    assert detect_language(P["ar"] * 2) == "ar"
    assert detect_language(OTHER["fa"] * 2) == "fa"
    assert detect_language(OTHER["ur"] * 2) == "ur"


def test_detect_language_cyrillic_tells_ukrainian_from_russian():
    assert detect_language(P["ru"] * 2) == "ru"
    assert detect_language(OTHER["uk"] * 2) == "uk"


@pytest.mark.parametrize("other", ["en", "fr"])
def test_detect_language_en_fr_keep_their_vote_when_other_languages_are_listed(other):
    # the extended stop-word lists must not take English or French text for a sibling
    assert detect_language(P[other] * 3) == other


# --------------------------------------------------------------------------- 2. language values

@pytest.mark.parametrize(
    "value, expected",
    [
        ("pt-BR", "pt"), ("pt_br", "pt"), ("PT-pt", "pt"), ("pt", "pt"), ("por", "pt"), ("Português", "pt"),
        ("Portuguese", "pt"), ("Brazilian Portuguese", "pt"), ("Português (Brasil)", "pt"),
        ("zh-CN", "zh"), ("zh-Hans", "zh"), ("zh-Hans-CN", "zh"), ("zh-TW", "zh"), ("zh_tw", "zh"),
        ("zh-Hant", "zh"), ("chi", "zh"), ("zho", "zh"), ("cmn", "zh"), ("Chinese", "zh"), ("中文", "zh"),
        ("简体中文", "zh"), ("繁體中文", "zh"), ("Simplified Chinese", "zh"), ("Mandarin", "zh"),
        ("es-MX", "es"), ("es-419", "es"), ("es_AR", "es"), ("spa", "es"), ("Español", "es"), ("Spanish", "es"),
        ("espanol", "es"), ("castellano", "es"),
        ("ja", "ja"), ("ja-JP", "ja"), ("jpn", "ja"), ("Japanese", "ja"), ("日本語", "ja"),
        ("ko", "ko"), ("ko-KR", "ko"), ("kor", "ko"), ("Korean", "ko"), ("한국어", "ko"),
        ("hi", "hi"), ("hi-IN", "hi"), ("hin", "hi"), ("Hindi", "hi"), ("हिन्दी", "hi"), ("हिंदी", "hi"),
        ("ar", "ar"), ("ar-EG", "ar"), ("ar_SA", "ar"), ("ara", "ar"), ("arb", "ar"), ("Arabic", "ar"),
        ("العربية", "ar"),
        ("nl", "nl"), ("nl-BE", "nl"), ("nld", "nl"), ("dut", "nl"), ("Dutch", "nl"), ("Nederlands", "nl"),
        ("Vlaams", "nl"),
        ("ru", "ru"), ("ru-RU", "ru"), ("rus", "ru"), ("Russian", "ru"), ("Русский", "ru"),
        ("de-AT", "de"), ("Deutsch", "de"), ("it-IT", "it"), ("Italiano", "it"),
        ("en-GB", "en"), ("fr-CA", "fr"), ("eng", "en"), ("Français", "fr"),
        # outside the 13: kept as the language they are, never mapped onto one of the 13
        ("pl", "pl"), ("pl-PL", "pl"), ("Polish", "pl"), ("el", "el"), ("fas", "fa"), ("Persian", "fa"),
        ("uk", "uk"),
        # no language at all
        ("und", None), ("mul", None), ("", None), (None, None), ("zz", None), ("???", None),
        # bidirectional marks around the value do not matter
        ("‏ar‏", "ar"), ("‫العربية‬", "ar"),
    ],
)
def test_normalize_language_spellings(value, expected):
    assert normalize_language(value) == expected


def test_normalize_language_never_returns_a_non_registry_code_for_the_13_spellings():
    for code in ALL:
        assert languages.normalize_code(normalize_language(code)) == code
        native = languages.get(code).native
        assert normalize_language(native) == code, native
        assert normalize_language(languages.get(code).name) == code


def test_supported_and_unsupported_message():
    assert all(is_supported_language(c) for c in ALL)
    assert not any(is_supported_language(c) for c in ("pl", "el", "fa", "", None))
    msg = unsupported_language_message("pl")
    assert "'pl'" in msg and "Audiobook Studio" in msg
    # lists the 13 languages, not "English and French only"
    for code in ALL:
        assert f"({code})" in msg
    assert "only" not in msg.lower()


# --------------------------------------------------------------------------- 3. front/back matter

# per language: titles that are front matter, back matter, and titles that stay narrated
MATTER = {
    "es": {
        "front": ["Índice", "Derechos de autor", "Dedicatoria", "Epígrafe", "Portada", "Portadilla",
                  "Tabla de contenido", "Lista de ilustraciones", "Del mismo autor"],
        "back": ["Agradecimientos", "Sobre el autor", "Acerca del autor", "Notas", "Notas finales", "Glosario",
                 "Bibliografía", "Referencias", "Índice analítico", "Índice onomástico", "Créditos",
                 "Sobre la editorial"],
        "narrated": ["Prólogo", "Prefacio", "Introducción", "Epílogo", "Capítulo 1"],
    },
    "de": {
        "front": ["Inhaltsverzeichnis", "Inhalt", "Impressum", "Urheberrecht", "Widmung", "Titelseite", "Schmutztitel",
                  "Abbildungsverzeichnis"],
        "back": ["Danksagung", "Über den Autor", "Über die Autorin", "Anmerkungen", "Fußnoten", "Endnoten",
                 "Glossar", "Literaturverzeichnis", "Quellenverzeichnis", "Register", "Stichwortverzeichnis",
                 "Über den Verlag"],
        "narrated": ["Vorwort", "Einleitung", "Einführung", "Prolog", "Epilog", "Kapitel IV"],
    },
    "it": {
        "front": ["Indice", "Sommario", "Diritti d'autore", "Dedica", "Epigrafe", "Copertina", "Frontespizio",
                  "Dello stesso autore"],
        "back": ["Ringraziamenti", "L'autore", "Informazioni sull'autore", "Note finali", "Glossario",
                 "Bibliografia", "Indice analitico", "Crediti", "Sull'editore"],
        "narrated": ["Prefazione", "Introduzione", "Prologo", "Epilogo", "Capitolo 3"],
    },
    "pt": {
        "front": ["Sumário", "Índice", "Direitos autorais", "Direitos de autor", "Dedicatória", "Epígrafe", "Capa",
                  "Folha de rosto", "Ficha catalográfica", "Do mesmo autor"],
        "back": ["Agradecimentos", "Sobre o autor", "Sobre a autora", "Notas", "Notas de rodapé", "Glossário",
                 "Bibliografia", "Referências", "Índice remissivo", "Créditos", "Sobre a editora"],
        "narrated": ["Prefácio", "Introdução", "Prólogo", "Epílogo", "Capítulo 3"],
    },
    "nl": {
        "front": ["Inhoudsopgave", "Inhoud", "Colofon", "Auteursrecht", "Opdracht", "Epigraaf", "Omslag",
                  "Titelpagina", "Eerder verschenen"],
        "back": ["Dankwoord", "Woord van dank", "Over de auteur", "Over de schrijver", "Noten", "Eindnoten",
                 "Voetnoten", "Woordenlijst", "Bibliografie", "Literatuurlijst", "Bronnen", "Register",
                 "Over de uitgever"],
        "narrated": ["Voorwoord", "Inleiding", "Proloog", "Epiloog", "Hoofdstuk 2"],
    },
    "ru": {
        "front": ["Оглавление", "Содержание", "Авторские права", "Выходные данные", "Посвящение", "Эпиграф",
                  "Обложка", "Титульный лист", "Другие книги автора"],
        "back": ["Благодарности", "Об авторе", "Примечания", "Сноски", "Глоссарий", "Библиография",
                 "Список литературы", "Литература", "Источники", "Указатель", "Об издательстве"],
        "narrated": ["Предисловие", "Введение", "Пролог", "Эпилог", "Глава 3"],
    },
    "zh": {
        "front": ["目录", "目錄", "目 录", "版权", "版權頁", "版权页", "版权声明", "献词", "献辞", "题记", "封面", "扉页",
                  "作者其他作品"],
        "back": ["致谢", "致謝", "关于作者", "作者简介", "注释", "註釋", "脚注", "尾注", "词汇表", "术语表",
                 "参考文献", "參考文獻", "参考书目", "索引", "关于出版社"],
        "narrated": ["前言", "序言", "引言", "后记", "第三章"],
    },
    "ja": {
        "front": ["目次", "奥付", "著作権", "献辞", "エピグラフ", "表紙", "扉", "タイトルページ", "図版一覧"],
        "back": ["謝辞", "著者紹介", "著者略歴", "著者について", "注", "注釈", "脚注", "訳注", "用語集", "参考文献",
                 "索引", "さくいん", "出版社について"],
        "narrated": ["まえがき", "はじめに", "序文", "あとがき", "第三章"],
    },
    "ko": {
        "front": ["목차", "차례", "저작권", "판권", "헌사", "헌정", "표지", "속표지", "에피그래프"],
        "back": ["감사의 글", "감사의 말", "저자 소개", "작가 소개", "주석", "각주", "미주", "용어집", "참고문헌",
                 "참고 문헌", "색인", "찾아보기", "출판사 소개"],
        "narrated": ["머리말", "서문", "들어가며", "후기", "제3장"],
    },
    "hi": {
        "front": ["विषय सूची", "विषय-सूची", "अनुक्रमणिका", "कॉपीराइट", "सर्वाधिकार सुरक्षित", "समर्पण", "आवरण",
                  "शीर्षक पृष्ठ", "चित्र सूची"],
        "back": ["आभार", "लेखक परिचय", "लेखक के बारे में", "टिप्पणियाँ", "शब्दावली", "संदर्भ सूची", "ग्रंथ सूची",
                 "प्रकाशक के बारे में"],
        "narrated": ["प्रस्तावना", "भूमिका", "परिचय", "उपसंहार", "अध्याय 3"],
    },
    "ar": {
        "front": ["فهرس", "فهرس المحتويات", "المحتويات", "حقوق النشر", "حقوق الطبع والنشر", "إهداء", "الغلاف",
                  "صفحة العنوان", "قائمة الصور"],
        "back": ["شكر وتقدير", "نبذة عن المؤلف", "عن المؤلف", "الهوامش", "هوامش", "المسرد", "المراجع",
                 "المصادر والمراجع", "كشاف", "عن الناشر"],
        "narrated": ["مقدمة", "تمهيد", "تقديم", "خاتمة", "الفصل الأول"],
    },
}


def _section(title: str, **kw) -> Section:
    sec = Section(index=3, title=title, kind="chapter", paragraphs=["Texto de relleno. " * 300], **kw)
    return sec


@pytest.mark.parametrize("lang", NEW)
def test_front_matter_titles(lang):
    for title in MATTER[lang]["front"]:
        assert matter_title(title) == "front", (lang, title)
        sec = _section(title)
        classify_section(sec)
        assert (sec.kind, sec.include) == ("front", False), (lang, title)
        assert sec.reasons, (lang, title)


@pytest.mark.parametrize("lang", NEW)
def test_back_matter_titles(lang):
    for title in MATTER[lang]["back"]:
        assert matter_title(title) == "back", (lang, title)
        sec = _section(title)
        classify_section(sec)
        assert (sec.kind, sec.include) == ("back", False), (lang, title)


@pytest.mark.parametrize("lang", NEW)
def test_preface_foreword_introduction_stay_narrated(lang):
    for title in MATTER[lang]["narrated"]:
        assert matter_title(title) is None, (lang, title)
        sec = _section(title)
        classify_section(sec)
        assert (sec.kind, sec.include) == ("chapter", True), (lang, title)


def test_matter_titles_ignore_case_accents_numbers_and_punctuation():
    for title, kind in [("ÍNDICE", "front"), ("indice", "front"), ("  Índice  ", "front"), ("INDICE.", "front"),
                        ("DERECHOS DE AUTOR", "front"), ("derechos de autor", "front"), ("Inhaltsverzeichnis:", "front"),
                        ("INHALTSVERZEICHNIS", "front"), ("IMPRESSUM", "front"), ("ÜBER DEN AUTOR", "back"),
                        ("Uber den Autor", "back"), ("Fussnoten", "back"), ("FUßNOTEN", "back"),
                        ("ОГЛАВЛЕНИЕ", "front"), ("оглавление", "front"), ("Благодарности.", "back"),
                        ("Agradecimentos 2", "back"), ("Notas 1", "back"), ("Glossario", "back"), ("GLOSSÁRIO", "back"),
                        ("Dankwoord", "back"), ("INHOUDSOPGAVE", "front"), ("Sobre El Autor", "back"),
                        ("sobre el autor", "back"), ("OVER DE AUTEUR", "back"), ("【目次】", "front"),
                        ("「注釈」", "back"), ("목차", "front"), ("Ｉｎｄｉｃｅ", "front")]:
        assert matter_title(title) == kind, title


def test_matter_titles_with_right_to_left_marks_and_arabic_variants():
    for title, kind in [("‏فهرس‏", "front"), ("‫فهرس المحتويات‬", "front"),
                        ("فِهْرِس", "front"),  # vowel marks
                        ("الإهداء", "front"), ("اهداء", "front"), ("إهداء", "front"),
                        ("نبذة عن المؤلف", "back"), ("نبذة عن المؤلّف", "back"), ("الهوامش ‏", "back"),
                        ("شكر وتقدير", "back"), ("شكـــر وتقدير", "back")]:  # tatweel
        assert matter_title(title) == kind, title


def test_matter_titles_are_whole_headings_not_prefixes():
    # a chapter that merely starts with a matter word is a chapter
    for title in ["Notas de un viajero", "Índice de refracción", "Anmerkungen eines Ungeübten", "Noten van een vreemdeling",
                  "Примечания к будущему", "Register your name", "Über den Wolken", "Sobre el autor de la carta"]:
        assert matter_title(title) is None, title


def test_english_and_french_matter_titles_are_unchanged():
    for title, kind in [("Table of Contents", "front"), ("Contents", "front"), ("Table des matières", "front"),
                        ("Dedication", "front"), ("Copyright", "front"), ("Notes", "back"), ("Index", "back"),
                        ("Acknowledgments", "back"), ("Remerciements", "back"), ("About the Author", "back"),
                        ("Epigraph", None), ("Foreword", None), ("Chapter 1", None), ("Introduction", None)]:
        assert matter_title(title) == kind, title


def test_copyright_text_in_a_short_opening_section_in_each_language():
    notices = {
        "es": "Todos los derechos reservados. Primera edición.", "de": "Alle Rechte vorbehalten. Erstausgabe.",
        "it": "Tutti i diritti riservati. Prima edizione.", "pt": "Todos os direitos reservados. Primeira edição.",
        "nl": "Alle rechten voorbehouden. Eerste druk.", "ru": "Все права защищены. Первое издание.",
        "zh": "版权所有，侵权必究。第一版。", "ja": "無断転載を禁じます。初版。", "ko": "무단 복제를 금합니다. 초판.",
        "hi": "सर्वाधिकार सुरक्षित। पहला संस्करण।", "ar": "جميع الحقوق محفوظة. الطبعة الأولى.",
    }
    for lang, notice in notices.items():
        sec = Section(index=0, title="Primera página", kind="chapter", paragraphs=[notice])
        classify_section(sec)
        assert sec.kind == "front" and not sec.include, lang
        assert "copyright notice" in front_matter_signals([notice]), lang
        long_chapter = Section(index=1, title="x", kind="chapter", paragraphs=[P[lang] * (3500 // len(P[lang]) + 1) + " " + notice])
        classify_section(long_chapter)
        assert long_chapter.kind == "chapter", lang  # only short sections are taken for the copyright page


def test_printed_table_of_contents_heading_in_each_language():
    for lang in NEW:
        title = MATTER[lang]["front"][0]
        assert "printed table of contents" in front_matter_signals([title, "1 ... 5"]), lang
        assert "printed table of contents" in front_matter_signals([f"{title} 1 ... 5 2 ... 9"]) or lang in ("zh", "ja", "ko", "ar", "hi")
    # prose that merely starts with the word is not a contents page
    assert "printed table of contents" not in front_matter_signals(["Contenido de la caja es muy útil para todos."])
    assert "printed table of contents" not in front_matter_signals(["Inhalt dieses Buches war schwer zu verstehen"])


# --------------------------------------------------------------------------- 4. chapter headings

NUMBERED = [
    ("Capítulo 3", ("capitulo", 3)), ("CAPÍTULO IV", ("capitulo", 4)), ("Capitulo 12.", ("capitulo", 12)),
    ("Kapitel IV", ("kapitel", 4)), ("Kapitel 12", ("kapitel", 12)), ("Capitolo VII", ("capitolo", 7)),
    ("Hoofdstuk 12", ("hoofdstuk", 12)), ("Глава 5", ("глава", 5)), ("Глава III", ("глава", 3)),
    ("第三章", ("章", 3)), ("第3章", ("章", 3)), ("第１２章", ("章", 12)), ("第十二章", ("章", 12)),
    ("第三话 夜", ("话", 3)), ("第3話", ("話", 3)), ("第二十一回", ("回", 21)),
    ("제3장", ("장", 3)), ("제 12 장", ("장", 12)), ("3장 시작", ("장", 3)),
    ("अध्याय 3", ("अध्याय", 3)), ("अध्याय एक", ("अध्याय", 1)), ("अध्याय ३", ("अध्याय", 3)),
    ("الفصل الأول", ("الفصل", 1)), ("الفصل الثالث", ("الفصل", 3)), ("الفصل 3", ("الفصل", 3)),
    ("‏الفصل الثاني‏", ("الفصل", 2)), ("الفصل ٣", ("الفصل", 3)),
]


@pytest.mark.parametrize("title, expected", NUMBERED)
def test_chapter_number_of_a_labelled_heading(title, expected):
    assert _number_of(title) == expected


def test_chapter_number_still_reads_english_and_french_headings():
    assert _number_of("Chapter 3") == ("chapter", 3)
    assert _number_of("Chapitre IV") == ("chapitre", 4)
    assert _number_of("IV") == ("", 4)
    assert _number_of("3. The Boy") == ("", 3)
    assert _number_of("Chapter") is None


def test_parts_are_told_from_chapters():
    for title, group in [("第一部", "part"), ("第一章", "chapter"), ("제2부", "part"), ("제2장", "chapter"),
                        ("الجزء الأول", "part"), ("الفصل الأول", "chapter"), ("भाग 2", "part"), ("अध्याय 2", "chapter"),
                        ("Parte 2", "part"), ("Teil III", "part"), ("Deel 1", "part"), ("Часть 2", "part"),
                        ("Libro IV", "part"), ("Capítulo 2", "chapter"), ("Глава 2", "chapter")]:
        assert vocab.heading_group(title) == group, title
    assert vocab.heading_group("Introducción") is None
    assert vocab.heading_group("Parti") is None


def test_cjk_numerals():
    for text, n in [("一", 1), ("十", 10), ("十二", 12), ("二十", 20), ("二十三", 23), ("一百零五", 105), ("三千五百", 3500),
                    ("二〇", 20), ("零", 0), ("삼", 3), ("십이", 12), ("이십삼", 23)]:
        assert vocab.cjk_int(text) == n, text
    for text in ["", "abc", "第三", "三章"]:
        assert vocab.cjk_int(text) is None, text


HEADINGS = [
    # (block, titles the section is known by, is it the section's own heading?)
    ("Capítulo 3: El mar", ["El mar"], True), ("Capítulo 3. El mar", ["Capítulo 3"], True),
    ("CAPÍTULO TRES", ["Capítulo tres: El mar"], True),
    ("Capítulo dos: Llegada", ["Llegada"], True),
    ("Capitolo VII", ["Capitolo VII: Il ritorno"], True), ("Capitolo 7: Il ritorno", ["Il ritorno"], True),
    ("KAPITEL IV", ["Kapitel IV: Die Rückkehr"], True), ("Kapitel 4: Die Rückkehr", ["Die Rückkehr"], True),
    ("Drittes Kapitel", ["Drittes Kapitel"], True),
    ("Kapitel zwei: Ankunft", ["Ankunft"], True),
    ("Hoofdstuk 2", ["Hoofdstuk 2: Thuiskomst"], True), ("Hoofdstuk twee: Thuiskomst", ["Thuiskomst"], True),
    ("Capítulo 3 O mar", ["O mar"], True), ("Capítulo 3: O regresso", ["Capítulo 3"], True),
    ("Глава 3. Возвращение", ["Возвращение"], True), ("ГЛАВА ТРЕТЬЯ", ["Глава третья"], True),
    ("Глава 3", ["Глава 3. Возвращение"], True),
    ("第三章", ["第三章 夜の海"], True), ("第三章 夜の海", ["第三章"], True), ("第三章　夜の海", ["第三章"], True),
    ("夜の海", ["第三章 夜の海"], True), ("第三章 夜の海", ["第三章 夜の海"], True),
    ("第3話", ["第3話 夜の海"], True), ("第十二回", ["第十二回 鬧元宵"], True),
    ("第三章 夜海", ["夜海"], True),
    ("一、概述", ["概述"], True), ("二．方法", ["方法"], True),
    ("제3장", ["제3장 밤바다"], True), ("제3장 밤바다", ["제3장"], True), ("밤바다", ["제3장 밤바다"], True),
    ("अध्याय 3: वापसी", ["अध्याय 3"], True), ("अध्याय 3", ["अध्याय 3: वापसी"], True),
    ("अध्याय तीन", ["अध्याय तीन"], True),
    ("الفصل الأول: العودة", ["الفصل الأول"], True), ("‏الفصل الأول‏", ["الفصل الأول: العودة"], True),
    ("الفصل الثالث", ["الفصل الثالث"], True), ("العودة", ["الفصل الأول: العودة"], True),
    # ordinary sentences are not headings
    ("Capítulo a capítulo, ella fue leyendo la carta.", ["Capítulo 3"], False),
    ("Ella llegó tarde a la estación.", ["Llegada"], False),
    ("Er ging zum Fenster und sah auf das Meer.", ["Kapitel 4"], False),
    ("Hij liep naar het raam en keek naar de zee.", ["Hoofdstuk 2"], False),
    ("Он подошёл к окну и посмотрел на море.", ["Глава 3"], False),
    ("朝の電車はまた遅れていた。", ["第一章"], False), ("她走到窗边，望着大海。", ["第一章 海"], False),
    ("그는 창가로 걸어가 바다를 바라보았다.", ["제3장"], False), ("وقف عند النافذة ونظر إلى البحر.", ["الفصل الأول"], False),
    ("वह खिड़की के पास गया और समुद्र को देखा।", ["अध्याय 3"], False),
    ("第三章の物語は、海から始まる。" * 8, ["第三章"], False),  # long blocks never are
]


@pytest.mark.parametrize("block, titles, expected", HEADINGS)
def test_looks_like_title_per_language(block, titles, expected):
    assert looks_like_title(block, titles) is expected


def test_looks_like_title_class_hint_works_for_any_script():
    assert looks_like_title("第三章 夜の海", [], "chapter-title")
    assert looks_like_title("الفصل الأول", [], "ChapterTitle")
    assert not looks_like_title("彼は窓に歩み寄った。", [], "chapter-text")


# --------------------------------------------------------------------------- 5. listening time

@pytest.mark.parametrize("lang", ALL)
def test_seconds_per_char_follows_the_registry(lang):
    assert seconds_per_char(lang) == languages.get(lang).sec_per_char
    assert estimate_seconds(1000, lang) == pytest.approx(1000 * languages.get(lang).sec_per_char)


def test_en_fr_estimates_are_identical_to_before():
    assert seconds_per_char("en") == seconds_per_char("fr") == SECONDS_PER_CHAR == 0.065
    sec = Section(index=0, title="x", kind="chapter", paragraphs=["a" * 1000])
    assert sec.est_seconds == pytest.approx(65.0)
    assert LangSection(index=0, title="x", kind="chapter", paragraphs=["a" * 1000]).est_seconds == pytest.approx(65.0)


def test_unknown_language_falls_back_to_the_default_rate():
    for lang in ("pl", "el", "", None, "zz"):
        assert seconds_per_char(lang) == SECONDS_PER_CHAR
    assert seconds_per_char("pt-BR") == languages.get("pt").sec_per_char


def test_apply_language_updates_a_book_and_its_json(tmp_path):
    book = read_book(build_epub(tmp_path / "es.epub", "es"))
    es_rate, ja_rate = languages.get("es").sec_per_char, languages.get("ja").sec_per_char
    assert book.metadata["sec_per_char"] == es_rate
    before = book.to_json()["included_est_seconds"]
    assert apply_language(book, "ja") == ja_rate  # the user picks another language by hand
    after = book.to_json()["included_est_seconds"]
    assert after == pytest.approx(before * ja_rate / es_rate, rel=0.01)
    assert book.metadata["est_minutes"] == pytest.approx(book.chars * ja_rate / 60, abs=0.06)


def test_cjk_sections_are_estimated_with_their_own_rate():
    zh = LangSection(index=0, title="x", kind="chapter", paragraphs=["字" * 1000], sec_per_char=seconds_per_char("zh"))
    zh_rate = languages.get("zh").sec_per_char
    assert zh.est_seconds == pytest.approx(1000 * zh_rate)
    assert zh.to_json()["est_seconds"] == pytest.approx(1000 * zh_rate, abs=0.5)
    assert zh.est_seconds > 4 * LangSection(index=0, title="x", kind="chapter", paragraphs=["a" * 1000]).est_seconds


def test_first_words_of_unspaced_text_is_short():
    sec = LangSection(index=0, title="x", kind="chapter", paragraphs=[P["zh"] * 20])
    assert len(sec.first_words) <= 100 and sec.first_words.endswith("…")
    en = LangSection(index=0, title="x", kind="chapter", paragraphs=[P["en"]])
    assert en.first_words == Section(index=0, title="x", kind="chapter", paragraphs=[P["en"]]).first_words


# --------------------------------------------------------------------------- 6. synthetic EPUBs

CHAPTER_NAMES = {
    "es": ["La llegada", "El mar", "La carta"], "de": ["Die Ankunft", "Das Meer", "Der Brief"],
    "it": ["L'arrivo", "Il mare", "La lettera"], "pt": ["A chegada", "O mar", "A carta"],
    "nl": ["De aankomst", "De zee", "De brief"], "ru": ["Приезд", "Море", "Письмо"],
    "zh": ["到来", "大海", "来信"], "ja": ["到着", "海", "手紙"], "ko": ["도착", "바다", "편지"],
    "hi": ["आगमन", "समुद्र", "चिट्ठी"], "ar": ["الوصول", "البحر", "الرسالة"],
}
ROMAN = ["I", "II", "III"]
CJK_NUM = ["一", "二", "三"]
AR_ORD = ["الأول", "الثاني", "الثالث"]


def chapter_label(lang: str, n: int) -> str:
    return {
        "es": f"Capítulo {n}", "de": f"Kapitel {ROMAN[n - 1]}", "it": f"Capitolo {n}", "pt": f"Capítulo {n}",
        "nl": f"Hoofdstuk {n}", "ru": f"Глава {n}", "zh": f"第{CJK_NUM[n - 1]}章", "ja": f"第{CJK_NUM[n - 1]}章",
        "ko": f"제{n}장", "hi": f"अध्याय {n}", "ar": f"الفصل {AR_ORD[n - 1]}",
    }[lang]


def _title_with_role(lang: str, group: str, role: str) -> str:
    return next(t for t in MATTER[lang][group] if (vocab.matter_role(t) or ("", ""))[1] == role)


# title of each kind of page, in each language (every one of them is in MATTER above)
PAGES = {
    lang: {
        "copyright": _title_with_role(lang, "front", "copyright"), "toc": _title_with_role(lang, "front", "toc"),
        "preface": MATTER[lang]["narrated"][0], "ack": _title_with_role(lang, "back", "acknowledgements"),
        "author": _title_with_role(lang, "back", "about_author"), "notes": _title_with_role(lang, "back", "notes"),
    }
    for lang in NEW
}


def _ebook(lang_meta: str | list[str] | None, title: str = "Livre") -> epub.EpubBook:
    b = epub.EpubBook()
    b.set_identifier(f"lang-{title}")
    b.set_title(title)
    b.add_author("Test Author")
    metas = [lang_meta] if isinstance(lang_meta, str) else list(lang_meta or [])
    for m in metas:
        b.add_metadata("DC", "language", m)
    return b


def _page(name: str, heading: str, paragraphs: list[str], lang: str = "en") -> epub.EpubHtml:
    item = epub.EpubHtml(title=heading, file_name=name, lang=lang)
    body = f"<h1>{heading}</h1>" + "".join(f"<p>{p}</p>" for p in paragraphs)
    item.content = f"<html><head><title>{heading}</title></head><body>{body}</body></html>"
    return item


def build_epub(path: Path, lang: str, meta: str | list[str] | None = None) -> Path:
    """A book in `lang`: copyright page, contents page, preface, three chapters, acknowledgements, author, notes."""
    meta = lang if meta is None else meta
    b = _ebook(meta)
    pg = PAGES[lang]
    body = [P[lang] * 2]
    items = [
        _page("copyright.xhtml", pg["copyright"], [{"zh": "版权所有。", "ja": "無断転載を禁じます。"}.get(lang, "© 2024 ISBN 978-0-00-000000-0")]),
        _page("toc.xhtml", pg["toc"], [f"{chapter_label(lang, n)} ..... {n}" for n in (1, 2, 3)]),
        _page("preface.xhtml", pg["preface"], body),
    ]
    for n in (1, 2, 3):
        items.append(_page(f"c{n}.xhtml", f"{chapter_label(lang, n)} {CHAPTER_NAMES[lang][n - 1]}", body))
    items += [
        _page("ack.xhtml", pg["ack"], ["Merci. " * 20]),
        _page("author.xhtml", pg["author"], ["Né quelque part. " * 20]),
        _page("notes.xhtml", pg["notes"], ["Une note. " * 20]),
    ]
    toc = [epub.Link(it.file_name, it.title, f"i{k}") for k, it in enumerate(items)]
    return fx._finish(b, items, path, toc)


@pytest.mark.parametrize("lang", NEW)
def test_epub_in_each_language(tmp_path, lang):
    book = read_book(build_epub(tmp_path / f"{lang}.epub", lang))
    pg = PAGES[lang]
    assert (book.language, book.language_source) == (lang, "metadata")
    assert not any("looks like" in w for w in book.warnings), book.warnings
    assert not any("not one Audiobook Studio can narrate" in w for w in book.warnings)
    kinds = {s.title: (s.kind, s.include) for s in book.sections}
    assert kinds[pg["copyright"]] == ("front", False)
    assert kinds[pg["toc"]] == ("front", False)
    assert kinds[pg["preface"]] == ("chapter", True)
    for key in ("ack", "author", "notes"):
        assert kinds[pg[key]] == ("back", False), (key, kinds)
    chapters = [s for s in book.sections if s.include]
    assert [s.title for s in chapters] == [pg["preface"]] + [
        f"{chapter_label(lang, n)} {CHAPTER_NAMES[lang][n - 1]}" for n in (1, 2, 3)
    ]
    assert all(s.starts_with_heading for s in chapters)
    # the contents page and the back matter are not read
    text = " ".join(p for s in chapters for p in s.paragraphs)
    assert "Merci." not in text and "Une note." not in text and "....." not in text


@pytest.mark.parametrize("lang", NEW)
def test_epub_estimated_minutes_follow_the_language(tmp_path, lang):
    book = read_book(build_epub(tmp_path / f"{lang}.epub", lang))
    rate = languages.get(lang).sec_per_char
    chars = sum(s.chars for s in book.sections if s.include)
    assert book.metadata["sec_per_char"] == rate
    assert book.metadata["est_minutes"] == pytest.approx(chars * rate / 60, abs=0.06)
    for s in book.sections:
        assert s.est_seconds == pytest.approx(s.chars * rate)
    assert book.to_json()["included_est_seconds"] == pytest.approx(chars * rate, abs=0.1 * len(book.sections))


def test_epub_cjk_minutes_are_several_times_the_english_figure(tmp_path):
    zh = read_book(build_epub(tmp_path / "zh.epub", "zh"))
    chars = sum(s.chars for s in zh.sections if s.include)
    assert zh.metadata["est_minutes"] == pytest.approx(chars * languages.get("zh").sec_per_char / 60, abs=0.06)
    assert zh.metadata["est_minutes"] > 4 * chars * 0.065 / 60


@pytest.mark.parametrize("lang", ["en", "fr"])
def test_epub_en_fr_estimates_keep_0_065(tmp_path, lang):
    book = read_book(fx.epub_language(tmp_path / "l.epub", lang, french=lang == "fr"))
    assert book.metadata["sec_per_char"] == 0.065
    assert all(s.est_seconds == pytest.approx(s.chars * 0.065) for s in book.sections)


@pytest.mark.parametrize("lang", NEW)
def test_epub_language_detected_when_dc_language_is_missing_or_undetermined(tmp_path, lang):
    for k, meta in enumerate([None, "und", "mul", "zz", ""]):
        b = build_epub(tmp_path / f"{lang}{k}.epub", lang, meta=[] if meta is None else meta)
        book = read_book(b)
        assert (book.language, book.language_source) == (lang, "detected"), (lang, meta, book.warnings)


@pytest.mark.parametrize("lang", NEW)
def test_epub_wrong_dc_language_is_kept_with_a_warning(tmp_path, lang):
    wrong = "en" if lang != "es" else "fr"
    book = read_book(build_epub(tmp_path / f"{lang}.epub", lang, meta=wrong))
    assert (book.language, book.language_source) == (wrong, "metadata")
    assert any(f"looks like '{lang}'" in w for w in book.warnings), book.warnings


@pytest.mark.parametrize(
    "meta, lang",
    [("pt-BR", "pt"), ("pt_br", "pt"), ("por", "pt"), ("zh-CN", "zh"), ("zh-Hans", "zh"), ("zh-TW", "zh"),
     ("chi", "zh"), ("es-MX", "es"), ("spa", "es"), ("ja-JP", "ja"), ("jpn", "ja"), ("kor", "ko"), ("hin", "hi"),
     ("ara", "ar"), ("ar-EG", "ar"), ("nld", "nl"), ("nl-BE", "nl"), ("Deutsch", "de"), ("Italiano", "it"),
     ("Русский", "ru")],
)
def test_epub_dc_language_spellings(tmp_path, meta, lang):
    book = read_book(build_epub(tmp_path / "s.epub", lang, meta=meta))
    assert (book.language, book.language_source) == (lang, "metadata")
    assert not any("looks like" in w for w in book.warnings)


def test_epub_first_usable_dc_language_wins(tmp_path):
    book = read_book(build_epub(tmp_path / "m.epub", "es", meta=["und", "es-MX"]))
    assert (book.language, book.language_source) == ("es", "metadata")


@pytest.mark.parametrize("code", ["pl", "el", "fa"])
def test_epub_language_outside_the_13_is_reported_as_unsupported(tmp_path, code):
    text = OTHER[code] if code in OTHER else P["ar"]
    b = _ebook(code)
    page = _page("c1.xhtml", "Chapter", [text * 3])
    path = fx._finish(b, [page], tmp_path / "o.epub", [epub.Link("c1.xhtml", "Chapter", "c1")])
    book = read_book(path)
    assert book.language == code
    assert any("'%s'" % code in w and "not one Audiobook Studio can narrate" in w for w in book.warnings)
    assert not any("English and French" in w for w in book.warnings)
    assert book.metadata["sec_per_char"] == SECONDS_PER_CHAR


def test_epub_greek_text_is_detected_and_reported_as_unsupported(tmp_path):
    b = _ebook("und")
    page = _page("c1.xhtml", "Κεφάλαιο", [OTHER["el"] * 3])
    book = read_book(fx._finish(b, [page], tmp_path / "g.epub", [epub.Link("c1.xhtml", "Κεφάλαιο", "c1")]))
    assert (book.language, book.language_source) == ("el", "detected")
    assert any("not one Audiobook Studio can narrate" in w for w in book.warnings)


def test_epub_tiny_text_has_no_language_and_defaults_to_english(tmp_path):
    for text in ("你好。", "Hola.", "Привет!", "ありがとう。"):
        b = _ebook("und")
        page = _page("c1.xhtml", "x", [text])
        book = read_book(fx._finish(b, [page], tmp_path / "t.epub", [epub.Link("c1.xhtml", "x", "c1")]))
        assert (book.language, book.language_source) == ("en", "default"), text
        assert any("could not be determined" in w for w in book.warnings)


def test_epub_russian_book_with_latin_names(tmp_path):
    text = P["ru"].replace("Мальчик", "Peter Smith и Мальчик") + " Anna Karenina, London, Paris, New York Times, Google."
    b = _ebook("und")
    page = _page("c1.xhtml", "Глава 1", [text * 2])
    book = read_book(fx._finish(b, [page], tmp_path / "ru.epub", [epub.Link("c1.xhtml", "Глава 1", "c1")]))
    assert (book.language, book.language_source) == ("ru", "detected")


def test_epub_right_to_left_marks_are_removed_from_titles_and_text(tmp_path):
    b = _ebook("ar")
    p1 = _page("c1.xhtml", "‏الفصل الأول‏", ["‏" + P["ar"] + "‏"])
    p2 = _page("c2.xhtml", "‏الفصل الثاني‏", [P["ar"]])
    toc = [epub.Link("c1.xhtml", "‏الفصل الأول‏", "c1"), epub.Link("c2.xhtml", "الفصل الثاني", "c2")]
    book = read_book(fx._finish(b, [p1, p2], tmp_path / "rtl.epub", toc))
    assert book.language == "ar"
    assert [s.title for s in book.sections] == ["الفصل الأول", "الفصل الثاني"]
    assert all(s.kind == "chapter" and s.include for s in book.sections)
    assert all("‏" not in p for s in book.sections for p in s.paragraphs)


@pytest.mark.parametrize("lang, labels", [
    ("zh", ["第一章", "第二章", "第三章", "第四章", "第五章", "第六章", "第七章"]),
    ("ja", ["第1話", "第2話", "第3話", "第4話", "第5話", "第6話", "第7話"]),
    ("ko", ["제1장", "제2장", "제3장", "제4장", "제5장", "제6장", "제7장"]),
    ("es", ["Capítulo 1", "Capítulo 2", "Capítulo 3", "Capítulo 4", "Capítulo 5", "Capítulo 6", "Capítulo 7"]),
    ("ru", ["Глава 1", "Глава 2", "Глава 3", "Глава 4", "Глава 5", "Глава 6", "Глава 7"]),
    ("ar", ["الفصل 1", "الفصل 2", "الفصل 3", "الفصل 4", "الفصل 5", "الفصل 6", "الفصل 7"]),
    ("hi", ["अध्याय 1", "अध्याय 2", "अध्याय 3", "अध्याय 4", "अध्याय 5", "अध्याय 6", "अध्याय 7"]),
])
def test_epub_chapter_missing_from_the_toc_is_recovered_in_each_language(tmp_path, lang, labels):
    # one file holding seven chapters; the contents leaves out the fourth (its heading is an <h5>)
    body = ""
    for n, label in enumerate(labels, start=1):
        tag = "h5" if n == 4 else "h2"
        body += f'<{tag} id="ch{n}">{label}</{tag}><p>{P[lang] * 2}</p>'
    b = _ebook(lang)
    page = epub.EpubHtml(title="t", file_name="all.xhtml", lang="en")
    page.content = f"<html><head><title>t</title></head><body>{body}</body></html>"
    toc = [epub.Link(f"all.xhtml#ch{n}", label, f"c{n}") for n, label in enumerate(labels, start=1) if n != 4]
    book = read_book(fx._finish(b, [page], tmp_path / "gap.epub", toc))
    assert [s.title for s in book.sections if s.include] == labels
    assert any(f"Recovered '{labels[3]}'" in w for w in book.warnings), book.warnings


def test_epub_cjk_title_not_spoken_twice(tmp_path):
    # the heading is a styled <p>, not an <h1>: the narrator must still skip it
    b = _ebook("ja")
    page = epub.EpubHtml(title="t", file_name="c1.xhtml", lang="ja")
    page.content = (
        "<html><head><title>t</title></head><body><p>第三章　夜の海</p>"
        f"<p>{P['ja']}</p><p>{P['ja']}</p></body></html>"
    )
    book = read_book(fx._finish(b, [page], tmp_path / "j.epub", [epub.Link("c1.xhtml", "第三章", "c1")]))
    assert book.sections[0].title == "第三章" and book.sections[0].starts_with_heading


# --------------------------------------------------------------------------- 7. synthetic PDFs

ARIAL_UNICODE = Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
BUILTIN_FONT = {"ru": "china-s", "zh": "china-s", "ja": "japan", "ko": "korea"}  # PyMuPDF's own CJK fonts


def _wrap(lang: str, text: str, width: int) -> list[str]:
    if lang in ("zh", "ja"):
        return [text[i:i + 28] for i in range(0, len(text), 28)]
    return textwrap.wrap(text, width)


def build_pdf(path: Path, lang: str, meta_lang: str | None = None) -> Path:
    """Copyright page, two chapters and a notes page, outlined; text is placed line by line."""
    pg = PAGES[lang]
    rtl = lang == "ar"
    doc = pymupdf.open()
    fontname = BUILTIN_FONT.get(lang, "helv")
    fontfile = None
    if lang in ("hi", "ar"):
        fontname, fontfile = "uni", str(ARIAL_UNICODE)
    chapters = [f"{chapter_label(lang, n)}" for n in (1, 2)]
    pages = [
        (pg["copyright"], ["© 2024 ISBN 978-0-00-000000-0"]),
        (chapters[0], [P[lang] * 3]),
        (chapters[1], [P[lang] * 3]),
        (pg["notes"], [P[lang]]),
    ]
    for heading, paragraphs in pages:
        page = doc.new_page(width=595, height=842)
        if fontfile:
            page.insert_font(fontname=fontname, fontfile=fontfile)
        shown = (lambda s: s[::-1]) if rtl else (lambda s: s)  # right-to-left text is stored in visual order
        page.insert_text((60, 90), shown(heading), fontsize=22, fontname=fontname)
        y = 180  # far enough below the heading to be a block of its own
        for para in paragraphs:
            for line in _wrap(lang, para, 70):
                page.insert_text((60, y), shown(line), fontsize=11, fontname=fontname)
                y += 15
            y += 8
    doc.set_toc([[1, pg["copyright"], 1], [1, chapters[0], 2], [1, chapters[1], 3], [1, pg["notes"], 4]])
    doc.set_metadata({"title": "Livre", "author": "Test Author"})
    if meta_lang:
        doc.xref_set_key(doc.pdf_catalog(), "Lang", f"({meta_lang})")
    doc.save(str(path))
    return path


def _need_font(lang: str) -> None:
    if lang in ("hi", "ar") and not ARIAL_UNICODE.exists():
        pytest.skip("needs the system font Arial Unicode for Devanagari/Arabic glyphs")


@pytest.mark.parametrize("lang", NEW)
def test_pdf_in_each_language(tmp_path, lang):
    _need_font(lang)
    book = read_book(build_pdf(tmp_path / f"{lang}.pdf", lang))
    pg = PAGES[lang]
    assert (book.language, book.language_source) == (lang, "detected")
    titles = [s.title for s in book.sections]
    assert titles == [pg["copyright"], chapter_label(lang, 1), chapter_label(lang, 2), pg["notes"]], titles
    assert [(s.kind, s.include) for s in book.sections] == [("front", False), ("chapter", True), ("chapter", True),
                                                             ("back", False)]
    # estimated listening time follows the language
    rate = languages.get(lang).sec_per_char
    chapters = [s for s in book.sections if s.include]
    chars = sum(s.chars for s in chapters)
    assert book.metadata["est_minutes"] == pytest.approx(chars * rate / 60, abs=0.06)
    assert all(s.est_seconds == pytest.approx(s.chars * rate) for s in book.sections)


@pytest.mark.parametrize("lang", ["zh", "ja"])
def test_pdf_cjk_lines_are_joined_without_spaces(tmp_path, lang):
    book = read_book(build_pdf(tmp_path / f"{lang}.pdf", lang))
    chapter = next(s for s in book.sections if s.include)
    body = chapter.paragraphs[-1]
    assert " " not in body, body[:80]  # the lines of one paragraph, joined
    assert P[lang] in body


def test_pdf_metadata_language_is_used_when_the_text_gives_no_answer(tmp_path):
    # a short Latin text cannot be detected; the PDF's own /Lang then decides
    doc = pymupdf.open()
    page = doc.new_page()
    page.insert_text((60, 90), "Capitulo uno", fontsize=22)
    page.insert_text((60, 130), "Hola amigo, que tal. " * 4, fontsize=11)
    doc.xref_set_key(doc.pdf_catalog(), "Lang", "(es-MX)")
    doc.save(str(tmp_path / "m.pdf"))
    book = read_book(tmp_path / "m.pdf")
    assert (book.language, book.language_source) == ("es", "metadata")


def test_pdf_without_language_hint_defaults_to_english_with_a_warning(tmp_path):
    doc = pymupdf.open()
    page = doc.new_page()
    page.insert_text((60, 90), "Hola amigo, que tal. " * 4, fontsize=11)
    doc.save(str(tmp_path / "n.pdf"))
    book = read_book(tmp_path / "n.pdf")
    assert (book.language, book.language_source) == ("en", "default")
    assert any("could not be determined" in w for w in book.warnings)


def test_pdf_text_wins_over_a_wrong_metadata_language(tmp_path):
    book = read_book(build_pdf(tmp_path / "w.pdf", "ru", meta_lang="en-US"))
    assert (book.language, book.language_source) == ("ru", "detected")
    assert any("'en'" in w and "looks like 'ru'" in w for w in book.warnings)


def test_pdf_page_numbers_in_other_languages_are_not_chapter_text(tmp_path):
    doc = pymupdf.open()
    for n in range(6):
        page = doc.new_page(width=595, height=842)
        page.insert_text((290, 825), f"Página {n + 1}", fontsize=9)
        if n in (0, 3):
            page.insert_text((60, 90), "Capítulo %d" % (1 if n == 0 else 2), fontsize=24)
        y = 130
        for line in textwrap.wrap(P["es"] * 2, 80):
            page.insert_text((60, y), line, fontsize=11)
            y += 15
    doc.set_toc([[1, "Capítulo 1", 1], [1, "Capítulo 2", 4]])
    doc.save(str(tmp_path / "pn.pdf"))
    book = read_book(tmp_path / "pn.pdf")
    assert book.language == "es"
    assert not any("Página" in p for s in book.sections for p in s.paragraphs)


def test_pdf_outline_levels_with_parts_in_other_languages(tmp_path):
    from audiobook_engine.ingest.pdf import _outline_level

    cases = [
        [[1, "第一部", 1], [2, "第一章", 1], [2, "第二章", 2], [1, "第二部", 3], [2, "第三章", 3]],
        [[1, "Teil I", 1], [2, "Kapitel 1", 1], [2, "Kapitel 2", 2], [1, "Teil II", 3], [2, "Kapitel 3", 3]],
        [[1, "Часть первая", 1], [2, "Глава 1", 1], [2, "Глава 2", 2], [1, "Часть вторая", 3], [2, "Глава 3", 3]],
        [[1, "الجزء الأول", 1], [2, "الفصل الأول", 1], [2, "الفصل الثاني", 2], [1, "الجزء الثاني", 3],
         [2, "الفصل الثالث", 3]],
        [[1, "제1부", 1], [2, "제1장", 1], [2, "제2장", 2], [1, "제2부", 3], [2, "제3장", 3]],
        [[1, "भाग 1", 1], [2, "अध्याय 1", 1], [2, "अध्याय 2", 2], [1, "भाग 2", 3], [2, "अध्याय 3", 3]],
    ]
    for toc in cases:
        assert _outline_level(toc) == 2, toc
    # chapters with numbered sections stay at level 1
    assert _outline_level([[1, "第一章", 1], [2, "一、概述", 1], [2, "二、方法", 2], [1, "第二章", 3],
                           [2, "一、概述", 3], [1, "第三章", 4]]) == 1


def test_pdf_cjk_paragraph_continues_across_a_page_break(tmp_path):
    doc = pymupdf.open()
    first = "那天傍晚雨刚停，空气里还有泥土的味道。他们沿着河岸慢慢地向前走去，谁也没有再说话，天色渐渐暗了下来，远处的灯一盏一盏地亮了起来，河面上飘"
    second = "着薄薄的雾。他们在桥边停了下来，望着对岸的灯火，过了很久才继续往前走，谁也没有先开口。"
    for text in (first, second):
        page = doc.new_page(width=595, height=842)
        for k in range(0, len(text), 30):  # lines of 30 characters stay inside the page
            page.insert_text((60, 90 + 15 * (k // 30)), text[k:k + 30], fontsize=11, fontname="china-s")
    doc.save(str(tmp_path / "pb.pdf"))
    book = read_book(tmp_path / "pb.pdf")
    paragraphs = [p for s in book.sections for p in s.paragraphs]
    assert any("河面上飘着薄薄的雾" in p for p in paragraphs), paragraphs
