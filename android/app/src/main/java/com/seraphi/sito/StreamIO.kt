package com.seraphi.sito

import java.io.ByteArrayOutputStream
import java.io.InputStream

/** A bounded stream reader that also works on Android 8 (API 26). */
internal fun InputStream.readAtMost(limit: Int): ByteArray {
    require(limit > 0)
    val output = ByteArrayOutputStream(minOf(limit, 16_384))
    val buffer = ByteArray(8192)
    while (output.size() < limit) {
        val count = read(buffer, 0, minOf(buffer.size, limit - output.size()))
        if (count < 0) break
        if (count > 0) output.write(buffer, 0, count)
    }
    return output.toByteArray()
}
