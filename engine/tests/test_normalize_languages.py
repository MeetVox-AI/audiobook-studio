"""Tests for the eleven languages beyond English and French: es, de, it, pt, ru, zh, ja, ko, hi, ar, nl.

Expected strings were checked against num2words (registry codes of languages.py), against the Chinese reader in
zhnum.py (tested on its own below) or against well-known orthography; see the engine notes for the points a
native speaker should still review. The GOLDEN_* tables at the end were produced by the English/French rules
as they were before the other languages were added, and pin them byte for byte.
"""

from __future__ import annotations

import random
import re
import time

import pytest
from num2words import num2words

from audiobook_engine import languages
from audiobook_engine.textproc import multilang, zhnum
from audiobook_engine.textproc.normalize import (
    NORMALIZER_VERSION,
    Rules,
    expand_abbreviations,
    expand_numbers,
    expand_symbols,
    heading_to_speech,
    normalize_paragraph,
    normalize_section,
)
from audiobook_engine.textproc.segment import split_sentences

NEW = ["es", "de", "it", "pt", "ru", "zh", "ja", "ko", "hi", "ar", "nl"]


LANGUAGE_CASES = [
    ('es', 'Cuesta 5 € y 3,50 € y 1.250,75 €.', False, 'Cuesta cinco euros y tres euros con cincuenta céntimos y mil doscientos cincuenta euros con setenta y cinco céntimos.'),
    ('es', 'El Sr. García pagó $1.000.000 el 1.º de mayo.', False, 'El Señor García pagó un millón de dólares el primero de mayo.'),
    ('es', 'Tiene 21 años, 1 libra, £1 y £21.', False, 'Tiene veintiún años, una libra, una libra y veintiuna libras.'),
    ('es', 'Hizo el 50 % del trabajo a las 10:30 en el siglo XIX.', False, 'Hizo el cincuenta por ciento del trabajo a las diez y treinta en el siglo diecinueve.'),
    ('es', 'Felipe II, Carlos V e Isabel II.', False, 'Felipe segundo, Carlos quinto e Isabel segunda.'),
    ('es', 'Nació en 1999, el 3.er hijo, la 2.ª vez, 12º y 40º.', False, 'Nació en mil novecientos noventa y nueve, el tercer hijo, la segunda vez, duodécimo y cuadragésimo.'),
    ('es', 'Hace 30 °C y 2 ºC; D. Quijote y Sancho, etc. Luego vino.', False, 'Hace treinta grados Celsius y dos grados Celsius; Don Quijote y Sancho, etcétera. Luego vino.'),
    ('es', 'Dra. Pérez, pág. 5, cap. IV, núm. 7, p. ej. esto, EE. UU.', False, 'Doctora Pérez, página cinco, capítulo cuatro, número siete, por ejemplo esto, Estados Unidos.'),
    ('es', 'Habitaciones 101 102 103 y 10 000 soldados.', False, 'Habitaciones ciento uno ciento dos ciento tres y diez mil soldados.'),
    ('es', '5 euros es poco. 10 personas vinieron.', False, 'Cinco euros es poco. Diez personas vinieron.'),
    ('es', 'Capítulo IV', True, 'Capítulo cuatro.'),
    ('es', 'CAPÍTULO 21: El viaje', True, 'Capítulo veintiuno. El viaje.'),
    ('de', 'Das kostet 5 € und 3,50 € und 1.250,75 €.', False, 'Das kostet fünf Euro und drei Euro fünfzig und eintausendzweihundertfünfzig Euro fünfundsiebzig.'),
    ('de', 'Am 3. Mai 1999 kam Herr Dr. Müller, z. B. um 10:30 Uhr.', False, 'Am dritten Mai neunzehnhundertneunundneunzig kam Herr Doktor Müller, zum Beispiel um zehn Uhr dreißig.'),
    ('de', 'Im 19. Jahrhundert regierte Friedrich II. Dann kam er.', False, 'Im neunzehnten Jahrhundert regierte Friedrich der Zweite. Dann kam er.'),
    ('de', 'Er hat 1.500 Euro; im Jahr 1999 usw. Dann ging er.', False, 'Er hat eintausendfünfhundert Euro; im Jahr neunzehnhundertneunundneunzig und so weiter. Dann ging er.'),
    ('de', 'Zimmer 3. Er kam in der 2. Etage an, am 31. Dezember.', False, 'Zimmer drei. Er kam in der zweiten Etage an, am einunddreißigsten Dezember.'),
    ('de', 'Er kam um 1 Uhr mit 1 Mann und 1 Frau; 50 % und 20 °C.', False, 'Er kam um ein Uhr mit einem Mann und eine Frau; fünfzig Prozent und zwanzig Grad Celsius.'),
    ('de', 'Prof. Dr. Meier, z.B. heute, bzw. d.h. morgen, Hauptstr. 5.', False, 'Professor Doktor Meier, zum Beispiel heute, beziehungsweise das heißt morgen, Hauptstraße fünf.'),
    ('de', '12.05.2024 ist ein Datum', False, 'Zwölf fünf zweitausendvierundzwanzig ist ein Datum'),
    ('de', 'Kapitel 4', True, 'Kapitel vier.'),
    ('de', 'KAPITEL IV. DER ANFANG', True, 'Kapitel vier. Der anfang.'),
    ('it', 'Costa 5 € e 3,50 € e 1.250,75 € e £1 e £21 e $1 e 3,05 €.', False, 'Costa cinque euro e tre euro e cinquanta e milleduecentocinquanta euro e settantacinque e una sterlina e ventuna sterline e un dollaro e tre euro e cinque.'),
    ('it', 'Il Sig. Rossi, la Sig.ra Bianchi e il Dott. Verdi, ecc. Poi 1° piano e 2ª volta.', False, 'Il Signor Rossi, la Signora Bianchi e il Dottor Verdi, eccetera. Poi primo piano e seconda volta.'),
    ('it', 'Alle 10:30, il 50 % nel secolo XIX; Luigi XIV e Vittorio Emanuele II.', False, 'Alle dieci e trenta, il cinquanta per cento nel secolo diciannovesimo; Luigi quattordicesimo e Vittorio Emanuele secondo.'),
    ('it', "Il 1 maggio e il 2 maggio c'erano 1 uomo e 1 donna.", False, "Il primo maggio e il due maggio c'erano un uomo e una donna."),
    ('it', 'Capitolo XII', True, 'Capitolo dodici.'),
    ('it', 'I promessi sposi', True, 'I promessi sposi.'),
    ('pt', 'Custa 5 € e R$ 3,50 e R$ 1.250,75 e £21.', False, 'Custa cinco euros e três reais e cinquenta centavos e mil duzentos e cinquenta reais e setenta e cinco centavos e vinte e uma libras.'),
    ('pt', 'O Sr. Silva e a Dra. Costa, etc. Depois 1º e 2ª, 21º.', False, 'O Senhor Silva e a Doutora Costa, etcétera. Depois primeiro e segunda, vigésimo primeiro.'),
    ('pt', 'Às 10:30, 50 % no século XIX, Pedro II. Faz 30 °C.', False, 'Às dez e trinta, cinquenta por cento no século dezenove, Pedro segundo. Faz trinta graus Celsius.'),
    ('pt', 'Tem 1 hora, 2 horas, 200 casas e 21 casas; 1 de maio.', False, 'Tem uma hora, duas horas, duzentas casas e vinte e uma casas; primeiro de maio.'),
    ('pt', 'Capítulo IV', True, 'Capítulo quatro.'),
    ('nl', 'Het kost € 5 en € 3,50 en 1.250,75 €.', False, 'Het kost vijf euro en drie euro vijftig en duizendtweehonderdvijftig euro vijfenzeventig.'),
    ('nl', 'Dhr. Jansen en Mevr. de Vries, enz. Daarna 8ste en 2e en 21ste.', False, 'De heer Jansen en Mevrouw de Vries, enzovoort. Daarna achtste en tweede en eenentwintigste.'),
    ('nl', 'Om 10:30, 50 % in 1999, in de 19e eeuw, Willem II. Het is 30 °C.', False, 'Om tien uur dertig, vijftig procent in negentien honderd negenennegentig, in de negentiende eeuw, Willem de Tweede. Het is dertig graden Celsius.'),
    ('nl', 'Hoofdstuk 7', True, 'Hoofdstuk zeven.'),
    ('ru', 'Это стоит 5 ₽, 3,50 $, 2 руб. и 21 коп. и 1,5 млн руб.', False, 'Это стоит пять рублей, три доллара пятьдесят центов, два рубля и двадцать одна копейка и одна целая пять десятых миллиона рублей'),
    ('ru', 'В 1999 году, до 5 мая, с 5 до 7 часов, 2 минуты, 5-й, 5-го, 5-я.', False, 'В тысяча девятьсот девяносто девятом году, до пятого мая, с пяти до семи часов, две минуты, пятый, пятого, пятая.'),
    ('ru', 'Это 50 % и 3,5 %. XIX век, в XIX веке, Пётр I и Екатерина II.', False, 'Это пятьдесят процентов и три целых пять десятых процента. Девятнадцатый век, в девятнадцатом веке, Пётр Первый и Екатерина Вторая.'),
    ('ru', 'Жил в г. Москве. Потом т. е. и т. д. Улица: ул. Ленина.', False, 'Жил в городе Москве. Потом то есть и так далее. Улица: улица Ленина.'),
    ('ru', 'Было 1 окно, 2 женщины и 1 минута и 21 год; 10 января 2024 года.', False, 'Было одно окно, две женщины и одна минута и двадцать один год; десятое января две тысячи двадцать четвёртого года.'),
    ('ru', 'Глава 5', True, 'Глава пятая.'),
    ('ru', 'ГЛАВА XII. ПРОБУЖДЕНИЕ', True, 'Глава двенадцатая. Пробуждение.'),
    ('zh', '价格是¥100，￥3.55，$3.50，3.5%，10%，100%。', False, '价格是一百元，三元五角五分，三美元五十美分，百分之三点五，百分之十，百分之百。'),
    ('zh', '今天是2024年3月5日，下午2:30，温度30℃，共1,000,000人，第3名，2个人，200人，22000人，3.14。', False, '今天是二零二四年三月五日，下午两点三十分，温度摄氏三十度，共一百万人，第三名，两个人，两百人，两万两千人，三点一四。'),
    ('zh', '他在1985年到2000年间，温度是-5℃，１２３４ＡＢＣ。', False, '他在一九八五年到二零零零年间，温度是零下五摄氏度，1234ABC。'),
    ('zh', '第12章 风雪', True, '第十二章。风雪。'),
    ('zh', '第十二章', True, '第十二章。'),
    ('ja', '価格は¥100、$3.50、10%、2024年、第12章、３個。', False, '価格は百円、三ドル五十セント、十パーセント、二千二十四年、第十二章、三個。'),
    ('ja', '午後2:30に1000人が集まった。30℃。', False, '午後二時三十分に千人が集まった。摂氏三十度。'),
    ('ja', '第12章 嵐', True, '第十二章。嵐。'),
    ('ko', '가격은 10,000원, 3명, 2024년 6월 10일, 제3장, 20살, 5시 30분, 3개월.', False, '가격은 만 원, 세 명, 이천이십사 년 유월 십 일, 제삼장, 스무 살, 다섯 시 삼십 분, 삼 개월.'),
    ('ko', '오후 2:30, 50%, 25℃, 3.5, 100명, 21살.', False, '오후 두 시 삼십 분, 오십 퍼센트, 섭씨 이십오 도, 삼 점 오, 백 명, 스물한 살.'),
    ('ko', '제3장 시작', True, '제삼장. 시작.'),
    ('ar', 'السعر ٥٠ دولار و 3.5 و ١٢٣ و ١٬٢٥٠٫٥ في ٢٠٢٤، 50٪ الساعة 10:30 ـــ', False, 'السعر خمسون دولار و ثلاثة فاصلة خمسة و مائة و ثلاثة و عشرون و ألف و مئتان و خمسون فاصلة خمسة في ألفان و أربعة و عشرون، خمسون في المئة الساعة 10:30'),
    ('ar', '\u200fالسعر 25\u200e دولار كتَابٌ مُـــــمتع', False, 'السعر خمسة و عشرون دولار كتَابٌ مُمتع'),
    ('ar', 'في الفصل 4 قال $5 و€10', False, 'في الفصل الرابع قال خمسة دولار وعشرة يورو'),
    ('ar', 'الفصل 4', True, 'الفصل الرابع.'),
    ('ar', 'الفصل ٢٥', True, 'الفصل الخامس والعشرون.'),
    ('hi', 'कीमत 50 रुपये है। अध्याय 4 | डॉ. शर्मा 50% सही। क्\u200dया \u200dआप?', False, 'कीमत 50 रुपये है। अध्याय 4। डॉक्टर शर्मा 50 प्रतिशत सही। क्\u200dया \u200dआप?'),
    ('hi', 'अध्याय 4', True, 'अध्याय 4।'),
]



@pytest.mark.parametrize("lang, src, heading, want", LANGUAGE_CASES)
def test_language_cases(lang, src, heading, want):
    assert normalize_paragraph(src, lang, is_heading=heading) == want


def test_normalizer_version_is_unchanged():
    # the English/French rules did not change: the chunk cache stays valid
    assert NORMALIZER_VERSION == "5"


# ----------------------------------------------------------------------------- Chinese reader


@pytest.mark.parametrize("n, want, ordinal", [
    (0, "零", "零"), (2, "二", "二"), (10, "十", "十"), (11, "十一", "十一"), (20, "二十", "二十"),
    (22, "二十二", "二十二"), (100, "一百", "一百"), (101, "一百零一", "一百零一"), (110, "一百一十", "一百一十"),
    (200, "两百", "二百"), (220, "两百二十", "二百二十"), (1000, "一千", "一千"), (1001, "一千零一", "一千零一"),
    (1010, "一千零一十", "一千零一十"), (2000, "两千", "二千"), (2024, "两千零二十四", "二千零二十四"),
    (2200, "两千二百", "二千二百"), (10000, "一万", "一万"), (10001, "一万零一", "一万零一"),
    (12000, "一万两千", "一万二千"), (20000, "两万", "二万"), (22000, "两万两千", "二万二千"),
    (100000, "十万", "十万"), (110000, "十一万", "十一万"), (2000000, "两百万", "二百万"),
    (100000000, "一亿", "一亿"), (100000001, "一亿零一", "一亿零一"), (101000000, "一亿零一百万", "一亿零一百万"),
    (200000000, "两亿", "二亿"), (10 ** 12, "一万亿", "一万亿"), (2 * 10 ** 12, "两万亿", "二万亿"),
    (123456789, "一亿两千三百四十五万六千七百八十九", "一亿二千三百四十五万六千七百八十九"),
])
def test_zh_cardinals(n, want, ordinal):
    assert zhnum.cardinal(n) == want
    assert zhnum.ordinal_number(n) == ordinal


_ZH_D = {c: i for i, c in enumerate("零一二三四五六七八九")} | {"两": 2}
_ZH_U = {"十": 10, "百": 100, "千": 1000}


def zh_value(s: str) -> int:
    """An independent reader of Chinese numerals (万亿 = 10^12), used to check zhnum by round trip."""
    for big, mult in (("万亿", 10 ** 12), ("亿", 10 ** 8), ("万", 10 ** 4)):
        if big in s:
            head, tail = s.split(big, 1)
            return (zh_value(head) if head else 1) * mult + (zh_value(tail) if tail.strip("零") else 0)
    total = digit = 0
    for ch in s:
        if ch in _ZH_D:
            digit = _ZH_D[ch]
        elif ch in _ZH_U:
            total += (digit or 1) * _ZH_U[ch]
            digit = 0
    return total + digit


@pytest.mark.parametrize("n", [0, 1, 9, 10, 19, 99, 100, 999, 1000, 9999, 10000, 99999, 12345, 100000000, 999999999])
def test_zh_round_trip_known(n):
    for two in (True, False):
        assert zh_value(zhnum.cardinal(n, two)) == n


def test_zh_round_trip_random():
    rnd = random.Random(3)
    for _ in range(3000):
        n = rnd.randint(0, 10 ** rnd.randint(1, 11))
        spoken = zhnum.cardinal(n)
        assert zh_value(spoken) == n, (n, spoken)


def test_zh_rejects_numbers_out_of_range_and_reads_digits():
    with pytest.raises(ValueError):
        zhnum.cardinal(10 ** 16)
    assert zhnum.digits("2024") == "二零二四"
    assert zhnum.decimal("3", "14") == "三点一四"
    assert zhnum.decimal("0", "05") == "零点零五"
    # beyond 10^15 a number is read digit by digit rather than as a value
    assert normalize_paragraph("1234567890123456789", "zh") == "一二三四五六七八九零一二三四五六七八九"


# ----------------------------------------------------------------------------- numbers: num2words


@pytest.mark.parametrize("lang", ["es", "de", "it", "pt", "ru", "nl", "ja", "ko", "ar"])
@pytest.mark.parametrize("n", [0, 1, 7, 12, 21, 42, 99, 100, 101, 250, 999])
def test_plain_cardinals_are_num2words(lang, n):
    code = languages.get(lang).num2words
    want = num2words(n, lang=code).replace(", ", " ")
    got = normalize_paragraph(str(n), lang)
    assert got.lower() == want.lower()


@pytest.mark.parametrize("lang", ["es", "de", "it", "pt", "ru", "nl", "ja", "ko", "ar"])
def test_thousands_and_decimal_conventions(lang):
    code = languages.get(lang).num2words
    big = num2words(1234567, lang=code).replace(", ", " ")
    assert normalize_paragraph("1234567", lang).lower() == big.lower()
    # the group separator of the language, a no-break space, and the other convention all give one number
    forms = ["1.234.567", "1 234 567", "1 234 567"] if lang in multilang._COMMA_DEC else ["1,234,567"]
    for form in forms:
        assert normalize_paragraph(form, lang).lower() == big.lower(), form


@pytest.mark.parametrize("tok, lang, want", [
    ("1.234,56", "es", ("1234", "56", True)), ("1,234.56", "es", ("1234", "56", True)),
    ("1.234", "de", ("1234", None, True)), ("3.5", "de", ("3", "5", False)), ("0.75", "it", ("0", "75", False)),
    ("3,5", "ru", ("3", "5", False)), ("1,500", "nl", ("1", "500", False)), ("1,234,567", "ja", ("1234567", None, True)),
    ("3.14", "zh", ("3", "14", False)), ("12.05.2024", "de", None), ("1.2.3", "ja", None),
    ("1,2,3", "ko", None), ("1" + multilang._G + "000", "fr", ("1000", None, True)),
])
def test_parse_num(tok, lang, want):
    assert multilang.parse_num(tok, lang) == want


@pytest.mark.parametrize("lang, src, want", [
    ("es", "3,5", "Tres coma cinco"), ("pt", "3,14", "Três vírgula catorze"), ("it", "0,05", "Zero virgola zero cinque"),
    ("de", "3,14", "Drei Komma eins vier"), ("nl", "2,5", "Twee komma vijf"), ("ru", "3,5", "Три целых пять десятых"),
    ("ru", "0,05", "Ноль целых пять сотых"), ("ja", "3.14", "三点一四"), ("ko", "3.5", "삼 점 오"),
    ("zh", "3.14", "三点一四"), ("ar", "3.5", "ثلاثة فاصلة خمسة"),
])
def test_decimals(lang, src, want):
    assert normalize_paragraph(src, lang) == want


def test_hindi_numbers_are_left_as_digits():
    for src in ["कीमत 50 रुपये है।", "सन् 2024 में 3.5 प्रतिशत", "10,000 और 1 000 000", "४५ और 12:30"]:
        assert normalize_paragraph(src, "hi") == src
    assert expand_numbers("5 और 10", "hi") == "5 और 10"
    assert normalize_paragraph("50%", "hi") == "50 प्रतिशत"
    assert normalize_paragraph("अध्याय 4", "hi", is_heading=True) == "अध्याय 4।"


def test_very_long_numbers_are_read_digit_by_digit():
    for lang in NEW:
        if lang == "hi":
            continue
        out = normalize_paragraph("9" * 40, lang)
        assert out and not re.search(r"\d", out)
    assert normalize_paragraph("0" * 5000 + "7", "es") == "Siete"
    assert normalize_paragraph("1234567890123456", "es").split()[:3] == ["Uno", "dos", "tres"]


def test_numbers_beyond_the_library_do_not_crash():
    # num2words refuses them (OverflowError) for es and pt: they are read digit by digit instead
    want = " ".join(["uno"] + ["cero"] * 27)
    assert normalize_paragraph("1.000.000.000.000.000.000.000.000.000", "es").lower() == want
    assert normalize_paragraph("1 000 000 000 000 000 000", "pt").lower().startswith("um zero zero")


# ----------------------------------------------------------------------------- registry, routing


@pytest.mark.parametrize("code", ["pt-BR", "PT_br", "es-MX", "ES", "zh-CN", "zh-Hans", "pt-pt"])
def test_regional_codes_use_the_new_rules(code):
    sample = {"pt": "5 € e 50 %", "es": "5 € y 50 %", "zh": "10%"}[languages.normalize_code(code)]
    out = normalize_paragraph(sample, code)
    assert not re.search(r"\d", out) and "€" not in out


@pytest.mark.parametrize("code", ["en", "en-US", "EN", "xx", "fr", None])
def test_english_and_french_never_reach_the_new_rules(code):
    assert multilang.resolve(code) is None


def test_every_registry_language_has_a_text_path():
    for code in languages.codes():
        assert code in ("en", "fr") or code in NEW
        out = normalize_paragraph("Texte 1.", code)
        assert out


# ----------------------------------------------------------------------------- cleanup


BIDI = "\u200e\u200f\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069"


@pytest.mark.parametrize("lang", NEW)
def test_bidi_marks_are_removed(lang):
    assert normalize_paragraph(f"a{BIDI}b c{BIDI}", lang) == "ab c"


def test_other_languages_keep_their_text_unaltered():
    # the clean-up of the new languages never reaches English or French
    assert normalize_paragraph("a‎b ـc", "en") == "a‎b ـc"
    assert normalize_paragraph("a‎b ـc", "fr") == "a‎b ـc"
    assert normalize_paragraph("ＡＢＣ１２３", "en").startswith("ＡＢＣ")


def test_tatweel_is_removed_for_arabic_only_and_diacritics_are_kept():
    assert normalize_paragraph("كتَابٌ مُـــــمتع", "ar") == "كتَابٌ مُمتع"
    assert "ـ" in normalize_paragraph("aـb", "es")


@pytest.mark.parametrize("lang, text", [("hi", "क्\u200dया \u200cतापमान"), ("ar", "می\u200cخواهم"), ("hi", "क्ष त्र ज्ञ श्री")])
def test_zwj_and_zwnj_are_kept(lang, text):
    assert normalize_paragraph(text, lang) == text


def test_fullwidth_digits_and_latin_are_ascii_for_chinese_and_japanese_only():
    assert normalize_paragraph("ＡＢＣ１２３", "ja") == "ABC123"
    assert normalize_paragraph("１２３４", "zh") == "一千二百三十四"
    assert normalize_paragraph("１，０００円", "ja") == "千円"
    assert normalize_paragraph("ＡＢＣ", "es") == "ＡＢＣ"
    assert normalize_paragraph("１２３", "ko") == "１２３"
    # a full-width comma between ASCII digits is a list separator, not a thousands mark
    assert normalize_paragraph("3.5，10", "zh") == "三点五，十"


def test_arabic_digits_become_western_before_spelling():
    assert normalize_paragraph("٣", "ar") == "ثلاثة"
    assert normalize_paragraph("۴۲", "ar") == num2words(42, lang="ar")
    assert multilang.to_western_digits("١٬٢٥٠٫٥٪") == "1,250.5%"


def test_hindi_vertical_bar_is_a_danda():
    assert normalize_paragraph("वह गया | फिर आया", "hi") == "वह गया। फिर आया"


# ----------------------------------------------------------------------------- abbreviations, symbols


@pytest.mark.parametrize("lang, src, want", [
    ("es", "Sra. Pérez y Srta. Gómez.", "Señora Pérez y Señorita Gómez."),
    ("es", "Sr. García llegó.", "Señor García llegó."),
    ("es", "Pedro D. Fernández y Don Juan.", "Pedro D. Fernández y Don Juan."),
    ("es", "Av. de Mayo y Avda. Sur.", "Avenida de Mayo y Avenida Sur."),
    ("es", "Eran cien, etc. Luego se fueron.", "Eran cien, etcétera. Luego se fueron."),
    ("es", "Muchas cosas, etc.", "Muchas cosas, etcétera."),
    ("de", "Das ist z. B. so, d. h. gut, u. a. wichtig.", "Das ist zum Beispiel so, das heißt gut, unter anderem wichtig."),
    ("de", "Hr. Müller und Fr. Schmidt, Dr. med. Weber.", "Herr Müller und Frau Schmidt, Doktor der Medizin Weber."),
    ("de", "Er kam v. Chr. und sie n. Chr.", "Er kam vor Christus und sie nach Christus."),
    ("it", "Il Dott. Rossi, l'Ing. Bianchi e l'Avv. Neri.", "Il Dottor Rossi, l'Ingegner Bianchi e l'Avvocato Neri."),
    ("it", "Sig.na Verdi, cfr. pag. 5 e p. es. questo.", "Signorina Verdi, confronta pagina cinque e per esempio questo."),
    ("pt", "A Sra. Costa e o Dr. Silva, p. ex. isso.", "A Senhora Costa e o Doutor Silva, por exemplo isso."),
    ("pt", "Veja pág. 12 e cap. 3.", "Veja página doze e capítulo três."),
    ("nl", "Mw. Peters, bijv. dit en o.a. dat.", "Mevrouw Peters, bijvoorbeeld dit en onder andere dat."),
    ("nl", "Dr. Smit, d.w.z. nu, t.o.v. hem.", "Doctor Smit, dat wil zeggen nu, ten opzichte van hem."),
    ("ru", "Он жил, т. е. долго, и т. д.", "Он жил, то есть долго, и так далее."),
    ("ru", "Подробно: см. рис. 3, длина 5 см. Потом.", "Подробно: смотри рисунок три, длина пять см. Потом."),
    ("ru", "Проф. Иванов и д-р Петров, напр. так.", "Профессор Иванов и доктор Петров, например так."),
    ("ru", "Жил на ул. Ленина, в г. Твери, из г. Москвы.", "Жил на улице Ленина, в городе Твери, из города Москвы."),
    ("ar", "وغيرها إلخ.", "وغيرها إلى آخره."),
    ("hi", "डॉ. शर्मा और प्रो. वर्मा", "डॉक्टर शर्मा और प्रोफेसर वर्मा"),
    ("ja", "㈱ABC", "株式会社ABC"),
])
def test_abbreviations(lang, src, want):
    assert normalize_paragraph(src, lang) == want


def test_abbreviation_helpers_dispatch_by_language():
    assert expand_abbreviations("Sr. García", "es") == "Señor García"
    assert expand_abbreviations("Sr. Smith", "en") == "Senior Smith"
    assert expand_numbers("5 €", "de") == "Fünf Euro"
    assert expand_symbols("a & b", "de") == "a und b"
    assert heading_to_speech("Kapitel 3", "de") == "Kapitel drei."


@pytest.mark.parametrize("lang, src, want", [
    ("es", "Tom & Jerry = 2 × 3 + 4 § 5", "Tom y Jerry igual a dos por tres más cuatro párrafo cinco"),
    ("de", "Tom & Jerry = 2 × 3 + 4", "Tom und Jerry gleich zwei mal drei plus vier"),
    ("it", "A & B = 2 × 3 + 4", "A e B uguale a due per tre più quattro"),
    ("pt", "A & B = 2 × 3 + 4", "A e B igual a dois vezes três mais quatro"),
    ("nl", "A & B = 2 × 3 + 4", "A en B is gelijk aan twee keer drie plus vier"),
    ("ru", "А & Б = 2 × 3 + 4", "А и Б равно два умножить на три плюс четыре"),
    ("zh", "A & B = 2 × 3 + 4", "A和B等于二乘三加四"),
    ("ja", "A & B = 2 × 3 + 4", "AアンドBイコール二かける三プラス四"),
])
def test_symbols(lang, src, want):
    assert normalize_paragraph(src, lang) == want


def test_a_currency_symbol_left_alone_is_spoken_as_the_currency():
    assert normalize_paragraph("millones de €", "es") == "millones de euros"
    assert normalize_paragraph("5 Mio. €", "de") == "Fünf Millionen Euro"
    assert normalize_paragraph("mijn €", "nl") == "mijn euro"


# ----------------------------------------------------------------------------- sentence capitals


@pytest.mark.parametrize("lang, src", [
    ("es", "Fin. Sr. García llegó."), ("de", "Ende. Prof. Meier kam."), ("it", "Fine. Il Sig. Rossi partì."),
    ("pt", "Fim. Sr. Silva chegou."), ("nl", "Einde. Dhr. Jansen kwam."), ("ru", "Конец. 5 человек пришли."),
    ("es", "Fin. 5 personas vinieron."), ("de", "Ende. 5 Leute kamen."),
])
def test_a_sentence_opened_by_an_expansion_keeps_its_capital(lang, src):
    out = normalize_paragraph(src, lang)
    sentences = split_sentences(out, lang)
    assert len(sentences) == 2, out
    assert sentences[1][0].isupper()


# ----------------------------------------------------------------------------- headings, sections


def test_heading_dispatch_and_sections():
    assert normalize_section(["Capítulo IV", "Cuesta 5 €."], "es", True, "Capítulo IV") == [
        "Capítulo cuatro.", "Cuesta cinco euros."]
    assert normalize_section(["Текст 5 минут."], "ru", False, "Глава 5") == ["Глава пятая.", "Текст пять минут."]
    # the title is in the text as an ordinary paragraph, and in the contents as another notation
    assert normalize_section(["KAPITEL IV", "Text."], "de", False, "Kapitel 4") == ["Kapitel vier.", "Text."]
    assert normalize_section(["第十二章", "文字。"], "zh", False, "第12章") == ["第十二章。", "文字。"]


@pytest.mark.parametrize("lang, src, want", [
    ("es", "Capítulo I", "Capítulo uno."), ("es", "XII", "Doce."), ("es", "PARTE II: EL VIAJE", "Parte dos. El viaje."),
    ("pt", "CAPÍTULO XXI - A viagem", "Capítulo vinte e um. - A viagem."),
    ("it", "I. Introduzione", "Uno. Introduzione."), ("it", "CAPITOLO 21", "Capitolo ventuno."),
    ("de", "Kapitel 21", "Kapitel einundzwanzig."), ("de", "Teil II", "Teil zwei."),
    ("nl", "HOOFDSTUK XII", "Hoofdstuk twaalf."), ("nl", "Deel II", "Deel twee."),
    ("ru", "Часть вторая", "Часть вторая."), ("ru", "Глава IV", "Глава четвёртая."), ("ru", "Том 2", "Том второй."),
    ("ru", "Акт II", "Акт второй."), ("ru", "12", "Двенадцать."),
    ("ar", "الفصل الرابع", "الفصل الرابع."), ("ar", "فصل 12", "فصل الثاني عشر."), ("ar", "12", "اثنا عشر."),
    ("ar", "الباب ٢١", "الباب الحادي والعشرون."), ("ar", "الجزء 3", "الجزء الثالث."),
    ("hi", "भाग 12 शुरुआत", "भाग 12। शुरुआत।"),
    ("zh", "第101章", "第一百零一章。"), ("zh", "第3节：开始", "第三节。开始。"), ("zh", "12", "十二。"),
    ("ja", "第三章", "第三章。"), ("ja", "30℃", "摂氏三十度。"), ("ja", "12", "十二。"),
    ("ko", "3장", "삼장."), ("ko", "12", "십이."), ("ko", "제12장 바다", "제십이장. 바다."),
])
def test_headings(lang, src, want):
    assert normalize_paragraph(src, lang, is_heading=True) == want


def test_a_heading_always_ends_with_a_terminator():
    for lang in NEW:
        for text in ["Titre", "第一章", "Intro 5"]:
            out = normalize_paragraph(text, lang, is_heading=True)
            assert out[-1] in ".!?…。！？؟۔।", (lang, out)


def test_small_caps_opening_and_acronyms():
    assert normalize_paragraph("MIJN vader was thuis.", "nl", is_section_opening=True) == "Mijn vader was thuis."
    assert normalize_paragraph("EL HOMBRE llegó tarde.", "es", is_section_opening=True) == "El Hombre llegó tarde."
    assert normalize_paragraph("ОН ушёл домой.", "ru", is_section_opening=True) == "Он ушёл домой."
    assert normalize_paragraph("NASA hat gesagt.", "de", is_section_opening=True) == "NASA hat gesagt."
    assert normalize_paragraph("США подписали.", "ru", is_section_opening=True) == "США подписали."
    # elsewhere an upper-case word is an acronym
    assert normalize_paragraph("Dit is de NASA.", "nl", is_section_opening=True) == "Dit is de NASA."


def test_all_caps_paragraphs_are_sentence_cased():
    assert normalize_paragraph("ЭТО ВСЁ ЧТО БЫЛО ТАМ", "ru") == "Это всё что было там"
    assert normalize_paragraph("DAS IST DAS ENDE. UND DANN", "de") == "Das ist das ende. Und dann"


def test_book_rules_apply_last():
    rules = Rules([("Müller", "Mueller", False), (r"\bzehn\b", "10", True)])
    assert normalize_paragraph("Herr Müller hat 10 Euro.", "de", rules) == "Herr Mueller hat 10 Euro."


# ----------------------------------------------------------------------------- properties


_TOKENS = {
    "es": ["Hola", "5", "1.234,56", "€", "$", "%", "XIV", "Sr.", "ª", "º", "10:30", "°C", "etc.", "¿Qué?", "1.º", "21"],
    "de": ["Hallo", "5", "3.", "1.234,56", "€", "%", "XIV.", "Dr.", "z. B.", "10:30", "°C", "usw.", "Uhr", "1999"],
    "it": ["Ciao", "5", "1.234,56", "€", "%", "XIV", "Sig.", "ecc.", "1°", "2ª", "10:30", "°C", "1", "maggio"],
    "pt": ["Olá", "5", "1.234,56", "€", "R$", "%", "XIV", "Sr.", "1º", "2ª", "10:30", "°C", "etc.", "hora"],
    "nl": ["Hallo", "5", "1.234,56", "€", "%", "XIV", "Dhr.", "2e", "8ste", "10:30", "°C", "enz.", "1999"],
    "ru": ["Привет", "5", "1 234,56", "₽", "%", "XIV", "г.", "5-й", "5-го", "10:30", "°C", "т. д.", "мая", "руб."],
    "zh": ["你好", "5", "1,234.56", "¥", "%", "2024年", "第3章", "10:30", "℃", "。", "，", "２", "个"],
    "ja": ["こんにちは", "5", "1,234.56", "¥", "%", "2024年", "第3章", "10:30", "℃", "。", "、", "３"],
    "ko": ["안녕", "5", "1,234.56", "₩", "%", "2024년", "제3장", "10:30", "℃", "명", "시", "6월"],
    "ar": ["مرحبا", "٥", "1,234.56", "$", "%", "الفصل", "10:30", "°C", "٫", "؟", "ـ"],
    "hi": ["नमस्ते", "5", "1,234.56", "%", "अध्याय", "डॉ.", "|", "।", "क्ष"],
}


@pytest.mark.parametrize("lang", NEW)
def test_random_text_never_breaks_the_rules(lang):
    rnd = random.Random(sum(map(ord, lang)))
    toks = _TOKENS[lang] + [".", ",", "!", "-", "\u00a0"]
    for glued in (False, True):
        for _ in range(300):
            parts = [rnd.choice(toks) for _ in range(rnd.randint(1, 20))]
            text = "".join(p + rnd.choice(["", " "]) for p in parts) if glued else " ".join(parts)
            for kw in ({}, {"is_heading": True}, {"is_section_opening": True}):
                out = normalize_paragraph(text, lang, **kw)
                assert isinstance(out, str)
                assert out == out.strip() and "  " not in out
                assert not any(0xE000 <= ord(c) < 0xF000 for c in out), (text, out)  # no private marker leaks
                # separate numbers are all spelled out (Hindi keeps digits; Arabic keeps clock times as written)
                if not glued and lang != "hi" and not (lang == "ar" and ":" in text):
                    assert not re.search(r"[0-9]", out), (lang, text, out)


@pytest.mark.parametrize("lang", NEW)
def test_normalising_is_deterministic_and_linear(lang):
    text = "Sr. 12.05.2024 1 000 000 € 3,5 % IV. XIV 5-й 2024年 " * 600
    t = time.perf_counter()
    first = normalize_paragraph(text, lang)
    assert time.perf_counter() - t < 6
    assert normalize_paragraph(text, lang) == first
    for hostile in ["1" * 20000, "1 " * 10000, "1." * 10000, "€" * 10000, "5 %" * 5000, "Capítulo IV " * 3000]:
        t = time.perf_counter()
        normalize_paragraph(hostile, lang)
        assert time.perf_counter() - t < 3, hostile[:20]


# ----------------------------------------------------------------------------- English and French unchanged


GOLDEN_NORM = [('en', 'It cost $5.', False, 'It cost five dollars.'),
 ('en',
  'It cost $1,250.50 in total.',
  False,
  'It cost one thousand, two hundred and fifty dollars and fifty cents in total.'),
 ('en', 'A £1 coin and a €2.50 stamp.', False, 'A one pound coin and a two euros and fifty cents stamp.'),
 ('en', 'About 50% of them, or 3.5 percent.', False, 'About fifty percent of them, or three point five percent.'),
 ('en', 'On the 21st of May 1873.', False, 'On the twenty-first of May eighteen seventy-three.'),
 ('en',
  "Born in 1873, she left in 2005; the 1920s were loud and the '80s louder.",
  False,
  'Born in eighteen seventy-three, she left in two thousand and five; the nineteen twenties were loud and the eighties '
  'louder.'),
 ('en', 'Pi is 3.14 roughly; 1,000,000 stars.', False, 'Pi is three point one four roughly; one million stars.'),
 ('en',
  'We met at 10:30, left at 7pm, the 4.50 from Paddington.',
  False,
  'We met at ten thirty, left at seven pm, the four fifty from Paddington.'),
 ('en',
  "Mr. and Mrs. Bennet met Dr. Jones and Prof. Smith at St. Paul's.",
  False,
  "Mister and Missus Bennet met Doctor Jones and Professor Smith at Saint Paul's."),
 ('en', 'Tom & Jerry = friends + 2 × fun § 4.', False, 'Tom and Jerry equals friends plus two times fun section four.'),
 ('en', 'See www.gutenberg.org/ebooks/1342 for more.[12] Next.', False, 'See gutenberg.org for more. Next.'),
 ('en',
  'It was “quoted” and it’s fine… 3°C or 30 °F or 45°.',
  False,
  'It was "quoted" and it\'s fine... three degrees Celsius or thirty degrees Fahrenheit or forty-five degrees.'),
 ('en',
  'Chapter XIV: George V and Louis XIV in the XIX century, Act II, Scene I, vol. 3 p. 12.',
  False,
  'Chapter fourteen: George the Fifth and Louis the Fourteenth in the XIX century, Act two, Scene one, volume three '
  'page twelve.'),
 ('en',
  'He lives on Baker St. The rooms were small. J. K. Rowling, the U.S. Army, etc. and so on.',
  False,
  'He lives on Baker Street. The rooms were small. J. K. Rowling, the U.S. Army, et cetera and so on.'),
 ('en', 'HAPPY for all the people and NASA too.', False, 'HAPPY for all the people and NASA too.'),
 ('en', 'THE END OF THE STORY IS HERE', False, 'The end of the story is here'),
 ('en',
  'Room 101 102 103, call 555 1234, 12345678901234567890.',
  False,
  'Room one hundred and one one hundred and two one hundred and three, call five hundred and fifty-five twelve '
  'thirty-four, one two three four five six seven eight nine zero one two three four five six seven eight nine zero.'),
 ('en',
  'He won by 1.50 metres and rose by 2.25 points at 3.00 against Leeds.',
  False,
  "He won by one point five zero metres and rose by two point two five points at three o'clock against Leeds."),
 ('en', 'It cost $5.', True, 'It cost five dollars.'),
 ('en',
  'It cost $1,250.50 in total.',
  True,
  'It cost one thousand, two hundred and fifty dollars and fifty cents in total.'),
 ('en', 'A £1 coin and a €2.50 stamp.', True, 'A one pound coin and a two euros and fifty cents stamp.'),
 ('en', 'About 50% of them, or 3.5 percent.', True, 'About fifty percent of them, or three point five percent.'),
 ('fr',
  "Il a payé 10 €, puis 3,50 € et 1 000 000 d'euros.",
  False,
  "Il a payé dix euros, puis trois euros cinquante et un million d'euros."),
 ('fr',
  'Environ 50 % des gens, 3,14 environ, 2,05 kilos.',
  False,
  'Environ cinquante pour cent des gens, trois virgule quatorze environ, deux virgule zéro cinq kilos.'),
 ('fr',
  'Le 1er mai et la 1re fois, le XIXe siècle, François Ier, Louis XIV.',
  False,
  'Le premier mai et la première fois, le dix-neuvième siècle, François premier, Louis quatorze.'),
 ('fr',
  'Il y avait 10 000 soldats en 1873, soit 1 500 000 hommes.',
  False,
  'Il y avait dix mille soldats en mille huit cent soixante-treize, soit un million cinq cent mille hommes.'),
 ('fr',
  'M. Fogg et Mme Aouda, MM. Dupont, Mlle Ève, Dr Martin, Me Durand.',
  False,
  'Monsieur Fogg et Madame Aouda, Messieurs Dupont, Mademoiselle Ève, Docteur Martin, Maître Durand.'),
 ('fr',
  'Rendez-vous à 10h30, à 8 h 30 ou à 10:15.',
  False,
  'Rendez-vous à dix heures trente, à huit heures trente ou à dix heures quinze.'),
 ('fr',
  'Voir p. 12, chap. IV, vol. 3, n° 5 etc. Puis cf. c.-à-d. p. ex. ceci.',
  False,
  "Voir page douze, chapitre quatre, volume trois, numéro cinq et cetera. Puis confer c'est-à-dire par exemple ceci."),
 ('fr',
  'Il fait 30°C, 20 °F, ou 45°. Tom & Jerry = 2 × 3 + 4.',
  False,
  'Il fait trente degrés Celsius, vingt degrés Fahrenheit, ou quarante-cinq degrés. Tom et Jerry égale deux fois trois '
  'plus quatre.'),
 ('fr',
  '« Où allez-vous ? » demanda-t-elle. — Nulle part.',
  False,
  '« Où allez-vous ? » demanda-t-elle. — Nulle part.'),
 ('fr', 'LE CHAPITRE DEUX COMMENCE ICI', False, 'Le chapitre deux commence ici'),
 ('fr', 'UN jour, il partit.', False, 'UN jour, il partit.'),
 ('fr',
  'Chambres 101 102 103 et 999 999 999 francs.',
  False,
  'Chambres cent un cent deux cent trois et neuf cent quatre-vingt-dix-neuf millions neuf cent quatre-vingt-dix-neuf '
  'mille neuf cent quatre-vingt-dix-neuf francs.'),
 ('fr',
  "Il a payé 10 €, puis 3,50 € et 1 000 000 d'euros.",
  True,
  "Il a payé dix euros, puis trois euros cinquante et un million d'euros."),
 ('fr',
  'Environ 50 % des gens, 3,14 environ, 2,05 kilos.',
  True,
  'Environ cinquante pour cent des gens, trois virgule quatorze environ, deux virgule zéro cinq kilos.'),
 ('fr',
  'Le 1er mai et la 1re fois, le XIXe siècle, François Ier, Louis XIV.',
  True,
  'Le premier mai et la première fois, le dix-neuvième siècle, François premier, Louis quatorze.'),
 ('fr',
  'Il y avait 10 000 soldats en 1873, soit 1 500 000 hommes.',
  True,
  'Il y avait dix mille soldats en mille huit cent soixante-treize, soit un million cinq cent mille hommes.')]

GOLDEN_HEAD = [('en', 'CHAPTER XLV.', 'Chapter forty-five.'),
 ('en', 'Chapter 3: The Return', 'Chapter three. The Return.'),
 ('en', 'I. The Beginning', 'One. The Beginning.'),
 ('en', 'XII', 'Twelve.'),
 ('en', 'I Remember Mama', 'I Remember Mama.'),
 ('en', 'Part II', 'Part two.'),
 ('fr', 'CHAPITRE XII.', 'Chapitre douze.'),
 ('fr', 'XII OÙ PHILEAS FOGG', 'Douze. Où phileas fogg.'),
 ('fr', 'Livre premier', 'Livre premier.'),
 ('fr', 'Partie III — La guerre', 'Partie trois. — La guerre.'),
 ('fr', 'DIX ANS', 'Dix ans.')]



@pytest.mark.parametrize("lang, src, opening, want", GOLDEN_NORM)
def test_english_and_french_normalisation_is_unchanged(lang, src, opening, want):
    assert normalize_paragraph(src, lang, is_section_opening=opening) == want


@pytest.mark.parametrize("lang, src, want", GOLDEN_HEAD)
def test_english_and_french_headings_are_unchanged(lang, src, want):
    assert normalize_paragraph(src, lang, is_heading=True) == want
    assert heading_to_speech(src.strip(), lang)  # same entry point, still the English/French rules


def test_heading_entry_point_cleans_its_input_for_arabic_and_cjk():
    assert heading_to_speech("الفصل ٤", "ar") == "الفصل الرابع."
    assert heading_to_speech("第１２章 風雪", "zh") == "第十二章。風雪"


def test_chinese_and_japanese_quotes_keep_their_direction():
    assert normalize_paragraph("他说：“你好。”她说：‘好’。", "zh") == "他说：「你好。」她说：『好』。"
    assert normalize_paragraph("“多少钱？”李先生问。“三块。”", "zh") == "「多少钱？」李先生问。「三块。」"
    sentences = split_sentences(normalize_paragraph("“多少钱？”李先生问。“三块。”", "zh"), "zh")
    assert sentences == ["「多少钱？」", "李先生问。", "「三块。」"]
    # other languages keep the generic straight quotes
    assert normalize_paragraph("Er sagte „Hallo“.", "de") == 'Er sagte "Hallo".'
