package com.seraphi.sito

import androidx.compose.ui.test.assertExists
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

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
}
