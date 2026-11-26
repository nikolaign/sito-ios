package com.seraphi.sito

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.ceil

internal data class WitnessQuestion(val titleSR: String, val titleEN: String,
                                   val reference: String, val choices: List<String>, val answer: String)

internal object WitnessExam {
    fun sample(articles: List<Article>): List<Article> {
        val unique = articles.filter { it.title.length >= 24 && it.published > 1_577_836_800_000L }
            .sortedByDescending { it.published }.distinctBy { it.title.lowercase() }
        val freshest = unique.filter { it.published > System.currentTimeMillis() - 5L * 86400_000L }
        val pool = if (freshest.size >= 4) freshest else unique
        val result = mutableListOf<Article>()
        val sources = mutableSetOf<String>()
        pool.forEach { if (result.size < 7 && sources.add(it.sourceID)) result += it }
        pool.forEach { if (result.size < 7 && it !in result) result += it }
        return result
    }

    private fun words(text: String): List<String> {
        val ignored = setOf("about", "after", "before", "their", "there", "where", "which", "would",
            "could", "these", "those", "today", "because", "between", "through", "prema", "nakon",
            "između", "jedan", "jedna", "jednog", "svoje", "samo", "kako", "zašto", "izjavio",
            "rekao", "novom", "novi", "neće")
        return text.split(Regex("[^\\p{L}\\p{N}]+"))
            .filter { it.length >= 4 && it.lowercase() !in ignored && it.any(Char::isLetter) }
    }

    fun make(articles: List<Article>): List<WitnessQuestion> {
        if (articles.size < 4) return emptyList()
        val questions = mutableListOf<WitnessQuestion>()
        val publishers = (articles.map { it.sourceName } + Sources.curated.map { it.name }).distinct()
        val tokens = articles.flatMap { words(it.title) }
        if (articles.map { it.sourceID }.distinct().size >= 3) {
            articles.indices.step(2).forEach { index ->
                val story = articles[index]
                val distractors = publishers.filter { it != story.sourceName }.shuffled().take(3)
                if (distractors.size == 3) questions += WitnessQuestion("KO JE BIO SVEDOK?", "WHO WAS THE WITNESS?",
                    story.title, (distractors + story.sourceName).shuffled(), story.sourceName)
            }
        }
        for (story in articles.shuffled()) {
            val unique = words(story.title).filter { word ->
                word.length in 5..18 && tokens.count { it.equals(word, ignoreCase = true) } == 1 }
            val hidden = unique.randomOrNull() ?: continue
            val masked = story.title.replaceFirst(Regex(Regex.escape(hidden), RegexOption.IGNORE_CASE), "▯▯▯▯▯")
            val distractors = tokens.filter {
                it != hidden && kotlin.math.abs(it.length - hidden.length) <= 3 &&
                    !story.title.contains(it, ignoreCase = true)
            }.distinct().shuffled().take(3)
            if (distractors.size == 3) questions += WitnessQuestion("KOJU REČ SI VIDEO?", "WHICH WORD DID YOU SEE?",
                masked, (distractors + hidden).shuffled(), hidden)
        }
        for (index in articles.indices.filter { it >= 2 && it % 2 == 0 }) {
            val answer = articles[index - 1].title
            val alternatives = articles.indices.filter { it != index && it != index - 1 }
                .map { articles[it].title }.shuffled().take(3)
            if (alternatives.size == 3) questions += WitnessQuestion("ŠTA JE DOŠLO NEPOSREDNO PRE?",
                "WHAT CAME IMMEDIATELY BEFORE?", articles[index].title, (alternatives + answer).shuffled(), answer)
        }
        for (index in articles.indices.filter { it % 2 == 0 }) {
            val answer = articles[index].title
            val alternatives = articles.map { it.title }.filter { it != answer }.shuffled().take(3)
            if (alternatives.size == 3) questions += WitnessQuestion("ŠTA JE BILO NA EKRANU %02d?".format(index + 1),
                "WHAT WAS ON SCREEN %02d?".format(index + 1), "SITO / %02d".format(index + 1),
                (alternatives + answer).shuffled(), answer)
        }
        return questions.shuffled().take(12)
    }
}

@Composable
internal fun RealityWitnessPuzzle(articles: List<Article>, sr: Boolean,
                                 onComplete: (Int, Int, String) -> Unit,
                                 onFail: () -> Unit, penalize: (Int) -> Unit,
                                 onExit: () -> Unit) {
    val sample = remember { WitnessExam.sample(articles) }
    val questions = remember(sample) { WitnessExam.make(sample) }
    var examination by remember { mutableStateOf(false) }
    var position by remember { mutableIntStateOf(0) }
    var ready by remember { mutableStateOf(false) }
    var correct by remember { mutableIntStateOf(0) }
    var marked by remember { mutableStateOf(false) }
    var answerCorrect by remember { mutableStateOf<Boolean?>(null) }
    val scope = rememberCoroutineScope()
    val pass = ceil(questions.size * .82).toInt().coerceAtLeast(1)

    LaunchedEffect(position, examination) {
        if (!examination && sample.size >= 4) {
            ready = false
            delay(4300)
            ready = true
        }
    }

    Column(Modifier.fillMaxWidth().heightIn(max = 460.dp).verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(if (sr) "POSLE POSLEDNJE KAPIJE" else "AFTER THE LAST GATE", color = gateRed,
            fontFamily = FontFamily.Monospace, letterSpacing = 2.sp, fontSize = 10.sp)
        PuzzleTitle("REALITY / HELL / HEAVEN", if (!examination)
            (if (sr) "Naslovi su stvarni. Zapamti njihov redosled, izvor i reči."
            else "These headlines are real. Remember their order, sources and words.")
            else (if (sr) "Rekonstruiši viđeno. Odgovor je konačan."
            else "Reconstruct what you saw. Each answer is final."))
        if (sample.size < 4) {
            Text(if (sr) "NEMA DOVOLJNO VESTI U LOKALNOJ MEMORIJI"
                else "NOT ENOUGH STORIES IN LOCAL MEMORY", color = gateWhite, fontSize = 12.sp)
            Text(if (sr) "Ova soba ne izmišlja vesti. Osveži SITO i vrati se."
                else "This room will not invent news. Refresh SITO and return.", color = gateFaint)
            TextButton(onClick = onExit) { Text(if (sr) "VRATI SE U SITO" else "RETURN TO SITO") }
        } else if (!examination) {
            val article = sample[position]
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("%02d / %02d".format(position + 1, sample.size), color = gateFaint, fontSize = 11.sp)
                Text(if (sr) "PROČITAJ · UPAMTI" else "READ · REMEMBER", color = gateFaint, fontSize = 11.sp)
            }
            Column(Modifier.fillMaxWidth().background(Color(0xFF111115)).padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(11.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("SITO", color = gateWhite, fontSize = 18.sp, fontFamily = FontFamily.Serif)
                    Text(if (article.region == Region.SERBIA) "SRBIJA" else "WORLD", color = gateFaint, fontSize = 11.sp)
                }
                HorizontalDivider(color = gateRed)
                if (article.image != null) AsyncImage(model = article.image, contentDescription = null,
                    contentScale = ContentScale.Crop, modifier = Modifier.fillMaxWidth().height(67.dp))
                Text(article.title, color = gateWhite, fontSize = 18.sp, fontFamily = FontFamily.Serif,
                    lineHeight = 24.sp, maxLines = 5)
                Text(article.summary, color = gateFaint, fontSize = 12.sp, fontFamily = FontFamily.Serif,
                    maxLines = 3)
                Text(article.sourceName, color = gateFaint, fontSize = 11.sp)
            }
            Button(enabled = ready, onClick = {
                if (position + 1 == sample.size) { examination = true; position = 0 }
                else { ready = false; position++ }
            }) { Text(if (position + 1 == sample.size)
                (if (sr) "PREĐI NA ISPIT" else "ENTER THE EXAMINATION")
                else (if (sr) "SLEDEĆI EKRAN" else "NEXT SCREEN")) }
        } else if (position in questions.indices) {
            val question = questions[position]
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("%02d / %02d".format(position + 1, questions.size), color = gateRed, fontSize = 11.sp)
                Text("$correct / $pass", color = gateRed, fontSize = 11.sp)
            }
            Text(if (sr) question.titleSR else question.titleEN, color = gateFaint, fontSize = 10.sp,
                fontFamily = FontFamily.Monospace, letterSpacing = 1.sp)
            Text(question.reference, color = gateWhite, fontSize = 16.sp, fontFamily = FontFamily.Serif,
                textAlign = TextAlign.Center, lineHeight = 22.sp)
            question.choices.forEach { choice ->
                OutlinedButton(enabled = !marked, onClick = {
                    marked = true
                    answerCorrect = choice == question.answer
                    if (answerCorrect == true) correct++ else penalize(25)
                    scope.launch {
                        delay(480)
                        if (position + 1 == questions.size) {
                            if (correct >= pass) onComplete(correct, questions.size, sample.first().title)
                            else onFail()
                        } else { position++; marked = false; answerCorrect = null }
                    }
                }, modifier = Modifier.fillMaxWidth()) {
                    Text(choice, color = gateWhite, fontSize = 12.sp, fontFamily = FontFamily.Serif,
                        textAlign = TextAlign.Center)
                }
            }
            Text(answerCorrect?.let { if (it) "REMEMBERED." else "THE MEMORY MISSED." }
                ?: (if (sr) "ODGOVOR JE KONAČAN · GREŠKA −25s"
                else "ANSWERS ARE FINAL · ERROR −25s"), color = gateFaint, fontSize = 10.sp)
        }
    }
}
