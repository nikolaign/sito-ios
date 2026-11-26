package com.seraphi.sito

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import kotlinx.coroutines.delay
import kotlin.random.Random

/** The same signature as iOS: black, an abrupt red square, a brief fracture, silence. */
@Composable
internal fun LaunchGlitchScreen(onFinish: () -> Unit) {
    var frame by remember { mutableIntStateOf(0) }
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        delay(105)
        visible = true
        for (time in listOf(35L, 24L, 80L, 41L, 26L, 95L, 49L, 23L, 70L)) {
            frame++
            visible = frame !in listOf(3, 7)
            delay(time)
        }
        visible = false
        delay(110)
        onFinish()
    }
    Canvas(Modifier.fillMaxSize().background(Color.Black)) {
        if (!visible) return@Canvas
        val width = size.minDimension * .14f
        val drift = if (frame % 3 == 0) -14f else if (frame % 3 == 1) 7f else 0f
        val left = (size.width - width) / 2 + drift
        val top = (size.height - width) / 2
        drawRect(gateRed, Offset(left, top), Size(width, width))
        if (frame % 2 == 0) {
            drawRect(Color.Black, Offset(left - 5, top + width * .36f), Size(width + 12, 4f))
            drawRect(gateRed.copy(alpha = .55f), Offset(left + 18, top + width * .64f),
                Size(width * .85f, 2.5f))
        }
    }
}
