package com.seraphi.sito

import org.junit.Assert.*
import org.junit.Test

class NewsEngineTest {
    private val source = Source("test", "Test Publisher", "https://example.org/feed.xml", Region.WORLD)

    @Test fun rssKeepsSourceAndMetadata() {
        val feed = """
            <rss version="2.0"><channel><title>Example</title>
              <item><title>Parliament approves a new law</title>
                <link>https://example.org/story</link>
                <pubDate>Mon, 23 Nov 2026 09:00:00 +0000</pubDate>
                <description><![CDATA[<p>Short <b>summary</b></p>]]></description>
                <category>Politics</category>
                <enclosure url="https://example.org/pic.jpg" type="image/jpeg" />
              </item>
            </channel></rss>
        """.trimIndent()
        val news = NewsEngine.parseXml(feed, source)
        assertEquals(1, news.size)
        assertEquals("Test Publisher", news.single().sourceName)
        assertEquals("Short summary", news.single().summary)
        assertEquals("https://example.org/pic.jpg", news.single().image)
        assertEquals(Topic.POLITICS, TopicRules.classify(news.single()))
    }

    @Test fun jsonFeedHasReadableTitle() {
        val json = """{"version":"https://jsonfeed.org/version/1","items":[
          {"id":"one","url":"https://example.org/one","title":"New research",
           "summary":"A short preview","date_published":"2026-11-25T10:00:00Z"}
        ]}"""
        val news = NewsEngine.parseJson(json, source)
        assertEquals("New research", news.single().title)
        assertEquals("https://example.org/one", news.single().url)
    }

    @Test fun celebrityHeadlineIsNotEnvironment() {
        val item = Article("1", "test", "Test", Region.WORLD,
            "Hilari Svonk odgovorila svima koji je kritikuju zbog trudnoće",
            "", "https://example.org/story", null, 0L)
        assertEquals(Topic.ALL, TopicRules.classify(item))
    }

    @Test fun sourceMixPreventsSingleFeedFlooding() {
        fun item(id: Int, source: String) = Article(id.toString(), source, source, Region.WORLD,
            "Article $id", "", "https://example.org/$id", null, (100 - id).toLong())
        val mixed = NewsEngine.mixed((0 until 8).map { item(it, "a") } + (20 until 23).map { item(it, "b") })
        assertEquals(11, mixed.size)
        assertTrue(mixed.take(2).map { it.sourceID }.toSet().size == 2)
    }
}
