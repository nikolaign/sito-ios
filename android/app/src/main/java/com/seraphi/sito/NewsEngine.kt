package com.seraphi.sito

import org.jsoup.Jsoup
import org.jsoup.parser.Parser
import org.jsoup.nodes.Element
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.OffsetDateTime
import java.util.Date
import java.util.Locale
import kotlin.math.min

data class Source(
    val id: String,
    val name: String,
    val feed: String,
    val region: Region,
    val defaultOn: Boolean = true,
    val custom: Boolean = false,
)

enum class Region { SERBIA, WORLD }

enum class Topic(val sr: String, val en: String) {
    ALL("Sve", "All"), POLITICS("Politika", "Politics"), SOCIETY("Društvo", "Society"),
    ECONOMY("Ekonomija", "Economy"), TECHNOLOGY("Tehnologija", "Technology"),
    SCIENCE("Nauka", "Science"), HEALTH("Zdravlje", "Health"),
    ENVIRONMENT("Priroda", "Environment"), CULTURE("Kultura", "Culture"),
    SPORT("Sport", "Sport"), ENTERTAINMENT("Zabava", "Entertainment");

    fun label(srLanguage: Boolean) = if (srLanguage) sr else en
}

data class Article(
    val id: String,
    val sourceID: String,
    val sourceName: String,
    val region: Region,
    val title: String,
    val summary: String,
    val url: String,
    val image: String?,
    val published: Long,
    val categories: List<String> = emptyList(),
    val author: String? = null,
    val fullText: String? = null,
    val bookmark: Boolean = false,
)

object Sources {
    val curated = listOf(
        Source("n1", "N1", "https://n1info.rs/feed/", Region.SERBIA),
        Source("danas", "Danas", "https://www.danas.rs/feed/", Region.SERBIA),
        Source("nova", "Nova.rs", "https://nova.rs/feed/", Region.SERBIA),
        Source("krik", "KRIK", "https://www.krik.rs/feed/", Region.SERBIA),
        Source("cins", "CINS", "https://www.cins.rs/feed/", Region.SERBIA),
        Source("bbc", "BBC World", "https://feeds.bbci.co.uk/news/world/rss.xml", Region.WORLD),
        Source("dw", "DW English", "https://rss.dw.com/xml/rss-en-all", Region.WORLD),
        Source("guardian", "The Guardian", "https://www.theguardian.com/world/rss", Region.WORLD),
    )
}

object TopicRules {
    private val rules = linkedMapOf(
        Topic.SPORT to listOf("sport", "fudbal", "football", "soccer", "tenis", "tennis", "basketball", "košarka", "kosarka", "liga", "nba", "uefa"),
        Topic.ENTERTAINMENT to listOf("showbiz", "estrada", "rijaliti", "celebrity", "hollywood", "gossip"),
        Topic.POLITICS to listOf("politika", "politics", "izbori", "election", "parliament", "skupština", "vlada", "government", "president", "predsednik"),
        Topic.SOCIETY to listOf("društvo", "drustvo", "society", "studenti", "students", "obrazovanje", "education", "policija", "police"),
        Topic.ECONOMY to listOf("ekonomija", "economy", "inflation", "inflacija", "business", "berza", "finance"),
        Topic.TECHNOLOGY to listOf("tehnologija", "technology", "software", "softver", "artificial intelligence", "iphone", "nvidia", "cybersecurity", "robot"),
        Topic.SCIENCE to listOf("nauka", "science", "svemir", "astronomy", "astronomija", "archaeology", "physics", "fizika"),
        Topic.HEALTH to listOf("zdravlje", "health", "medicine", "medicina", "vaccine", "vakcina", "epidemic"),
        Topic.ENVIRONMENT to listOf("environment", "ekologija", "ecology", "climate", "klima", "zagađenje", "zagadjenje", "pollution", "biodiversity"),
        Topic.CULTURE to listOf("kultura", "culture", "literature", "književnost", "pozorište", "muzej", "museum", "theatre", "art exhibition"),
    )

    fun classify(article: Article): Topic {
        val metadata = article.categories.joinToString(" ").lowercase(Locale.ROOT)
        val headline = article.title.lowercase(Locale.ROOT)
        return rules.entries.firstOrNull { (_, terms) ->
            terms.any { word -> metadata.split(Regex("[^\\p{L}]+")).contains(word) || metadata.contains(word + " ") }
        }?.key ?: rules.entries.firstOrNull { (_, terms) ->
            terms.any { word ->
                if (word.length <= 3) Regex("(?<![\\p{L}])${Regex.escape(word)}(?![\\p{L}])").containsMatchIn(headline)
                else headline.contains(word)
            }
        }?.key ?: Topic.ALL
    }
}

object NewsEngine {
    fun fetch(source: Source): List<Article> {
        val url = URL(source.feed)
        require(url.protocol == "https")
        val connection = (url.openConnection() as HttpURLConnection).apply {
            connectTimeout = 12_000
            readTimeout = 15_000
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", "SITO/0.9.4 (+Android; RSS reader)")
            setRequestProperty("Accept", "application/rss+xml, application/atom+xml, application/feed+json, application/xml, text/xml, application/json, */*")
        }
        return try {
            require(connection.responseCode in 200..299) { "HTTP ${connection.responseCode}" }
            require(connection.url.protocol == "https") { "Non-HTTPS redirect" }
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            if (body.trimStart().startsWith("{")) parseJson(body, source) else parseXml(body, source)
        } finally {
            connection.disconnect()
        }
    }

    internal fun parseXml(xml: String, source: Source): List<Article> {
        val document = Jsoup.parse(xml, "", Parser.xmlParser())
        return document.select("item, entry").take(90).mapNotNull { entry ->
            val title = entry.childText("title")
            val link = entry.childText("link").ifEmpty {
                entry.getElementsByTag("link").firstOrNull()?.attr("href").orEmpty()
            }
            val destination = normalizeHttpURL(link) ?: return@mapNotNull null
            if (title.isBlank()) return@mapNotNull null
            val summary = clean(entry.childText("description").ifEmpty { entry.childText("summary") })
            val content = clean(entry.childText("content:encoded").ifEmpty { entry.childText("content") })
            val image = listOf("media:thumbnail", "media:content", "enclosure").firstNotNullOfOrNull { name ->
                normalizeHttpURL(entry.getElementsByTag(name).firstOrNull()?.attr("url").orEmpty())
            } ?: findImage(entry.childText("description") + entry.childText("content:encoded"))
            Article(
                id = digest(source.id + ":" + destination), sourceID = source.id,
                sourceName = source.name, region = source.region,
                title = clean(title), summary = summary, url = destination,
                image = image, published = parseDate(entry.childText("pubDate")
                    .ifEmpty { entry.childText("published") }.ifEmpty { entry.childText("updated") }),
                categories = entry.getElementsByTag("category").map { it.text() }.filter { it.isNotBlank() },
                author = entry.childText("dc:creator").ifBlank { entry.childText("author") }.ifBlank { null },
                fullText = content.takeIf { it.length >= 650 && it.length >= summary.length + 180 },
            )
        }.distinctBy { it.url }
    }

    internal fun parseJson(json: String, source: Source): List<Article> {
        val items = JSONObject(json).optJSONArray("items") ?: return emptyList()
        return (0 until min(items.length(), 90)).mapNotNull { index ->
            val item = items.optJSONObject(index) ?: return@mapNotNull null
            val destination = normalizeHttpURL(item.optString("url")) ?: return@mapNotNull null
            val title = item.optString("title").takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val attachments = item.optJSONArray("attachments")
            val image = normalizeHttpURL(item.optString("image"))
                ?: (0 until (attachments?.length() ?: 0)).firstNotNullOfOrNull { n ->
                    val a = attachments?.optJSONObject(n)
                    if (a?.optString("mime_type")?.startsWith("image/") == true) normalizeHttpURL(a.optString("url")) else null
                }
            val content = clean(item.optString("content_html").ifEmpty { item.optString("content_text") })
            Article(
                id = digest(source.id + ":" + destination), sourceID = source.id,
                sourceName = source.name, region = source.region, title = title,
                summary = clean(item.optString("summary")), url = destination, image = image,
                published = parseDate(item.optString("date_published")),
                fullText = content.takeIf { it.length >= 650 },
            )
        }
    }

    fun mixed(items: List<Article>): List<Article> {
        val sources = items.groupBy { it.sourceID }.mapValues { (_, articles) -> articles.sortedByDescending { it.published }.toMutableList() }
        val order = sources.keys.sorted()
        val output = mutableListOf<Article>()
        var index = 0
        while (output.size < items.size && index < items.size) {
            val round = order.mapNotNull { id -> sources[id]?.getOrNull(index) }
                .sortedByDescending { it.published }
            output += round
            index++
        }
        return output
    }

    private fun Element.childText(tag: String): String = getElementsByTag(tag).firstOrNull()?.text().orEmpty()
    private fun clean(value: String): String = Jsoup.parse(value).text().replace(Regex("\\s+"), " ").trim()
    private fun findImage(html: String): String? = normalizeHttpURL(Jsoup.parse(html).selectFirst("img[src]")?.attr("src").orEmpty())
    private fun normalizeHttpURL(raw: String): String? = try {
        val url = URL(raw.trim())
        if (url.protocol == "https") url.toString() else null
    } catch (_: Exception) { null }

    private fun parseDate(value: String): Long {
        if (value.isBlank()) return System.currentTimeMillis()
        try { return OffsetDateTime.parse(value).toInstant().toEpochMilli() } catch (_: Exception) { }
        try { return Instant.parse(value).toEpochMilli() } catch (_: Exception) { }
        for (format in listOf("EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm:ss Z")) {
            try { return SimpleDateFormat(format, Locale.US).parse(value)?.time ?: continue } catch (_: Exception) { }
        }
        return Date().time
    }

    private fun digest(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
}
