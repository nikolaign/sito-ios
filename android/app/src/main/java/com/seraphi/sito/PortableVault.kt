package com.seraphi.sito

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.util.UUID

class PDFStore(private val context: Context) {
    private val folder = File(context.filesDir, "sito-pdfs")
    private fun path(id: String) = File(folder, VaultCipher.sha256(id.toByteArray()) + ".pdf")
    fun contains(id: String): Boolean = path(id).isFile
    fun file(id: String): File? = path(id).takeIf { it.isFile }
    fun temporary(): File = File.createTempFile("sito-import-", ".pdf", context.cacheDir)
    fun read(id: String): ByteArray? = path(id).takeIf { it.isFile }?.readBytes()
    fun totalBytes(): Long = folder.listFiles()?.sumOf { it.length() } ?: 0L
    fun deleteUnreferenced(validIDs: Set<String>): Int {
        val retained = validIDs.mapTo(hashSetOf()) { VaultCipher.sha256(it.toByteArray()) + ".pdf" }
        return folder.listFiles()?.count { file ->
            file.isFile && file.extension == "pdf" && file.name !in retained && file.delete()
        } ?: 0
    }
    fun save(id: String, bytes: ByteArray) {
        require(bytes.size in 5 until 35_000_000 && bytes.copyOfRange(0, 5)
            .contentEquals("%PDF-".toByteArray())) { "Invalid PDF" }
        folder.mkdirs()
        val staging = File(folder, "${UUID.randomUUID()}.tmp")
        try {
            staging.writeBytes(bytes)
            require(staging.renameTo(path(id))) { "Could not save this PDF" }
        } finally { staging.delete() }
    }
}

object PortableVault {
    private val magic = "SITOVLT1".toByteArray()
    private const val MAX_META = 200_000_000L
    private const val MAX_PDF = 36_000_000L

    private fun OutputStream.length(size: Long) { write(ByteBuffer.allocate(8).putLong(size).array()) }
    private fun InputStream.exact(count: Int): ByteArray {
        require(count >= 0) { "Invalid encrypted file length" }
        val result = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = read(result, offset, count - offset)
            require(read > 0) { "Truncated encrypted archive" }
            offset += read
        }
        return result
    }

    private fun InputStream.length(max: Long): Int {
        val size = ByteBuffer.wrap(exact(8)).long
        require(size in 1..max) { "Invalid encrypted object size" }
        return size.toInt()
    }

    suspend fun export(store: LocalStore, pdfs: PDFStore, output: OutputStream,
                       key: ByteArray, withPDFs: Boolean, progress: (String) -> Unit) = withContext(Dispatchers.IO) {
        val articles = store.allArticles()
        val attachments = if (withPDFs) articles.filter { pdfs.contains(it.id) } else emptyList()
        val metadata = JSONObject().apply {
            put("version", 1)
            put("createdAt", (System.currentTimeMillis() - 978307200000L) / 1000.0)
            put("articles", JSONArray().also { array -> articles.forEach { array.put(VaultJSON.encode(it)) } })
            put("bookmarks", JSONArray().also { array -> articles.filter { it.bookmark }.forEach {
                array.put(VaultJSON.encode(it))
            } })
            put("pdfs", JSONArray().also { array -> attachments.forEach {
                array.put(JSONObject().put("id", it.id))
            } })
        }
        val ciphertext = VaultCipher.encrypt(VaultCipher.pack(metadata.toString().toByteArray()), key)
        require(ciphertext.size < MAX_META) { "Portable metadata is too large" }
        output.use { target ->
            target.write(magic)
            target.length(ciphertext.size.toLong())
            target.write(ciphertext)
            attachments.forEachIndexed { index, article ->
                progress("Saving PDF ${index + 1}/${attachments.size}")
                val plain = requireNotNull(pdfs.read(article.id))
                val aad = "SITO-portable-PDF-v1:${article.id}".toByteArray()
                val encrypted = VaultCipher.encrypt(plain, key, aad)
                require(encrypted.size < MAX_PDF) { "PDF is too large" }
                target.length(encrypted.size.toLong())
                target.write(encrypted)
            }
            target.flush()
        }
    }

    suspend fun import(store: LocalStore, pdfs: PDFStore, input: InputStream,
                       key: ByteArray, progress: (String) -> Unit): Int = withContext(Dispatchers.IO) {
        // Authenticate the complete file before changing the local SQLite data.
        val stage = mutableListOf<Pair<String, File>>()
        var articles = emptyList<Article>()
        var marks = emptyList<Article>()
        try {
            input.use { source ->
            require(source.exact(8).contentEquals(magic)) { "Not a SITO encrypted backup" }
            val metadata = source.exact(source.length(MAX_META))
            val json = JSONObject(String(VaultCipher.unpack(VaultCipher.decrypt(metadata, key))))
            require(json.getInt("version") == 1) { "Unsupported portable format" }
            val items = json.getJSONArray("articles")
            require(items.length() <= 100_000) { "Too many archived stories" }
            articles = (0 until items.length()).map { VaultJSON.decode(items.getJSONObject(it)) }
            val bookmarks = json.optJSONArray("bookmarks") ?: JSONArray()
            marks = (0 until bookmarks.length()).map { VaultJSON.decode(bookmarks.getJSONObject(it), bookmark = true) }
            val attachments = json.getJSONArray("pdfs")
            require(attachments.length() <= 10_000) { "Too many PDFs" }
            val seenIDs = mutableSetOf<String>()
            for (index in 0 until attachments.length()) {
                progress("Authenticating PDF ${index + 1}/${attachments.length()}")
                val id = attachments.getJSONObject(index).getString("id")
                require(seenIDs.add(id)) { "Duplicate PDF" }
                val sealed = source.exact(source.length(MAX_PDF))
                val aad = "SITO-portable-PDF-v1:$id".toByteArray()
                val plain = VaultCipher.decrypt(sealed, key, aad)
                require(plain.size >= 5 && plain.size < 35_000_000 &&
                    plain.copyOfRange(0, 5).contentEquals("%PDF-".toByteArray())) { "Invalid PDF" }
                val temporary = pdfs.temporary()
                stage += id to temporary
                temporary.writeBytes(plain)
            }
            require(source.read() == -1) { "Unexpected bytes after backup" }
            }
            val bookmarked = marks.associateBy { it.id }
            val articleIDs = articles.mapTo(hashSetOf()) { it.id }
            val merged = articles.map { article ->
                if (article.id in bookmarked) article.copy(bookmark = true) else article
            } + marks.filterNot { it.id in articleIDs }
            val before = store.count()
            store.merge(merged)
            for ((id, file) in stage) pdfs.save(id, file.readBytes())
            store.count() - before
        } finally {
            stage.forEach { (_, file) -> file.delete() }
        }
    }
}
