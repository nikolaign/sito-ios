package com.seraphi.sito

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlin.random.Random

@Composable
internal fun SettingsScreen(
    sr: Boolean, foreground: Color, muted: Color,
    currentSources: List<Source>, settings: SettingsStore, archive: LocalStore,
    language: String, theme: String, compact: Boolean, paged: Boolean, advanced: Boolean,
    onLanguage: (String) -> Unit, onTheme: (String) -> Unit,
    onCompact: (Boolean) -> Unit, onPaged: (Boolean) -> Unit, onAdvanced: (Boolean) -> Unit,
    onSourcesChanged: () -> Unit,
    onTopicsChanged: () -> Unit,
    unavailableSources: Set<String>, updatedAt: Long,
    onRetrySources: () -> Unit,
) {
    var showSources by remember { mutableStateOf(false) }
    var showAdd by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    var newURL by remember { mutableStateOf("") }
    var newRegion by remember { mutableStateOf(Region.WORLD) }
    var error by remember { mutableStateOf("") }
    var showTopics by remember { mutableStateOf(false) }
    var showStatus by remember { mutableStateOf(false) }
    var showCatalogue by remember { mutableStateOf(false) }
    var showArchiveTools by remember { mutableStateOf(false) }
    var showCloud by remember { mutableStateOf(false) }
    val context = LocalContext.current

    if (showCloud) {
        CloudVaultScreen(context, archive, sr, foreground, muted, onBack = { showCloud = false })
        return
    }
    if (showArchiveTools) {
        ArchiveToolsScreen(context, archive, sr, foreground, muted,
            onBack = { showArchiveTools = false })
        return
    }
    if (showCatalogue) {
        SourceDirectoryScreen(sr, settings, context, foreground, muted,
            onBack = { showCatalogue = false }, onAdded = onSourcesChanged)
        return
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(19.dp)) {
        Heading(if (sr) "Čitanje" else "Reading", muted)
        SettingRow(if (sr) "Jezik" else "Language", foreground) {
            TextButton(onClick = { onLanguage(if (language == "sr") "en" else "sr") }) {
                Text(if (language == "sr") "Srpski" else "English")
            }
        }
        SettingRow(if (sr) "Tema" else "Theme", foreground) {
            var expanded by remember { mutableStateOf(false) }
            Box {
                TextButton(onClick = { expanded = true }) {
                    Text(when (theme) { "dark" -> "Dark"; "light" -> "Light"; else -> "System" })
                }
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    listOf("system", "light", "dark").forEach { option ->
                        DropdownMenuItem(text = { Text(option.replaceFirstChar { it.uppercase() }) },
                            onClick = { onTheme(option); expanded = false })
                    }
                }
            }
        }
        SettingRow(if (sr) "Kompaktan prikaz" else "Compact view", foreground) {
            Switch(checked = compact, onCheckedChange = onCompact)
        }
        SettingRow(if (sr) "Jedna vest po ekranu" else "Page by page", foreground) {
            Switch(checked = paged, onCheckedChange = onPaged)
        }
        TextButton(onClick = { showTopics = !showTopics }) {
            Text(if (sr) "Teme koje se prikazuju" else "Visible topics")
        }
        if (showTopics) Topic.entries.filter { it != Topic.ALL }.forEach { topic ->
            var checked by remember(topic) { mutableStateOf(topic in settings.visibleTopics()) }
            SettingRow(topic.label(sr), foreground) {
                Checkbox(checked = checked, onCheckedChange = { selected ->
                    checked = selected
                    settings.setTopicVisible(topic, selected)
                    onTopicsChanged()
                })
            }
        }
        HorizontalDivider(color = muted.copy(alpha = 0.2f))
        Heading(if (sr) "Izvori" else "Sources", muted)
        TextButton(onClick = { showSources = !showSources }) {
            Text(if (sr) "Izaberi izvore" else "Choose publishers")
        }
        if (showSources) currentSources.groupBy { it.region }.forEach { (region, sources) ->
            Text(if (region == Region.SERBIA) (if (sr) "Srbija" else "Serbia")
                else (if (sr) "Svet" else "World"), color = muted)
            sources.forEach { source ->
                var checked by remember(source.id) { mutableStateOf(settings.enabled(source.id, source.defaultOn)) }
                SettingRow(source.name, foreground) {
                    Checkbox(checked = checked, onCheckedChange = { value ->
                        checked = value
                        settings.setEnabled(source.id, value)
                        onSourcesChanged()
                    })
                }
            }
        }
        TextButton(onClick = { showAdd = true }) {
            Text(if (sr) "+ Dodaj RSS izvor" else "+ Add RSS source")
        }
        HorizontalDivider(color = muted.copy(alpha = 0.2f))
        Heading(if (sr) "Napredna podešavanja" else "Advanced options", muted)
        SettingRow(if (sr) "Prikaži napredne opcije" else "Show advanced options", foreground) {
            Switch(checked = advanced, onCheckedChange = onAdvanced)
        }
        if (advanced) {
            TextButton(onClick = { showStatus = !showStatus }) {
                Text(if (sr) "Status izvora" else "Source status")
            }
            if (showStatus) {
                val enabledCount = currentSources.count { settings.enabled(it.id, it.defaultOn) }
                val availableCount = (enabledCount - unavailableSources.size).coerceAtLeast(0)
                Text(if (updatedAt == 0L) (if (sr) "Izvori još nisu provereni" else "Sources not checked yet")
                    else (if (sr) "Dostupno: $availableCount od $enabledCount"
                        else "Available: $availableCount of $enabledCount"), color = muted)
                if (unavailableSources.isNotEmpty()) Text(unavailableSources.sorted().joinToString(" · "),
                    color = Color(0xFFCB202B), fontSize = 12.sp)
                TextButton(onClick = onRetrySources) {
                    Text(if (sr) "Ponovo proveri izvore" else "Retry sources")
                }
            }
            TextButton(onClick = { showCatalogue = true }) {
                Text(if (sr) "Istraži kataloge RSS izvora" else "Explore RSS source catalogues")
            }
            TextButton(onClick = { showArchiveTools = true }) {
                Text(if (sr) "Arhiva, dopuna teksta i backup" else "Archive, complete texts & backup")
            }
            TextButton(onClick = { showCloud = true }) {
                Text(if (sr) "Privatni Cloudflare backup" else "Private Cloudflare backup")
            }
        }
        HorizontalDivider(color = muted.copy(alpha = 0.2f))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (sr) "Razvio " else "Developed by ", color = muted, fontSize = 13.sp)
            var fracture by remember { mutableStateOf(false) }
            LaunchedEffect(Unit) {
                while (true) {
                    delay(Random.nextLong(5800, 17000))
                    fracture = true
                    delay(Random.nextLong(35, 75))
                    fracture = false
                }
            }
            Box(Modifier.clickable {
                runCatching { context.startActivity(Intent(Intent.ACTION_SENDTO,
                    Uri.parse("mailto:seraphiheaven@gmail.com"))) }
            }) {
                Text("seraphi", color = if (fracture) Color(0xFFBB1D2D) else foreground,
                    fontSize = 13.sp, letterSpacing = if (fracture) .4.sp else 0.sp,
                    modifier = Modifier.offset(x = if (fracture) 1.dp else 0.dp))
            }
        }
    }

    if (showAdd) {
        AlertDialog(onDismissRequest = { showAdd = false },
            title = { Text(if (sr) "Novi RSS izvor" else "New RSS source") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(value = newName, onValueChange = { newName = it },
                        label = { Text(if (sr) "Naziv" else "Name") }, singleLine = true)
                    OutlinedTextField(value = newURL, onValueChange = { newURL = it },
                        label = { Text("HTTPS RSS / Atom / JSON Feed") }, singleLine = true)
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        FilterChip(selected = newRegion == Region.SERBIA, onClick = { newRegion = Region.SERBIA },
                            label = { Text(if (sr) "Srbija" else "Serbia") })
                        FilterChip(selected = newRegion == Region.WORLD, onClick = { newRegion = Region.WORLD },
                            label = { Text(if (sr) "Svet" else "World") })
                    }
                    if (error.isNotBlank()) Text(error, color = Color.Red, fontSize = 12.sp)
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val secure = SourceDirectory.secureURL(newURL)
                    if (newName.isBlank() || secure == null) {
                        error = if (sr) "Unesi naziv i ispravnu HTTPS adresu izvora"
                            else "Enter a name and valid HTTPS feed URL"
                    } else {
                        settings.addSource(newName.trim(), secure, newRegion)
                        newName = ""; newURL = ""; error = ""
                        showAdd = false
                        onSourcesChanged()
                    }
                }) { Text(if (sr) "Dodaj" else "Add") }
            },
            dismissButton = { TextButton(onClick = { showAdd = false }) { Text(if (sr) "Otkaži" else "Cancel") } }
        )
    }
}

@Composable
private fun Heading(title: String, muted: Color) {
    Text(title, color = muted, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
}

@Composable
private fun SettingRow(title: String, foreground: Color, trailing: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, modifier = Modifier.weight(1f), color = foreground, fontSize = 16.sp)
        trailing()
    }
}
