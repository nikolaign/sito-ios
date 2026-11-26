package com.seraphi.sito

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.min

internal val gateRed = Color(0xFFCC252B)
internal val gateWhite = Color(0xFFE4DCD1)
internal val gateFaint = Color(0xFF807C7C)
internal val gateSymbols = listOf("◯", "△", "□", "◇", "✕", "✦", "⊕", "◈", "⌁", "⌘", "⋈", "✧")

@Composable
internal fun PuzzleTitle(title: String, guidance: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, color = gateWhite, fontFamily = FontFamily.Serif, fontSize = 19.sp,
            letterSpacing = 2.sp, textAlign = TextAlign.Center)
        Text(guidance, color = gateFaint, fontFamily = FontFamily.Monospace, fontSize = 10.sp,
            lineHeight = 15.sp, textAlign = TextAlign.Center)
    }
}

@Composable
internal fun GateKey(label: String, modifier: Modifier = Modifier, selected: Boolean = false,
                     enabled: Boolean = true, height: androidx.compose.ui.unit.Dp = 48.dp,
                     onClick: () -> Unit) {
    Box(modifier.height(height).background(if (selected) gateRed.copy(alpha = 0.22f)
        else gateWhite.copy(alpha = 0.06f))
        .clickable(enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) {
        Text(label, color = when {
            selected -> gateRed
            enabled -> gateWhite
            else -> gateFaint
        }, fontFamily = FontFamily.Monospace, fontSize = 20.sp)
    }
}

@Composable
internal fun GatePuzzle(room: Int, sr: Boolean, solved: () -> Unit, penalize: (Int) -> Unit) {
    when (room) {
        8 -> EchoPuzzle(sr, solved)
        7 -> FogMazePuzzle(sr, solved)
        6 -> MirrorPuzzle(sr, solved, penalize)
        5 -> LightsPuzzle(sr, solved)
        4 -> SequencePuzzle(sr, solved, penalize)
        3 -> PrimePuzzle(sr, solved, penalize)
        2 -> CipherPuzzle(sr, solved, penalize)
        else -> SkylinePuzzle(sr, solved)
    }
}

@Composable
private fun EchoPuzzle(sr: Boolean, solved: () -> Unit) {
    var round by remember { mutableIntStateOf(0) }
    var pattern by remember { mutableStateOf(List(7) { (0..3).random() }) }
    val attempt = remember { mutableStateListOf<Int>() }
    var visible by remember { mutableStateOf(true) }
    var revealIndex by remember { mutableIntStateOf(-1) }
    var signal by remember { mutableIntStateOf(0) }
    var mistake by remember { mutableStateOf(false) }
    LaunchedEffect(round, signal) {
        visible = true
        revealIndex = -1
        delay(550)
        for (index in pattern.indices) {
            revealIndex = index
            delay(470)
            revealIndex = -1
            delay(150)
        }
        visible = false
    }
    Column(verticalArrangement = Arrangement.spacedBy(15.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        PuzzleTitle(if (sr) "ODJEK" else "THE ECHO",
            if (sr) "Znakovi dolaze jedan po jedan. Zapamti redosled, ne sliku."
            else "The signs arrive one at a time. Remember the sequence, not an image.")
        Text("${round + 1} / 4", color = gateRed, fontFamily = FontFamily.Monospace)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            pattern.indices.forEach { index ->
                Text(if (visible) (if (index == revealIndex) gateSymbols[pattern[index]] else "·")
                    else if (index < attempt.size) gateSymbols[attempt[index]] else "·",
                    color = if (mistake) gateRed else gateWhite, fontSize = 17.sp, textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f))
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            (0..3).forEach { index -> GateKey(gateSymbols[index], Modifier.weight(1f), enabled = !visible && !mistake) {
                attempt += index
                if (attempt.size == pattern.size) {
                    if (attempt == pattern) {
                        if (round == 3) solved()
                        else { round++; pattern = List(7 + round) { (0..3).random() }; attempt.clear() }
                    } else {
                        mistake = true
                        signal++
                        attempt.clear()
                    }
                }
            } }
        }
        LaunchedEffect(mistake) { if (mistake) { delay(850); mistake = false } }
    }
}

@Composable
private fun FogMazePuzzle(sr: Boolean, solved: () -> Unit) {
    val maze = remember { FogMaze.create() }
    var position by remember { mutableIntStateOf(maze.start) }
    val seals = remember { mutableStateListOf<Int>() }
    val footsteps = remember { mutableStateListOf(maze.start) }
    fun move(dr: Int, dc: Int) {
        val row = position / 17 + dr
        val column = position % 17 + dc
        if (row !in 0..16 || column !in 0..16) return
        val next = row * 17 + column
        if (next !in maze.open) return
        position = next
        footsteps += next
        if (footsteps.size > 7) footsteps.removeAt(0)
        if (next in maze.seals && next !in seals) seals += next
        if (next == maze.exit && seals.size == 3) solved()
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(9.dp)) {
        PuzzleTitle(if (sr) "ZIDOVI KOJI PAMTE" else "THE REMEMBERING WALLS",
            if (sr) "Nema mape. Vidiš samo dva koraka. Pronađi tri pečata i izlaz."
            else "There is no map. See only two steps. Find three seals and the exit.")
        Text("${seals.size} / 3", color = gateRed, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            (0..6).forEach { r ->
                Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                    (0..6).forEach { c ->
                        val dr = r - 3; val dc = c - 3
                        val row = position / 17 + dr; val col = position % 17 + dc
                        val inside = row in 0..16 && col in 0..16
                        val index = row * 17 + col
                        val radius = abs(dr) + abs(dc)
                        val seen = inside && radius <= 2
                        val open = seen && index in maze.open
                        val symbol = when {
                            radius == 0 -> "●"
                            !seen -> ""
                            index in maze.seals && index !in seals -> "✦"
                            index == maze.exit -> "◇"
                            index in footsteps && open -> "·"
                            else -> ""
                        }
                        Box(Modifier.size(34.dp).background(when {
                            !seen -> Color.Black
                            open -> gateWhite.copy(alpha = if (radius == 2) .09f else .20f)
                            else -> gateRed.copy(alpha = .07f)
                        }), contentAlignment = Alignment.Center) {
                            Text(symbol, color = if (radius == 0 || index in maze.seals) gateRed else gateWhite, fontSize = 14.sp)
                        }
                    }
                }
            }
        }
        GateKey("↑", Modifier.width(66.dp), height = 34.dp) { move(-1, 0) }
        Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            GateKey("←", Modifier.width(66.dp), height = 34.dp) { move(0, -1) }
            GateKey("↓", Modifier.width(66.dp), height = 34.dp) { move(1, 0) }
            GateKey("→", Modifier.width(66.dp), height = 34.dp) { move(0, 1) }
        }
    }
}

@Composable
private fun MirrorPuzzle(sr: Boolean, solved: () -> Unit, penalize: (Int) -> Unit) {
    val cards = remember { (0..11).flatMap { listOf(it, it) }.shuffled() }
    val shown = remember { mutableStateListOf<Int>() }
    val found = remember { mutableStateListOf<Int>() }
    var preview by remember { mutableStateOf(true) }
    var secondLook by remember { mutableStateOf(false) }
    var seconds by remember { mutableIntStateOf(6) }
    var errors by remember { mutableIntStateOf(0) }
    var waiting by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(seconds) { if (preview) { delay(seconds * 1000L); preview = false } }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        PuzzleTitle(if (sr) "DVANAEST OGLEDALA" else "TWELVE MIRRORS",
            if (sr) "Dvanaest parova. Šest sekundi pogleda. Svaka greška košta vremena."
            else "Twelve pairs. Six seconds to look. Mistakes cost time.")
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("${found.size / 2} / 12", color = gateRed, fontFamily = FontFamily.Monospace)
            Spacer(Modifier.weight(1f))
            if (preview) Text(if (sr) "ZAPAMTI" else "REMEMBER", color = gateRed, fontSize = 11.sp)
            else if (!secondLook) TextButton(onClick = {
                secondLook = true
                shown.clear(); preview = true; seconds = 4; penalize(30)
            }) { Text(if (sr) "JOŠ POGLED · −30s" else "LOOK AGAIN · −30s", fontSize = 10.sp) }
        }
        (0..5).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                (0..3).forEach { col ->
                    val index = row * 4 + col
                    val faceUp = preview || index in shown || index in found
                    GateKey(if (faceUp) gateSymbols[cards[index]] else "·", Modifier.width(60.dp),
                        selected = index in found, height = 40.dp,
                        enabled = !preview && !waiting && index !in found) {
                        if (index !in shown) shown += index
                        if (shown.size == 2) {
                            if (cards[shown[0]] == cards[shown[1]]) {
                                found += shown
                                shown.clear()
                                if (found.size == 24) solved()
                            } else {
                                errors++
                                penalize(min(17, 6 + errors * 2))
                                waiting = true
                                scope.launch { delay(900); shown.clear(); waiting = false }
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun toggleLights(board: MutableList<Boolean>, index: Int) {
    val row = index / 4; val col = index % 4
    listOf(0 to 0, -1 to 0, 1 to 0, 0 to -1, 0 to 1).forEach { (dr, dc) ->
        val r = row + dr; val c = col + dc
        if (r in 0..3 && c in 0..3) board[r * 4 + c] = !board[r * 4 + c]
    }
}

@Composable
private fun LightsPuzzle(sr: Boolean, solved: () -> Unit) {
    val board = remember {
        mutableStateListOf<Boolean>().also { light ->
            light.addAll(List(16) { false })
            (0..15).shuffled().take((11..14).random()).forEach { toggleLights(light, it) }
            if (light.none { it }) toggleLights(light, 6)
        }
    }
    var moves by remember { mutableIntStateOf(0) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        PuzzleTitle(if (sr) "ŠESNAEST PLAMENOVA" else "SIXTEEN FLAMES",
            if (sr) "Ugasi 4×4 mrežu: dodir menja jedno polje i četiri suseda."
            else "Extinguish the 4×4 grid. Each touch changes one tile and its neighbours.")
        Text(if (sr) "DODIRA: $moves" else "TOUCHES: $moves", color = gateFaint, fontSize = 11.sp)
        (0..3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                (0..3).forEach { col ->
                    val index = row * 4 + col
                    Box(Modifier.size(62.dp).background(if (board[index]) gateRed.copy(alpha = .78f)
                        else gateWhite.copy(alpha = .06f)).clickable {
                        moves++
                        toggleLights(board, index)
                        if (board.none { it }) solved()
                    })
                }
            }
        }
    }
}

@Composable
private fun SequencePuzzle(sr: Boolean, solved: () -> Unit, penalize: (Int) -> Unit) {
    var round by remember { mutableIntStateOf(0) }
    var riddle by remember { mutableStateOf(SequenceRiddle.create(0)) }
    var input by remember { mutableStateOf("") }
    var mistakes by remember { mutableIntStateOf(0) }
    var clueUsed by remember { mutableStateOf(false) }
    val clues = if (sr) listOf("Pogledaj razlike između razlika.", "Dva niza se smenjuju.",
        "Svaki član čuje prethodna dva i isti šapat.", "Treće razlike ostaju nepromenjene.")
    else listOf("Look at the differences between differences.", "Two sequences alternate.",
        "Each term hears the previous two and one constant whisper.", "The third differences do not change.")
    fun enter() {
        val number = input.toIntOrNull() ?: return
        input = ""
        if (number != riddle.next) {
            mistakes++
            penalize(min(54, 24 + mistakes * 10))
        } else if (round == 3) solved()
        else {
            round++
            riddle = SequenceRiddle.create(round)
            mistakes = 0; clueUsed = false
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        PuzzleTitle(if (sr) "NIZOVI KOJI LAŽU" else "THE LYING SEQUENCES",
            if (sr) "Upiši sledeći broj bez ponuđenih odgovora. Greške oduzimaju sve više vremena."
            else "Enter the next number without multiple choice. Mistakes cost increasingly more time.")
        Text("${round + 1} / 4", color = gateRed, fontFamily = FontFamily.Monospace)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
            (riddle.terms.map { "$it" } + "?").forEach { term ->
                Text(term, Modifier.weight(1f), color = if (term == "?") gateRed else gateWhite,
                    fontSize = 17.sp, fontFamily = FontFamily.Serif, textAlign = TextAlign.Center,
                    maxLines = 1)
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(if (input.isBlank()) "_" else input, color = gateWhite, fontSize = 28.sp,
                modifier = Modifier.weight(1f), textAlign = TextAlign.Center)
            TextButton(enabled = !clueUsed, onClick = { clueUsed = true; penalize(18) }) {
                Text(if (sr) "TRAG · −18s" else "CLUE · −18s", fontSize = 10.sp)
            }
        }
        (0..3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                (0..2).forEach { col ->
                    val index = row * 3 + col
                    val label = when (index) { 9 -> "⌫"; 10 -> "0"; 11 -> "↵"; else -> "${index + 1}" }
                    GateKey(label, Modifier.weight(1f), height = 35.dp) {
                        when (index) {
                            9 -> input = input.dropLast(1)
                            11 -> enter()
                            else -> if (input.length < 5) input += label
                        }
                    }
                }
            }
        }
        if (clueUsed) Text(clues[round], color = gateFaint, fontSize = 10.sp, textAlign = TextAlign.Center)
        if (mistakes > 0) Text(if (sr) "GREŠKE: $mistakes · CENA RASTE" else "ERRORS: $mistakes · THE COST RISES",
            color = gateRed, fontSize = 10.sp)
    }
}

@Composable
private fun PrimePuzzle(sr: Boolean, solved: () -> Unit, penalize: (Int) -> Unit) {
    val pairPool = listOf(listOf(11, 13), listOf(17, 19), listOf(29, 31),
        listOf(41, 43), listOf(59, 61), listOf(71, 73), listOf(101, 103))
    val answer = remember { pairPool.shuffled().take(5).sortedBy { it.first() }.flatten() }
    val numbers = remember {
        (answer + listOf(4, 8, 14, 21, 25, 27, 33, 35, 39, 49, 51, 57, 67, 79, 89)
            .shuffled().take(10)).shuffled()
    }
    var position by remember { mutableIntStateOf(0) }
    var mistake by remember { mutableStateOf(false) }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        PuzzleTitle(if (sr) "BLIZANCI U PRAZNINI" else "TWINS IN THE VOID",
            if (sr) "Pet parova prostih brojeva sa razlikom dva. Biraj manje pa veće, uzlazno."
            else "Find five twin-prime pairs two apart. Tap low then high, in ascending order.")
        Text("${position / 2} / 5", color = gateRed, fontFamily = FontFamily.Monospace)
        (0..4).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                (0..3).forEach { col ->
                    val digit = numbers[row * 4 + col]
                    GateKey("$digit", Modifier.width(62.dp), selected = digit in answer.take(position),
                        enabled = digit !in answer.take(position), height = 42.dp) {
                        if (digit == answer[position]) {
                            position++
                            mistake = false
                            if (position == answer.size) solved()
                        } else {
                            position = 0; mistake = true; penalize(12)
                        }
                    }
                }
            }
        }
        if (mistake) Text(if (sr) "PAROVI SU SE RAZDVOJILI. PONOVO." else "THE PAIRS HAVE SEPARATED. START AGAIN.",
            color = gateRed, fontSize = 10.sp, textAlign = TextAlign.Center)
    }
}

internal data class CodeGuess(val digits: List<Int>, val exact: Int, val displaced: Int)

@Composable
private fun CipherPuzzle(sr: Boolean, solved: () -> Unit, penalize: (Int) -> Unit) {
    val code = remember { (0..5).shuffled().take(4) }
    val input = remember { mutableStateListOf<Int>() }
    val guesses = remember { mutableStateListOf<CodeGuess>() }
    fun submit() {
        if (input.size != 4) return
        val exact = code.zip(input).count { it.first == it.second }
        if (exact == 4) { solved(); return }
        val elsewhere = input.count { it in code } - exact
        guesses += CodeGuess(input.toList(), exact, elsewhere)
        input.clear()
        if (guesses.size > 7) penalize(12)
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        PuzzleTitle(if (sr) "ŠIFRA SA DVA LICA" else "THE TWO-FACED CIPHER",
            if (sr) "Četiri različite cifre (0–5). Trag kaže koliko je na pravom, a koliko na drugom mestu."
            else "Four distinct digits (0–5). Each guess reveals exact and misplaced digits.")
        Column(Modifier.height(115.dp), verticalArrangement = Arrangement.Bottom) {
            guesses.takeLast(5).forEach { guess ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(guess.digits.joinToString(" "), color = gateWhite, fontSize = 11.sp)
                    Text(if (sr) "TAČNO ${guess.exact} · DRUGDE ${guess.displaced}"
                        else "EXACT ${guess.exact} · ELSEWHERE ${guess.displaced}", color = gateRed, fontSize = 10.sp)
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            (0..3).forEach { index ->
                Text(input.getOrNull(index)?.toString() ?: "_", Modifier.weight(1f),
                    color = gateWhite, fontFamily = FontFamily.Monospace,
                    fontSize = 27.sp, textAlign = TextAlign.Center)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            (0..5).forEach { digit ->
                GateKey("$digit", Modifier.weight(1f), selected = digit in input, height = 44.dp,
                    enabled = digit !in input && input.size < 4) { input += digit }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(15.dp)) {
            TextButton(onClick = { if (input.isNotEmpty()) input.removeAt(input.lastIndex) }) {
                Text(if (sr) "⌫ OBRIŠI" else "⌫ ERASE", fontSize = 11.sp)
            }
            TextButton(enabled = input.size == 4, onClick = ::submit) {
                Text(if (sr) "PROVERI →" else "TEST →", fontSize = 11.sp)
            }
        }
    }
}

@Composable
private fun SkylinePuzzle(sr: Boolean, solved: () -> Unit) {
    val puzzle = remember { Skyline.create() }
    val grid = remember { mutableStateListOf<Int>().also { board ->
        board.addAll((0..15).map { if (it in puzzle.givens) puzzle.solution[it] else 0 })
    } }
    var selected by remember { mutableIntStateOf((0..15).first { it !in puzzle.givens }) }
    fun clue(index: Int): String = puzzle.clues[index]?.toString() ?: "·"
    fun duplicate(cell: Int): Boolean {
        val digit = grid[cell]
        return digit != 0 && grid.indices.any { index -> index != cell && grid[index] == digit &&
            (index / 4 == cell / 4 || index % 4 == cell % 4) }
    }
    fun enter(digit: Int) {
        if (selected in puzzle.givens) return
        grid[selected] = digit
        if (grid.toIntArray().contentEquals(puzzle.solution)) solved()
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        PuzzleTitle(if (sr) "ARHITEKTURA TIŠINE" else "THE ARCHITECTURE OF SILENCE",
            if (sr) "Redovi i kolone sadrže 1–4. Brojevi sa ivica kažu koliko se kula vidi."
            else "Rows and columns use 1–4. Edge clues count how many towers are visible.")
        Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Spacer(Modifier.width(27.dp))
            (0..3).forEach { col -> Text(clue(col), Modifier.width(45.dp),
                color = gateFaint, textAlign = TextAlign.Center, fontSize = 12.sp) }
            Spacer(Modifier.width(27.dp))
        }
        (0..3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(clue(8 + row), Modifier.width(27.dp), color = gateFaint, textAlign = TextAlign.Center)
                (0..3).forEach { col ->
                    val index = row * 4 + col
                    GateKey(if (grid[index] == 0) "·" else "${grid[index]}", Modifier.width(45.dp),
                        selected = selected == index, height = 45.dp,
                        enabled = index !in puzzle.givens) { selected = index }
                }
                Text(clue(12 + row), Modifier.width(27.dp), color = gateFaint, textAlign = TextAlign.Center)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Spacer(Modifier.width(27.dp))
            (0..3).forEach { col -> Text(clue(4 + col), Modifier.width(45.dp),
                color = gateFaint, textAlign = TextAlign.Center, fontSize = 12.sp) }
            Spacer(Modifier.width(27.dp))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            (1..4).forEach { digit -> GateKey("$digit", Modifier.width(55.dp)) { enter(digit) } }
        }
        TextButton(onClick = { enter(0) }) { Text(if (sr) "OBRIŠI POLJE" else "ERASE CELL", fontSize = 10.sp) }
        if ((0..15).any(::duplicate)) Text(if (sr) "DUPLIKAT U REDU ILI KOLONI" else "DUPLICATE IN ROW OR COLUMN",
            color = gateRed, fontSize = 10.sp)
    }
}

@Composable
internal fun SudokuPuzzle(sr: Boolean, solved: () -> Unit) {
    val board = remember { SudokuBoard.create() }
    val current = remember { mutableStateListOf<Int>().apply { addAll(board.clues.toList()) } }
    var selected by remember { mutableIntStateOf(-1) }
    val width = 30.dp
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        (0..8).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                (0..8).forEach { col ->
                    val index = row * 9 + col
                    val fixed = board.clues[index] != 0
                    val conflicted = conflict(current.toIntArray(), index, current[index])
                    Box(Modifier.size(width).background(when {
                        selected == index -> gateRed.copy(alpha = .28f)
                        (row / 3 + col / 3) % 2 == 0 -> Color(0xFF1A1618)
                        else -> Color(0xFF100E10)
                    }).clickable(enabled = !fixed) { selected = index }, contentAlignment = Alignment.Center) {
                        Text(current[index].takeIf { it != 0 }?.toString() ?: "",
                            color = if (conflicted) gateRed else if (fixed) gateWhite else gateWhite.copy(alpha = .8f),
                            fontSize = 16.sp, fontFamily = FontFamily.Serif)
                    }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            (1..9).forEach { digit ->
                GateKey("$digit", Modifier.width(width), height = 37.dp, enabled = selected >= 0) {
                    if (selected >= 0) {
                        current[selected] = digit
                        if (current.toIntArray().contentEquals(board.answer)) solved()
                    }
                }
            }
        }
        TextButton(enabled = selected >= 0, onClick = { if (selected >= 0) current[selected] = 0 }) {
            Text(if (sr) "⌫ OBRIŠI" else "⌫ ERASE", fontSize = 11.sp)
        }
    }
}
