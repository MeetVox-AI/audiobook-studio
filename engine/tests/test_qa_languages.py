"""Speech-check scoring for every language: a correct reading scores ~0, harmless Whisper spelling variants are
not flagged, dropped words and sentences are."""

from __future__ import annotations

import pytest

from audiobook_engine.qa import verify
from audiobook_engine.qa.verify import fold, fold_words, score, score_packed

# lang -> (reference text, harmless Whisper variant, a version with the second half dropped)
CASES = {
    "es": ("¿Habría llegado ya el cartero? Hacía una semana que esperaba una carta de su hermano.",
           "habria llegado ya el cartero hacia una semana que esperaba una carta de su hermano",
           "habría llegado ya el cartero. Hacía una semana que esperaba."),
    "de": ("Die Straße führte über den Fluß zur Müllerei, und Österreich lag weit entfernt hinter den Bergen.",
           "Die Strasse fuehrte ueber den Fluss zur Muellerei und Oesterreich lag weit entfernt hinter den Bergen",
           "Die Straße führte über den Fluss zur Müllerei."),
    "it": ("L'uomo andò all'università e comprò un po' di pane più tardi, perché aveva fame.",
           "L'uomo andò all'università e comprò un po di pane piu tardi perche aveva fame",
           "L'uomo andò all'università e comprò un po' di pane."),
    "pt": ("A criança não conseguiu encontrar a maçã que tinha deixado na cozinha antes de sair.",
           "A crianca nao conseguiu encontrar a maca que tinha deixado na cozinha antes de sair",
           "A criança não conseguiu encontrar a maçã."),
    "nl": ("De postbode ging naar het café en bestelde een kopje koffie met melk voor de reis.",
           "De postbode ging naar het cafe en bestelde een kopje koffie met melk voor de reis",
           "De postbode ging naar het café en bestelde."),
    "ru": ("Ёжик пошёл в лес, где всё было тихо и спокойно, и долго собирал грибы под деревьями.",
           "Ежик пошел в лес где все было тихо и спокойно и долго собирал грибы под деревьями",
           "Ёжик пошёл в лес, где всё было тихо и спокойно."),
    "ko": ("그녀는 저도 모르게 미소를 지었다. 우체부가 벌써 다녀갔을까? 오빠의 편지를 기다린 지 벌써 일주일이었다.",
           "그녀는 저도 모르게 미소를 지었다 우체부가 벌써 다녀 갔을까 오빠의 편지를 기다린지 벌써 일주일 이었다",
           "그녀는 저도 모르게 미소를 지었다."),
    "hi": ("हिन्दी भाषा में क़िताब पढ़ना मुझे बहुत अच्छा लगता है। आँगन में बैठकर चाय पीना भी।",
           "हिंदी भाषा में किताब पढ़ना मुझे बहुत अच्छा लगता है आंगन में बैठकर चाय पीना भी",
           "हिन्दी भाषा में किताब पढ़ना मुझे बहुत अच्छा लगता है।"),
    "ar": ("عندما طلع الفجر كانت القرية لا تزال نائمة، ومن نافذة المطبخ كان يُرى الجبل مغطى بالضباب.",
           "عندما طلع الفجر كانت القريه لا تزال نائمه ومن نافذه المطبخ كان يرى الجبل مغطى بالضباب",
           "عندما طلع الفجر كانت القرية لا تزال نائمة."),
    "zh": ("天亮的时候，村子还在沉睡。从厨房的窗口望出去，山笼罩在薄雾里，山脚下的河水缓缓流过一排杨树。",
           "天亮的時候，村子還在沉睡。從廚房的窗口望出去，山籠罩在薄霧裡，山腳下的河水緩緩流過一排楊樹。",
           "天亮的时候，村子还在沉睡。"),
    "ja": ("夜が明けるころ、村はまだ眠っていました。台所の窓からは、霧に包まれた山が見えます。",
           "夜が明けるころ、村はまだ眠っていました。台所の窓からは、霧に包まれた山がみえます。",
           "夜が明けるころ、村はまだ眠っていました。"),
    "en": ("The old man walked slowly to the window and looked out at the calm grey sea this morning.",
           "the old man walked slowly to the window and looked out at the calm gray sea this morning",
           "The old man walked slowly to the window."),
    "fr": ("Il marchait le long du quai, pensant à la lettre qu'elle lui avait écrite pour son retour.",
           "Il marchait le long du quai pensant à la lettre qu'elle lui avait écrit pour son retour",
           "Il marchait le long du quai, pensant à la lettre."),
}


@pytest.mark.parametrize("lang", CASES)
def test_correct_reading_scores_zero(lang):
    ref = CASES[lang][0]
    s = score(ref, ref, lang)
    assert s.cer == 0 and not s.bad and s.chars > 20


@pytest.mark.parametrize("lang", CASES)
def test_harmless_whisper_variants_are_not_flagged(lang):
    ref, variant, _ = CASES[lang]
    assert not score(ref, variant, lang).bad


@pytest.mark.parametrize("lang", CASES)
def test_a_dropped_sentence_is_flagged(lang):
    ref, _, dropped = CASES[lang]
    s = score(ref, dropped, lang)
    assert s.bad and s.cer > 0.15


@pytest.mark.parametrize("lang", CASES)
def test_hallucinated_tail_is_flagged(lang):
    ref = CASES[lang][0]
    tail = {"zh": "谢谢观看请订阅我们的频道并且点赞分享", "ja": "ご視聴ありがとうございましたチャンネル登録お願いします",
            "ko": "시청해 주셔서 감사합니다 구독과 좋아요 부탁드립니다 안녕히 계세요",
            "ar": "شكرا لكم على المشاهدة لا تنسوا الاشتراك في القناة", "hi": "देखने के लिए धन्यवाद चैनल को सब्सक्राइब करना न भूलें",
            "ru": "спасибо за просмотр подписывайтесь на наш канал и ставьте лайки"}.get(
        lang, "thank you for watching please subscribe to the channel and like the video")
    s = score(ref, ref + " " + tail, lang)
    assert s.bad


def test_en_fr_scores_use_the_original_thresholds():
    s = score("abc def", "abc def", "en")
    assert s.lang == "" and "lang" not in s.to_json() and "variant_suspect" not in s.to_json()


# ----------------------------------------------------------------------------- script specific folding

def test_german_umlaut_and_eszett_spellings():
    assert fold("Müller aß Brötchen für Größe", "de") == fold("Mueller ass Broetchen fuer Groesse", "de")


def test_russian_yo_stress_and_case():
    assert fold("Всё ЕЩЁ тут", "ru") == fold("все еще тут", "ru")
    assert fold("до́ма", "ru") == fold("дома", "ru")
    assert fold("и", "ru") != fold("й", "ru")  # short i stays distinct


def test_arabic_tashkeel_tatweel_and_letter_variants():
    assert fold("كَتَبَ الطِّفْلُ", "ar") == fold("كتب الطفل", "ar")
    assert fold("الـــعربية", "ar") == fold("العربيه", "ar")
    assert fold("أحمد إلى آمنة", "ar") == fold("احمد الى امنة", "ar")
    assert fold("على مدرسة", "ar") == fold("علي مدرسه", "ar")
    assert fold("عام ٢٠٢٤", "ar") == fold("عام 2024", "ar")


def test_hindi_nukta_chandrabindu_and_nasals():
    assert fold("क़िताब", "hi") == fold("किताब", "hi")
    assert fold("आँगन", "hi") == fold("आंगन", "hi")
    assert fold("हिन्दी", "hi") == fold("हिंदी", "hi")
    assert fold("बच्चा।", "hi") == fold("बच्चा", "hi")
    assert verify._fold_hi("१२३") == "123"
    assert fold("पानी", "hi") != fold("पाणी", "hi")  # real differences survive


def test_korean_spacing_does_not_matter_for_characters():
    assert fold("할 수 있다", "ko") == fold("할수있다", "ko")
    assert len(fold_words("할 수 있다", "ko")) == 3


def test_chinese_and_japanese_are_scored_per_character():
    assert fold_words("你好，世界！", "zh") == list("你好世界")
    assert fold_words("こんにちは。", "ja") == list("こんにちは")
    # katakana vs hiragana spelling of the same word, hanzi digits vs arabic digits
    assert fold("コーヒー", "ja") == fold("こーひー", "ja")
    assert fold("二〇二四年", "zh") == fold("2024年", "zh")


def test_chinese_traditional_variants_are_folded_or_judged_conservatively():
    ref = "他们说这个国家的学生都会来开会，讨论明天的问题，并且一起准备晚饭和水果。"
    trad_common = "他們說這個國家的學生都會來開會，討論明天的問題，並且一起準備晚飯和水果。"
    assert not score(ref, trad_common, "zh").bad
    # characters outside the built-in pairs: only one-for-one substitutions -> looser verdict, flagged as suspect
    rare = ref.replace("讨论", "討論").replace("准备", "準備").replace("晚饭", "晚飯").replace("水果", "水菓")
    s = score(ref, rare, "zh")
    assert not s.bad
    # but a dropped half sentence is still bad, whatever the script
    assert score(ref, "他们说这个国家的学生都会来开会", "zh").bad
    assert score(ref, "他们说这个国家的学生都会来开会", "zh").to_json()["bad"] is True


def test_cjk_short_chunk_is_judged_by_absolute_errors():
    assert not score("你好吗", "你好吗", "zh").bad
    assert not score("你好吗", "你好", "zh").bad  # tiny chunks: only gross failures matter


def test_cjk_deletion_runs_count_characters_not_words():
    ref = "春天来了花开了鸟叫了我们去公园玩耍吧天气真好大家都很高兴"
    one_clause = ref.replace("我们去公园玩耍吧", "")
    assert score(ref, one_clause, "zh").max_deletion_run == 8


def test_packed_scoring_for_cjk_attributes_errors_to_the_right_chunk():
    a = "春天来了花开了鸟叫了我们去公园玩耍大家都很高兴"
    b = "夏天到了我们去海边游泳晒太阳吃冰淇淋喝汽水然后一起回家休息"
    s = score_packed([a, b], a + "夏天到了我们去海边", "zh")
    assert not s[0].bad and s[1].bad


def test_packed_scoring_arabic_and_hindi():
    for lang in ("ar", "hi"):
        s = score_packed([CASES[lang][0], CASES[lang][1]], CASES[lang][0] + " " + CASES[lang][1], lang)
        assert not s[0].bad and not s[1].bad


def test_text_with_nothing_comparable_gets_no_verdict_in_each_script():
    assert not score("... !!", "anything", "ar").bad
    assert not score("、。", "いいえ", "ja").bad


def test_whisper_receives_the_bare_language_code():
    assert verify.Verifier("pt-BR").lang == "pt" and verify.Verifier("zh").lang == "zh"
    seen = {}

    class M:
        def generate(self, audio, **kw):
            seen.update(kw)
            return type("O", (), {"text": "x"})()

    for code in ("de", "zh", "ar"):
        v = verify.Verifier(code)
        v.model = M()
        seen.clear()
        v.transcribe(__import__("numpy").zeros(10, "float32"))
        assert seen["language"] == code
        assert ("initial_prompt" in seen) == (code == "zh")
