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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

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
    val textCheckedAt: Long? = null,
    val textOrigin: String? = null,
    val previewText: String? = null,
)

fun Article.hasFullText(): Boolean {
    val body = fullText?.trim().orEmpty()
    if (body.isBlank()) return false
    return if (textOrigin == "feed") {
        body.length >= 650 && body.length >= summary.length + 180 &&
            (body.split("\n\n").count { it.length >= 65 } >= 2 || body.length >= 1800)
    } else body.length >= 500
}

object Sources {
    val curated = listOf(
        Source("n1", "N1", "https://n1info.rs/feed/", Region.SERBIA),
        Source("danas", "Danas", "https://www.danas.rs/feed/", Region.SERBIA),
        Source("nova", "Nova.rs", "https://nova.rs/feed/", Region.SERBIA),
        Source("krik", "KRIK", "https://www.krik.rs/feed/", Region.SERBIA),
        Source("cins", "CINS", "https://www.cins.rs/feed/", Region.SERBIA),
        Source("raspad", "Raspad Sistema", "https://raspadsistema.com/?status=potvrdjeno", Region.SERBIA),
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
    data class FetchReport(val items: List<Article>, val unavailable: List<String>)

    suspend fun fetchAll(sources: List<Source>): FetchReport = coroutineScope {
        // Slow sources must never block scrolling or source selection. A bounded
        // number of concurrent requests avoids flooding phones and publishers.
        val slots = Semaphore(4)
        val results = sources.map { source ->
            async(Dispatchers.IO) {
                slots.withPermit {
                    runCatching { fetch(source) }.fold(
                        onSuccess = { it to null },
                        onFailure = { emptyList<Article>() to source.name },
                    )
                }
            }
        }.awaitAll()
        FetchReport(results.flatMap { it.first }, results.mapNotNull { it.second })
    }

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
            val body = connection.inputStream.use { stream ->
                val bytes = stream.readNBytes(3_000_001)
                require(bytes.size <= 3_000_000) { "Feed is too large" }
                String(bytes, Charsets.UTF_8)
            }
            if (source.id == "raspad") parseRaspad(body, source)
            else if (body.trimStart().startsWith("{")) parseJson(body, source)
            else parseXml(body, source)
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
            val rawContent = entry.getElementsByTag("content:encoded").firstOrNull()?.html()
                ?: entry.getElementsByTag("content").firstOrNull()?.html().orEmpty()
            val content = FullTextExtractor.plainText(rawContent)
            val image = listOf("media:thumbnail", "media:content", "enclosure").firstNotNullOfOrNull { name ->
                normalizeHttpURL(entry.getElementsByTag(name).firstOrNull()?.attr("url").orEmpty())
            } ?: findImage(entry.childText("description") + entry.childText("content:encoded"))
            Article(
                id = source.id + "|" + entry.childText("guid")
                    .ifBlank { entry.childText("id") }.ifBlank { destination }, sourceID = source.id,
                sourceName = source.name, region = source.region,
                title = clean(title), summary = summary, url = destination,
                image = image, published = parseDate(entry.childText("pubDate")
                    .ifEmpty { entry.childText("published") }.ifEmpty { entry.childText("updated") }),
                categories = entry.getElementsByTag("category").map { it.text() }.filter { it.isNotBlank() },
                author = entry.childText("dc:creator").ifBlank { entry.childText("author") }.ifBlank { null },
                fullText = content.takeIf { candidate ->
                    candidate.length >= 650 && candidate.length >= summary.length + 180 &&
                        (candidate.split("\n\n").count { it.length >= 65 } >= 2 || candidate.length >= 1800)
                },
                textOrigin = "feed",
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
            val content = FullTextExtractor.plainText(item.optString("content_html")
                .ifEmpty { item.optString("content_text") })
            Article(
                id = source.id + "|" + item.optString("id").ifBlank { destination }, sourceID = source.id,
                sourceName = source.name, region = source.region, title = title,
                summary = clean(item.optString("summary")), url = destination, image = image,
                published = parseDate(item.optString("date_published")),
                fullText = content.takeIf { it.length >= 650 && it.length >= 180 + item.optString("summary").length },
                textOrigin = "feed",
            )
        }
    }

    internal fun parseRaspad(html: String, source: Source): List<Article> {
        // This is not an RSS source. Only explicitly confirmed / official
        // entries from the publisher's public listing are included.
        val months = listOf("januar", "februar", "mart", "april", "maj", "jun",
            "jul", "avgust", "septembar", "oktobar", "novembar", "decembar")
        val document = Jsoup.parse(html, "https://raspadsistema.com")
        var day = 0
        var month = 0
        val zone = java.time.ZoneId.of("Europe/Belgrade")
        val now = java.time.ZonedDateTime.now(zone)
        return document.select("li.dayhdr, li.item").mapNotNull { node ->
            if (node.hasClass("dayhdr")) {
                val match = Regex("(\\d{1,2})\\.\\s*([\\p{L}]+)")
                    .find(node.text().lowercase(Locale.ROOT))
                day = match?.groupValues?.getOrNull(1)?.toIntOrNull() ?: 0
                month = months.indexOf(match?.groupValues?.getOrNull(2)) + 1
                return@mapNotNull null
            }
            val id = node.id().takeIf { it.matches(Regex("c-[a-zA-Z0-9]+")) }
                ?: return@mapNotNull null
            val status = node.selectFirst("span.st.potvrdjeno, span.st.zvanicno")
                ?: return@mapNotNull null
            val title = node.selectFirst("div.title")?.text()?.trim().orEmpty()
            if (title.isBlank()) return@mapNotNull null
            val summary = node.selectFirst("div.text")?.text().orEmpty()
            val link = node.selectFirst("div.srcline a[href]")?.absUrl("href").orEmpty()
            val destination = normalizeHttpURL(link)
                ?: "https://raspadsistema.com/?status=potvrdjeno#$id"
            val time = node.selectFirst("div.time")?.text()?.trim().orEmpty().split(":")
            val published = runCatching {
                val hour = time.getOrNull(0)?.toIntOrNull() ?: 12
                val minute = time.getOrNull(1)?.toIntOrNull() ?: 0
                var date = now.withMonth(month).withDayOfMonth(day)
                    .withHour(hour).withMinute(minute).withSecond(0).withNano(0)
                if (date.isAfter(now.plusDays(2))) date = date.minusYears(1)
                date.toInstant().toEpochMilli()
            }.getOrDefault(System.currentTimeMillis())
            Article(id = "raspad|$id", sourceID = source.id,
                sourceName = source.name, region = source.region,
                title = title, summary = summary, url = destination,
                image = null, published = published,
                categories = listOf(if (status.hasClass("zvanicno")) "zvanično" else "potvrđeno"))
        }
    }

    fun mixed(items: List<Article>): List<Article> {
        val sourceCount = items.map { it.sourceID }.distinct().size.coerceAtLeast(1)
        val cap = if (sourceCount == 1) 700 else maxOf(20, 180 / sourceCount)
        val counts = mutableMapOf<String, Int>()
        val windows = sortedMapOf<Long, MutableList<Article>>(reverseOrder())
        for (item in items.sortedByDescending { it.published }) {
            val used = counts[item.sourceID] ?: 0
            if (used >= cap) continue
            counts[item.sourceID] = used + 1
            windows.getOrPut(item.published / 21_600_000L) { mutableListOf() }.add(item)
        }
        val output = mutableListOf<Article>()
        for (window in windows.values) {
            val queues = window.groupBy { it.sourceID }
            val order = queues.keys.sortedByDescending { queues[it]?.firstOrNull()?.published ?: 0 }
            val positions = mutableMapOf<String, Int>()
            while (positions.values.sum() < window.size) {
                for (id in order) {
                    val index = positions[id] ?: 0
                    val article = queues[id]?.getOrNull(index) ?: continue
                    output.add(article)
                    positions[id] = index + 1
                }
            }
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

}
