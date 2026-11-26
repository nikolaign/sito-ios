package com.seraphi.sito

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject

class LocalStore(context: Context) : SQLiteOpenHelper(context, "sito-history.db", null, 1) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("""CREATE TABLE articles (
            id TEXT PRIMARY KEY, source_id TEXT NOT NULL, source_name TEXT NOT NULL,
            region TEXT NOT NULL, title TEXT NOT NULL, summary TEXT NOT NULL,
            url TEXT NOT NULL, image TEXT, published INTEGER NOT NULL,
            categories TEXT NOT NULL, author TEXT, full_text TEXT, bookmark INTEGER NOT NULL DEFAULT 0
        )""")
        db.execSQL("CREATE INDEX history_date ON articles(published DESC)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    @Synchronized fun merge(articles: List<Article>) {
        writableDatabase.beginTransaction()
        try {
            for (item in articles) {
                val previous = writableDatabase.rawQuery(
                    "SELECT full_text, bookmark FROM articles WHERE id = ?", arrayOf(item.id)
                ).use { cursor ->
                    if (!cursor.moveToFirst()) null
                    else Pair(cursor.getString(0), cursor.getInt(1) != 0)
                }
                val olderText = previous?.first
                val merged = item.copy(
                    bookmark = previous?.second == true,
                    fullText = item.fullText?.takeIf { it.length >= (olderText?.length ?: 0) }
                        ?: olderText,
                )
                writableDatabase.insertWithOnConflict("articles", null, values(merged), SQLiteDatabase.CONFLICT_REPLACE)
            }
            writableDatabase.setTransactionSuccessful()
        } finally {
            writableDatabase.endTransaction()
        }
    }

    @Synchronized fun archive(query: String = "", bookmarkOnly: Boolean = false): List<Article> {
        val clauses = mutableListOf<String>()
        val args = mutableListOf<String>()
        if (query.isNotBlank()) {
            clauses += "(title LIKE ? OR source_name LIKE ? OR summary LIKE ?)"
            repeat(3) { args += "%${query.trim()}%" }
        }
        if (bookmarkOnly) clauses += "bookmark = 1"
        val where = if (clauses.isEmpty()) null else clauses.joinToString(" AND ")
        return readableDatabase.query("articles", null, where, args.toTypedArray().takeIf { args.isNotEmpty() },
            null, null, "published DESC", "8000").use { cursor ->
            buildList { while (cursor.moveToNext()) {
                fun text(key: String): String? = cursor.getColumnIndex(key).takeIf { it >= 0 }?.let { index ->
                    if (cursor.isNull(index)) null else cursor.getString(index)
                }
                val region = runCatching { Region.valueOf(text("region") ?: "SERBIA") }.getOrDefault(Region.SERBIA)
                val cats = runCatching { JSONArray(text("categories") ?: "[]") }.getOrDefault(JSONArray())
                add(Article(
                    id = text("id").orEmpty(), sourceID = text("source_id").orEmpty(),
                    sourceName = text("source_name").orEmpty(), region = region,
                    title = text("title").orEmpty(), summary = text("summary").orEmpty(),
                    url = text("url").orEmpty(), image = text("image"),
                    published = cursor.getLong(cursor.getColumnIndexOrThrow("published")),
                    categories = (0 until cats.length()).map { cats.optString(it) },
                    author = text("author"), fullText = text("full_text"),
                    bookmark = cursor.getInt(cursor.getColumnIndexOrThrow("bookmark")) != 0,
                ))
            } }
        }
    }

    @Synchronized fun count(): Int = readableDatabase.rawQuery("SELECT COUNT(*) FROM articles", null).use {
        if (it.moveToFirst()) it.getInt(0) else 0
    }

    @Synchronized fun byId(id: String): Article? = archive().firstOrNull { it.id == id }

    @Synchronized fun bookmark(id: String, value: Boolean) {
        writableDatabase.execSQL("UPDATE articles SET bookmark = ? WHERE id = ?", arrayOf(if (value) 1 else 0, id))
    }

    @Synchronized fun cleanup(olderThan: Long, protectBookmarks: Boolean = true): Int {
        val condition = "published < ?" + if (protectBookmarks) " AND bookmark = 0" else ""
        return writableDatabase.delete("articles", condition, arrayOf(olderThan.toString()))
    }

    private fun values(item: Article) = ContentValues().apply {
        put("id", item.id)
        put("source_id", item.sourceID)
        put("source_name", item.sourceName)
        put("region", item.region.name)
        put("title", item.title)
        put("summary", item.summary)
        put("url", item.url)
        put("image", item.image)
        put("published", item.published)
        put("categories", JSONArray(item.categories).toString())
        put("author", item.author)
        put("full_text", item.fullText)
        put("bookmark", if (item.bookmark) 1 else 0)
    }
}

class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("sito-options", Context.MODE_PRIVATE)

    var language: String
        get() = prefs.getString("language", "sr") ?: "sr"
        set(v) { prefs.edit().putString("language", v).apply() }

    var theme: String
        get() = prefs.getString("theme", "system") ?: "system"
        set(v) { prefs.edit().putString("theme", v).apply() }

    var compact: Boolean
        get() = prefs.getBoolean("compact", false)
        set(v) { prefs.edit().putBoolean("compact", v).apply() }

    var paged: Boolean
        get() = prefs.getBoolean("paged", false)
        set(v) { prefs.edit().putBoolean("paged", v).apply() }

    var advanced: Boolean
        get() = prefs.getBoolean("advanced", false)
        set(v) { prefs.edit().putBoolean("advanced", v).apply() }

    fun enabled(id: String, default: Boolean = true) = prefs.getBoolean("source_$id", default)
    fun setEnabled(id: String, enabled: Boolean) { prefs.edit().putBoolean("source_$id", enabled).apply() }

    fun customSources(): List<Source> {
        val array = runCatching { JSONArray(prefs.getString("custom-sources", "[]")) }.getOrDefault(JSONArray())
        return (0 until array.length()).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            runCatching {
                Source(item.getString("id"), item.getString("name"), item.getString("feed"),
                    Region.valueOf(item.getString("region")), custom = true)
            }.getOrNull()
        }
    }

    fun addSource(name: String, feed: String, region: Region) {
        val list = customSources()
        val id = "custom_" + java.security.MessageDigest.getInstance("SHA-256")
            .digest(feed.lowercase().toByteArray()).take(8).joinToString("") { "%02x".format(it) }
        val array = JSONArray()
        for (source in list.filterNot { it.id == id } + Source(id, name, feed, region, custom = true)) {
            array.put(JSONObject().put("id", source.id).put("name", source.name)
                .put("feed", source.feed).put("region", source.region.name))
        }
        prefs.edit().putString("custom-sources", array.toString()).apply()
    }

    fun allSources() = Sources.curated + customSources()
}
