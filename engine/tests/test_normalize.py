from __future__ import annotations

import pytest

from audiobook_engine.textproc.normalize import (
    Rules,
    heading_to_speech,
    normalize_paragraph,
    normalize_section,
    roman_to_int,
)


def en(t, **kw):
    return normalize_paragraph(t, "en", **kw)


def fr(t, **kw):
    return normalize_paragraph(t, "fr", **kw)


@pytest.mark.parametrize("src, want", [
    ("It cost $5.", "It cost five dollars."),
    ("It cost $1,250.50 in total.", "It cost one thousand, two hundred and fifty dollars and fifty cents in total."),
    ("A £1 coin.", "A one pound coin."),
    ("About 50% of them.", "About fifty percent of them."),
    ("On the 21st of May.", "On the twenty-first of May."),
    ("Born in 1873, she left in 2005.", "Born in eighteen seventy-three, she left in two thousand and five."),
    ("The 1920s were loud.", "The nineteen twenties were loud."),
    ("Pi is 3.14 roughly.", "Pi is three point one four roughly."),
    ("We met at 10:30.", "We met at ten thirty."),
    ("Meet at 9:05.", "Meet at nine oh five."),
    ("He counted 1,000,000 stars.", "He counted one million stars."),
    ("Mr. and Mrs. Bennet met Dr. Jones.", "Mister and Missus Bennet met Doctor Jones."),
    ("Tom & Jerry.", "Tom and Jerry."),
    ("See www.gutenberg.org/ebooks/1342 for more.", "See gutenberg.org for more."),
    ("A footnote here.[12] Next.", "A footnote here. Next."),
    ("It was “quoted” and it’s fine…", 'It was "quoted" and it\'s fine...'),
])
def test_english_rules(src, want):
    assert en(src) == want


@pytest.mark.parametrize("src, want", [
    ("Il a payé 10 €.", "Il a payé dix euros."),
    ("Environ 50 % des gens.", "Environ cinquante pour cent des gens."),
    ("Le 1er mai et la 1re fois.", "Le premier mai et la première fois."),
    ("Au XIXe siècle.", "Au dix-neuvième siècle."),
    ("François Ier régna.", "François premier régna."),
    ("Il y avait 10 000 soldats.", "Il y avait dix mille soldats."),
    ("Pi vaut 3,14 environ.", "Pi vaut trois virgule quatorze environ."),
    ("Il pèse 2,05 kilos.", "Il pèse deux virgule zéro cinq kilos."),
    ("M. Fogg et Mme Aouda.", "Monsieur Fogg et Madame Aouda."),
    ("Rendez-vous à 10h30.", "Rendez-vous à dix heures trente."),
    ("En 1873, il partit.", "En mille huit cent soixante-treize, il partit."),
])
def test_french_rules(src, want):
    assert fr(src) == want


@pytest.mark.parametrize("src", [
    "Le soleil se levait.", "Ce matin-là, il partit.", "Le XXe arrondissement est loin.",
])
def test_french_words_are_never_read_as_roman_ordinals(src):
    out = fr(src)
    assert "cinquantième" not in out and "centième" not in out
    assert out.startswith(src.split()[0])


@pytest.mark.parametrize("src, lang, want", [
    ("CHAPTER XLV.", "en", "Chapter forty-five."),
    ("Chapter I.", "en", "Chapter one."),
    ("XII", "fr", "Douze."),
    ("XII OÙ PHILEAS FOGG ET SES COMPAGNONS", "fr", "Douze. Où phileas fogg et ses compagnons"),
    ("I DANS LEQUEL PHILEAS FOGG", "fr", "Un. Dans lequel phileas fogg"),
    ("I. The Beginning", "en", "One. The Beginning"),
    ("I Remember Mama", "en", "I Remember Mama"),
    ("DIX ANS PLUS TARD", "fr", "Dix ans plus tard"),
    ("MIX TAPE", "en", "Mix tape"),
    ("Part 3: Home", "en", "Part three. Home"),
])
def test_headings(src, lang, want):
    assert heading_to_speech(src, lang) == want


def test_heading_paragraph_gets_final_punctuation():
    assert normalize_paragraph("CHAPTER XLV", "en", is_heading=True) == "Chapter forty-five."


def test_small_caps_opening_but_acronyms_later_kept():
    opening = {"is_section_opening": True}
    assert en("HAPPY for all her feelings, said the BBC.", **opening) == "Happy for all her feelings, said the BBC."
    assert en("MR. BENNET was among the earliest.", **opening) == "Mister Bennet was among the earliest."


def test_all_caps_paragraph_is_sentence_cased():
    assert en("PLEASE READ THIS BEFORE YOU GO") == "Please read this before you go"


def test_roman_parser_is_canonical():
    assert roman_to_int("XLV") == 45 and roman_to_int("MIX") == 1009
    assert roman_to_int("IIII") is None and roman_to_int("VX") is None and roman_to_int("Le") is None


def test_rules_apply_whole_words_and_regex():
    r = Rules([("Phileas", "Fi-lé-as", False), (r"\bFogg\b", "Fog", True)])
    assert normalize_paragraph("Phileas Fogg et Phileasx.", "fr", rules=r) == "Fi-lé-as Fog et Phileasx."


def test_section_speaks_title_when_text_lacks_heading():
    out = normalize_section(["It was a dark night."], "en", starts_with_heading=False, title="CHAPTER III")
    assert out == ["Chapter three.", "It was a dark night."]
    out = normalize_section(["CHAPTER III", "It was dark."], "en", starts_with_heading=True, title="ignored")
    assert out == ["Chapter three.", "It was dark."]


# ----------------------------------------------------------------------------- regression tests (review findings)

@pytest.mark.parametrize("src, want", [
    ("M. de Villefort entra.", "Monsieur de Villefort entra."),
    ("Il vit M. de Villefort.", "Il vit Monsieur de Villefort."),
    ("M. d’Artagnan arriva.", "Monsieur d'Artagnan arriva."),
    ("M. le comte sortit.", "Monsieur le comte sortit."),
    ("M. l'abbé vint.", "Monsieur l'abbé vint."),
    ("Il salua MM. de Rênal et Valenod.", "Il salua Messieurs de Rênal et Valenod."),
    ("Mr. Fogg partit avec Mrs. Aouda.", "Mister Fogg partit avec Missis Aouda."),
    ("J. M. Barrie écrivit.", "J. M. Barrie écrivit."),  # M. is an initial here, not Monsieur
])
def test_french_monsieur_before_particles_and_english_titles(src, want):
    assert fr(src) == want


def test_french_messieurs_survives_a_small_caps_opening():
    assert fr("MM. de Rênal et Valenod.", is_section_opening=True) == "Messieurs de Rênal et Valenod."
    assert normalize_section(["MM. de Rênal et Valenod."], "fr", False, "Un") == ["Un.", "Messieurs de Rênal et Valenod."]


@pytest.mark.parametrize("lang, src, want", [
    ("en", "It cost $5 million.", "It cost five million dollars."),
    ("en", "It cost $1.5 billion.", "It cost one point five billion dollars."),
    ("en", "It cost $5m.", "It cost five million dollars."),
    ("en", "It cost £2bn.", "It cost two billion pounds."),
    ("en", "It cost $3k.", "It cost three thousand dollars."),
    ("fr", "Il coûte 1 000 000 €.", "Il coûte un million d'euros."),
    ("fr", "Il coûte 2 000 000 €.", "Il coûte deux millions d'euros."),
    ("fr", "Il coûte 1,5 million €.", "Il coûte un virgule cinq million d'euros."),
    ("fr", "Il coûte 3 M€.", "Il coûte trois millions d'euros."),
    ("fr", "Il coûte 2 000 000 $.", "Il coûte deux millions de dollars."),
])
def test_currency_with_magnitude(lang, src, want):
    assert normalize_paragraph(src, lang) == want


@pytest.mark.parametrize("lang, src, want", [
    ("en", "The 1,000th visitor.", "The one thousandth visitor."),
    ("en", "The 10,000th visitor.", "The ten thousandth visitor."),
    ("fr", "Le 10 000e visiteur.", "Le dix millième visiteur."),
    ("fr", "Le 10 000e visiteur.", "Le dix millième visiteur."),
])
def test_grouped_ordinals(lang, src, want):
    assert normalize_paragraph(src, lang) == want


@pytest.mark.parametrize("src, want", [
    ("Rendez-vous à 10h.", "Rendez-vous à dix heures."),
    ("Il est 8 h 30.", "Il est huit heures trente."),
    ("Il arriva à 10 h 30 précises.", "Il arriva à dix heures trente précises."),
    ("Il dort 2 h par nuit.", "Il dort deux heures par nuit."),
    ("Ils étaient 2 hommes.", "Ils étaient deux hommes."),
])
def test_french_hours_with_h(src, want):
    assert fr(src) == want


@pytest.mark.parametrize("src, want", [
    ("À 1h05.", "À une heure cinq."),
    ("À 1h00.", "À une heure."),
    ("À 21h15.", "À vingt et une heures quinze."),
    ("À 0h30.", "À zéro heure trente."),
    ("À 10h21.", "À dix heures vingt et une."),
])
def test_french_clock_is_feminine(src, want):
    assert fr(src) == want


@pytest.mark.parametrize("lang, src, want", [
    ("en", "It was 30°C outside.", "It was thirty degrees Celsius outside."),
    ("en", "It was 20 °F.", "It was twenty degrees Fahrenheit."),
    ("en", "A 1° drop.", "A one degree drop."),
    ("en", "A 21° turn.", "A twenty-one degrees turn."),
    ("en", "Turn 45°.", "Turn forty-five degrees."),
    ("fr", "Il faisait 20°C.", "Il faisait vingt degrés Celsius."),
    ("fr", "N° 12 de la rue.", "numéro douze de la rue."),
    ("fr", "Le nº 5.", "Le numéro cinq."),
])
def test_degrees_and_numero(lang, src, want):
    assert normalize_paragraph(src, lang) == want


@pytest.mark.parametrize("src, want", [
    ("He lived at 221B Baker St. The rooms were small.", "He lived at 221B Baker Street. The rooms were small."),
    ("Baker St. was busy.", "Baker Street was busy."),
    ("He lived on Baker St.", "He lived on Baker Street."),
    ("St. Paul preached.", "Saint Paul preached."),
    ("Mount St. Helens erupted.", "Mount Saint Helens erupted."),
])
def test_street_abbreviation_keeps_the_sentence_period(src, want):
    assert en(src) == want


@pytest.mark.parametrize("lang, src, want", [
    ("en", "Apples, pears, etc. Then he left.", "Apples, pears, et cetera. Then he left."),
    ("en", "Apples, pears, etc., all ripe.", "Apples, pears, et cetera, all ripe."),
    ("en", "Martin Luther King Jr. He spoke.", "Martin Luther King Junior. He spoke."),
    ("en", "Martin Luther King Jr. Day.", "Martin Luther King Junior Day."),
    ("en", "Visit www.example.com. Then leave.", "Visit example.com. Then leave."),
    ("en", "(See https://example.com/a/b.) Then.", "(See example.com.) Then."),
    ("fr", "Des pommes, etc. Puis il partit.", "Des pommes, et cetera. Puis il partit."),
])
def test_sentence_final_abbreviation_and_url_keep_the_period(lang, src, want):
    assert normalize_paragraph(src, lang) == want


@pytest.mark.parametrize("src, want", [
    ("Il paya 3,50 €.", "Il paya trois euros cinquante."),
    ("Il paya 1,99 $.", "Il paya un dollar quatre-vingt-dix-neuf."),
    ("Il paya 5 €50.", "Il paya cinq euros cinquante."),
    ("Il paya 0,50 €.", "Il paya cinquante centimes."),
    ("Il paya 4,00 €.", "Il paya quatre euros."),
])
def test_french_prices(src, want):
    assert fr(src) == want


@pytest.mark.parametrize("src, want", [
    ("We met at 10.30 p.m. yesterday.", "We met at ten thirty p.m. yesterday."),
    ("We met at 10.30.", "We met at ten thirty."),
    ("He took the 4.50 from Paddington.", "He took the four fifty from Paddington."),
    ("Wait until 9.05.", "Wait until nine oh five."),
    ("It weighs 2.50 kilos.", "It weighs two point five zero kilos."),
    ("The wall rose by 1.50 metres.", "The wall rose by one point five zero metres."),
])
def test_british_dotted_times(src, want):
    assert en(src) == want


@pytest.mark.parametrize("src, want", [
    ("In 1066 the Normans came.", "In ten sixty-six the Normans came."),
    ("By October 1066 it was over.", "By October ten sixty-six it was over."),
    ("A force of 1050 men.", "A force of one thousand and fifty men."),
    ("The 1920’s were loud.", "The nineteen twenties were loud."),
    ("Music of the ’80s.", "Music of the eighties."),
    ("He was in his 30s.", "He was in his thirties."),
    ("Born in 1873's spring.", "Born in eighteen seventy-three's spring."),
])
def test_english_years_and_decades(src, want):
    assert en(src) == want


@pytest.mark.parametrize("src, want", [
    ("Les chambres 101 102 103 étaient vides.", "Les chambres cent un cent deux cent trois étaient vides."),
    ("Il y avait 100 000 soldats.", "Il y avait cent mille soldats."),
    ("Il y avait 125 432 habitants.", "Il y avait cent vingt-cinq mille quatre cent trente-deux habitants."),
    ("Il y avait 1 500 000 habitants.", "Il y avait un million cinq cent mille habitants."),
    ("Il y eut en 1914 18 000 morts.", "Il y eut en mille neuf cent quatorze dix-huit mille morts."),
    ("Il y avait 123 456 789 étoiles.",
     "Il y avait cent vingt-trois millions quatre cent cinquante-six mille sept cent quatre-vingt-neuf étoiles."),
])
def test_french_thousands_grouping(src, want):
    assert fr(src) == want


@pytest.mark.parametrize("lang, src, want", [
    ("fr", "Le XVIIIe et le XIXe siècles.", "Le dix-huitième et le dix-neuvième siècles."),
    ("fr", "Le IIIe Reich.", "Le troisième Reich."),
    ("fr", "Louis XIV régna.", "Louis quatorze régna."),
    ("fr", "Au chapitre XII, il partit.", "Au chapitre douze, il partit."),
    ("en", "Louis XIV's court.", "Louis the Fourteenth's court."),
    ("en", "Henry VIII had six wives.", "Henry the Eighth had six wives."),
    ("en", "Chapter XIV begins.", "Chapter fourteen begins."),
    ("en", "After World War II ended.", "After World War two ended."),
    ("en", "Act I, Scene II.", "Act one, Scene two."),
    ("en", "For my part I think so.", "For my part I think so."),
    ("en", "When John I met him.", "When John I met him."),
])
def test_roman_numerals_in_running_text(lang, src, want):
    assert normalize_paragraph(src, lang) == want


@pytest.mark.parametrize("src", ["Le siècle des Lumières.", "Ce siècle avait deux ans."])
def test_french_le_and_ce_before_siecle_are_not_roman(src):
    assert fr(src) == src


def test_small_caps_fix_only_at_section_opening():
    # mid-chapter, an opening upper-case word is an acronym
    assert en("US officials said no.") == "US officials said no."
    assert en("IT staff left.") == "IT staff left."
    out = normalize_section(["IT is a truth universally acknowledged.", "US officials said no."], "en",
                            starts_with_heading=False, title="Chapter 1")
    assert out == ["Chapter one.", "It is a truth universally acknowledged.", "US officials said no."]
    # the opening is the first body paragraph after the heading (and after empty paragraphs)
    out = normalize_section(["CHAPTER I", " ", "HAPPY for all.", "FBI agents arrived."], "en",
                            starts_with_heading=True, title="x")
    assert out == ["Chapter one.", "Happy for all.", "FBI agents arrived."]


def test_small_caps_opening_keeps_a_lone_acronym():
    assert en("US officials said no.", is_section_opening=True) == "US officials said no."
    assert en("AI models are everywhere now.", is_section_opening=True) == "AI models are everywhere now."


@pytest.mark.parametrize("paragraphs, title", [
    (["CHAPTER III", "It was dark."], "Chapter III"),
    (["Chapter III.", "It was dark."], "CHAPTER III"),
    (["CHAPTER III", "It was dark."], "Chapter 3"),
])
def test_section_does_not_repeat_a_title_styled_as_a_paragraph(paragraphs, title):
    assert normalize_section(paragraphs, "en", starts_with_heading=False, title=title) == ["Chapter three.", "It was dark."]


def test_section_does_not_speak_a_title_cut_from_its_first_paragraph():
    p0 = "It was a bright cold day in April, and the clocks were striking thirteen."
    assert normalize_section([p0], "en", starts_with_heading=False, title=p0[:60]) == [p0]
    # a real title that the text happens to repeat is still announced
    out = normalize_section(["Spring came early that year."], "en", starts_with_heading=False, title="Spring")
    assert out == ["Spring.", "Spring came early that year."]


# ----------------------------------------------------------------------------- regression tests (round 2)

@pytest.mark.parametrize("src, want", [
    # an ordinary space between 3-digit groups: never a stray "zéro", never a number cut in two
    ("Il compta 123 100 000 voix.", "Il compta cent vingt-trois millions cent mille voix."),
    ("Il avait 123 456 000 francs.", "Il avait cent vingt-trois millions quatre cent cinquante-six mille francs."),
    ("Il avait 100 000 123 francs.", "Il avait cent millions cent vingt-trois francs."),
    ("En 1870 300 000 soldats moururent.", "En mille huit cent soixante-dix trois cent mille soldats moururent."),
    ("En 2015 120 000 personnes.", "En deux mille quinze cent vingt mille personnes."),
    ("La Terre est à 149 600 000 km.", "La Terre est à cent quarante-neuf millions six cent mille km."),
    ("Une hausse de 839 514 000 %.", "Une hausse de huit cent trente-neuf millions cinq cent quatorze mille pour cent."),
    ("Il y avait 331 449 281 habitants.",
     "Il y avait trois cent trente et un millions quatre cent quarante-neuf mille deux cent quatre-vingt-un habitants."),
    # a run that looks like a list stays a list
    ("Les chambres 101 102 103 étaient vides.", "Les chambres cent un cent deux cent trois étaient vides."),
])
def test_french_plain_space_thousands(src, want):
    assert fr(src) == want


@pytest.mark.parametrize("src, want", [
    # decimals after at/by/from stay decimals
    ("It peaked at 1.45 million.", "It peaked at one point four five million."),
    ("He won by 2.15 seconds.", "He won by two point one five seconds."),
    ("The delay grew by 1.30 hours.", "The delay grew by one point three zero hours."),
    ("Inflation fell by 0.25 last month.", "Inflation fell by zero point two five last month."),
    ("The pound traded at 1.15 against the dollar.", "The pound traded at one point one five against the dollar."),
    ("The odds were cut from 2.50 to 1.80.", "The odds were cut from two point five zero to one point eight zero."),
    ("The odds were cut from 2.50 to 1.45.", "The odds were cut from two point five zero to one point four five."),
    ("Unemployment rose by 1.10 percentage points.", "Unemployment rose by one point one zero percentage points."),
    ("Prices rose by 1.25 last year.", "Prices rose by one point two five last year."),
    ("The shares were valued at 1.15 each.", "The shares were valued at one point one five each."),
    ("It varied between 1.15 and 1.45.", "It varied between one point one five and one point four five."),
    # times, wherever the sentence starts
    ("At 10.30 we left.", "At ten thirty we left."),
    ("From 9.15 to 10.45 we waited.", "From nine fifteen to ten forty-five we waited."),
    ("Until 6.30 nothing happened.", "Until six thirty nothing happened."),
    ("Be home by 6.30.", "Be home by six thirty."),
    ("He rose at 6.30 and dressed.", "He rose at six thirty and dressed."),
    ("We met at 4.30 each day.", "We met at four thirty each day."),
    ("Between 9.15 and 10.45 nobody came.", "Between nine fifteen and ten forty-five nobody came."),
    ("Open from 9.30-5.30 daily.", "Open from nine thirty to five thirty daily."),
    # am/pm glued to the time
    ("We met at 10.30am.", "We met at ten thirty am."),
    ("We met at 10:30pm.", "We met at ten thirty pm."),
    ("Dinner is at 7pm.", "Dinner is at seven pm."),
    ("It opens at 10:00 a.m.", "It opens at ten a.m."),
])
def test_british_dotted_times_and_decimals(src, want):
    assert en(src) == want


@pytest.mark.parametrize("lang, src, want", [
    ("en", "The novelist George V. Higgins wrote it.", "The novelist George V. Higgins wrote it."),
    ("en", "John V. Lindsay was mayor.", "John V. Lindsay was mayor."),
    ("en", "Louis V. Gerstner led IBM.", "Louis V. Gerstner led IBM."),
    ("fr", "Jean V. Dupont signa.", "Jean V. Dupont signa."),
    ("en", "George V. He was king.", "George the Fifth. He was king."),
    ("en", "It was under George V.", "It was under George the Fifth."),
    ("fr", "Charles V. Il mourut.", "Charles cinq. Il mourut."),
])
def test_regnal_v_is_not_a_middle_initial(lang, src, want):
    assert normalize_paragraph(src, lang) == want


@pytest.mark.parametrize("lang, src, want", [
    ("en", "A fever of 101°F.", "A fever of one hundred and one degrees Fahrenheit."),
    ("en", "It turned 201°.", "It turned two hundred and one degrees."),
    ("en", "At 1,001°C.", "At one thousand and one degrees Celsius."),
    ("fr", "Il faisait 101°.", "Il faisait cent un degrés."),
    ("fr", "Il faisait 21°.", "Il faisait vingt et un degrés."),
    ("fr", "Il faisait 0°C.", "Il faisait zéro degré Celsius."),
    ("en", "It was 0°C.", "It was zero degrees Celsius."),
    ("en", "A 1° drop.", "A one degree drop."),
    ("en", "The kiln reached 1200°C.", "The kiln reached twelve hundred degrees Celsius."),
])
def test_degree_singular_only_for_one(lang, src, want):
    assert normalize_paragraph(src, lang) == want


@pytest.mark.parametrize("src, want", [
    ("Ils virent J.M. de Villefort.", "Ils virent J.M. de Villefort."),
    ("Ils virent J.M. Dupont.", "Ils virent J.M. Dupont."),
    ("Sous Louis XVI. M. de Villefort entra.", "Sous Louis seize. Monsieur de Villefort entra."),
    ("M. et Mme Thénardier.", "Monsieur et Madame Thénardier."),
    ("Mr. et Mrs. Fogg.", "Mister et Missis Fogg."),
])
def test_french_initials_and_couples(src, want):
    assert fr(src) == want


@pytest.mark.parametrize("title, paragraph", [
    ("Spring", "Springfield was quiet."),
    ("Rose", "Roses bloomed early that year."),
    ("It", "Itinerary: Paris, then Rome."),
])
def test_short_title_that_prefixes_the_first_word_is_still_spoken(title, paragraph):
    out = normalize_section([paragraph], "en", starts_with_heading=False, title=title)
    assert out == [f"{title}.", paragraph]


@pytest.mark.parametrize("src, want", [
    ("Il coûte 1,50 £.", "Il coûte une livre cinquante."),
    ("Il coûte 1 £.", "Il coûte une livre."),
    ("Il coûte 21 £.", "Il coûte vingt et une livres."),
    ("Il coûte 1 000 000 £.", "Il coûte un million de livres."),
    ("Il coûte 1 €.", "Il coûte un euro."),
])
def test_french_pound_is_feminine(src, want):
    assert fr(src) == want


@pytest.mark.parametrize("lang, src, want", [
    ("en", "It cost $5 million dollars.", "It cost five million dollars."),
    ("en", "It cost $5 dollars.", "It cost five dollars."),
    ("en", "It cost £2bn pounds.", "It cost two billion pounds."),
    ("fr", "Il coûte $5 millions de dollars.", "Il coûte cinq millions de dollars."),
])
def test_currency_word_after_a_symbol_is_not_repeated(lang, src, want):
    assert normalize_paragraph(src, lang) == want


@pytest.mark.parametrize("src, want", [
    ("Go to https://en.wikipedia.org/wiki/Foo_(bar) now.", "Go to en.wikipedia.org now."),
    ("(See https://en.wikipedia.org/wiki/Foo_(bar).) Then.", "(See en.wikipedia.org.) Then."),
    ('He said "see http://x.com/a" and left.', 'He said "see x.com" and left.'),
])
def test_url_brackets_and_trailing_punctuation(src, want):
    assert en(src) == want


@pytest.mark.parametrize("src, want", [
    ("He gave me 10s.", "He gave me 10s."),  # ten shillings, not "tens"
    ("It cost 20s 6d.", "It cost 20s 6d."),
    ("It cost 10s. 6d.", "It cost 10s. 6d."),
    ("The year 2000's events.", "The year two thousand's events."),
    ("In the 1960s and 70s.", "In the nineteen sixties and seventies."),
    ("In the 30s, 40s and 50s.", "In the thirties, forties and fifties."),
    ("The mid-80s were loud.", "The mid-eighties were loud."),
])
def test_decades_shillings_and_year_possessives(src, want):
    assert en(src) == want


@pytest.mark.parametrize("lang, src, want", [
    ("fr", "Il fut accusé de vol.", "Il fut accusé de vol."),
    ("fr", "L'auteur du vol. C'était lui.", "L'auteur du vol. C'était lui."),
    ("fr", "Vol. 2 du recueil.", "Volume deux du recueil."),
    ("en", "He ate a fig.", "He ate a fig."),
    ("en", "See fig. 3 and vol. 2.", "See figure three and volume two."),
    ("en", "See pp. 12 and p. 4.", "See pages twelve and page four."),
])
def test_word_like_abbreviations_expand_only_before_a_number(lang, src, want):
    assert normalize_paragraph(src, lang) == want


def test_long_digit_strings_are_read_digit_by_digit_without_crashing():
    assert en("Card 4532015112830366.") == (
        "Card four five three two zero one five one one two eight three zero three six six.")
    assert en("He scored 1,000,000,000,000,000,000 points.") == "He scored one quintillion points."
    for lang in ("en", "fr"):
        out = normalize_paragraph("Digits: " + "7" * 5000 + ".", lang)  # int() refuses > 4300 digits
        assert out.split()[1:4] == [normalize_paragraph("7", lang)] * 3


def _seconds(fn, *args) -> float:
    import time

    t = time.perf_counter()
    fn(*args)
    return time.perf_counter() - t


@pytest.mark.parametrize("name, text", [
    ("url and punctuation run", "see www.x" + "!," * 32000 + "a end"),
    ("run of spaces", "a" + " " * 60000 + "b"),
    ("run of tabs and newlines", "a" + "\t\n" * 30000 + "b"),
    ("spaces before a dash", "a" + " " * 60000 + "\u2014 b"),
])
def test_cleanup_is_linear_on_pathological_input(name, text):
    from audiobook_engine.textproc.normalize import cleanup

    assert _seconds(cleanup, text) < 0.25, name


@pytest.mark.parametrize("lang, text", [
    ("en", "\u202f".join(["123"] * 5000) + " 4"),  # was quadratic, then failed in int()
    ("fr", "\u202f".join(["123"] * 5000) + " 4"),
    ("en", ",".join(["123"] * 5000) + "4"),
])
def test_normalize_is_fast_on_long_digit_runs(lang, text):
    assert _seconds(normalize_paragraph, text, lang) < 1.0


# ----------------------------------------------------------------------------- regression tests (round 3)

@pytest.mark.parametrize("src, want", [
    # "1920's" is a decade wherever it stands, in a list and in a range
    ("In the 1920's and 1930's people danced.", "In the nineteen twenties and nineteen thirties people danced."),
    ("Throughout the 1920's, 1930's and 1940's.", "Throughout the nineteen twenties, nineteen thirties and nineteen forties."),
    ("His 1920's novels sold well.", "His nineteen twenties novels sold well."),
    ("1920's jazz was wild.", "nineteen twenties jazz was wild."),
    ("In the 1960s–70s they marched.", "In the nineteen sixties–seventies they marched."),
    ("In the 60s-70s they marched.", "In the sixties-seventies they marched."),
    ("In the 60s/70s they marched.", "In the sixties/seventies they marched."),
    ("The 1950's-60's boom.", "The nineteen fifties-sixties boom."),
    # a year possessive after "year" or a month is kept
    ("The year 2000's events.", "The year two thousand's events."),
    ("By June 1940's end, France had fallen.", "By June nineteen forty's end, France had fallen."),
    ("Born in 1873's spring.", "Born in eighteen seventy-three's spring."),
])
def test_decades_in_lists_and_ranges(src, want):
    assert en(src) == want


@pytest.mark.parametrize("src, want", [
    # "between" after a form of "be" is a value as often as a time: left as a decimal
    ("The ratio was between 1.10 and 1.30.", "The ratio was between one point one zero and one point three zero."),
    ("The pH was between 6.50 and 7.25.", "The pH was between six point five zero and seven point two five."),
    # "against" makes a measure only before a currency
    ("Kick-off was at 3.00 against Leeds.", "Kick-off was at three o'clock against Leeds."),
    ("The match started at 7.45 against Spain.", "The match started at seven forty-five against Spain."),
    ("He arrived at 8.15 against all odds.", "He arrived at eight fifteen against all odds."),
    ("The pound stood at 1.15 against the dollar.", "The pound stood at one point one five against the dollar."),
    ("The pound traded at 1.15 against the US dollar.", "The pound traded at one point one five against the US dollar."),
    # unchanged: other "between" ranges stay times
    ("He slept between 2.30 and 4.15.", "He slept between two thirty and four fifteen."),
    # am/pm on the second half makes the first half a time too
    ("From 10.30 to 11am we talked.", "From ten thirty to eleven am we talked."),
    ("Between 2.30 and 4pm he slept.", "Between two thirty and four pm he slept."),
    ("From 10.30 to 11.45 p.m. we danced.", "From ten thirty to eleven forty-five p.m. we danced."),
    ("Open from 9.30-5.30pm daily.", "Open from nine thirty to five thirty pm daily."),
    ("Lunch is between 12.30 and 2pm.", "Lunch is between twelve thirty and two pm."),
])
def test_dotted_time_pairs_between_against_and_am_pm(src, want):
    assert en(src) == want


@pytest.mark.parametrize("lang, src, want", [
    ("en", "0" * 4301, "zero"),
    ("fr", "0" * 4301, "zéro"),
    ("en", "0" * 5000 + "1", "one"),
    ("en", "$" + "0" * 5000, "zero dollars"),
    ("en", "0" * 5000 + "%", "zero percent"),
    ("en", "0" * 5000 + "°", "zero degrees"),
    ("en", "0" + ",000" * 1500, "zero"),
    ("fr", "1234" + " 000" * 1500, "mille deux cent trente-quatre zéro"),
])
def test_long_runs_of_leading_zeros_do_not_crash(lang, src, want):
    # int() refuses a string of more than 4300 digits, leading zeros included
    assert normalize_paragraph(src, lang) == want


def test_cleanup_is_linear_on_unbalanced_brackets_after_a_url():
    from audiobook_engine.textproc.normalize import cleanup

    assert _seconds(cleanup, "see www.x" + "(" * 32000 + ")" * 64000 + " end") < 0.25


@pytest.mark.parametrize("p0, cut_before", [
    ("It was the best of times, it was the worst of times, it was the age of wisdom.", "t"),  # cut before a word
    ("PREFACE. List of Illustrations. Chapter: I., II., III., IV., V. and so on for a while.", " "),  # after a comma
    ("In my younger and more vulnerable years my father said to me: work, and I did.", ":"),  # before a colon
])
def test_section_does_not_speak_a_title_cut_at_a_word_boundary(p0, cut_before):
    assert p0[60] == cut_before
    assert normalize_section([p0], "en", starts_with_heading=False, title=p0[:60]) == [en(p0, is_section_opening=True)]


@pytest.mark.parametrize("src, want", [
    ("In 1990,500 soldiers died.", "In one thousand, nine hundred and ninety,five hundred soldiers died."),
    ("Scores: 1000,500,250.", "Scores: one thousand,five hundred,two hundred and fifty."),
    ("In 1234,567 people.", "In one thousand, two hundred and thirty-four,five hundred and sixty-seven people."),
])
def test_digits_after_a_malformed_comma_group_are_still_read(src, want):
    assert en(src) == want


@pytest.mark.parametrize("src, want", [
    ("Il avait 999 999 999 francs.",
     ("Il avait neuf cent quatre-vingt-dix-neuf millions neuf cent quatre-vingt-dix-neuf mille "
      "neuf cent quatre-vingt-dix-neuf francs.")),
    ("Il avait 111 111 111 francs.", "Il avait cent onze millions cent onze mille cent onze francs."),
    # lists still read as lists, in either direction
    ("Les chambres 101 102 103 étaient vides.", "Les chambres cent un cent deux cent trois étaient vides."),
    ("Les chambres 103 102 101 étaient vides.", "Les chambres cent trois cent deux cent un étaient vides."),
])
def test_french_equal_groups_are_one_number_not_a_list(src, want):
    assert fr(src) == want



@pytest.mark.parametrize("src, want", [
    ("Visiting hours are between 2.30 and 4.30.", "Visiting hours are between two thirty and four thirty."),
    ("Breakfast is between 7.30 and 9.30.", "Breakfast is between seven thirty and nine thirty."),
    ("The murder must have been between 11.15 and 11.45.", "The murder must have been between eleven fifteen and eleven forty-five."),
    ("The pH was between 6.50 and 7.25.", "The pH was between six point five zero and seven point two five."),
    ("A pH between 6.50 and 7.25 is normal.", "A pH between six point five zero and seven point two five is normal."),
    ("The ratio between 1.10 and 1.30 is ideal.", "The ratio between one point one zero and one point three zero is ideal."),
])
def test_between_ranges_are_times_unless_a_measurement_noun_precedes(src, want):
    assert normalize_paragraph(src, "en") == want
