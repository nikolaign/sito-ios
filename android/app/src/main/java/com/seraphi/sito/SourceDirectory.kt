package com.seraphi.sito

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.jsoup.Jsoup
import org.jsoup.parser.Parser
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

data class FeedDirectory(val id: String, val title: String, val url: String, val custom: Boolean = false)
data class DirectoryFeed(val name: String, val feedURL: String, val group: String, val region: Region)

object SourceDirectory {
    val featured = listOf(
        FeedDirectory("plenary-news", "World news", "https://raw.githubusercontent.com/plenaryapp/awesome-rss-feeds/master/recommended/with_category/News.opml"),
        FeedDirectory("plenary-tech", "Technology", "https://raw.githubusercontent.com/plenaryapp/awesome-rss-feeds/master/recommended/with_category/Tech.opml"),
        FeedDirectory("plenary-science", "Science", "https://raw.githubusercontent.com/plenaryapp/awesome-rss-feeds/master/recommended/with_category/Science.opml"),
        FeedDirectory("plenary-economy", "Business", "https://raw.githubusercontent.com/plenaryapp/awesome-rss-feeds/master/recommended/with_category/Business%20%26%20Economy.opml"),
        FeedDirectory("plenary-environment", "Environment", "https://raw.githubusercontent.com/plenaryapp/awesome-rss-feeds/master/recommended/with_category/Environment.opml"),
        FeedDirectory("plenary-books", "Books", "https://raw.githubusercontent.com/plenaryapp/awesome-rss-feeds/master/recommended/with_category/Books.opml"),
    )

    fun inferredRegion(address: String): Region {
        val host = runCatching { URI(address).host?.lowercase().orEmpty() }.getOrDefault("")
        return if (host == "rs" || host.endsWith(".rs")) Region.SERBIA else Region.WORLD
    }

    fun secureURL(raw: String): String? = runCatching {
        val value = raw.trim().replace(Regex("^http://", RegexOption.IGNORE_CASE), "https://")
        val uri = URI(if (value.contains("://")) value else "https://$value")
        if (uri.scheme?.lowercase() != "https" || uri.host.isNullOrBlank() ||
            !uri.host.contains('.') || uri.userInfo != null) null
        else uri.toASCIIString().substringBefore('#')
    }.getOrNull()

    fun directoryURL(input: String): String? {
        val url = secureURL(input) ?: return null
        val uri = URI(url)
        if (uri.host != "github.com") return url
        val path = uri.path.trim('/').split('/')
        if (path.size < 5 || path[2] != "blob") return null
        return "https://raw.githubusercontent.com/${path[0]}/${path[1]}/${path.drop(3).joinToString("/")}" 
    }

    suspend fun load(address: String): List<DirectoryFeed> = withContext(Dispatchers.IO) {
        val url = URL(directoryURL(address) ?: error("Invalid HTTPS catalogue URL"))
        val connection = (url.openConnection() as HttpURLConnection).apply {
            connectTimeout = 12_000
            readTimeout = 18_000
            instanceFollowRedirects = true
            setRequestProperty("Accept", "application/xml, text/xml, application/json, text/plain")
        }
        try {
            require(connection.responseCode in 200..299 && connection.url.protocol == "https") {
                "Catalogue HTTP ${connection.responseCode}"
            }
            val bytes = connection.inputStream.use { it.readAtMost(1_000_001) }
            require(bytes.size <= 1_000_000) { "Catalogue exceeds 1 MB" }
            parse(String(bytes, Charsets.UTF_8))
        } finally { connection.disconnect() }
    }

    internal fun parse(body: String): List<DirectoryFeed> {
        val text = body.trim().removePrefix("\uFEFF")
        val entries: List<DirectoryFeed> = when {
            text.startsWith("<") -> {
                val document = Jsoup.parse(text, "", Parser.xmlParser())
                require(document.selectFirst("opml") != null) { "This is not an OPML file" }
                document.select("outline[xmlUrl], outline[xmlurl]").mapNotNull { node ->
                    val feed = secureURL(node.attr("xmlUrl").ifBlank { node.attr("xmlurl") })
                        ?: return@mapNotNull null
                    val name = node.attr("title").ifBlank { node.attr("text") }.ifBlank { URI(feed).host }
                    val group = node.parent()?.attr("title").orEmpty().ifBlank {
                        node.parent()?.attr("text").orEmpty()
                    }
                    DirectoryFeed(name, feed, group, inferredRegion(feed))
                }
            }
            text.startsWith("{") || text.startsWith("[") -> {
                val root = if (text.startsWith("[")) JSONArray(text) else JSONObject(text).let { json ->
                    json.optJSONArray("feeds") ?: json.optJSONArray("sources") ?: json.optJSONArray("items") ?: JSONArray()
                }
                (0 until root.length()).mapNotNull { index ->
                    val entry = root.optJSONObject(index) ?: return@mapNotNull null
                    val feed = listOf("xmlUrl", "xmlurl", "feed_url", "feedURL", "feed", "url")
                        .firstNotNullOfOrNull { key -> entry.optString(key).takeIf { it.isNotBlank() } }
                        ?.let(::secureURL) ?: return@mapNotNull null
                    val name = listOf("title", "name", "text")
                        .firstNotNullOfOrNull { key -> entry.optString(key).takeIf { it.isNotBlank() } }
                        ?: URI(feed).host
                    DirectoryFeed(name, feed, entry.optString("category", entry.optString("group")),
                        if (entry.optString("section").equals("serbia", ignoreCase = true))
                            Region.SERBIA else inferredRegion(feed))
                }
            }
            else -> text.lines().mapNotNull { line ->
                val raw = line.trim()
                if (raw.startsWith("#") || !raw.startsWith("http")) return@mapNotNull null
                val feed = secureURL(raw) ?: return@mapNotNull null
                DirectoryFeed(URI(feed).host, feed, "", inferredRegion(feed))
            }
        }
        return entries.distinctBy { it.feedURL.lowercase() }.take(1500)
            .also { require(it.isNotEmpty()) { "No HTTPS feed links found" } }
    }
}

class DirectoryCache(context: Context) {
    private val prefs = context.getSharedPreferences("sito-catalogue", Context.MODE_PRIVATE)
    fun custom(): List<FeedDirectory> = runCatching {
        val array = JSONArray(prefs.getString("catalogues", "[]"))
        (0 until array.length()).mapNotNull { i -> array.optJSONObject(i)?.let {
            FeedDirectory(it.optString("id"), it.optString("title"), it.optString("url"), true)
        } }
    }.getOrDefault(emptyList())

    fun add(name: String, address: String) {
        val url = SourceDirectory.directoryURL(address) ?: error("Use an HTTPS OPML, JSON or text URL")
        val list = custom().filterNot { it.url == url } + FeedDirectory(java.util.UUID.randomUUID().toString(), name, url, true)
        val array = JSONArray()
        list.forEach { array.put(JSONObject().put("id", it.id).put("title", it.title).put("url", it.url)) }
        prefs.edit().putString("catalogues", array.toString()).apply()
    }

    fun cached(id: String): List<DirectoryFeed> = runCatching {
        val array = JSONArray(prefs.getString("cache_$id", "[]"))
        (0 until array.length()).mapNotNull { n -> array.optJSONObject(n)?.let { json ->
            DirectoryFeed(json.optString("name"), json.optString("feed"), json.optString("group"),
                if (json.optString("region") == "SERBIA") Region.SERBIA else Region.WORLD)
        } }
    }.getOrDefault(emptyList())

    fun save(id: String, entries: List<DirectoryFeed>) {
        val array = JSONArray()
        entries.forEach { array.put(JSONObject().put("name", it.name).put("feed", it.feedURL)
            .put("group", it.group).put("region", it.region.name)) }
        prefs.edit().putString("cache_$id", array.toString()).putLong("updated_$id", System.currentTimeMillis()).apply()
    }

    fun updated(id: String) = prefs.getLong("updated_$id", 0L)
}

@Composable
fun SourceDirectoryScreen(sr: Boolean, settings: SettingsStore, context: Context,
                          foreground: Color, muted: Color, onBack: () -> Unit, onAdded: () -> Unit) {
    val cache = remember { DirectoryCache(context.applicationContext) }
    var directories by remember { mutableStateOf(SourceDirectory.featured + cache.custom()) }
    var selected by remember { mutableStateOf<FeedDirectory?>(null) }
    var entries by remember { mutableStateOf<List<DirectoryFeed>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    var search by remember { mutableStateOf("") }
    var showCustom by remember { mutableStateOf(false) }
    var customName by remember { mutableStateOf("") }
    var customURL by remember { mutableStateOf("") }
    var installedFeeds by remember { mutableStateOf<Set<String>>(settings.allSources().map { it.feed }.toSet()) }
    val regionOverrides = remember { mutableStateMapOf<String, Region>() }
    val scope = rememberCoroutineScope()

    fun refresh(directory: FeedDirectory) {
        loading = true
        error = ""
        scope.launch {
            try {
                val updated = SourceDirectory.load(directory.url)
                withContext(Dispatchers.IO) { cache.save(directory.id, updated) }
                if (selected?.id == directory.id) entries = updated
            } catch (failure: Exception) {
                error = failure.localizedMessage ?: "Catalogue unavailable"
            } finally { loading = false }
        }
    }

    Column(Modifier.fillMaxSize().padding(horizontal = 18.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { if (selected == null) onBack() else { selected = null; search = "" } }) {
                Text(if (sr) "‹ Nazad" else "‹ Back")
            }
            Spacer(Modifier.weight(1f))
            Text(if (sr) "Katalog izvora" else "Source catalogue", color = foreground)
        }
        if (selected == null) {
            Text(if (sr) "Izaberi katalog. Izvori se dodaju samo kada ih ti odabereš."
                else "Choose a catalogue. Nothing is subscribed without your tap.", color = muted)
            Spacer(Modifier.height(12.dp))
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(directories, key = { it.id }) { directory ->
                    ListItem(headlineContent = { Text(directory.title) },
                        supportingContent = { Text(directory.url, maxLines = 1) },
                        modifier = Modifier.clickable {
                            selected = directory
                            entries = cache.cached(directory.id)
                            error = ""
                            if (entries.isEmpty() || System.currentTimeMillis() - cache.updated(directory.id) > 7L * 86400_000L) refresh(directory)
                        })
                }
                item { TextButton(onClick = { showCustom = true }) {
                    Text(if (sr) "+ Dodaj katalog" else "+ Add your own catalogue")
                } }
            }
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(selected!!.title, color = foreground, modifier = Modifier.weight(1f))
                TextButton(onClick = { refresh(selected!!) }, enabled = !loading) {
                    Text(if (sr) "Ažuriraj" else "Update")
                }
            }
            if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (error.isNotBlank()) Text(error, color = Color(0xFFCB202B))
            OutlinedTextField(value = search, onValueChange = { search = it },
                label = { Text(if (sr) "Pretraži izvore" else "Search feeds") },
                singleLine = true, modifier = Modifier.fillMaxWidth())
            val filtered = remember(entries, search) { entries.filter {
                search.isBlank() || it.name.contains(search, ignoreCase = true) || it.group.contains(search, ignoreCase = true)
            } }
            Text("${filtered.size} feeds", color = muted)
            LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                items(filtered, key = { it.feedURL }) { feed ->
                    val installed = feed.feedURL in installedFeeds
                    var regionExpanded by remember(feed.feedURL) { mutableStateOf(false) }
                    Row(Modifier.fillMaxWidth().padding(vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(feed.name, color = foreground)
                            if (feed.group.isNotBlank()) Text(feed.group, color = muted)
                        }
                        if (!installed) Box {
                            TextButton(onClick = { regionExpanded = true },
                                contentPadding = PaddingValues(horizontal = 4.dp)) {
                                Text((if ((regionOverrides[feed.feedURL] ?: feed.region) == Region.SERBIA)
                                    (if (sr) "Srbija" else "Serbia") else (if (sr) "Svet" else "World")) + " ⌄",
                                    color = muted, style = MaterialTheme.typography.labelSmall)
                            }
                            DropdownMenu(expanded = regionExpanded, onDismissRequest = { regionExpanded = false }) {
                                listOf(Region.SERBIA, Region.WORLD).forEach { region ->
                                    DropdownMenuItem(text = { Text(if (region == Region.SERBIA)
                                        (if (sr) "Srbija" else "Serbia") else (if (sr) "Svet" else "World")) },
                                        onClick = { regionOverrides[feed.feedURL] = region; regionExpanded = false })
                                }
                            }
                        }
                        TextButton(enabled = !installed, onClick = {
                            settings.addSource(feed.name, feed.feedURL, regionOverrides[feed.feedURL] ?: feed.region)
                            installedFeeds = installedFeeds + feed.feedURL
                            onAdded()
                        }) { Text(if (installed) "✓" else "+") }
                    }
                    HorizontalDivider(color = muted.copy(alpha = 0.12f))
                }
            }
        }
    }

    if (showCustom) AlertDialog(onDismissRequest = { showCustom = false },
        title = { Text(if (sr) "Novi katalog" else "Add catalogue") },
        text = { Column {
            OutlinedTextField(value = customName, onValueChange = { customName = it }, label = { Text("Name") })
            OutlinedTextField(value = customURL, onValueChange = { customURL = it }, label = { Text("HTTPS · OPML / JSON / TXT") })
            if (error.isNotBlank()) Text(error, color = Color.Red)
        } },
        confirmButton = { TextButton(onClick = {
            try {
                require(customName.isNotBlank()) { "Enter a catalogue name" }
                cache.add(customName.trim(), customURL)
                directories = SourceDirectory.featured + cache.custom()
                customName = ""; customURL = ""; error = ""; showCustom = false
            } catch (failure: Exception) { error = failure.message ?: "Invalid URL" }
        }) { Text(if (sr) "Dodaj" else "Add") } },
        dismissButton = { TextButton(onClick = { showCustom = false }) { Text(if (sr) "Otkaži" else "Cancel") } })
}
