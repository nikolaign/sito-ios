package com.seraphi.sito

import android.graphics.Bitmap
import android.graphics.Color as AndroidColor
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

@Composable
fun PDFReader(file: File, sr: Boolean, onClose: () -> Unit) {
    var page by remember(file) { mutableIntStateOf(0) }
    var total by remember(file) { mutableIntStateOf(0) }
    var bitmap by remember(file) { mutableStateOf<Bitmap?>(null) }
    var failure by remember(file) { mutableStateOf("") }

    LaunchedEffect(file, page) {
        try {
            val result = withContext(Dispatchers.IO) {
                ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                    PdfRenderer(fd).use { pdf ->
                        val index = page.coerceIn(0, pdf.pageCount - 1)
                        pdf.openPage(index).use { sheet ->
                            val width = minOf(1080, maxOf(1, sheet.width * 2))
                            val height = maxOf(1, sheet.height * width / sheet.width)
                            val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                            output.eraseColor(AndroidColor.WHITE)
                            sheet.render(output, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            output to pdf.pageCount
                        }
                    }
                }
            }
            bitmap = result.first
            total = result.second
        } catch (error: Exception) { failure = error.localizedMessage ?: "PDF unavailable" }
    }
    Column(Modifier.fillMaxSize().padding(13.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onClose) { Text(if (sr) "‹ Nazad" else "‹ Back") }
            Spacer(Modifier.weight(1f))
            Text(if (total > 0) "${page + 1} / $total" else "PDF")
        }
        if (failure.isNotBlank()) Text(failure, color = Color(0xFFCC252B))
        Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()),
            contentAlignment = Alignment.TopCenter) {
            bitmap?.let { Image(it.asImageBitmap(), contentDescription = null,
                modifier = Modifier.fillMaxWidth(), contentScale = ContentScale.FillWidth) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            OutlinedButton(enabled = page > 0, onClick = { page-- }) {
                Text(if (sr) "Prethodna" else "Previous")
            }
            OutlinedButton(enabled = page + 1 < total, onClick = { page++ }) {
                Text(if (sr) "Sledeća" else "Next")
            }
        }
    }
}
