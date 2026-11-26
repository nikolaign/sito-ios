package com.seraphi.sito

import androidx.compose.ui.test.assertExists
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

@RunWith(AndroidJUnit4::class)
class SitoSmokeTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun readerSettingsAndArchiveOpenWithoutNetwork() {
        compose.waitUntil(45_000) {
            compose.onAllNodesWithText("SITO").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("⋮").performClick()
        compose.onNodeWithText("Prikaži napredne opcije").assertExists()
        compose.onNodeWithText("×").performClick()
        compose.onNodeWithText("▤").performClick()
        compose.onNodeWithText("Pretraži arhivu").assertExists()
    }

    @Test fun encryptedPortableBackupRestoresCompleteTextAndOriginalPdf() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val history = LocalStore(context)
        val pdfs = PDFStore(context)
        val id = "smoke|${System.currentTimeMillis()}"
        val fullBody = "Verified original report. ".repeat(40)
        val article = Article(id, "smoke", "Smoke Publisher", Region.WORLD,
            "Smoke test article", "Preview", "https://example.org/smoke", null,
            System.currentTimeMillis(), fullText = fullBody, textOrigin = "original")
        history.merge(listOf(article))
        val examplePdf = "%PDF-1.4\n1 0 obj\n<<>>\nendobj\n%%EOF".toByteArray()
        pdfs.save(id, examplePdf)
        val key = ByteArray(32) { (it * 3).toByte() }
        val bytes = ByteArrayOutputStream().also { output ->
            PortableVault.export(history, pdfs, output, key, withPDFs = true) { }
        }.toByteArray()
        assertFalse(String(bytes, Charsets.ISO_8859_1).contains("Smoke test article"))
        PortableVault.import(history, pdfs, ByteArrayInputStream(bytes), key) { }
        assertEquals(fullBody, history.byId(id)?.fullText)
        assertArrayEquals(examplePdf, pdfs.read(id))
    }
}
