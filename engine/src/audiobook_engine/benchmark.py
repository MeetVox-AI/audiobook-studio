"""Measure an engine on this Mac with fixed public-domain passages.

Results are saved (perf.json) and seed every later time estimate, so the app
can say "on this Mac" instead of quoting someone else's hardware.
"""

from __future__ import annotations

import time

from .perf import save_rate
from .textproc.normalize import normalize_paragraph
from .textproc.segment import chunk_section
from .tts import VoiceChoice, get_engine

# Public domain: Austen, Pride and Prejudice (1813), ch. 1; Verne, Le Tour du monde (1872), ch. 1.
PASSAGES = {
    "en": (
        "It is a truth universally acknowledged, that a single man in possession of a good fortune must be in want "
        "of a wife. However little known the feelings or views of such a man may be on his first entering a "
        "neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered "
        "as the rightful property of some one or other of their daughters. My dear Mister Bennet, said his lady to "
        "him one day, have you heard that Netherfield Park is let at last? Mister Bennet replied that he had not. "
        "But it is, returned she; for Missus Long has just been here, and she told me all about it. Mister Bennet "
        "made no answer. Do not you want to know who has taken it? cried his wife impatiently. You want to tell me, "
        "and I have no objection to hearing it. This was invitation enough. Why, my dear, you must know, Missus Long "
        "says that Netherfield is taken by a young man of large fortune from the north of England; that he came down "
        "on Monday in a chaise and four to see the place, and was so much delighted with it that he agreed with "
        "Mister Morris immediately; that he is to take possession before Michaelmas, and some of his servants are to "
        "be in the house by the end of next week."
    ),
    "fr": (
        "En l'année mil huit cent soixante-douze, la maison portant le numéro sept de Saville-row, Burlington "
        "Gardens, maison dans laquelle Sheridan mourut en mil huit cent quatorze, était habitée par Phileas Fogg, "
        "esquire, l'un des membres les plus singuliers et les plus remarqués du Reform-Club de Londres, bien qu'il "
        "semblât prendre à tâche de ne rien faire qui pût attirer l'attention. À l'un des plus grands orateurs qui "
        "honorent l'Angleterre, succédait donc ce Phileas Fogg, personnage énigmatique, dont on ne savait rien, "
        "sinon que c'était un fort galant homme et l'un des plus beaux gentlemen de la haute société anglaise. On "
        "disait qu'il ressemblait à Byron, par la tête, car il était irréprochable quant aux pieds, mais un Byron à "
        "moustaches et à favoris, un Byron impassible, qui aurait vécu mille ans sans vieillir. Anglais, à coup sûr, "
        "Phileas Fogg n'était peut-être pas Londonner. On ne l'avait jamais vu ni à la Bourse, ni à la Banque, ni "
        "dans aucun des comptoirs de la Cité."
    ),
}

# Original paragraphs (written for this project, no quotation) so a benchmark or a voice preview works in every
# language. About 600 characters; Chinese and Japanese pack far more speech per character, so they are shorter.
# They must be reviewed by native speakers (see the language review list).
_ORIGINAL = {
    "es": (
        "Cuando amaneció, el pueblo todavía dormía. Desde la ventana de la cocina se veía la montaña cubierta de "
        "niebla y, más abajo, el río que bajaba despacio entre los álamos. Marta preparó un café, abrió la puerta "
        "y salió al patio con una manta sobre los hombros. ¿Habría llegado ya el cartero? Hacía una semana que "
        "esperaba una carta de su hermano, y cada mañana el camino le parecía más largo. A lo lejos sonó una "
        "campana, un perro ladró dos veces, y la luz fue llenando poco a poco las calles estrechas. Por fin vio "
        "una bicicleta que subía la cuesta, y sonrió sin darse cuenta."
    ),
    "de": (
        "Als es hell wurde, schlief das Dorf noch. Vom Küchenfenster aus sah man den Berg im Nebel und weiter "
        "unten den Fluss, der langsam zwischen den Weiden dahinzog. Anna kochte Kaffee, öffnete die Tür und trat "
        "mit einer Decke um die Schultern in den Hof. Ob der Briefträger schon unterwegs war? Seit einer Woche "
        "wartete sie auf einen Brief ihres Bruders, und jeden Morgen kam ihr der Weg länger vor. Irgendwo "
        "schlug eine Glocke, ein Hund bellte zweimal, und das Licht füllte nach und nach die engen Gassen. "
        "Schließlich sah sie ein Fahrrad den Hügel heraufkommen und lächelte, ohne es zu merken."
    ),
    "it": (
        "Quando spuntò l'alba, il paese dormiva ancora. Dalla finestra della cucina si vedeva la montagna avvolta "
        "dalla nebbia e, più in basso, il fiume che scendeva piano tra i pioppi. Giulia preparò il caffè, aprì la "
        "porta e uscì nel cortile con una coperta sulle spalle. Sarebbe già passato il postino? Da una settimana "
        "aspettava una lettera di suo fratello, e ogni mattina la strada le sembrava più lunga. In lontananza "
        "suonò una campana, un cane abbaiò due volte, e la luce riempì a poco a poco le vie strette. Finalmente "
        "vide una bicicletta che saliva lungo la salita, e sorrise senza accorgersene."
    ),
    "pt": (
        "Quando amanheceu, a aldeia ainda dormia. Da janela da cozinha via-se a montanha coberta de nevoeiro e, "
        "mais abaixo, o rio que descia devagar entre os choupos. A Marta fez café, abriu a porta e saiu para o "
        "quintal com um cobertor sobre os ombros. Será que o carteiro já tinha passado? Havia uma semana que "
        "esperava uma carta do irmão, e a cada manhã o caminho parecia-lhe mais comprido. Ao longe tocou um sino, "
        "um cão ladrou duas vezes, e a luz foi enchendo aos poucos as ruas estreitas. Por fim viu uma bicicleta "
        "a subir a ladeira e sorriu sem dar por isso."
    ),
    "nl": (
        "Toen het licht werd, sliep het dorp nog. Vanuit het keukenraam zag je de berg in de mist en, wat lager, "
        "de rivier die langzaam tussen de wilgen stroomde. Anna zette koffie, deed de deur open en liep met een "
        "deken om haar schouders het erf op. Zou de postbode al langs geweest zijn? Al een week wachtte ze op een "
        "brief van haar broer, en elke ochtend leek de weg langer. Ergens luidde een klok, een hond blafte twee "
        "keer, en het licht vulde langzaam de smalle straatjes. Eindelijk zag ze een fiets de heuvel opkomen, en "
        "ze glimlachte zonder het te merken."
    ),
    "ru": (
        "Когда рассвело, деревня ещё спала. Из кухонного окна были видны гора в тумане и, чуть ниже, река, "
        "медленно текущая между ивами. Марина сварила кофе, открыла дверь и вышла во двор, накинув на плечи "
        "одеяло. Неужели почтальон уже приходил? Уже неделю она ждала письма от брата, и с каждым утром дорога "
        "казалась ей длиннее. Вдали ударил колокол, дважды пролаяла собака, и свет понемногу заполнил узкие "
        "улочки. Наконец она увидела велосипед, который поднимался в гору, и улыбнулась, сама того не заметив."
    ),
    "zh": (
        "天亮的时候，村子还在沉睡。从厨房的窗口望出去，山笼罩在薄雾里，山脚下的河水缓缓流过一排杨树。"
        "玛丽煮了咖啡，打开门，披着毯子走到院子里。邮递员来过了吗？她已经等了哥哥的来信整整一个星期，"
        "每天早晨，那条路都显得更长。远处传来一阵钟声，狗叫了两声，阳光一点一点地照进狭窄的小巷。"
        "终于，她看见一辆自行车沿着坡路骑了上来，不由自主地笑了。"
    ),
    "ja": (
        "夜が明けるころ、村はまだ眠っていました。台所の窓からは、霧に包まれた山と、ポプラの間をゆっくり流れる川が見えます。"
        "マリは珈琲をいれ、戸を開けて、毛布を肩にかけたまま庭に出ました。郵便屋さんはもう来たでしょうか。"
        "兄からの手紙を待ち始めて一週間、朝ごとに道が長くなるように思えます。遠くで鐘が鳴り、犬が二度吠え、"
        "細い路地に光が少しずつ満ちていきました。やがて、坂を上ってくる自転車が見え、彼女は思わず微笑みました。"
    ),
    "ko": (
        "동이 틀 무렵, 마을은 아직 잠들어 있었다. 부엌 창문으로 안개에 싸인 산이 보였고, 그 아래로 강이 "
        "버드나무 사이를 천천히 흘렀다. 민지는 커피를 끓이고 문을 열어 담요를 어깨에 두른 채 마당으로 "
        "나갔다. 우체부가 벌써 다녀갔을까? 오빠의 편지를 기다린 지 벌써 일주일이었고, 아침마다 길이 더 "
        "길게 느껴졌다. 멀리서 종이 울렸고 개가 두 번 짖었으며, 좁은 골목에 빛이 조금씩 차올랐다. "
        "마침내 언덕을 오르는 자전거가 보였고, 그녀는 저도 모르게 미소를 지었다."
    ),
    "hi": (
        "जब सुबह हुई, तब गाँव अभी सो रहा था। रसोई की खिड़की से कोहरे में लिपटा पहाड़ दिखाई देता था और उससे नीचे वह "
        "नदी, जो पेड़ों के बीच धीरे-धीरे बह रही थी। मीना ने चाय बनाई, दरवाज़ा खोला और कंधों पर शॉल डालकर आँगन में आ "
        "गई। क्या डाकिया आ चुका होगा? एक हफ़्ते से वह अपने भाई की चिट्ठी का इंतज़ार कर रही थी, और हर सुबह रास्ता "
        "उसे और लंबा लगता था। दूर कहीं घंटी बजी, एक कुत्ता दो बार भौंका, और रोशनी धीरे-धीरे तंग गलियों में भरने लगी। "
        "आख़िर उसे ढलान पर चढ़ती हुई एक साइकिल दिखाई दी, और वह अनजाने ही मुस्कुरा उठी।"
    ),
    "ar": (
        "عندما طلع الفجر كانت القرية لا تزال نائمة. من نافذة المطبخ كان يُرى الجبل مغطى بالضباب، وتحته النهر "
        "الذي يجري ببطء بين أشجار الصفصاف. أعدّت مريم القهوة، وفتحت الباب، وخرجت إلى الفناء وعلى كتفيها "
        "بطانية. هل مرّ ساعي البريد؟ منذ أسبوع وهي تنتظر رسالة من أخيها، وكل صباح يبدو لها الطريق أطول. "
        "رنّ جرس من بعيد، ونبح كلب مرتين، وامتلأت الأزقة الضيقة بالضوء شيئًا فشيئًا. وأخيرًا رأت دراجة "
        "تصعد المنحدر، فابتسمت دون أن تشعر."
    ),
}
PASSAGES.update(_ORIGINAL)


def passage(lang: str) -> str:
    """The benchmark paragraph for `lang` (any spelling the registry accepts); English when there is none."""
    from .languages import normalize_code

    return PASSAGES.get(normalize_code(lang) or lang) or PASSAGES["en"]


def run(engine_id: str, voice: VoiceChoice, lang: str, batch: int | None = None, repeats: int = 1, emit=None) -> dict:
    import mlx.core as mx

    engine = get_engine(engine_id)
    spec = engine.spec
    text = normalize_paragraph(passage(lang), lang)
    chunks = chunk_section(0, [text], spec.cap_for(lang), first_is_heading=False, min_chars=spec.min_chunk, lang=lang)
    texts = [c.text for c in chunks]
    bs = batch or spec.batch_size
    load_s = engine.load(voice)
    t = time.perf_counter()
    engine.synthesize(texts[:1], voice, lang)
    warm = time.perf_counter() - t
    mx.reset_peak_memory()
    queue = texts * repeats  # one long queue so large batches are actually full
    audio = 0.0
    t = time.perf_counter()
    for i in range(0, len(queue), bs):
        out = engine.synthesize(queue[i:i + bs], voice, lang)
        audio += sum(a.size for a in out) / engine.sample_rate
    wall = time.perf_counter() - t
    walls = [wall]
    chars = sum(len(x) for x in queue)
    result = {
        "event": "benchmark", "engine": spec.id, "voice": voice.label(), "lang": lang, "batch": bs,
        "chunks": len(queue), "chars": chars, "load_s": round(load_s, 2), "warmup_s": round(warm, 2),
        "wall_s": round(wall, 2), "audio_s": round(audio, 1), "chars_per_s": round(chars / wall, 1),
        "realtime_x": round(audio / wall, 2), "seconds_per_char": round(audio / chars, 4),
        "peak_memory_gb": round(mx.get_peak_memory() / 1e9, 2),
        "runs": [round(w, 2) for w in walls],
    }
    if batch is None or batch == spec.batch_size:
        save_rate(spec.id, voice.label(), chars, wall, audio, "benchmark")
    if emit:
        emit(result)
    return result
