package com.seraphi.sito

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element

/** Private, text-only archive capture. Browsing still opens the original website. */
object FullTextExtractor {
    data class Capture(val text: String?, val byline: String? = null)

    suspend fun fetch(article: Article): Capture = withContext(Dispatchers.IO) {
        runCatching {
            val connection = Jsoup.connect(article.url).timeout(18_000).maxBodySize(6_000_000)
                .userAgent("SITO/0.9.4 (private text archive; Android)")
                .header("Accept", "text/html, application/xhtml+xml")
            val response = connection.execute()
            require(response.statusCode() in 200..299 && response.url().protocol == "https")
            val document = response.parse()
            Capture(findBody(document, article.summary),
                document.selectFirst("meta[name=author], meta[property=article:author]")?.attr("content"))
        }.getOrElse { Capture(null) }
    }

    internal fun findBody(document: Document, preview: String): String? {
        val structured = mutableListOf<String>()
        for (node in document.select("script[type=application/ld+json]")) {
            runCatching {
                val raw = node.data().trim().ifEmpty { node.html().trim() }
                val json: Any = if (raw.startsWith("[")) JSONArray(raw) else JSONObject(raw)
                scanArticleBodies(json, structured)
            }
        }
        for (body in structured.sortedByDescending { it.length }) {
            val candidate = plainText(body)
            if (quality(candidate, body, preview, 0)) return candidate
        }

        val tiers = listOf(
            "article .entry-content, article .article-body, article .article__body, " +
                "article .story-body, article .post-content, article .content__article, " +
                ".entry-content, .article-body, .article__body, .story-body, .post-content, .content__article" to 1,
            "article" to 1,
            "main" to 2,
        )
        for ((selector, strength) in tiers) {
            val candidates = document.select(selector).map { element ->
                val copy = element.clone()
                copy.select("script, style, noscript, nav, footer, aside, form, svg, figure, iframe, button, " +
                    ".related, .recommended, .advertisement, .ad, .newsletter, .cookie-banner").remove()
                val candidate = paragraphs(copy)
                Triple(candidate, copy.outerHtml(), strength)
            }.sortedByDescending { it.first.length }
            candidates.firstOrNull { quality(it.first, it.second, preview, it.third) }
                ?.let { return it.first }
        }
        return null
    }

    private fun scanArticleBodies(value: Any?, destination: MutableList<String>) {
        when (value) {
            is JSONArray -> for (index in 0 until value.length()) scanArticleBodies(value.opt(index), destination)
            is JSONObject -> {
                val type = value.opt("@type")?.toString()?.lowercase().orEmpty()
                if (listOf("newsarticle", "article", "blogposting", "reportagenewsarticle").any { type.contains(it) }) {
                    value.optString("articleBody").takeIf { it.isNotBlank() }?.let(destination::add)
                }
                scanArticleBodies(value.opt("@graph"), destination)
            }
        }
    }

    private fun paragraphs(element: Element): String {
        val paragraphs = element.select("p, h2, h3, blockquote, li")
            .filterNot { it.parents().any { ancestor -> ancestor != element && ancestor.tagName() in listOf("li", "blockquote") } }
            .map { it.text().trim() }.filter { it.length >= 12 }
        return (if (paragraphs.isNotEmpty()) paragraphs.joinToString("\n\n") else element.text())
            .trim().take(250_000)
    }

    fun plainText(source: String): String {
        if (source.isBlank()) return ""
        if (!source.contains('<')) return source.trim().replace(Regex("\n{3,}"), "\n\n")
        val document = Jsoup.parseBodyFragment(source)
        document.select("script, style, nav, footer, aside, form, svg, figure, iframe, button").remove()
        return paragraphs(document.body())
    }

    private fun quality(text: String, html: String, preview: String, strength: Int): Boolean {
        val minimum = maxOf(if (strength == 2) 1200 else 600, minOf(1000, preview.length + 180))
        if (text.length !in minimum..250_000 || text.length < preview.length + 180) return false
        if (text.split("\n\n").count { it.trim().length >= 70 } < (if (strength == 2) 4 else 2) && text.length < 1800) return false
        val sentences = text.count { it in ".!?…" }
        if (sentences < if (strength == 2) 5 else 3) return false
        val linked = Jsoup.parseBodyFragment(html).select("a").sumOf { it.text().length }
        if (linked.toDouble() / text.length >= if (strength == 2) 0.23 else 0.50) return false
        val lower = text.lowercase()
        return listOf("privacy policy", "cookie preferences", "all rights reserved", "enable javascript",
            "terms of service", "subscribe to our newsletter", "najnovije vesti",
            "prijavite se na newsletter", "pratite nas na").count { lower.contains(it) } < 3
    }
}
