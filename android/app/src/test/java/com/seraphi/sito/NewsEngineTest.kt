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

    @Test fun customDirectoryAcceptsOpmlAndJson() {
        val opml = """<?xml version="1.0"?><opml version="2.0"><body>
            <outline title="Technology"><outline text="Example" xmlUrl="https://example.org/rss" /></outline>
            </body></opml>"""
        val fromOpml = SourceDirectory.parse(opml)
        assertEquals("Example", fromOpml.single().name)
        assertEquals("Technology", fromOpml.single().group)
        val json = """{"feeds":[{"title":"Radio","feed_url":"https://example.org/radio.xml"}]}"""
        assertEquals("Radio", SourceDirectory.parse(json).single().name)
    }

    @Test fun curatedCollectionsAreDistinctAndUseExistingPlenaryTopics() {
        assertEquals(listOf("News", "Technology", "Science", "Business", "Environment", "Books"),
            SourceDirectory.featured.map { it.title })
        assertEquals(6, SourceDirectory.featured.map { it.url }.toSet().size)
        assertTrue(SourceDirectory.featured.all { it.url.startsWith(
            "https://raw.githubusercontent.com/plenaryapp/awesome-rss-feeds/") })
    }

    @Test fun directorySuggestsSerbiaForSerbianHostsAndWorldElsewhere() {
        assertEquals(Region.SERBIA, SourceDirectory.inferredRegion("https://n1info.rs/feed/"))
        assertEquals(Region.WORLD, SourceDirectory.inferredRegion("https://bbc.com/feed/"))
        assertEquals(Region.SERBIA, SourceDirectory.parse(
            "https://www.danas.rs/feed/\nhttps://feeds.bbci.co.uk/news/rss.xml").first().region)
    }

    @Test fun longerFogMazeHasReachableSealsAndDeadEnds() {
        repeat(60) {
            val maze = FogMaze.create()
            assertEquals(19, FogMaze.width)
            assertEquals(3, maze.seals.size)
            val reached = mutableSetOf(maze.start)
            val queue = ArrayDeque<Int>().apply { add(maze.start) }
            while (queue.isNotEmpty()) {
                val tile = queue.removeFirst()
                val row = tile / FogMaze.width; val col = tile % FogMaze.width
                for ((dr, dc) in listOf(-1 to 0, 1 to 0, 0 to -1, 0 to 1)) {
                    val r = row + dr; val c = col + dc
                    if (r !in 0 until FogMaze.width || c !in 0 until FogMaze.width) continue
                    val next = r * FogMaze.width + c
                    if (next in maze.open && reached.add(next)) queue.add(next)
                }
            }
            assertTrue(maze.exit in reached)
            assertTrue(reached.containsAll(maze.seals))
            assertTrue(maze.open.size >= 150)
        }
    }

    @Test fun sourceDirectoryPromotesPlainHttpToHttps() {
        assertEquals("https://example.org/feed", SourceDirectory.secureURL("http://example.org/feed"))
        assertNull(SourceDirectory.secureURL("javascript:alert(1)"))
    }

    @Test fun neverAcceptRumorsFromRaspadListing() {
        val source = Sources.curated.first { it.id == "raspad" }
        val sample = """<ul><li class="dayhdr">25. novembar</li>
            <li class="item" id="c-OK"><span class="st potvrdjeno">potvrđeno</span>
              <div class="title">Confirmed event</div><div class="text">Verified report</div>
              <div class="time">13:40</div></li>
            <li class="item" id="c-NO"><span class="st nepotvrdjeno">glasina</span>
              <div class="title">Unconfirmed event</div></li></ul>"""
        val items = NewsEngine.parseRaspad(sample, source)
        assertEquals(1, items.size)
        assertEquals("raspad|c-OK", items.single().id)
    }

    @Test fun encryptedArchiveIsAuthenticated() {
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            VaultCipher.sha256("abc".toByteArray()))
        val key = ByteArray(32) { it.toByte() }
        val plain = "Private story contents, never uploaded in the clear".toByteArray()
        val aad = "SITO-portable-PDF-v1:test".toByteArray()
        val encrypted = VaultCipher.encrypt(plain, key, aad)
        assertArrayEquals(plain, VaultCipher.decrypt(encrypted, key, aad))
        assertThrows(IllegalStateException::class.java) {
            VaultCipher.decrypt(encrypted, key, "other article".toByteArray())
        }
        assertThrows(IllegalStateException::class.java) {
            VaultCipher.decrypt(encrypted, ByteArray(32), aad)
        }
    }

    @Test fun archiveRetainsOptionalSwiftMetadata() {
        val item = Article("publisher|story", "publisher", "Publisher", Region.WORLD,
            "Article title", "An RSS preview", "https://example.org/story", null,
            1795600000000, fullText = "This is a full article. ".repeat(40),
            textOrigin = "original", author = "Reporter",
            sourceStatus = "confirmed", canonicalURL = "https://example.org/canonical",
            languageCode = "en", modifiedAt = 1795600001000, textCapturedAt = 1795600005000)
        val restored = VaultJSON.decode(VaultJSON.encode(item))
        assertEquals(item.id, restored.id)
        assertEquals(item.fullText, restored.fullText)
        assertEquals(item.canonicalURL, restored.canonicalURL)
        assertEquals(item.sourceStatus, restored.sourceStatus)
        assertEquals(item.modifiedAt, restored.modifiedAt)
        assertEquals(item.textCapturedAt, restored.textCapturedAt)
    }
}
