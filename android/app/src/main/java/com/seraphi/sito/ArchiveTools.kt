package com.seraphi.sito

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

object ArchiveTools {
    suspend fun complete(store: LocalStore, limit: Int, progress: (Int, Int) -> Unit): Pair<Int, Int> = coroutineScope {
        val staleBefore = System.currentTimeMillis() - TimeUnit.DAYS.toMillis(30)
        val candidates = withContext(Dispatchers.IO) { store.incomplete(limit, staleBefore) }
        var captured = 0
        var attempted = 0
        for (batch in candidates.chunked(4)) {
            val results = batch.map { item -> async(Dispatchers.IO) {
                item.id to FullTextExtractor.fetch(item)
            } }.awaitAll()
            withContext(Dispatchers.IO) {
                results.forEach { (id, result) ->
                    store.recordCapture(id, result)
                    if (result.text != null) captured++
                    attempted++
                }
            }
            progress(attempted, candidates.size)
        }
        captured to candidates.size
    }

    // Plain JSON is intentionally opt-in. It never includes cached images or
    // credentials. Cloud / encrypted portable backups are a separate feature.
    fun exportJSON(store: LocalStore): ByteArray {
        val articles = JSONArray()
        for (item in store.allArticles()) {
            articles.put(JSONObject().apply {
                put("id", item.id); put("sourceID", item.sourceID); put("sourceName", item.sourceName)
                put("section", item.region.name.lowercase()); put("title", item.title)
                put("summary", item.summary); put("url", item.url); put("publishedMillis", item.published)
                put("imageURL", item.image ?: JSONObject.NULL)
                put("feedCategories", JSONArray(item.categories))
                put("byline", item.author ?: JSONObject.NULL)
                put("fullText", item.fullText ?: JSONObject.NULL)
                put("textOrigin", item.textOrigin ?: JSONObject.NULL)
                put("textCheckedAtMillis", item.textCheckedAt ?: JSONObject.NULL)
                put("previewText", item.previewText ?: JSONObject.NULL)
                put("sourceStatus", item.sourceStatus ?: JSONObject.NULL)
                put("canonicalURL", item.canonicalURL ?: JSONObject.NULL)
                put("languageCode", item.languageCode ?: JSONObject.NULL)
                put("modifiedAtMillis", item.modifiedAt ?: JSONObject.NULL)
                put("textCapturedAtMillis", item.textCapturedAt ?: JSONObject.NULL)
                put("bookmark", item.bookmark)
            })
        }
        return JSONObject().put("format", "sito-json-v1").put("exportedAtMillis", System.currentTimeMillis())
            .put("articles", articles).toString(2).toByteArray(Charsets.UTF_8)
    }

    fun importJSON(store: LocalStore, data: ByteArray): Int {
        require(data.size <= 100_000_000) { "Archive exceeds the 100 MB import limit" }
        val root = JSONObject(String(data, Charsets.UTF_8))
        require(root.optString("format") == "sito-json-v1") { "Unsupported archive format" }
        val array = root.getJSONArray("articles")
        require(array.length() <= 50_000) { "Too many articles" }
        val entries = (0 until array.length()).map { i ->
            val item = array.getJSONObject(i)
            val id = item.getString("id")
            val link = item.getString("url")
            require(id.isNotBlank() && link.startsWith("https://")) { "Invalid article at row ${i + 1}" }
            val categories = item.optJSONArray("feedCategories") ?: JSONArray()
            Article(id = id, sourceID = item.getString("sourceID"),
                sourceName = item.getString("sourceName"),
                region = if (item.optString("section") == "world") Region.WORLD else Region.SERBIA,
                title = item.getString("title"), summary = item.optString("summary"), url = link,
                image = item.optString("imageURL").takeIf { it.startsWith("https://") },
                published = item.getLong("publishedMillis"),
                categories = (0 until categories.length()).map { categories.optString(it) },
                author = item.optString("byline").ifBlank { null },
                fullText = item.optString("fullText").ifBlank { null },
                bookmark = item.optBoolean("bookmark"),
                textCheckedAt = item.optLong("textCheckedAtMillis", 0).takeIf { it > 0 },
                textOrigin = item.optString("textOrigin").ifBlank { null },
                previewText = item.optString("previewText").takeIf { it.isNotBlank() && it != "null" },
                sourceStatus = item.optString("sourceStatus").takeIf { it.isNotBlank() && it != "null" },
                canonicalURL = item.optString("canonicalURL").takeIf { it.isNotBlank() && it != "null" },
                languageCode = item.optString("languageCode").takeIf { it.isNotBlank() && it != "null" },
                modifiedAt = item.optLong("modifiedAtMillis", 0).takeIf { it > 0 },
                textCapturedAt = item.optLong("textCapturedAtMillis", 0).takeIf { it > 0 })
        }
        val before = store.count()
        store.merge(entries)
        return store.count() - before
    }
}

@Composable
fun ArchiveToolsScreen(context: Context, store: LocalStore, sr: Boolean, foreground: Color,
                       muted: Color, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var revision by remember { mutableIntStateOf(0) }
    val articles = remember(revision) { store.count() }
    val complete = remember(revision) { store.completeCount() }
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf("") }
    var days by remember { mutableIntStateOf(365) }
    var confirmDelete by remember { mutableStateOf(false) }
    val pdfs = remember { PDFStore(context.applicationContext) }
    val cloud = remember { CloudOptions(context.applicationContext) }
    val encryptedExport = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            try {
                val key = android.util.Base64.decode(requireNotNull(cloud.secrets.read("recovery-key")), android.util.Base64.DEFAULT)
                withContext(Dispatchers.IO) {
                    requireNotNull(context.contentResolver.openOutputStream(uri)).use { stream ->
                        PortableVault.export(store, pdfs, stream, key, withPDFs = true) { status = it }
                    }
                }
                status = if (sr) "Šifrovani backup sačuvan" else "Encrypted backup saved"
            } catch (failure: Exception) { status = failure.localizedMessage ?: "Export failed" }
            finally { busy = false }
        }
    }
    val encryptedImport = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            try {
                val key = android.util.Base64.decode(requireNotNull(cloud.secrets.read("recovery-key")), android.util.Base64.DEFAULT)
                val count = withContext(Dispatchers.IO) {
                    requireNotNull(context.contentResolver.openInputStream(uri)).use { stream ->
                        PortableVault.import(store, pdfs, stream, key) { status = it }
                    }
                }
                revision++
                status = if (sr) "Vraćeno $count novih vesti" else "Restored $count new articles"
            } catch (failure: Exception) { status = failure.localizedMessage ?: "Import failed" }
            finally { busy = false }
        }
    }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    val bytes = ArchiveTools.exportJSON(store)
                    requireNotNull(context.contentResolver.openOutputStream(uri)) { "Cannot write this location" }
                        .use { it.write(bytes) }
                }
                status = if (sr) "Arhiva je sačuvana" else "Archive saved"
            } catch (failure: Exception) { status = failure.localizedMessage ?: "Export failed" }
            finally { busy = false }
        }
    }
    val open = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            try {
                val added = withContext(Dispatchers.IO) {
                    val bytes = requireNotNull(context.contentResolver.openInputStream(uri)) { "Cannot read file" }
                        .use { it.readAtMost(100_000_001) }
                    ArchiveTools.importJSON(store, bytes)
                }
                revision++
                status = if (sr) "Dodato $added vesti · ostale su sačuvane" else "Restored $added new articles · nothing deleted"
            } catch (failure: Exception) { status = failure.localizedMessage ?: "Restore failed" }
            finally { busy = false }
        }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        TextButton(onClick = onBack) { Text(if (sr) "‹ Nazad" else "‹ Back") }
        Text(if (sr) "Arhiva i lokalni backup" else "Archive & local backup", color = foreground,
            style = MaterialTheme.typography.headlineMedium)
        Text(if (sr) "$articles vesti · $complete kompletnih tekstova" else "$articles articles · $complete complete texts", color = muted)
        Text(if (sr) "PDF datoteke: ${pdfs.totalBytes() / 1024} KB"
            else "Saved PDFs: ${pdfs.totalBytes() / 1024} KB", color = muted)
        Text(if (sr) "Čuvaju se naslov, originalni link, datum, izvor, kategorija i dostupan tekst bez slika."
            else "Titles, source URLs, dates, categories and available article text are stored without images.", color = muted)
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        Button(enabled = !busy, onClick = {
            busy = true
            scope.launch {
                try {
                    val (captured, attempted) = ArchiveTools.complete(store, 40) { completed, total ->
                        status = "Reading original pages · $completed / $total"
                    }
                    revision++
                    status = if (sr) "Dopunjeno $captured od $attempted pokušaja"
                        else "Completed $captured of $attempted attempts"
                } catch (failure: Exception) { status = failure.localizedMessage ?: "Capture failed" }
                finally { busy = false }
            }
        }) { Text(if (sr) "Dopuni sledećih 40 vesti" else "Complete the next 40 articles") }
        HorizontalDivider()
        Text(if (sr) "Lokalni backup" else "Local backup", color = foreground)
        OutlinedButton(enabled = !busy, onClick = {
            if (cloud.secrets.read("recovery-key") == null)
                status = if (sr) "Prvo sačuvaj ključ za oporavak u Cloud podešavanjima"
                    else "First generate and safely store your recovery key in Cloud settings"
            else encryptedExport.launch("SITO-private.sitobackup")
        }) { Text(if (sr) "Sačuvaj šifrovani .sitobackup" else "Export encrypted .sitobackup") }
        OutlinedButton(enabled = !busy, onClick = {
            if (cloud.secrets.read("recovery-key") == null)
                status = if (sr) "Uvezi ključ za oporavak u Cloud podešavanjima"
                    else "Import your recovery key in Cloud settings first"
            else encryptedImport.launch(arrayOf("application/octet-stream", "application/x-binary", "*/*"))
        }) { Text(if (sr) "Uvezi šifrovani .sitobackup" else "Import encrypted .sitobackup") }
        Text(if (sr) "Kompatibilno sa iOS .sitobackup formatom, uključujući PDF-ove."
            else "Compatible with iOS .sitobackup files, including PDFs.", color = muted)
        OutlinedButton(enabled = !busy, onClick = { save.launch("SITO-archive.json") }) {
            Text(if (sr) "Sačuvaj JSON arhivu" else "Export archive JSON")
        }
        OutlinedButton(enabled = !busy, onClick = { open.launch(arrayOf("application/json", "text/plain")) }) {
            Text(if (sr) "Uvezi JSON arhivu" else "Import archive JSON")
        }
        Text(if (sr) "JSON nije šifrovan. Sačuvaj ga na privatnom mestu."
            else "JSON is unencrypted. Store it in a private location.", color = muted)
        HorizontalDivider()
        Text(if (sr) "Oslobodi prostor" else "Free up space", color = foreground)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(30, 90, 365).forEach { option ->
                FilterChip(selected = days == option, onClick = { days = option }, label = { Text("$option d") })
            }
        }
        OutlinedButton(enabled = !busy, onClick = { confirmDelete = true }) {
            Text(if (sr) "Obriši starije od $days dana" else "Delete history older than $days days")
        }
        Text(if (sr) "Sačuvani članci (bookmarks) neće biti obrisani."
            else "Bookmarked articles are protected.", color = muted)
        if (status.isNotBlank()) Text(status, color = Color(0xFFCB202B))
    }
    if (confirmDelete) AlertDialog(onDismissRequest = { confirmDelete = false },
        title = { Text(if (sr) "Obrisati stare vesti?" else "Delete old articles?") },
        text = { Text(if (sr) "Ova radnja briše lokalnu istoriju stariju od $days dana, osim sačuvanih vesti."
            else "This removes local stories older than $days days, except bookmarks.") },
        confirmButton = { TextButton(onClick = {
            val threshold = System.currentTimeMillis() - TimeUnit.DAYS.toMillis(days.toLong())
            val removed = store.cleanup(threshold)
            val pdfsRemoved = pdfs.deleteUnreferenced(store.articleIDs())
            revision++
            status = if (sr) "Obrisano $removed vesti i $pdfsRemoved PDF-ova"
                else "Removed $removed stories and $pdfsRemoved PDFs"
            confirmDelete = false
        }) { Text(if (sr) "Obriši" else "Delete") } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(if (sr) "Otkaži" else "Cancel") } })
}
