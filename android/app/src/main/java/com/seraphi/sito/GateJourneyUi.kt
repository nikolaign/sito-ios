package com.seraphi.sito

import android.content.Intent
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import kotlinx.coroutines.delay
import kotlin.math.cos
import kotlin.math.sin

private enum class JourneyPhase { PLAYING, PASSAGE, RECKONING, REVELATION, FAILED, COLLAPSE, AFTERMATH }

private val roomsSR = listOf("IZA KAPIJE", "ARHITEKTURA TIŠINE", "ŠIFRA SA DVA LICA", "BLIZANCI U PRAZNINI",
    "NIZOVI KOJI LAŽU", "ŠESNAEST PLAMENOVA", "DVANAEST OGLEDALA", "LAVIRINT", "ODJEK", "DEVETA KAPIJA")
private val roomsEN = listOf("BEYOND THE GATE", "THE ARCHITECTURE OF SILENCE", "THE TWO-FACED CIPHER",
    "TWINS IN THE VOID", "THE LYING SEQUENCES", "SIXTEEN FLAMES", "TWELVE MIRRORS", "THE LABYRINTH",
    "THE ECHO", "THE NINTH GATE")
private val circlesSR = listOf("PRAG", "IZDAJA", "OBMANA", "NASILJE", "JERES", "GNEV", "POHLEPA",
    "PROŽDRLJIVOST", "POŽUDA", "LIMBO")
private val circlesEN = listOf("THE THRESHOLD", "TREACHERY", "FRAUD", "VIOLENCE", "HERESY", "WRATH",
    "GREED", "GLUTTONY", "LUST", "LIMBO")

@Composable
private fun GateAtmosphere() {
    val infinite = rememberInfiniteTransition(label = "red atmosphere")
    val breath by infinite.animateFloat(0.65f, 1.15f,
        infiniteRepeatable(tween(5500, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "breathing")
    val tick by infinite.animateFloat(0f, 100f,
        infiniteRepeatable(tween(4200, easing = LinearEasing)), label = "fracture")
    Canvas(Modifier.fillMaxSize().background(Color.Black)) {
        drawCircle(brush = Brush.radialGradient(listOf(gateRed.copy(alpha = .22f * breath), Color.Transparent)),
            radius = size.width * .58f, center = Offset(size.width * .14f, size.height * .76f))
        for (line in 0..6) {
            val x = ((sin(line * 13.0 + tick / 29.0) + 1) * .47).toFloat() * size.width
            val y = ((cos(line * 9.0 + tick / 37.0) + 1) * .47).toFloat() * size.height
            drawLine(color = gateRed.copy(alpha = if (line % 2 == 0) .12f else .05f),
                start = Offset(x, y), end = Offset(x + line * 7 + 13f, y), strokeWidth = 1.2f)
        }
    }
}

@Composable
internal fun DreamGateJourneyAndroid(articles: List<Article>, sr: Boolean, onExit: () -> Unit) {
    val context = LocalContext.current
    val narrator = remember { GateNarrator(context.applicationContext) }
    val activity = context as ComponentActivity
    val prefs = remember { context.getSharedPreferences("seraphi-gate-state", android.content.Context.MODE_PRIVATE) }
    var cycle by remember { mutableIntStateOf(prefs.getInt("cycle", 0)) }
    var room by remember { mutableIntStateOf(9) }
    var phase by remember { mutableStateOf(JourneyPhase.PLAYING) }
    var time by remember { mutableIntStateOf(540) }
    var whisper by remember { mutableStateOf("") }
    var opacity by remember { mutableFloatStateOf(.9f) }
    var serial by remember { mutableIntStateOf(0) }
    var penalties by remember { mutableIntStateOf(0) }
    var failures by remember { mutableIntStateOf(0) }
    val performance = remember { mutableStateMapOf<Int, Int>() }
    var witnessScore by remember { mutableIntStateOf(0) }
    var witnessTotal by remember { mutableIntStateOf(0) }
    var finalHeadline by remember { mutableStateOf("") }
    var doorChoice by remember { mutableIntStateOf(-1) }
    var endingSeed by remember { mutableIntStateOf((0..10000).random()) }
    var collapseTick by remember { mutableIntStateOf(0) }

    fun allowance(level: Int) = if (level == 0) 420 else level.coerceIn(1, 9) * 60
    fun won(score: Int = 0, total: Int = 0, headline: String = "") {
        if (phase != JourneyPhase.PLAYING && phase != JourneyPhase.RECKONING) return
        performance[room] = time
        if (room == 0) { witnessScore = score; witnessTotal = total; finalHeadline = headline }
        phase = if (room == 0) JourneyPhase.REVELATION else JourneyPhase.PASSAGE
    }
    fun failed() { if (phase == JourneyPhase.PLAYING || phase == JourneyPhase.RECKONING) {
        failures++
        phase = JourneyPhase.FAILED
    } }
    fun penalize(seconds: Int) {
        if (phase != JourneyPhase.PLAYING && phase != JourneyPhase.RECKONING) return
        penalties++
        time = (time - seconds).coerceAtLeast(0)
        if (time == 0) failed()
    }
    fun restart() {
        cycle++
        prefs.edit().putInt("cycle", cycle).apply()
        time = allowance(room)
        serial = 0
        phase = if (room == 0) JourneyPhase.RECKONING else JourneyPhase.PLAYING
    }
    fun newCycle() {
        cycle++
        prefs.edit().putInt("cycle", cycle).apply()
        room = 9; phase = JourneyPhase.PLAYING; time = allowance(9)
        whisper = ""; serial = 0; performance.clear(); penalties = 0; failures = 0
        witnessScore = 0; witnessTotal = 0; finalHeadline = ""; doorChoice = -1
        endingSeed = (0..10000).random()
    }
    fun openPortal() {
        val destinations = listOf("https://www.fallingfalling.com/", "https://www.psychedelicio.us/",
            "https://psilly.com/experiments/polygons.html", "https://hotdoom.com/",
            "https://thaer.no/", "https://zoomquilt.org/", "https://zoomquilt2.com/")
        val last = prefs.getString("lastPortal", "")
        val chosen = destinations.filter { it != last }.random()
        prefs.edit().putString("lastPortal", chosen).apply()
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(chosen))) }
    }

    BackHandler { onExit() }
    LaunchedEffect(room, phase, cycle) {
        if (phase == JourneyPhase.PLAYING || phase == JourneyPhase.RECKONING) {
            while (true) {
                delay(1000)
                if (activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) time--
                if (time <= 0) { failed(); break }
            }
        }
    }
    LaunchedEffect(room, phase, cycle) {
        if (phase == JourneyPhase.PLAYING || phase == JourneyPhase.RECKONING) {
            while (true) {
                serial++
                val line = narrator.next(room, sr, preferRoom = serial == 1 || serial % 4 == 0)
                whisper = ""; opacity = .9f
                for (character in line) { whisper += character; delay(42) }
                delay(if (line.contains('—')) 15000 else 11000)
                opacity = .32f
                delay((12..17).random() * 1000L)
            }
        }
    }
    LaunchedEffect(phase, room, cycle) {
        when (phase) {
            JourneyPhase.PASSAGE -> {
                delay(3200)
                if (room == 1) { room = 0; time = allowance(0); phase = JourneyPhase.RECKONING }
                else { room--; time = allowance(room); phase = JourneyPhase.PLAYING }
                whisper = ""; serial = 0
            }
            JourneyPhase.REVELATION -> { delay(3800); phase = JourneyPhase.COLLAPSE }
            JourneyPhase.COLLAPSE -> { delay(5000); phase = JourneyPhase.AFTERMATH }
            else -> Unit
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        GateAtmosphere()
        when (phase) {
            JourneyPhase.PLAYING, JourneyPhase.RECKONING -> Column(
                Modifier.fillMaxSize().padding(horizontal = 22.dp, vertical = 9.dp),
                horizontalAlignment = Alignment.CenterHorizontally) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("SITO / %02d".format(room), color = gateFaint,
                        fontFamily = FontFamily.Monospace, fontSize = 11.sp, letterSpacing = 3.sp)
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = onExit) { Text("×", fontSize = 24.sp, color = gateWhite) }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    (1..9).forEach { n -> Box(Modifier.weight(1f).height(2.dp)
                        .background(if (n >= room) gateRed.copy(alpha = .8f) else gateFaint.copy(alpha = .2f))) }
                }
                Spacer(Modifier.height(11.dp))
                Text("%02d / 09".format(room), color = gateFaint, fontFamily = FontFamily.Monospace,
                    fontSize = 10.sp, letterSpacing = 3.sp)
                Text("%02d:%02d".format(time / 60, time % 60),
                    color = if (time <= 30) gateRed else gateWhite,
                    fontFamily = FontFamily.Monospace, fontSize = 34.sp, letterSpacing = 3.sp)
                Spacer(Modifier.height(6.dp))
                Text((if (sr) circlesSR else circlesEN)[room], color = gateRed.copy(alpha = .8f),
                    fontFamily = FontFamily.Monospace, fontSize = 9.sp, letterSpacing = 3.sp)
                Text((if (sr) roomsSR else roomsEN)[room], color = gateFaint,
                    fontFamily = FontFamily.Monospace, fontSize = 10.sp, letterSpacing = 2.sp)
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                        horizontalAlignment = Alignment.CenterHorizontally) {
                        key("$room-$cycle") {
                            when (room) {
                                9 -> SudokuPuzzle(sr) { won() }
                                0 -> RealityWitnessPuzzle(articles, sr,
                                    onComplete = { score, total, headline -> won(score, total, headline) },
                                    onFail = ::failed, penalize = ::penalize, onExit = onExit)
                                else -> GatePuzzle(room, sr, solved = { won() }, penalize = ::penalize)
                            }
                        }
                    }
                }
                Text(if (whisper.isBlank()) "▌" else "$whisper ▌", color = gateWhite.copy(alpha = opacity),
                    fontFamily = FontFamily.Monospace, fontSize = 10.sp, lineHeight = 15.sp,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 54.dp, max = 66.dp), maxLines = 3)
            }
            JourneyPhase.PASSAGE, JourneyPhase.REVELATION -> GateRitualScreen(room, sr, false)
            JourneyPhase.FAILED -> Box(Modifier.fillMaxSize()) {
                GateRitualScreen(room, sr, true)
                Column(Modifier.fillMaxSize().padding(35.dp), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center) {
                    Text(if (sr) "NISI PROŠAO" else "YOU FAILED", color = gateRed,
                        fontFamily = FontFamily.Serif, fontSize = 31.sp, letterSpacing = 4.sp)
                    Spacer(Modifier.height(20.dp))
                    Text(if (sr) "DEVETA KAPIJA TE NIJE PUSTILA." else "THE GATE WOULD NOT LET YOU PASS.",
                        color = gateWhite, textAlign = TextAlign.Center, fontSize = 13.sp)
                    Text(if (sr) "Vreme je isteklo. Nešto sa druge strane sada zna tvoje ime."
                        else "Time ran out. Something on the other side now knows your name.",
                        color = gateFaint, fontFamily = FontFamily.Serif, textAlign = TextAlign.Center,
                        fontSize = 16.sp, modifier = Modifier.padding(vertical = 25.dp))
                    OutlinedButton(onClick = ::restart) { Text(if (sr) "POKUŠAJ PONOVO" else "TRY AGAIN") }
                    TextButton(onClick = onExit) { Text(if (sr) "VRATI SE U SVET" else "RETURN TO THE WORLD") }
                }
            }
            JourneyPhase.COLLAPSE -> {
                LaunchedEffect(Unit) { while (true) { collapseTick++; delay(105) } }
                Box(Modifier.fillMaxSize().offset(x = if (collapseTick % 2 == 0) 2.dp else (-2).dp),
                    contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(if (sr) "NIŠTA SE NIJE ZAVRŠILO" else "NOTHING HAS ENDED", color = gateRed,
                            fontSize = 14.sp, letterSpacing = 3.sp)
                        Spacer(Modifier.height(17.dp))
                        Text(if (sr) "DEVETI KRUG NEMA PLAMEN. SAMO LED."
                            else "THE NINTH CIRCLE HAS NO FLAME. ONLY ICE.",
                            color = gateWhite, fontFamily = FontFamily.Serif, textAlign = TextAlign.Center)
                    }
                }
            }
            JourneyPhase.AFTERMATH -> GateAftermath(sr, performance, penalties, failures,
                witnessScore, witnessTotal, finalHeadline, endingSeed, cycle, doorChoice,
                chooseDoor = { doorChoice = it }, openPortal = ::openPortal, beginAgain = ::newCycle,
                onExit = onExit)
        }
    }
}

@Composable
private fun GateRitualScreen(room: Int, sr: Boolean, failure: Boolean) {
    val infinite = rememberInfiniteTransition(label = "gate ritual")
    val flicker by infinite.animateFloat(.08f, .6f, infiniteRepeatable(tween(1200), RepeatMode.Reverse),
        label = "ritual flicker")
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(280.dp)) {
            for (index in 0..8) {
                drawRect(gateRed.copy(alpha = flicker / (index + 1)),
                    topLeft = Offset(size.width / 2 - 15 + sin(index.toDouble()).toFloat() * 55,
                        size.height / 2 - 8 + cos(index.toDouble() * 2).toFloat() * 60),
                    size = androidx.compose.ui.geometry.Size(20f + index * 7, 2f + (index % 3) * 4))
            }
        }
        if (!failure) Text(if (sr) "PROLAZ" else "PASSAGE", color = gateWhite,
            fontFamily = FontFamily.Monospace, letterSpacing = 5.sp, fontSize = 13.sp)
    }
}

@Composable
private fun GateAftermath(sr: Boolean, performance: Map<Int, Int>, penalties: Int, failures: Int,
                          witnessScore: Int, witnessTotal: Int, headline: String, seed: Int, cycle: Int,
                          door: Int, chooseDoor: (Int) -> Unit, openPortal: () -> Unit,
                          beginAgain: () -> Unit, onExit: () -> Unit) {
    val fraction = (1..9).sumOf { (performance[it] ?: 0).toDouble() / (it * 60) } / 9.0
    val register = when {
        failures >= 3 -> 3
        fraction > .6 && penalties <= 4 && witnessScore == witnessTotal -> 0
        fraction > .39 -> 1
        else -> 2
    }
    val opening = if (sr) listOf(
        "Prošao si brzo. To ne znači da si video sve. Brzina je samo još jedan način da se nešto propusti.",
        "Dovoljno si se sećao da stigneš dovde. Niko ti nije rekao da sećanje mora biti potpuno.",
        "Vreme se osipalo. Ti si ostao. Od onoga što nisi razumeo napravio si prolaz.",
        "Vrata su te vraćala, a ti si ponovo ulazio. Ovo nije pobeda nad paklom. Ovo je razgovor s njim.")
    else listOf(
        "You crossed quickly. That does not mean you saw everything. Speed is another way to miss what matters.",
        "You remembered enough to arrive here. Nobody promised that memory had to be complete.",
        "Time fell away. You remained. You built a passage from what you could not understand.",
        "The doors sent you back, and you entered again. This is not a victory over hell. It is a conversation with it.")
    val openLines = if (sr) listOf(
        "Ostavio si vrata otvorena. Sa one strane nema prestola. Samo drugi ljudi koji u istom trenutku biraju kuda će gledati.",
        "Vrata ostaju otvorena. Sve što si video može postati strah, saosećanje ili ništa. Ne odlučuje ekran.",
        "U sobu ulazi vazduh spolja. Pakao nije nestao; samo si prestao da ga zoveš jedinim mogućim svetom.",
        "Neko drugi će proći tvojim tragovima. Hoće li tvoja vrata biti zamka ili put?")
    else listOf(
        "You left the door open. There is no throne beyond it. Only other people, choosing what to look at in this same moment.",
        "The door remains open. Everything you saw may become fear, compassion, or nothing. The screen does not decide.",
        "Air enters from outside. Hell did not vanish; you simply stopped calling it the only possible world.",
        "Someone else will follow your footprints. Will your door be a trap or a passage?")
    val closedLines = if (sr) listOf(
        "Zatvorio si vrata. Tišina nije prazna. U njoj prvi put čuješ misao koja nije došla sa ekrana.",
        "Vrata su se zatvorila, ali slika je ostala u tebi. Nije te progonila vest — nego način na koji si je gledao.",
        "Ovde nema ni plamena ni anđela. Samo pažnja, mala i neumorna, koja bira čemu će dati oblik.",
        "Zatvorio si prolaz za svet, ne i prolaz u sebi. Neke brave postoje samo dok ih držimo.")
    else listOf(
        "You closed the door. Silence is not empty. For the first time you hear a thought that did not come from a screen.",
        "The door closed, but the image remained inside you. The headline did not haunt you; your way of looking did.",
        "There are no flames and no angels here. Only attention, small and tireless, choosing what to bring into being.",
        "You closed a passage to the world, not the passage within yourself. Some locks exist only while we hold them.")
    val codas = if (sr) listOf(
        "Ako si tražio Boga iza poslednjih vrata, možda si sve vreme stajao na mestu sa kog se ona otvaraju.",
        "Raj i pakao nisu dve adrese. Ponekad su dva načina da odgovoriš na isti prizor.",
        "Misao nije ceo svet. Ali menja način na koji ćeš u njega zakoračiti.",
        "Nisi dobio mapu. Dobio si ruku koja može da je nacrta.",
        "Iza svake kapije čekao je drugi oblik tvog izbora. Iza poslednje — njegov odjek.",
        "Niko ti ne može oduzeti pogled. Samo ga možeš predati.")
    else listOf(
        "If you sought God behind the last door, perhaps you stood all along where doors are opened.",
        "Heaven and hell are not two addresses. Sometimes they are two responses to the same sight.",
        "A thought is not the whole world. But it changes how you step into it.",
        "You were not given a map. You were given the hand that could draw one.",
        "Behind each gate waited another shape of your choosing. Behind the last, its echo.",
        "Nobody can take your gaze. You can only give it away.")
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 30.dp, vertical = 35.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(21.dp)) {
        Text("◇", color = gateRed, fontSize = 29.sp)
        Text(if (sr) "DEVET KRUGOVA. JEDAN EKRAN." else "NINE CIRCLES. ONE SCREEN.",
            color = gateRed, fontFamily = FontFamily.Serif, fontSize = 19.sp, letterSpacing = 2.sp,
            textAlign = TextAlign.Center)
        Text(opening[register], color = gateWhite, fontFamily = FontFamily.Serif,
            fontSize = 17.sp, lineHeight = 26.sp, textAlign = TextAlign.Center)
        HorizontalDivider(Modifier.width(44.dp), color = gateRed)
        Text(if (sr) "Na poslednjem ekranu ostao je naslov:" else "One headline remained on the last screen:",
            color = gateFaint, fontSize = 11.sp)
        Text(headline, color = gateWhite, fontFamily = FontFamily.Serif, fontSize = 14.sp,
            textAlign = TextAlign.Center)
        if (door < 0) {
            Text(if (sr) "VRATA SU PRED TOBOM. ŠTA BIRAŠ?" else "THE DOOR IS BEFORE YOU. WHAT DO YOU CHOOSE?",
                color = gateFaint, textAlign = TextAlign.Center, fontSize = 11.sp)
            OutlinedButton(onClick = { chooseDoor(0) }) { Text(if (sr) "OSTAVI VRATA OTVORENA" else "LEAVE THE DOOR OPEN") }
            OutlinedButton(onClick = { chooseDoor(1) }) { Text(if (sr) "ZATVORI VRATA" else "CLOSE THE DOOR") }
        } else {
            Text((if (door == 0) openLines else closedLines)[(seed + register + cycle) % 4],
                color = gateWhite, fontFamily = FontFamily.Serif, fontSize = 17.sp,
                lineHeight = 25.sp, textAlign = TextAlign.Center)
            Text(codas[(seed + cycle * 3 + register) % codas.size], color = gateRed,
                fontFamily = FontFamily.Serif, fontSize = 17.sp, textAlign = TextAlign.Center)
            OutlinedButton(onClick = openPortal) { Text(if (sr) "IZA EKRANA" else "BEYOND THE SCREEN") }
            TextButton(onClick = beginAgain) { Text(if (sr) "JOŠ JEDAN SILAZAK" else "ANOTHER DESCENT") }
            TextButton(onClick = onExit) { Text(if (sr) "VRATI SE VESTIMA" else "RETURN TO THE NEWS") }
        }
    }
}
