package com.seraphi.sito

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

// The Android story uses the same authored lines and quotations as iOS.
// History survives launches: a read line is never selected again.
internal class GateNarrator(private val context: Context) {
    private val prefs = context.getSharedPreferences("seraphi-gate-voice", Context.MODE_PRIVATE)
    private val corpus: JSONObject by lazy {
        JSONObject(context.assets.open("gate_narration.json").bufferedReader().use { it.readText() })
    }
    private val roomIndex = listOf(0, 1, 5, 2, 4, 6, 3, 7, 8, 9)

    private fun JSONObject.strings(key: String): List<String> = getJSONArray(key).texts()
    private fun JSONArray.texts(): List<String> = (0 until length()).map { getString(it) }
    private fun roomLines(key: String, room: Int): List<String> = corpus.getJSONArray(key)
        .getJSONArray(room).texts()

    fun next(room: Int, sr: Boolean, preferRoom: Boolean): String {
        val index = room.coerceIn(0, 9)
        val used = prefs.getStringSet("lines", emptySet()).orEmpty().toMutableSet()
        val roomLines = (if (index == 0) emptyList() else
            roomLines(if (sr) "srRooms" else "enRooms", roomIndex[index])) +
            roomLines(if (sr) "srArc" else "enArc", index)
        val common = corpus.strings(if (sr) "commonSR" else "commonEN")
        val quotes = corpus.strings(if (sr) "quotesSR" else "quotesEN")
        fun sentence(forRoom: Boolean): String {
            val prefix = if (sr) "sr" else "en"
            val subject = if (forRoom) {
                val motifs = roomLines(if (sr) "roomMotifsSR" else "roomMotifsEN", index)
                (if (sr) "Možda " else "Perhaps ") + motifs.random()
            } else corpus.strings(prefix + "Subjects").random()
            return "$subject ${corpus.strings(prefix + "Verbs").random()} ${corpus.strings(prefix + "Objects").random()}"
        }
        repeat(200) {
            val dice = (if (preferRoom) 0..43 else 0..99).random()
            val candidate = when (dice) {
                in 0..43 -> roomLines.random()
                in 44..62 -> common.random()
                in 63..82 -> quotes.random()
                in 83..91 -> sentence(true)
                else -> sentence(false)
            }
            if (used.add(candidate)) {
                prefs.edit().putStringSet("lines", used).apply()
                return candidate
            }
        }
        val sequence = prefs.getInt("serial", 0) + 1
        prefs.edit().putInt("serial", sequence).apply()
        return if (sr) "Još jedan oblik tišine: $sequence. ${sentence(false)}"
        else "Another shape of silence: $sequence. ${sentence(false)}"
    }
}
