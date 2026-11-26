package com.seraphi.sito

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

@Composable
fun CloudVaultScreen(context: Context, store: LocalStore, sr: Boolean,
                     foreground: Color, muted: Color, onBack: () -> Unit) {
    val options = remember { CloudOptions(context.applicationContext) }
    val cloud = remember { CloudArchive(options) }
    val scope = rememberCoroutineScope()
    var endpoint by remember { mutableStateOf(options.endpoint) }
    var token by remember { mutableStateOf("") }
    var recoveryInput by remember { mutableStateOf("") }
    var recoveryShown by remember { mutableStateOf<String?>(null) }
    var automatic by remember { mutableStateOf(options.automatic) }
    var wifiOnly by remember { mutableStateOf(options.wifiOnly) }
    var includePDFs by remember { mutableStateOf(options.includePDFs) }
    val pdfStore = remember { PDFStore(context.applicationContext) }
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf("") }

    fun run(action: suspend (progress: (String) -> Unit) -> String) {
        busy = true
        status = if (sr) "Povezivanje…" else "Connecting…"
        scope.launch {
            try {
                options.endpoint = endpoint
                status = action { message -> status = message }
            } catch (failure: Exception) {
                status = failure.localizedMessage ?: "Cloud connection failed"
            } finally { busy = false }
        }
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        TextButton(onClick = onBack) { Text(if (sr) "‹ Nazad" else "‹ Back") }
        Text(if (sr) "Privatni cloud backup" else "Private cloud backup", color = foreground,
            style = MaterialTheme.typography.headlineMedium)
        Text(if (sr) "Tvoja Cloudflare D1 baza · šifrovanje se radi na telefonu."
            else "Your own Cloudflare D1 · encryption happens on your phone.", color = muted)
        OutlinedTextField(value = endpoint, onValueChange = { endpoint = it },
            modifier = Modifier.fillMaxWidth(), singleLine = true,
            label = { Text("HTTPS Worker URL") },
            supportingText = { Text("e.g. https://your-worker.your-name.workers.dev") })
        OutlinedTextField(value = token, onValueChange = { token = it },
            modifier = Modifier.fillMaxWidth(), singleLine = true,
            label = { Text(if (sr) "Worker token" else "Worker access token") },
            visualTransformation = PasswordVisualTransformation())
        OutlinedButton(onClick = {
            try {
                options.endpoint = endpoint
                options.saveToken(token)
                token = ""
                status = if (sr) "Token je sigurno sačuvan" else "Access token saved securely"
            } catch (failure: Exception) { status = failure.localizedMessage ?: "Invalid token" }
        }, enabled = token.isNotBlank()) {
            Text(if (sr) "Sačuvaj token" else "Save access token")
        }
        HorizontalDivider()
        Text(if (sr) "Ključ za oporavak" else "Recovery key", color = foreground)
        Text(if (sr) "Isti Base64 ključ radi za iOS i Android. Sačuvaj ga van telefona."
            else "The same Base64 key works on iPhone and Android. Keep a safe copy outside your phone.", color = muted)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = {
                try { recoveryShown = options.recoveryKey() }
                catch (failure: Exception) { status = failure.localizedMessage ?: "Key unavailable" }
            }) { Text(if (sr) "Prikaži / generiši" else "Show / generate") }
            if (recoveryShown != null) OutlinedButton(onClick = {
                val clip = ClipData.newPlainText("SITO recovery key", recoveryShown)
                (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(clip)
                status = if (sr) "Kopirano · obriši clipboard kada sačuvaš" else "Copied · clear your clipboard after saving"
            }) { Text(if (sr) "Kopiraj" else "Copy") }
        }
        if (recoveryShown != null) {
            Text(recoveryShown.orEmpty(), color = Color(0xFFCB202B))
            TextButton(onClick = { recoveryShown = null }) { Text(if (sr) "Sakrij ključ" else "Hide key") }
        }
        OutlinedTextField(value = recoveryInput, onValueChange = { recoveryInput = it },
            modifier = Modifier.fillMaxWidth(), singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            label = { Text(if (sr) "Uvezi postojeći ključ" else "Import an existing recovery key") })
        OutlinedButton(onClick = {
            try {
                options.importRecoveryKey(recoveryInput)
                recoveryInput = ""; recoveryShown = null
                status = if (sr) "Ključ uvezen" else "Recovery key imported"
            } catch (failure: Exception) { status = failure.localizedMessage ?: "Invalid key" }
        }, enabled = recoveryInput.isNotBlank()) { Text(if (sr) "Uvezi ključ" else "Import key") }
        HorizontalDivider()
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Text(if (sr) "Automatski backup" else "Automatic backup", color = foreground,
                modifier = Modifier.weight(1f))
            Switch(checked = automatic, onCheckedChange = {
                automatic = it; options.automatic = it
            })
        }
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Text(if (sr) "Samo preko Wi-Fi" else "Wi-Fi only", color = foreground,
                modifier = Modifier.weight(1f))
            Switch(checked = wifiOnly, onCheckedChange = { wifiOnly = it; options.wifiOnly = it })
        }
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Text(if (sr) "Uključi i sačuvane PDF-ove (više prostora)"
                else "Include saved PDFs (more storage)", color = foreground,
                modifier = Modifier.weight(1f))
            Switch(checked = includePDFs, onCheckedChange = { includePDFs = it; options.includePDFs = it })
        }
        if (options.lastBackup > 0) Text(
            (if (sr) "Poslednji backup " else "Last backup ") +
                java.text.DateFormat.getDateTimeInstance().format(java.util.Date(options.lastBackup)), color = muted)
        if (options.lastVerified > 0) Text(
            (if (sr) "Cloud proveren " else "Cloud verified ") +
                java.text.DateFormat.getDateTimeInstance().format(java.util.Date(options.lastVerified)), color = muted)
        if (options.uploadedDigest.isNotEmpty() && options.uploadedDigest == options.verifiedDigest) {
            Text(if (sr) "Poslednji backup je potpuno proveren" else "Latest backup fully verified",
                color = Color(0xFFCB202B))
        }
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        Button(enabled = !busy, onClick = { run { progress ->
            val saved = cloud.backup(store, progress, pdfStore)
            "Backup saved · ${saved.records} records · ${saved.complete} full texts · ${saved.pdfs} PDFs"
        } }) { Text(if (sr) "Napravi backup" else "Back Up Now") }
        OutlinedButton(enabled = !busy, onClick = { run { progress ->
            val verified = cloud.verify(progress)
            "Cloud verified · ${verified.records} records · ${verified.complete} full texts · ${verified.pdfs} PDFs"
        } }) { Text(if (sr) "Proveri cloud arhivu" else "Verify Cloud Archive") }
        OutlinedButton(enabled = !busy, onClick = { run { progress ->
            val restored = cloud.restore(store, progress = progress, pdfStore = pdfStore)
            "Restored $restored new articles · bookmarks merged"
        } }) { Text(if (sr) "Vrati iz clouda" else "Restore from Cloud") }
        TextButton(enabled = !busy, onClick = { run { progress ->
            val restored = cloud.restore(store, previous = true, progress = progress, pdfStore = pdfStore)
            "Restored $restored new articles from previous backup"
        } }) { Text(if (sr) "Vrati prethodni cloud backup" else "Restore previous cloud backup") }
        if (status.isNotBlank()) Text(status, color = Color(0xFFCB202B))
        Text(if (sr) "Nikada ne šalji token ili ključ za oporavak u issue ili javni log."
            else "Never post your token or recovery key in an issue or public log.", color = muted)
    }
}
