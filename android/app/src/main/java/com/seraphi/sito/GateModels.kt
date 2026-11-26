package com.seraphi.sito

internal data class SudokuBoard(val answer: IntArray, val clues: IntArray) {
    companion object {
        fun create(): SudokuBoard {
            val digits = (1..9).shuffled()
            val rows = (0..2).shuffled().flatMap { band -> (0..2).shuffled().map { band * 3 + it } }
            val cols = (0..2).shuffled().flatMap { stack -> (0..2).shuffled().map { stack * 3 + it } }
            val answer = IntArray(81) { index ->
                val r = rows[index / 9]
                val c = cols[index % 9]
                digits[(r * 3 + r / 3 + c) % 9]
            }
            val clues = answer.clone()
            var removed = 0
            for (index in (0 until 81).shuffled()) {
                if (removed >= 43) break
                val value = clues[index]
                clues[index] = 0
                if (countSolutions(clues.clone(), 2) == 1) removed++ else clues[index] = value
            }
            return SudokuBoard(answer, clues)
        }

        private fun countSolutions(grid: IntArray, limit: Int): Int {
            var chosen = -1
            var available = emptyList<Int>()
            for (position in grid.indices) {
                if (grid[position] != 0) continue
                val choices = (1..9).filter { !conflict(grid, position, it) }
                if (choices.isEmpty()) return 0
                if (chosen == -1 || choices.size < available.size) {
                    chosen = position
                    available = choices
                    if (choices.size == 1) break
                }
            }
            if (chosen < 0) return 1
            var found = 0
            for (digit in available) {
                grid[chosen] = digit
                found += countSolutions(grid, limit - found)
                if (found >= limit) break
            }
            grid[chosen] = 0
            return found
        }
    }
}

internal fun conflict(grid: IntArray, cell: Int, digit: Int): Boolean {
    if (digit == 0) return false
    val row = cell / 9
    val col = cell % 9
    for (index in 0 until 81) {
        if (index == cell || grid[index] != digit) continue
        if (index / 9 == row || index % 9 == col ||
            (index / 27 == row / 3 && index % 9 / 3 == col / 3)) return true
    }
    return false
}

internal data class FogMaze(val open: Set<Int>, val start: Int, val exit: Int, val seals: Set<Int>) {
    companion object {
        const val width = 19
        fun create(): FogMaze {
            val start = width + 1
            val visited = mutableSetOf(start)
            val open = mutableSetOf(start)
            val stack = mutableListOf(start)
            while (stack.isNotEmpty()) {
                val tile = stack.last()
                val r = tile / width
                val c = tile % width
                val neighbors = listOf(-2 to 0, 2 to 0, 0 to -2, 0 to 2)
                    .mapNotNull { (dr, dc) ->
                        val nr = r + dr
                        val nc = c + dc
                        if (nr !in 1 until width - 1 || nc !in 1 until width - 1) null
                        else (nr * width + nc) to ((r + dr / 2) * width + c + dc / 2)
                    }.filter { it.first !in visited }.shuffled()
                if (neighbors.isEmpty()) { stack.removeAt(stack.lastIndex); continue }
                val (next, between) = neighbors.first()
                visited += next
                open += next
                open += between
                stack += next
            }
            val distance = mutableMapOf(start to 0)
            val queue = ArrayDeque<Int>().apply { add(start) }
            while (queue.isNotEmpty()) {
                val tile = queue.removeFirst()
                val r = tile / width
                val c = tile % width
                for ((dr, dc) in listOf(-1 to 0, 1 to 0, 0 to -1, 0 to 1)) {
                    val nr = r + dr
                    val nc = c + dc
                    if (nr !in 0 until width || nc !in 0 until width) continue
                    val next = nr * width + nc
                    if (next in open && next !in distance) {
                        distance[next] = distance.getValue(tile) + 1
                        queue.add(next)
                    }
                }
            }
            val exit = distance.maxByOrNull { it.value }?.key ?: start
            val seals = mutableSetOf<Int>()
            fun connections(tile: Int): List<Int> {
                val row = tile / width; val col = tile % width
                return listOf(-1 to 0, 1 to 0, 0 to -1, 0 to 1).mapNotNull { (dr, dc) ->
                    val r = row + dr; val c = col + dc
                    (r * width + c).takeIf { r in 0 until width && c in 0 until width && it in open }
                }
            }
            fun separation(first: Int, second: Int): Int {
                val queue = ArrayDeque<Int>().apply { add(first) }
                val steps = mutableMapOf(first to 0)
                while (queue.isNotEmpty()) {
                    val tile = queue.removeFirst()
                    if (tile == second) return steps.getValue(tile)
                    for (next in connections(tile)) if (next !in steps) {
                        steps[next] = steps.getValue(tile) + 1; queue.add(next)
                    }
                }
                return 0
            }
            val candidates = distance.filter { it.key != start && it.key != exit &&
                it.value > 20 && connections(it.key).size == 1 }
                .toList().sortedByDescending { it.second }
            for ((tile, _) in candidates.take(30).shuffled()) {
                if (seals.size >= 3) break
                if (seals.all { separation(tile, it) >= 24 }) seals += tile
            }
            if (seals.size < 3) distance.entries.sortedByDescending { it.value }.forEach { (tile, _) ->
                if (seals.size < 3 && tile != start && tile != exit) seals += tile
            }
            return FogMaze(open, start, exit, seals)
        }
    }
}

internal data class SequenceRiddle(val terms: List<Int>, val next: Int) {
    companion object {
        fun create(round: Int): SequenceRiddle = when (round) {
            0 -> {
                val a = (2..4).random(); val b = (1..5).random(); val c = (2..10).random()
                fun term(n: Int) = a * n * n + b * n + c
                SequenceRiddle((0..4).map(::term), term(5))
            }
            1 -> {
                val a = (3..12).random(); val b = (30..55).random()
                val even = (5..9).random(); val odd = (-8..-3).random()
                SequenceRiddle((0..5).map { if (it % 2 == 0) a + it / 2 * even else b + it / 2 * odd }, a + 3 * even)
            }
            2 -> {
                val shift = (2..8).random()
                val terms = mutableListOf((2..7).random(), (8..15).random())
                repeat(3) { terms += terms[terms.size - 1] + terms[terms.size - 2] + shift }
                SequenceRiddle(terms, terms[4] + terms[3] + shift)
            }
            else -> {
                val a = (1..3).random(); val b = (2..9).random()
                fun term(n: Int) = a * n * n * n + b * n + 7
                SequenceRiddle((0..4).map(::term), term(5))
            }
        }
    }
}

internal data class Skyline(val solution: IntArray, val clues: List<Int?>, val givens: Set<Int>) {
    companion object {
        private val permutations by lazy {
            fun build(rest: List<Int>, chosen: List<Int>): List<List<Int>> = if (rest.isEmpty()) listOf(chosen)
            else rest.flatMap { digit -> build(rest - digit, chosen + digit) }
            build(listOf(1, 2, 3, 4), emptyList())
        }
        private val boards by lazy {
            val all = mutableListOf<IntArray>()
            fun extend(rows: List<List<Int>>) {
                if (rows.size == 4) { all += rows.flatten().toIntArray(); return }
                permutations.forEach { next ->
                    if ((0..3).all { col -> rows.none { it[col] == next[col] } }) extend(rows + listOf(next))
                }
            }
            extend(emptyList())
            all
        }
        fun seen(line: List<Int>): Int {
            var height = 0
            var count = 0
            line.forEach { if (it > height) { count++; height = it } }
            return count
        }
        fun clues(board: IntArray): List<Int> {
            val top = (0..3).map { col -> seen((0..3).map { board[it * 4 + col] }) }
            val bottom = (0..3).map { col -> seen((3 downTo 0).map { board[it * 4 + col] }) }
            val left = (0..3).map { row -> seen((0..3).map { board[row * 4 + it] }) }
            val right = (0..3).map { row -> seen((3 downTo 0).map { board[row * 4 + it] }) }
            return top + bottom + left + right
        }
        fun create(): Skyline {
            var best: Skyline? = null
            repeat(22) {
                val answer = boards.random()
                val allClues = clues(answer)
                val shown = allClues.map { it as Int? }.toMutableList()
                for (index in shown.indices.shuffled()) {
                    if (shown.count { it != null } <= 9) break
                    val old = shown[index]
                    shown[index] = null
                    if (boards.count { board ->
                        val actual = clues(board)
                        shown.indices.all { index2 -> shown[index2] == null || shown[index2] == actual[index2] }
                    } != 1) shown[index] = old
                }
                val columns = (0..3).shuffled()
                val fixed = (0..3).map { it * 4 + columns[it] }.toMutableSet()
                for (cell in (0..15).shuffled()) { if (fixed.size >= 7) break; fixed += cell }
                val puzzle = Skyline(answer, shown, fixed)
                if (best == null || puzzle.clues.count { it != null } < best!!.clues.count { it != null }) best = puzzle
                if (shown.count { it != null } <= 9) return puzzle
            }
            return requireNotNull(best)
        }
    }
}
