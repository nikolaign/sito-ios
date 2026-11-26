package com.seraphi.sito

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
internal fun SettingsScreen(
    sr: Boolean, foreground: Color, muted: Color,
    currentSources: List<Source>, settings: SettingsStore,
    language: String, theme: String, compact: Boolean, paged: Boolean, advanced: Boolean,
    onLanguage: (String) -> Unit, onTheme: (String) -> Unit,
    onCompact: (Boolean) -> Unit, onPaged: (Boolean) -> Unit, onAdvanced: (Boolean) -> Unit,
    onSourcesChanged: () -> Unit,
) {
    var showSources by remember { mutableStateOf(false) }
    var showAdd by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    var newURL by remember { mutableStateOf("") }
    var newRegion by remember { mutableStateOf(Region.WORLD) }
    var error by remember { mutableStateOf("") }

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
            Text(if (sr) "Arhiva, katalog izvora i cloud podešavanja dobiće poseban ekran."
                else "Archive, source catalogue and cloud options will have their own screen.",
                color = muted, fontSize = 13.sp)
        }
        HorizontalDivider(color = muted.copy(alpha = 0.2f))
        Text(if (sr) "Razvio seraphi" else "Developed by seraphi",
            color = foreground, fontSize = 13.sp)
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
                    if (newName.isBlank() || !newURL.trim().startsWith("https://")) {
                        error = "Please enter a name and an HTTPS feed URL"
                    } else {
                        settings.addSource(newName.trim(), newURL.trim(), newRegion)
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
