package com.seraphi.sito

import android.os.Bundle
import android.os.PowerManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.gestures.ScrollableDefaults
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import coil.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

private val signature = Color(0xFFCB202B)
private val ink = Color(0xFF222222)
private val parchment = Color(0xFFF6F4EF)
private val night = Color(0xFF121215)
private val slate = Color(0xFF9E9BA0)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { SitoRoot() }
    }
}

private enum class Screen { FEED, ARCHIVE, SETTINGS, READER }

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SitoRoot() {
    val context = LocalContext.current
    val settings = remember { SettingsStore(context.applicationContext) }
    val archive = remember { LocalStore(context.applicationContext) }
    var language by remember { mutableStateOf(settings.language) }
    var theme by remember { mutableStateOf(settings.theme) }
    var compact by remember { mutableStateOf(settings.compact) }
    var paged by remember { mutableStateOf(settings.paged) }
    var advanced by remember { mutableStateOf(settings.advanced) }
    val sr = language == "sr"
    val isDark = when (theme) {
        "dark" -> true
        "light" -> false
        else -> androidx.compose.foundation.isSystemInDarkTheme()
    }
    val background = if (isDark) night else parchment
    val foreground = if (isDark) Color(0xFFEDE9E2) else ink
    val muted = if (isDark) Color(0xFFA9A5AC) else Color(0xFF77747A)
    var screen by remember { mutableStateOf(Screen.FEED) }
    var region by remember { mutableStateOf(Region.SERBIA) }
    var topic by remember { mutableStateOf(Topic.ALL) }
    var sourceFilter by remember { mutableStateOf<String?>(null) }
    var reader by remember { mutableStateOf<Article?>(null) }
    val feed = remember { mutableStateListOf<Article>() }
    var currentSources by remember { mutableStateOf(settings.allSources()) }
    var loading by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf("") }
    var updatedAt by remember { mutableLongStateOf(0L) }
    var refreshNonce by remember { mutableIntStateOf(0) }
    var savedNonce by remember { mutableIntStateOf(0) }
    var topicsNonce by remember { mutableIntStateOf(0) }
    val visibleTopics = remember(topicsNonce) { settings.visibleTopics() }
    var sourcesDirty by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val cloudOptions = remember { CloudOptions(context.applicationContext) }
    fun connectedWifi(): Boolean {
        val network = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        return network.getNetworkCapabilities(network.activeNetwork)
            ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }
    fun home() {
        screen = Screen.FEED
        reader = null
        if (sourcesDirty) { currentSources = settings.allSources(); sourcesDirty = false; refreshNonce++ }
    }

    LaunchedEffect(refreshNonce) {
        loading = true
        failure = ""
        try {
            val selected = currentSources.filter { settings.enabled(it.id, it.defaultOn) }
            val report = NewsEngine.fetchAll(selected)
            val results = report.items
            withContext(Dispatchers.IO) { archive.merge(results) }
            feed.clear()
            feed.addAll(NewsEngine.mixed(results))
            updatedAt = System.currentTimeMillis()
            if (results.isEmpty()) failure = if (sr) "Izvori trenutno nisu dostupni" else "Sources temporarily unavailable"
            if (results.isNotEmpty()) {
                val now = System.currentTimeMillis()
                val wifi = connectedWifi()
                val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                if (!power.isPowerSaveMode) {
                    if (settings.autoComplete && (!settings.autoCompleteWifiOnly || wifi) &&
                        now - settings.lastAutoComplete >= 45L * 60_000L) {
                        settings.lastAutoComplete = now
                        scope.launch {
                            runCatching { ArchiveTools.complete(archive, 4) { _, _ -> } }
                        }
                    }
                    if (cloudOptions.automatic && (!cloudOptions.wifiOnly || wifi) &&
                        now - cloudOptions.lastBackup >= 24L * 3_600_000L) {
                        scope.launch {
                            runCatching { CloudArchive(cloudOptions).backup(archive) { } }
                        }
                    }
                }
            }
        } catch (error: Exception) {
            failure = error.localizedMessage ?: "Network error"
        } finally {
            loading = false
        }
    }

    BackHandler(screen != Screen.FEED) { home() }

    MaterialTheme(
        colorScheme = if (isDark) darkColorScheme(primary = signature, background = background, surface = night)
            else lightColorScheme(primary = signature, background = background, surface = parchment),
    ) {
        Column(Modifier.fillMaxSize().background(background)) {
            if (screen == Screen.READER && reader != null) {
                Header(label = reader!!.sourceName, isDark = isDark, onHome = { home() },
                    onArchive = {}, onSettings = {}, showControls = false)
                ArticleBrowser(reader!!, Modifier.weight(1f))
            } else if (screen == Screen.SETTINGS) {
                Header(label = if (sr) "Podešavanja" else "Settings", isDark = isDark,
                    onHome = { home() }, onArchive = {}, onSettings = {}, showControls = false)
                SettingsScreen(
                    sr = sr, foreground = foreground, muted = muted, currentSources = currentSources,
                    settings = settings, archive = archive, language = language, theme = theme, compact = compact,
                    paged = paged, advanced = advanced,
                    onLanguage = { language = it; settings.language = it },
                    onTheme = { theme = it; settings.theme = it },
                    onCompact = { compact = it; settings.compact = it },
                    onPaged = { paged = it; settings.paged = it },
                    onAdvanced = { advanced = it; settings.advanced = it },
                    onSourcesChanged = { currentSources = settings.allSources(); sourcesDirty = true },
                    onTopicsChanged = { topicsNonce++; if (topic !in settings.visibleTopics()) topic = Topic.ALL },
                )
            } else if (screen == Screen.ARCHIVE) {
                Header(label = if (sr) "Arhiva" else "Archive", isDark = isDark,
                    onHome = { home() }, onArchive = {}, onSettings = {}, showControls = false)
                key(savedNonce) {
                    ArchiveScreen(archive, sr, foreground, muted,
                        onOpen = { reader = it; screen = Screen.READER },
                        onToggle = { article ->
                            archive.bookmark(article.id, !article.bookmark)
                            savedNonce++
                        })
                }
            } else {
                Header(label = "SITO", isDark = isDark,
                    onHome = { refreshNonce++ },
                    onArchive = { savedNonce++; screen = Screen.ARCHIVE },
                    onSettings = { screen = Screen.SETTINGS }, showControls = true)

                Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    listOf(Region.SERBIA, Region.WORLD).forEach { choice ->
                        val text = if (choice == Region.SERBIA) (if (sr) "Srbija" else "Serbia") else (if (sr) "Svet" else "World")
                        FilterChip(selected = region == choice, onClick = { region = choice; topic = Topic.ALL; sourceFilter = null },
                            label = { Text(text) })
                    }
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = { refreshNonce++ }) { Text(if (loading) "…" else "↻", fontSize = 24.sp) }
                }

                val active = currentSources.filter { it.region == region && settings.enabled(it.id, it.defaultOn) }
                val available = feed.filter { it.region == region }
                val filtered = available.filter { sourceFilter == null || it.sourceID == sourceFilter }
                    .filter { topic == Topic.ALL || TopicRules.classify(it) == topic }

                if (sourceFilter == null) {
                    ScrollableTabRow(selectedTabIndex = visibleTopics.indexOf(topic).coerceAtLeast(0), edgePadding = 14.dp,
                        containerColor = Color.Transparent, divider = {}, indicator = {}) {
                        visibleTopics.forEach { item ->
                            Tab(selected = item == topic, onClick = { topic = item },
                                text = { Text(item.label(sr), color = if (item == topic) signature else muted, fontSize = 12.sp) })
                        }
                    }
                }
                var showSources by remember { mutableStateOf(false) }
                Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 7.dp),
                    horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Text(if (sourceFilter == null) (if (sr) "Svi izvori" else "All sources")
                        else active.find { it.id == sourceFilter }?.name.orEmpty(),
                        color = muted, fontSize = 13.sp, modifier = Modifier.clickable { showSources = true })
                    if (updatedAt > 0) Text(DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(updatedAt)),
                        color = muted, fontSize = 11.sp)
                }
                if (showSources) AlertDialog(onDismissRequest = { showSources = false },
                    title = { Text(if (sr) "Izvor" else "Publisher") },
                    text = { Column {
                        TextButton(onClick = { sourceFilter = null; topic = Topic.ALL; showSources = false }) {
                            Text(if (sr) "Svi izvori" else "All sources")
                        }
                        active.forEach { source -> TextButton(onClick = { sourceFilter = source.id; topic = Topic.ALL; showSources = false }) {
                            Text(source.name)
                        } }
                    } }, confirmButton = {})

                if (loading && feed.isEmpty()) Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = signature)
                }
                if (failure.isNotBlank()) Text(failure, color = muted, modifier = Modifier.padding(20.dp))
                if (!loading && filtered.isEmpty() && failure.isBlank()) Text(
                    if (sr) "Nema vesti za ovaj izbor" else "No stories for this selection",
                    modifier = Modifier.padding(20.dp), color = muted)

                val listState = rememberLazyListState()
                val pointer = Modifier.pointerInput(topic, region, sourceFilter) {
                    var dragged = 0f
                    detectHorizontalDragGestures(onHorizontalDrag = { _, delta -> dragged += delta },
                        onDragEnd = {
                            if (sourceFilter == null && kotlin.math.abs(dragged) > 85f) {
                                val next = visibleTopics.indexOf(topic) + if (dragged < 0) 1 else -1
                                if (next in visibleTopics.indices) topic = visibleTopics[next]
                            }
                            dragged = 0f
                        })
                }
                BoxWithConstraints(Modifier.fillMaxSize()) {
                    val pageHeight = maxHeight
                    val snap = rememberSnapFlingBehavior(listState)
                    LazyColumn(modifier = Modifier.fillMaxSize().then(pointer), state = listState,
                        flingBehavior = if (paged) snap else ScrollableDefaults.flingBehavior(),
                        contentPadding = if (paged) PaddingValues(0.dp)
                            else PaddingValues(horizontal = 18.dp, vertical = 12.dp),
                        verticalArrangement = Arrangement.spacedBy(if (paged) 0.dp else if (compact) 9.dp else 16.dp)) {
                        items(filtered, key = { it.id }) { item ->
                            Box(Modifier.fillMaxWidth()
                                .then(if (paged) Modifier.height(pageHeight).padding(horizontal = 18.dp, vertical = 9.dp).clipToBounds()
                                    else Modifier)) {
                                StoryCardAndroid(item, compact && !paged, isDark, foreground, muted,
                                    fullHeight = paged,
                                    onOpen = { reader = item; screen = Screen.READER },
                                    onBookmark = { archive.bookmark(item.id, true); savedNonce++ })
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Header(label: String, isDark: Boolean, onHome: () -> Unit,
                   onArchive: () -> Unit, onSettings: () -> Unit, showControls: Boolean) {
    Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 14.dp, top = 14.dp, bottom = 9.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(17.dp).background(signature).clickable { onHome() })
        Spacer(Modifier.width(10.dp))
        Text(label, fontSize = 24.sp, letterSpacing = 2.sp, fontWeight = FontWeight.Light,
            color = if (isDark) Color.White else ink, modifier = Modifier.clickable { onHome() })
        Spacer(Modifier.weight(1f))
        if (showControls) {
            TextButton(onClick = onArchive) { Text("▤", color = signature, fontSize = 24.sp) }
            TextButton(onClick = onSettings) { Text("⋮", color = signature, fontSize = 27.sp) }
        } else TextButton(onClick = onHome) { Text("×", color = signature, fontSize = 26.sp) }
    }
}

@Composable
private fun StoryCardAndroid(article: Article, compact: Boolean, dark: Boolean, foreground: Color,
                             muted: Color, fullHeight: Boolean = false,
                             onOpen: () -> Unit, onBookmark: () -> Unit) {
    val fill = if (dark) Color(0xFF202024) else Color.White
    Column(Modifier.fillMaxWidth().then(if (fullHeight) Modifier.fillMaxHeight() else Modifier)
        .background(fill, RoundedCornerShape(22.dp))
        .clickable { onOpen() }.padding(if (compact) 17.dp else 22.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(article.sourceName.uppercase(), color = signature, fontSize = 11.sp,
                letterSpacing = 1.4.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.weight(1f))
            Text(DateFormat.getDateInstance(DateFormat.SHORT).format(Date(article.published)),
                color = muted, fontSize = 11.sp)
        }
        Spacer(Modifier.height(14.dp))
        if (article.image != null && !compact) {
            AsyncImage(model = article.image, contentDescription = null,
                contentScale = ContentScale.Crop, modifier = Modifier.fillMaxWidth()
                    .height(190.dp).background(if (dark) Color.DarkGray else Color.LightGray,
                        RoundedCornerShape(12.dp)))
            Spacer(Modifier.height(15.dp))
        }
        Text(article.title, color = foreground, fontFamily = FontFamily.Serif,
            fontSize = if (compact) 20.sp else 26.sp, lineHeight = if (compact) 26.sp else 34.sp,
            fontWeight = FontWeight.Normal)
        if (!compact && article.summary.isNotBlank()) {
            Spacer(Modifier.height(13.dp))
            Text(article.summary, color = muted, fontFamily = FontFamily.Serif,
                fontSize = 17.sp, lineHeight = 26.sp, maxLines = 6, overflow = TextOverflow.Ellipsis)
        }
        if (fullHeight) Spacer(Modifier.weight(1f))
        Spacer(Modifier.height(13.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(article.sourceName, color = muted, fontSize = 12.sp)
            Spacer(Modifier.weight(1f))
            Text("＋", color = signature, fontSize = 22.sp, modifier = Modifier.clickable { onBookmark() })
        }
    }
}

@Composable
private fun ArticleBrowser(article: Article, modifier: Modifier = Modifier) {
    AndroidView(modifier = modifier.fillMaxWidth(), factory = { context ->
        WebView(context).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.textZoom = 110
            webViewClient = WebViewClient()
            loadUrl(article.url)
        }
    }, update = { view -> if (view.url != article.url) view.loadUrl(article.url) })
}

@Composable
private fun ArchiveScreen(store: LocalStore, sr: Boolean, foreground: Color, muted: Color,
                          onOpen: (Article) -> Unit, onToggle: (Article) -> Unit) {
    var query by remember { mutableStateOf("") }
    var bookmarksOnly by remember { mutableStateOf(false) }
    val stories = remember(query, bookmarksOnly) { store.archive(query, bookmarksOnly) }
    Column(Modifier.fillMaxSize()) {
        OutlinedTextField(value = query, onValueChange = { query = it },
            label = { Text(if (sr) "Pretraži arhivu" else "Search history") },
            singleLine = true, modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp))
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 18.dp)) {
            Checkbox(checked = bookmarksOnly, onCheckedChange = { bookmarksOnly = it })
            Text(if (sr) "Sačuvane vesti" else "Bookmarked stories", color = foreground)
            Spacer(Modifier.weight(1f))
            Text("${stories.size}", color = muted)
        }
        LazyColumn(contentPadding = PaddingValues(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            items(stories, key = { it.id }) { story ->
                Row(Modifier.fillMaxWidth().clickable { onOpen(story) }.padding(vertical = 7.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text(story.sourceName, color = signature, fontSize = 12.sp)
                        Text(story.title, color = foreground, fontFamily = FontFamily.Serif, fontSize = 20.sp)
                    }
                    Text(if (story.bookmark) "★" else "☆", color = signature, fontSize = 24.sp,
                        modifier = Modifier.clickable { onToggle(story) }.padding(8.dp))
                }
                HorizontalDivider(color = muted.copy(alpha = 0.18f))
            }
        }
    }
}
