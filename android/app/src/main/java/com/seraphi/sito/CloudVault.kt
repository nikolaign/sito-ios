package com.seraphi.sito

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// Apple's open-source LZFSE decoder/encoder is a pinned native submodule.
// Both apps use the same byte-level format for encrypted cloud chunks.
internal object LzfseCodec {
    init { System.loadLibrary("sito_lzfse") }
    external fun nativeDecode(input: ByteArray, expected: Int): ByteArray?
    external fun nativeEncode(input: ByteArray): ByteArray?
}

internal object VaultCipher {
    fun sha256(data: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(data).joinToString("") { "%02x".format(it) }

    fun encrypt(input: ByteArray, key: ByteArray, aad: ByteArray? = null): ByteArray {
        require(key.size == 32) { "Recovery key must be 256-bit" }
        val nonce = ByteArray(12).also(SecureRandom()::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        if (aad != null) cipher.updateAAD(aad)
        return nonce + cipher.doFinal(input)
    }

    fun decrypt(input: ByteArray, key: ByteArray, aad: ByteArray? = null): ByteArray {
        require(key.size == 32 && input.size >= 29) { "Invalid encrypted archive" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, input.copyOfRange(0, 12)))
        if (aad != null) cipher.updateAAD(aad)
        return try { cipher.doFinal(input, 12, input.size - 12) }
        catch (_: Exception) { error("Wrong recovery key or failed integrity check") }
    }

    fun pack(data: ByteArray): ByteArray {
        if (data.size > 20_000_000) return byteArrayOf(0) + data
        val compressed = runCatching { LzfseCodec.nativeEncode(data) }.getOrNull()
        if (compressed == null || compressed.size + 5 >= data.size) return byteArrayOf(0) + data
        return byteArrayOf(1) + ByteBuffer.allocate(4).putInt(data.size).array() + compressed
    }

    fun unpack(data: ByteArray): ByteArray {
        require(data.isNotEmpty()) { "Empty encrypted archive" }
        return when (data[0].toInt()) {
            0 -> data.copyOfRange(1, data.size)
            1 -> {
                require(data.size >= 6) { "Truncated compressed archive" }
                val length = ByteBuffer.wrap(data, 1, 4).int
                require(length in 1..20_000_000) { "Invalid archive length" }
                requireNotNull(LzfseCodec.nativeDecode(data.copyOfRange(5, data.size), length)) {
                    "LZFSE decompression failed"
                }
            }
            else -> error("Unsupported compression mode")
        }
    }
}

/** The token and recovery key never go into preferences as plain text. */
class VaultSecrets(private val context: Context) {
    private val prefs = context.getSharedPreferences("sito-vault-secrets", Context.MODE_PRIVATE)
    private val alias = "sito-device-vault-key"

    private fun key(): java.security.Key {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(alias)) {
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            generator.init(KeyGenParameterSpec.Builder(alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
            generator.generateKey()
        }
        return requireNotNull(store.getKey(alias, null))
    }

    fun save(name: String, value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val packed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(name, Base64.encodeToString(packed, Base64.NO_WRAP)).apply()
    }

    fun read(name: String): String? = runCatching {
        val stored = prefs.getString(name, null) ?: return null
        val packed = Base64.decode(stored, Base64.DEFAULT)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, packed.copyOfRange(0, 12)))
        String(cipher.doFinal(packed, 12, packed.size - 12), Charsets.UTF_8)
    }.getOrNull()
}

class CloudOptions(private val context: Context) {
    private val preferences = context.getSharedPreferences("sito-vault-options", Context.MODE_PRIVATE)
    val secrets = VaultSecrets(context)

    var endpoint: String
        get() = preferences.getString("endpoint", "").orEmpty()
        set(value) { preferences.edit().putString("endpoint", value.trim()).apply() }
    var automatic: Boolean
        get() = preferences.getBoolean("automatic", false)
        set(value) { preferences.edit().putBoolean("automatic", value).apply() }
    var wifiOnly: Boolean
        get() = preferences.getBoolean("wifiOnly", true)
        set(value) { preferences.edit().putBoolean("wifiOnly", value).apply() }
    var includePDFs: Boolean
        get() = preferences.getBoolean("includePDFs", false)
        set(value) { preferences.edit().putBoolean("includePDFs", value).apply() }
    var lastBackup: Long
        get() = preferences.getLong("lastBackup", 0L)
        set(value) { preferences.edit().putLong("lastBackup", value).apply() }
    var lastVerified: Long
        get() = preferences.getLong("lastVerified", 0L)
        set(value) { preferences.edit().putLong("lastVerified", value).apply() }
    var uploadedDigest: String
        get() = preferences.getString("uploadedDigest", "").orEmpty()
        set(value) { preferences.edit().putString("uploadedDigest", value).apply() }
    var verifiedDigest: String
        get() = preferences.getString("verifiedDigest", "").orEmpty()
        set(value) { preferences.edit().putString("verifiedDigest", value).apply() }

    fun saveToken(value: String) {
        require(value.trim().length >= 24) { "Enter a valid Worker access token" }
        secrets.save("worker-token", value.trim())
    }

    fun recoveryKey(): String {
        secrets.read("recovery-key")?.let { return it }
        val fresh = ByteArray(32).also(SecureRandom()::nextBytes)
        val text = Base64.encodeToString(fresh, Base64.NO_WRAP)
        secrets.save("recovery-key", text)
        return text
    }

    fun importRecoveryKey(value: String) {
        val clean = value.trim()
        require(Base64.decode(clean, Base64.DEFAULT).size == 32) { "Recovery key must decode to 32 bytes" }
        secrets.save("recovery-key", clean)
    }

    fun credentials(): Pair<VaultAPI, ByteArray> {
        val uri = URI(endpoint.trim())
        require(uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.userInfo == null &&
            uri.query == null && uri.fragment == null && (uri.path.isNullOrBlank() || uri.path == "/")) {
            "Enter an HTTPS Worker URL with no path or query"
        }
        val token = secrets.read("worker-token") ?: error("Save the Worker token first")
        val recovery = secrets.read("recovery-key") ?: error("Generate or import the recovery key")
        val key = Base64.decode(recovery, Base64.DEFAULT)
        require(key.size == 32) { "Invalid recovery key" }
        return VaultAPI(endpoint.trim().trimEnd('/'), token) to key
    }
}

class VaultAPI(private val endpoint: String, private val token: String) {
    data class Response(val code: Int, val bytes: ByteArray, val parts: Int)

    private fun request(path: String, method: String, body: ByteArray? = null): Response {
        val address = URL("$endpoint/$path")
        val connection = (address.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 20_000
            readTimeout = 120_000
            instanceFollowRedirects = false
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Cache-Control", "no-store")
            if (body != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/octet-stream")
                setFixedLengthStreamingMode(body.size)
            }
        }
        try {
            if (body != null) connection.outputStream.use { it.write(body) }
            val status = connection.responseCode
            if (status == 401 || status == 403) error("Cloudflare rejected this Worker access token")
            if (status in 300..399) error("Unexpected cloud redirect")
            val data = if (method == "HEAD") ByteArray(0) else
                (if (status in 200..299) connection.inputStream else connection.errorStream)
                    ?.use { it.readNBytes(40_000_001) } ?: ByteArray(0)
            require(data.size <= 40_000_000) { "Cloud response exceeds the limit" }
            return Response(status, data, connection.getHeaderField("x-sito-parts")?.toIntOrNull() ?: 1)
        } finally { connection.disconnect() }
    }

    fun getManifest(previous: Boolean = false): ByteArray? {
        val result = request(if (previous) "v1/manifest/previous" else "v1/manifest", "GET")
        if (result.code == 404) return null
        require(result.code == 200) { "Cloudflare returned HTTP ${result.code}" }
        return result.bytes
    }

    fun putManifest(ciphertext: ByteArray) {
        val result = request("v1/manifest", "PUT", ciphertext)
        require(result.code in 200..201) { "Cloudflare returned HTTP ${result.code}" }
        require(getManifest()?.contentEquals(ciphertext) == true) { "Manifest readback failed" }
    }

    fun getObject(hash: String): ByteArray {
        require(hash.matches(Regex("[a-f0-9]{64}"))) { "Invalid object name" }
        val path = "v1/objects/$hash"
        val head = request(path, "HEAD")
        require(head.code == 200 && head.parts in 1..42) { "Cloud object unavailable" }
        val bytes = if (head.parts == 1) {
            val response = request(path, "GET")
            require(response.code == 200) { "Cloud object unavailable" }
            response.bytes
        } else {
            val result = ByteArrayOutputStream()
            for (index in 0 until head.parts) {
                val response = request("$path/parts/$index", "GET")
                require(response.code == 200) { "Cloud object part unavailable" }
                result.write(response.bytes)
            }
            result.toByteArray()
        }
        require(VaultCipher.sha256(bytes) == hash) { "Cloud object hash mismatch" }
        return bytes
    }

    fun putObject(ciphertext: ByteArray): String {
        val hash = VaultCipher.sha256(ciphertext)
        val path = "v1/objects/$hash"
        val head = request(path, "HEAD")
        if (head.code == 200) return hash
        require(head.code == 404) { "Cloudflare returned HTTP ${head.code}" }
        if (ciphertext.size <= 1_000_000) {
            val result = request(path, "PUT", ciphertext)
            require(result.code in 200..201) { "Cloudflare returned HTTP ${result.code}" }
        } else {
            for (offset in ciphertext.indices step 1_000_000) {
                val fragment = ciphertext.copyOfRange(offset, minOf(offset + 1_000_000, ciphertext.size))
                val result = request("$path/parts/${offset / 1_000_000}", "PUT", fragment)
                require(result.code in 200..201) { "Cloudflare returned HTTP ${result.code}" }
            }
            val commit = JSONObject().put("byteLength", ciphertext.size).toString().toByteArray()
            require(request("$path/commit", "PUT", commit).code in 200..201) { "Cloud object commit failed" }
        }
        require(getObject(hash).contentEquals(ciphertext)) { "Cloud object readback mismatch" }
        return hash
    }
}

class CloudArchive(private val options: CloudOptions) {
    data class Summary(val records: Int, val complete: Int, val pdfs: Int)
    private data class Chunk(val month: String, val fingerprint: String, val objectKey: String, val count: Int)
    private data class Manifest(val chunks: List<Chunk>, val bookmarks: List<Article>,
                                val pdfs: JSONArray, val raw: JSONObject)

    private fun manifest(ciphertext: ByteArray, key: ByteArray): Manifest {
        val json = JSONObject(String(VaultCipher.decrypt(ciphertext, key), Charsets.UTF_8))
        require(json.getInt("version") == 1) { "Unsupported iOS/Android backup version" }
        val chunks = json.getJSONArray("chunks").let { array ->
            require(array.length() <= 10_000) { "Too many backup chunks" }
            (0 until array.length()).map { index ->
                val item = array.getJSONObject(index)
                val objectKey = item.getString("object")
                val fingerprint = item.getString("fingerprint")
                require(objectKey.matches(Regex("[a-f0-9]{64}")) &&
                    fingerprint.matches(Regex("[a-f0-9]{64}"))) { "Invalid backup object reference" }
                Chunk(item.getString("month"), fingerprint, objectKey, item.getInt("count"))
            }
        }
        val bookmarks = json.optJSONArray("bookmarks")?.let { array ->
            (0 until array.length()).map { VaultJSON.decode(array.getJSONObject(it), bookmark = true) }
        } ?: emptyList()
        return Manifest(chunks, bookmarks, json.optJSONArray("pdfs") ?: JSONArray(), json)
    }

    private fun readChunks(api: VaultAPI, key: ByteArray, content: Manifest,
                           progress: (String) -> Unit): List<Article> {
        val items = mutableListOf<Article>()
        val seen = mutableSetOf<String>()
        for ((index, chunk) in content.chunks.withIndex()) {
            progress("Checking encrypted articles · ${index + 1}/${content.chunks.size}")
            val bytes = VaultCipher.unpack(VaultCipher.decrypt(api.getObject(chunk.objectKey), key))
            require(VaultCipher.sha256(bytes) == chunk.fingerprint) { "Backup fingerprint mismatch" }
            val entries = VaultJSON.decodeArticles(bytes)
            require(entries.size == chunk.count) { "Backup record count mismatch" }
            for (article in entries) {
                require(seen.add(article.id)) { "Duplicate article in cloud archive" }
                items.add(article)
            }
        }
        return items
    }

    private fun richer(a: Article, b: Article): Article {
        val primary = if ((a.fullText?.length ?: 0) >= (b.fullText?.length ?: 0)) a else b
        val other = if (primary === a) b else a
        return primary.copy(
            bookmark = a.bookmark || b.bookmark,
            image = primary.image ?: other.image,
            author = primary.author ?: other.author,
            categories = primary.categories.ifEmpty { other.categories },
            previewText = primary.previewText ?: other.previewText,
            textCheckedAt = maxOf(a.textCheckedAt ?: 0L, b.textCheckedAt ?: 0L).takeIf { it > 0 },
        )
    }

    suspend fun backup(store: LocalStore, progress: (String) -> Unit,
                       pdfStore: PDFStore? = null): Summary = withContext(Dispatchers.IO) {
        val (api, key) = options.credentials()
        val prior = api.getManifest()?.let { manifest(it, key) }
        val cloud = prior?.let { readChunks(api, key, it, progress) }.orEmpty()
        val union = linkedMapOf<String, Article>()
        cloud.forEach { union[it.id] = it }
        store.archive().forEach { local ->
            union[local.id] = union[local.id]?.let { richer(local, it) } ?: local
        }
        // Existing bookmarks and PDFs survive every upload, even if local
        // cleanup removed their articles. Cloud backup is an accumulating vault.
        val marks = linkedMapOf<String, Article>()
        prior?.bookmarks?.forEach { marks[it.id] = it }
        union.values.filter { it.bookmark }.forEach { local ->
            marks[local.id] = marks[local.id]?.let { richer(local, it) } ?: local
        }
        val previousIndex = prior?.chunks?.associateBy { it.month to it.fingerprint }.orEmpty()
        val chunks = mutableListOf<Chunk>()
        val grouped = union.values.groupBy { VaultJSON.month(it.published) }.toSortedMap()
        for ((month, articles) in grouped) {
            val sorted = articles.sortedBy { it.id }
            var part = 0
            var batch = mutableListOf<Article>()
            var estimated = 2
            fun flush() {
                if (batch.isEmpty()) return
                val raw = VaultJSON.encodeArticles(batch)
                val fingerprint = VaultCipher.sha256(raw)
                val label = "$month-$part"
                val old = previousIndex[label to fingerprint]
                val objectKey = old?.objectKey ?: run {
                    progress("Uploading texts · ${chunks.size + 1}")
                    api.putObject(VaultCipher.encrypt(VaultCipher.pack(raw), key))
                }
                chunks += Chunk(label, fingerprint, objectKey, batch.size)
                batch = mutableListOf()
                estimated = 2
                part++
            }
            for (article in sorted) {
                val bytes = VaultJSON.encode(article).toString().toByteArray().size + 1
                if (batch.isNotEmpty() && (estimated + bytes > 7_000_000 || batch.size >= 250)) flush()
                batch += article
                estimated += bytes
            }
            flush()
        }
        val pdfMap = linkedMapOf<String, JSONObject>()
        prior?.pdfs?.let { existing -> (0 until existing.length()).forEach { index ->
            val record = existing.getJSONObject(index)
            pdfMap[record.getString("id")] = record
        } }
        if (options.includePDFs && pdfStore != null) {
            for (article in union.values) {
                val bytes = pdfStore.read(article.id) ?: continue
                val fingerprint = VaultCipher.sha256(bytes)
                val fileName = "${VaultCipher.sha256(article.id.toByteArray())}-$fingerprint.pdf"
                if (pdfMap[article.id]?.optString("filename") == fileName) continue
                progress("Uploading original PDF · ${pdfMap.size + 1}")
                val objectKey = api.putObject(VaultCipher.encrypt(bytes, key))
                pdfMap[article.id] = JSONObject().put("id", article.id)
                    .put("filename", fileName).put("object", objectKey)
            }
        }
        val manifestJson = JSONObject().apply {
            put("version", 1)
            put("createdAt", (System.currentTimeMillis() - 978307200000L) / 1000.0)
            put("chunks", JSONArray().also { list -> chunks.forEach {
                list.put(JSONObject().put("month", it.month).put("fingerprint", it.fingerprint)
                    .put("object", it.objectKey).put("count", it.count))
            } })
            put("bookmarks", JSONArray().also { list -> marks.values.forEach { list.put(VaultJSON.encode(it)) } })
            put("pdfs", JSONArray().also { list -> pdfMap.values.forEach { list.put(it) } })
        }
        progress("Writing authenticated manifest…")
        val sealed = VaultCipher.encrypt(manifestJson.toString().toByteArray(), key)
        api.putManifest(sealed)
        options.uploadedDigest = VaultCipher.sha256(sealed)
        options.lastBackup = System.currentTimeMillis()
        Summary(union.size, union.values.count { it.hasFullText() }, pdfMap.size)
    }

    suspend fun verify(progress: (String) -> Unit): Summary = withContext(Dispatchers.IO) {
        val (api, key) = options.credentials()
        val ciphertext = api.getManifest() ?: error("No cloud backup exists yet")
        val content = manifest(ciphertext, key)
        val articles = readChunks(api, key, content, progress)
        for (index in 0 until content.pdfs.length()) {
            progress("Verifying saved PDFs · ${index + 1}/${content.pdfs.length()}")
            val item = content.pdfs.getJSONObject(index)
            val decrypted = VaultCipher.decrypt(api.getObject(item.getString("object")), key)
            require(decrypted.size < 35_000_000 && decrypted.take(5).toByteArray()
                .contentEquals("%PDF-".toByteArray())) { "Damaged cloud PDF" }
        }
        options.lastVerified = System.currentTimeMillis()
        options.verifiedDigest = VaultCipher.sha256(ciphertext)
        Summary(articles.size, articles.count { it.hasFullText() }, content.pdfs.length())
    }

    suspend fun restore(store: LocalStore, previous: Boolean = false,
                        progress: (String) -> Unit, pdfStore: PDFStore? = null): Int = withContext(Dispatchers.IO) {
        val (api, key) = options.credentials()
        val ciphertext = api.getManifest(previous) ?: error("This cloud backup doesn't exist")
        val content = manifest(ciphertext, key)
        val articles = readChunks(api, key, content, progress)
        val marks = content.bookmarks.associateBy { it.id }
        val merged = articles.map { item ->
            marks[item.id]?.let { richer(item.copy(bookmark = true), it) } ?: item
        } + content.bookmarks.filterNot { marks -> articles.any { it.id == marks.id } }
        val pdfStages = mutableListOf<Pair<String, ByteArray>>()
        if (pdfStore != null) {
            val validIDs = merged.map { it.id }.toHashSet()
            for (index in 0 until content.pdfs.length()) {
                val pdf = content.pdfs.getJSONObject(index)
                val id = pdf.getString("id")
                if (id !in validIDs) continue
                progress("Downloading PDF · ${index + 1}/${content.pdfs.length()}")
                val bytes = VaultCipher.decrypt(api.getObject(pdf.getString("object")), key)
                require(bytes.size >= 5 && bytes.size < 35_000_000 &&
                    bytes.copyOfRange(0, 5).contentEquals("%PDF-".toByteArray())) { "Invalid cloud PDF" }
                pdfStages += id to bytes
            }
        }
        val before = store.count()
        store.merge(merged)
        pdfStages.forEach { (id, bytes) -> pdfStore?.save(id, bytes) }
        store.count() - before
    }
}

internal object VaultJSON {
    // Swift's default JSONEncoder encodes Dates as seconds since 2001-01-01.
    private const val referenceEpochMillis = 978307200000L
    private fun swiftDate(millis: Long) = (millis - referenceEpochMillis) / 1000.0
    private fun androidDate(value: Double) = (value * 1000).toLong() + referenceEpochMillis

    fun encode(item: Article): JSONObject = JSONObject().apply {
        put("id", item.id); put("sourceID", item.sourceID); put("sourceName", item.sourceName)
        put("section", if (item.region == Region.SERBIA) "serbia" else "world")
        put("title", item.title); put("summary", item.summary); put("url", item.url)
        put("published", swiftDate(item.published))
        item.image?.let { put("imageURL", it) }
        if (item.categories.isNotEmpty()) put("feedCategories", JSONArray(item.categories))
        item.author?.let { put("byline", it) }
        item.fullText?.takeIf { item.hasFullText() }?.let { put("fullText", it) }
        item.textOrigin?.let { put("textOrigin", it) }
        item.textCheckedAt?.let { put("textCheckedAt", swiftDate(it)) }
        item.previewText?.let { put("previewText", it) }
    }

    fun decode(json: JSONObject, bookmark: Boolean = false): Article = Article(
        id = json.getString("id"), sourceID = json.getString("sourceID"),
        sourceName = json.getString("sourceName"),
        region = if (json.getString("section") == "world") Region.WORLD else Region.SERBIA,
        title = json.getString("title"), summary = json.optString("summary"),
        url = json.getString("url"), image = json.optString("imageURL").takeIf { it.startsWith("https://") },
        published = androidDate(json.getDouble("published")),
        categories = json.optJSONArray("feedCategories")?.let { list ->
            (0 until list.length()).map { list.optString(it) }
        } ?: emptyList(), author = json.optString("byline").takeIf { it != "null" && it.isNotBlank() },
        fullText = json.optString("fullText").takeIf { it != "null" && it.isNotBlank() },
        bookmark = bookmark, textOrigin = json.optString("textOrigin").takeIf { it.isNotBlank() },
        textCheckedAt = if (json.has("textCheckedAt") && !json.isNull("textCheckedAt"))
            androidDate(json.getDouble("textCheckedAt")) else null,
        previewText = json.optString("previewText").takeIf { it.isNotBlank() })

    fun decodeArticles(bytes: ByteArray): List<Article> {
        val array = JSONArray(String(bytes, Charsets.UTF_8))
        require(array.length() <= 250) { "Invalid article batch" }
        return (0 until array.length()).map { decode(array.getJSONObject(it)) }
    }

    fun encodeArticles(items: List<Article>): ByteArray = JSONArray().also { array ->
        items.forEach { array.put(encode(it)) }
    }.toString().toByteArray(Charsets.UTF_8)

    fun month(timestamp: Long): String = SimpleDateFormat("yyyy-MM", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.format(Date(timestamp))
}
