package com.seraphi.sito

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject

class LocalStore(context: Context) : SQLiteOpenHelper(context, "sito-history.db", null, 3) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("""CREATE TABLE articles (
            id TEXT PRIMARY KEY, source_id TEXT NOT NULL, source_name TEXT NOT NULL,
            region TEXT NOT NULL, title TEXT NOT NULL, summary TEXT NOT NULL,
            url TEXT NOT NULL, image TEXT, published INTEGER NOT NULL,
            categories TEXT NOT NULL, author TEXT, full_text TEXT, bookmark INTEGER NOT NULL DEFAULT 0,
            text_checked INTEGER, text_origin TEXT, preview_text TEXT,
            source_status TEXT, canonical_url TEXT, language_code TEXT,
            modified_at INTEGER, text_captured INTEGER
        )""")
        db.execSQL("CREATE INDEX history_date ON articles(published DESC)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE articles ADD COLUMN text_checked INTEGER")
            db.execSQL("ALTER TABLE articles ADD COLUMN text_origin TEXT")
            db.execSQL("ALTER TABLE articles ADD COLUMN preview_text TEXT")
        }
        if (oldVersion < 3) {
            db.execSQL("ALTER TABLE articles ADD COLUMN source_status TEXT")
            db.execSQL("ALTER TABLE articles ADD COLUMN canonical_url TEXT")
            db.execSQL("ALTER TABLE articles ADD COLUMN language_code TEXT")
            db.execSQL("ALTER TABLE articles ADD COLUMN modified_at INTEGER")
            db.execSQL("ALTER TABLE articles ADD COLUMN text_captured INTEGER")
        }
    }

    @Synchronized fun merge(articles: List<Article>) {
        writableDatabase.beginTransaction()
        try {
            for (item in articles) {
                val previous = writableDatabase.rawQuery(
                    "SELECT * FROM articles WHERE id = ?", arrayOf(item.id)
                ).use { cursor -> if (cursor.moveToFirst()) cursor.article() else null }
                val olderText = previous?.fullText
                val prefersNewText = item.fullText != null && item.fullText.length >= (olderText?.length ?: 0)
                val merged = item.copy(
                    bookmark = item.bookmark || previous?.bookmark == true,
                    fullText = item.fullText?.takeIf { it.length >= (olderText?.length ?: 0) }
                        ?: olderText,
                    textCheckedAt = item.textCheckedAt ?: previous?.textCheckedAt,
                    textOrigin = if (prefersNewText) item.textOrigin else previous?.textOrigin,
                    textCapturedAt = if (prefersNewText) item.textCapturedAt else previous?.textCapturedAt,
                    summary = item.summary.ifBlank { previous?.summary.orEmpty() },
                    image = item.image ?: previous?.image,
                    categories = item.categories.ifEmpty { previous?.categories.orEmpty() },
                    author = item.author ?: previous?.author,
                    previewText = item.previewText ?: previous?.previewText,
                    sourceStatus = item.sourceStatus ?: previous?.sourceStatus,
                    canonicalURL = item.canonicalURL ?: previous?.canonicalURL,
                    languageCode = item.languageCode ?: previous?.languageCode,
                    modifiedAt = item.modifiedAt ?: previous?.modifiedAt,
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
            buildList { while (cursor.moveToNext()) add(cursor.article()) }
        }
    }

    /** Backups must include every row, even when the history UI is capped. */
    @Synchronized fun allArticles(): List<Article> = readableDatabase.query(
        "articles", null, null, null, null, null, "published DESC").use { cursor ->
        buildList { while (cursor.moveToNext()) add(cursor.article()) }
    }

    @Synchronized fun completeCount(): Int = readableDatabase.rawQuery(
        "SELECT COUNT(*) FROM articles WHERE full_text IS NOT NULL AND LENGTH(full_text) >= 500", null
    ).use { if (it.moveToFirst()) it.getInt(0) else 0 }

    private fun Cursor.article(): Article {
        fun text(key: String): String? = getColumnIndex(key).takeIf { it >= 0 }?.let { index ->
            if (isNull(index)) null else getString(index)
        }
        val region = runCatching { Region.valueOf(text("region") ?: "SERBIA") }.getOrDefault(Region.SERBIA)
        val cats = runCatching { JSONArray(text("categories") ?: "[]") }.getOrDefault(JSONArray())
        return Article(id = text("id").orEmpty(), sourceID = text("source_id").orEmpty(),
            sourceName = text("source_name").orEmpty(), region = region,
            title = text("title").orEmpty(), summary = text("summary").orEmpty(),
            url = text("url").orEmpty(), image = text("image"),
            published = getLong(getColumnIndexOrThrow("published")),
            categories = (0 until cats.length()).map { cats.optString(it) },
            author = text("author"), fullText = text("full_text"),
            bookmark = getInt(getColumnIndexOrThrow("bookmark")) != 0,
            textCheckedAt = text("text_checked")?.toLongOrNull(),
            textOrigin = text("text_origin"), previewText = text("preview_text"),
            sourceStatus = text("source_status"), canonicalURL = text("canonical_url"),
            languageCode = text("language_code"), modifiedAt = text("modified_at")?.toLongOrNull(),
            textCapturedAt = text("text_captured")?.toLongOrNull())
    }

    @Synchronized fun count(): Int = readableDatabase.rawQuery("SELECT COUNT(*) FROM articles", null).use {
        if (it.moveToFirst()) it.getInt(0) else 0
    }

    @Synchronized fun articleIDs(): Set<String> = readableDatabase.rawQuery(
        "SELECT id FROM articles", null).use { cursor ->
        buildSet { while (cursor.moveToNext()) add(cursor.getString(0)) }
    }

    @Synchronized fun byId(id: String): Article? = readableDatabase.query("articles", null,
        "id = ?", arrayOf(id), null, null, null, "1").use { cursor ->
        if (cursor.moveToFirst()) cursor.article() else null
    }

    @Synchronized fun incomplete(limit: Int, olderThan: Long): List<Article> = readableDatabase.query(
        "articles", null, "(full_text IS NULL OR LENGTH(full_text) < 500) AND (text_checked IS NULL OR text_checked < ?)",
        arrayOf(olderThan.toString()), null, null, "published DESC", limit.coerceIn(1, 40).toString()
    ).use { cursor -> buildList { while (cursor.moveToNext()) add(cursor.article()) } }

    @Synchronized fun recordCapture(id: String, result: FullTextExtractor.Capture) {
        val values = ContentValues().apply {
            put("text_checked", System.currentTimeMillis())
            if (result.text != null) {
                put("full_text", result.text)
                put("text_origin", "original")
                put("text_captured", System.currentTimeMillis())
                if (!result.byline.isNullOrBlank()) put("author", result.byline)
            }
        }
        writableDatabase.update("articles", values, "id = ?", arrayOf(id))
    }

    @Synchronized fun bookmark(id: String, value: Boolean) {
        writableDatabase.execSQL("UPDATE articles SET bookmark = ? WHERE id = ?", arrayOf(if (value) 1 else 0, id))
    }

    @Synchronized fun cleanup(olderThan: Long, protectBookmarks: Boolean = true): Int {
        val condition = "published < ?" + if (protectBookmarks) " AND bookmark = 0" else ""
        val removed = writableDatabase.delete("articles", condition, arrayOf(olderThan.toString()))
        if (removed > 0) writableDatabase.execSQL("VACUUM")
        return removed
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
        put("text_checked", item.textCheckedAt)
        put("text_origin", item.textOrigin)
        put("preview_text", item.previewText)
        put("source_status", item.sourceStatus)
        put("canonical_url", item.canonicalURL)
        put("language_code", item.languageCode)
        put("modified_at", item.modifiedAt)
        put("text_captured", item.textCapturedAt)
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

    var autoComplete: Boolean
        get() = prefs.getBoolean("autoComplete", true)
        set(v) { prefs.edit().putBoolean("autoComplete", v).apply() }
    var autoCompleteWifiOnly: Boolean
        get() = prefs.getBoolean("autoCompleteWifiOnly", true)
        set(v) { prefs.edit().putBoolean("autoCompleteWifiOnly", v).apply() }
    var lastAutoComplete: Long
        get() = prefs.getLong("lastAutoComplete", 0L)
        set(v) { prefs.edit().putLong("lastAutoComplete", v).apply() }

    private val defaultTopics = setOf(Topic.POLITICS, Topic.SOCIETY, Topic.TECHNOLOGY,
        Topic.SCIENCE, Topic.CULTURE)
    fun visibleTopics(): List<Topic> = Topic.entries.filter {
        it == Topic.ALL || prefs.getBoolean("topic_${it.name}", it in defaultTopics)
    }
    fun setTopicVisible(topic: Topic, visible: Boolean) {
        if (topic != Topic.ALL) prefs.edit().putBoolean("topic_${topic.name}", visible).apply()
    }

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
