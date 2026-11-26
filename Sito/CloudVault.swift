import Foundation
import Combine
import CryptoKit
import Compression
import Network
import Security

// No Cloudflare credentials are shipped with SITO. Every installation can be
// paired with its own private Cloudflare D1 database + Worker, including future open-source
// builds. The Worker never sees plaintext stories or the recovery key.
private enum VaultSecrets {
    static let service = "com.seraphi.sito.private-vault"

    static func read(_ name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ name: String, value: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
        let data = Data(value.utf8)
        let changes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(identity as CFDictionary, changes as CFDictionary)
        if updated == errSecItemNotFound {
            var creation = identity
            creation[kSecValueData as String] = data
            creation[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(creation as CFDictionary, nil) == errSecSuccess else {
                throw CloudVaultError.keychain
            }
        } else if updated != errSecSuccess { throw CloudVaultError.keychain }
    }
}

enum CloudVaultError: LocalizedError {
    case keychain, noConfiguration, invalidEndpoint, noRecoveryKey, wifiRequired
    case badRecoveryKey, authorization, cloud(Int), malformedResponse, integrity, incompatible, busy
    var errorDescription: String? {
        switch self {
        case .keychain: return "Could not save the key securely on this device."
        case .noConfiguration: return "Enter your Worker URL and save its access token first."
        case .invalidEndpoint: return "Use a valid HTTPS Cloudflare Worker URL (no path or query)."
        case .noRecoveryKey: return "Generate or import your recovery key before backing up. Save a copy outside this iPhone."
        case .wifiRequired: return "Wi-Fi is required by your backup settings."
        case .badRecoveryKey: return "This cloud archive uses a different recovery key. Nothing was overwritten."
        case .authorization: return "Cloudflare rejected your access token (HTTP 401/403)."
        case .cloud(507): return "Your free cloud archive is near its storage limit. Local stories are safe. Try turning off PDF backups or manage the D1 database in Cloudflare."
        case .cloud(let code): return "Cloudflare returned HTTP \(code). Check the free D1 quotas, Worker setup and connection."
        case .malformedResponse: return "Cloudflare returned an unexpected response."
        case .integrity: return "Backup verification failed. Your previous cloud copy was not removed."
        case .incompatible: return "This cloud backup format is not supported by this version of SITO."
        case .busy: return "A cloud operation is already running."
        }
    }
}

private enum VaultCipher {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encrypt(_ data: Data, with key: SymmetricKey) throws -> Data {
        guard let sealed = try AES.GCM.seal(data, using: key).combined else { throw CloudVaultError.integrity }
        return sealed
    }

    static func decrypt(_ data: Data, with key: SymmetricKey) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key) }
        catch { throw CloudVaultError.badRecoveryKey }
    }

    // Four-byte original length + mode; small chunks can stay uncompressed.
    // PDFs are already compressed, and go straight through AES-GCM instead.
    static func pack(_ data: Data) -> Data {
        guard data.count <= 20_000_000 else {
            var unpacked = Data([0]); unpacked.append(data); return unpacked
        }
        let input = [UInt8](data)
        var target = [UInt8](repeating: 0, count: max(128, input.count + input.count / 2 + 64))
        let length = input.withUnsafeBufferPointer { source in
            target.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(destination.baseAddress!, destination.count,
                                          source.baseAddress!, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard length > 0, length + 5 < data.count else {
            var unpacked = Data([0]); unpacked.append(data); return unpacked
        }
        var header = Data([1])
        let original = UInt32(data.count)
        header.append(UInt8((original >> 24) & 255))
        header.append(UInt8((original >> 16) & 255))
        header.append(UInt8((original >> 8) & 255))
        header.append(UInt8(original & 255))
        header.append(contentsOf: target.prefix(length))
        return header
    }

    static func unpack(_ data: Data) throws -> Data {
        guard let flag = data.first else { throw CloudVaultError.integrity }
        if flag == 0 { return Data(data.dropFirst()) }
        guard flag == 1, data.count >= 5 else { throw CloudVaultError.integrity }
        let prefix = [UInt8](data.prefix(5))
        let length = Int(prefix[1]) << 24 | Int(prefix[2]) << 16 | Int(prefix[3]) << 8 | Int(prefix[4])
        guard length > 0 && length <= 20_000_000 else { throw CloudVaultError.integrity }
        let input = [UInt8](data.dropFirst(5))
        var output = [UInt8](repeating: 0, count: length)
        let count = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, destination.count,
                                          source.baseAddress!, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count == length else { throw CloudVaultError.integrity }
        return Data(output)
    }
}

private struct VaultChunk: Codable {
    let month: String
    let fingerprint: String   // Hash of the unencrypted JSON, not its encrypted cloud object.
    let object: String        // Hash of AES-GCM ciphertext, used as immutable key.
    let count: Int
}

private struct VaultPDF: Codable {
    let id: String
    let filename: String
    let object: String
}

private struct VaultManifest: Codable {
    let version: Int
    let createdAt: Date
    let chunks: [VaultChunk]
    let bookmarks: [NewsItem]
    let pdfs: [VaultPDF]
}

private struct VaultAPI {
    let endpoint: URL
    let token: String

    private func request(_ path: String, method: String, payload: Data? = nil) async throws -> (Int, Data, HTTPURLResponse) {
        var url = endpoint
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        req.httpMethod = method
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if payload != nil { req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        let data: Data
        let response: URLResponse
        if let payload { (data, response) = try await URLSession.shared.upload(for: req, from: payload) }
        else { (data, response) = try await URLSession.shared.data(for: req) }
        guard let http = response as? HTTPURLResponse else { throw CloudVaultError.malformedResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudVaultError.authorization }
        return (http.statusCode, data, http)
    }

    func getManifest() async throws -> Data? {
        let (code, data, _) = try await request("v1/manifest", method: "GET")
        if code == 404 { return nil }
        guard code == 200 else { throw CloudVaultError.cloud(code) }
        return data
    }

    func getPreviousManifest() async throws -> Data? {
        let (code, data, _) = try await request("v1/manifest/previous", method: "GET")
        if code == 404 { return nil }
        guard code == 200 else { throw CloudVaultError.cloud(code) }
        return data
    }

    func putManifest(_ ciphertext: Data) async throws {
        let (code, _, _) = try await request("v1/manifest", method: "PUT", payload: ciphertext)
        guard code == 200 || code == 201 else { throw CloudVaultError.cloud(code) }
        guard let verified = try await getManifest(), verified == ciphertext else {
            throw CloudVaultError.integrity
        }
    }

    func getObject(_ key: String) async throws -> Data {
        let path = "v1/objects/" + key
        let (head, _, response) = try await request(path, method: "HEAD")
        guard head == 200 else { throw CloudVaultError.cloud(head) }
        let parts = Int(response.value(forHTTPHeaderField: "x-sito-parts") ?? "") ?? 1
        guard (1...42).contains(parts) else { throw CloudVaultError.malformedResponse }
        let data: Data
        if parts == 1 {
            let (code, body, _) = try await request(path, method: "GET")
            guard code == 200 else { throw CloudVaultError.cloud(code) }
            data = body
        } else {
            var assembled = Data()
            for index in 0..<parts {
                let (code, body, _) = try await request(path + "/parts/\(index)", method: "GET")
                guard code == 200 else { throw CloudVaultError.cloud(code) }
                assembled.append(body)
            }
            data = assembled
        }
        guard VaultCipher.digest(data) == key else { throw CloudVaultError.integrity }
        return data
    }

    func putObject(_ ciphertext: Data) async throws -> String {
        let key = VaultCipher.digest(ciphertext)
        let path = "v1/objects/" + key
        let (existing, _, _) = try await request(path, method: "HEAD")
        if existing == 200 { return key }
        guard existing == 404 else { throw CloudVaultError.cloud(existing) }
        // Keep each Worker Free request small enough to fit its CPU budget.
        // Chunking matters for PDFs; article groups usually fit one request.
        let partSize = 1_000_000
        if ciphertext.count > partSize {
            for offset in stride(from: 0, to: ciphertext.count, by: partSize) {
                let fragment = Data(ciphertext[offset..<min(offset + partSize, ciphertext.count)])
                let (code, _, _) = try await request(path + "/parts/\(offset / partSize)",
                                                    method: "PUT", payload: fragment)
                guard code == 200 || code == 201 else { throw CloudVaultError.cloud(code) }
            }
            let commit = try JSONSerialization.data(withJSONObject: ["byteLength": ciphertext.count])
            let (code, _, _) = try await request(path + "/commit", method: "PUT", payload: commit)
            guard code == 200 || code == 201 else { throw CloudVaultError.cloud(code) }
            // A final readback checks the whole ciphertext SHA-256, including
            // ordering of all parts, before a manifest can reference the PDF.
            guard try await getObject(key) == ciphertext else { throw CloudVaultError.integrity }
        } else {
            let (code, _, _) = try await request(path, method: "PUT", payload: ciphertext)
            guard code == 200 || code == 201 else { throw CloudVaultError.cloud(code) }
        }
        let (head, _, _) = try await request(path, method: "HEAD")
        guard head == 200 else { throw CloudVaultError.integrity }
        return key
    }
}

@MainActor
final class CloudVault: ObservableObject {
    @Published var endpointText: String { didSet { UserDefaults.standard.set(endpointText, forKey: "vaultEndpoint") } }
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "vaultEnabled") } }
    @Published var wifiOnly: Bool { didSet { UserDefaults.standard.set(wifiOnly, forKey: "vaultWifiOnly") } }
    @Published var backupPDFs: Bool { didSet { UserDefaults.standard.set(backupPDFs, forKey: "vaultBackupPDFs") } }
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var lastBackup: Date?
    @Published private(set) var lastRestore: Date?
    @Published private(set) var lastVerification: Date?
    @Published private(set) var lastUploadedManifestDigest: String?
    @Published private(set) var lastVerifiedManifestDigest: String?
    @Published private(set) var wifiAvailable = false

    private let monitor = NWPathMonitor()
    private let defaults = UserDefaults.standard

    init() {
        endpointText = UserDefaults.standard.string(forKey: "vaultEndpoint") ?? ""
        enabled = UserDefaults.standard.bool(forKey: "vaultEnabled")
        wifiOnly = UserDefaults.standard.object(forKey: "vaultWifiOnly") as? Bool ?? true
        // Opt-in PDFs on fresh installations: the free D1 database is small.
        // Existing installations keep their explicit saved preference.
        backupPDFs = UserDefaults.standard.object(forKey: "vaultBackupPDFs") as? Bool ?? false
        lastBackup = UserDefaults.standard.object(forKey: "vaultLastBackup") as? Date
        lastRestore = UserDefaults.standard.object(forKey: "vaultLastRestore") as? Date
        lastVerification = UserDefaults.standard.object(forKey: "vaultLastVerification") as? Date
        lastUploadedManifestDigest = UserDefaults.standard.string(forKey: "vaultLastUploadedDigest")
        lastVerifiedManifestDigest = UserDefaults.standard.string(forKey: "vaultLastVerifiedDigest")
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.wifiAvailable = path.status == .satisfied && path.usesInterfaceType(.wifi)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.seraphi.sito.vault-network"))
    }

    deinit { monitor.cancel() }

    // A verified manifest is not the same as a successful audit of every
    // encrypted object. After a new upload, full verification becomes stale
    // until Verify Cloud Archive checks that exact manifest again.
    var latestBackupFullyVerified: Bool {
        guard let verified = lastVerifiedManifestDigest else { return false }
        return lastUploadedManifestDigest.map { $0 == verified } ?? true
    }

    var hasToken: Bool { VaultSecrets.read("access-token") != nil }
    var hasKey: Bool { VaultSecrets.read("recovery-key") != nil }

    func saveToken(_ token: String) throws {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 24 else { throw CloudVaultError.noConfiguration }
        try VaultSecrets.save("access-token", value: clean)
        status = "Access token saved in Keychain."
    }

    func recoveryKey() throws -> String {
        if let existing = VaultSecrets.read("recovery-key") { return existing }
        let created = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        try VaultSecrets.save("recovery-key", value: created)
        return created
    }

    func importRecoveryKey(_ input: String) throws {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Data(base64Encoded: clean), decoded.count == 32 else { throw CloudVaultError.badRecoveryKey }
        try VaultSecrets.save("recovery-key", value: clean)
        status = "Recovery key imported."
    }

    private func credentials(requireWiFi: Bool) throws -> (VaultAPI, SymmetricKey) {
        guard let parts = URLComponents(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let endpoint = parts.url else { throw CloudVaultError.invalidEndpoint }
        guard let token = VaultSecrets.read("access-token"), !token.isEmpty else { throw CloudVaultError.noConfiguration }
        guard let recovery = VaultSecrets.read("recovery-key"),
              let data = Data(base64Encoded: recovery), data.count == 32 else { throw CloudVaultError.noRecoveryKey }
        if requireWiFi && wifiOnly && !wifiAvailable { throw CloudVaultError.wifiRequired }
        return (VaultAPI(endpoint: endpoint, token: token), SymmetricKey(data: data))
    }

    func automaticBackupIfDue(feed: NewsFeed) async {
        guard enabled && !busy && !feed.textCaptureActive,
              (lastBackup.map { Date().timeIntervalSince($0) >= 24 * 3600 } ?? true) else { return }
        do { try await backup(feed: feed, automatic: true) }
        catch { status = error.localizedDescription }
    }

    // Full article bodies vary widely in length. Keep the raw JSON for one
    // encrypted object below 7 MB, rather than grouping a fixed 250 stories
    // that could unexpectedly exceed Worker request/restore limits.
    private func textBatches(_ articles: [NewsItem], using encoder: JSONEncoder) throws -> [[NewsItem]] {
        var batches: [[NewsItem]] = []
        var batch: [NewsItem] = []
        var size = 2
        for article in articles {
            let bytes = try encoder.encode(article).count + 1
            if !batch.isEmpty && (size + bytes > 7_000_000 || batch.count >= 250) {
                batches.append(batch)
                batch = []
                size = 2
            }
            batch.append(article)
            size += bytes
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    func backup(feed: NewsFeed, automatic: Bool = false) async throws {
        guard !busy else { throw CloudVaultError.busy }
        let (api, key) = try credentials(requireWiFi: automatic)
        busy = true
        defer { busy = false }
        status = "Reading the private cloud archive…"

        let previous: VaultManifest?
        if let remote = try await api.getManifest() {
            do { previous = try JSONDecoder().decode(VaultManifest.self, from: VaultCipher.decrypt(remote, with: key)) }
            catch { throw CloudVaultError.badRecoveryKey }
            guard previous?.version == 1 else { throw CloudVaultError.incompatible }
        } else { previous = nil }

        // Partition by publication month; a single new story changes only a
        // small group. Identical chunks and PDF files reuse previous objects.
        var groups: [String: [NewsItem]] = [:]
        let month = DateFormatter()
        month.locale = Locale(identifier: "en_US_POSIX")
        month.timeZone = TimeZone(secondsFromGMT: 0)
        month.dateFormat = "yyyy-MM"
        for item in try feed.completeArchiveForBackup() {
            groups[month.string(from: item.published), default: []].append(item.cleanedForArchive())
        }
        let encoder = JSONEncoder()
        var chunks: [VaultChunk] = []
        let existingByMonth = Dictionary(grouping: previous?.chunks ?? [], by: { String($0.month.prefix(7)) })
        let allMonths = Set(groups.keys).union(existingByMonth.keys).sorted()
        for name in allMonths {
            let local = groups[name] ?? []
            let oldChunks = (existingByMonth[name] ?? []).sorted { $0.month < $1.month }
            if local.isEmpty {
                // Removing old local history must NEVER delete the cloud copy.
                chunks.append(contentsOf: oldChunks)
                continue
            }
            var union = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
            // Only fetch remote month data if a slice no longer matches what
            // is on this iPhone (e.g. a local cleanup or imported archive).
            let localSorted = local.sorted { $0.id < $1.id }
            let candidateFingerprints = try textBatches(localSorted, using: encoder)
                .map { VaultCipher.digest(try encoder.encode($0)) }
            let isIdentical = oldChunks.count == candidateFingerprints.count &&
                zip(oldChunks, candidateFingerprints).allSatisfy { pair in pair.0.fingerprint == pair.1 }
            if isIdentical {
                chunks.append(contentsOf: oldChunks)
                continue
            }
            for chunk in oldChunks {
                let sealed = try await api.getObject(chunk.object)
                let raw = try VaultCipher.unpack(VaultCipher.decrypt(sealed, with: key))
                guard VaultCipher.digest(raw) == chunk.fingerprint else { throw CloudVaultError.integrity }
                let articles = try JSONDecoder().decode([NewsItem].self, from: raw)
                for item in articles {
                    union[item.id] = (union[item.id] ?? item).merging(older: item)
                }
            }
            let articles = union.values.sorted { $0.id < $1.id }
            for (index, slice) in try textBatches(articles, using: encoder).enumerated() {
                let identity = "\(name)-\(index)"
                let raw = try encoder.encode(slice)
                let fingerprint = VaultCipher.digest(raw)
                let old = oldChunks.first { $0.month == identity && $0.fingerprint == fingerprint }
                let object: String
                if let old { object = old.object }
                else {
                    status = "Uploading articles · \(chunks.count + 1)…"
                    object = try await api.putObject(VaultCipher.encrypt(VaultCipher.pack(raw), with: key))
                }
                chunks.append(VaultChunk(month: identity, fingerprint: fingerprint,
                                         object: object, count: slice.count))
            }
        }

        var pdfs = Dictionary(uniqueKeysWithValues: (previous?.pdfs ?? []).map { ($0.id, $0) })
        if backupPDFs {
            for entry in feed.completeItems {
                let path = feed.completePDFURL(for: entry)
                guard FileManager.default.fileExists(atPath: path.path) else { continue }
                if let old = pdfs[entry.id], old.filename == entry.filename {
                    continue
                }
                status = "Uploading saved PDFs · \(pdfs.count + 1)…"
                let data = try Data(contentsOf: path)
                guard data.count < 35_000_000 else { throw NewsFeed.BackupError.tooLarge }
                let object = try await api.putObject(VaultCipher.encrypt(data, with: key))
                pdfs[entry.id] = VaultPDF(id: entry.id, filename: entry.filename, object: object)
            }
        }

        let manifest = VaultManifest(version: 1, createdAt: .now, chunks: chunks,
                                     bookmarks: feed.saved.values.map { (feed.archivedArticle(id: $0.id) ?? $0).cleanedForArchive() },
                                     pdfs: pdfs.values.sorted { $0.id < $1.id })
        status = "Verifying cloud backup…"
        let ciphertext = try VaultCipher.encrypt(try encoder.encode(manifest), with: key)
        try await api.putManifest(ciphertext)
        let digest = VaultCipher.digest(ciphertext)
        lastUploadedManifestDigest = digest
        defaults.set(digest, forKey: "vaultLastUploadedDigest")
        lastBackup = .now
        defaults.set(lastBackup, forKey: "vaultLastBackup")
        status = "Backup saved · \(chunks.reduce(0) { $0 + $1.count }) records · tap Verify Cloud Archive for a full check"
    }

    // A genuine end-to-end, read-only cloud audit: download each referenced
    // ciphertext, check its SHA-256, AES-GCM authentication, compression,
    // JSON shape and article count. No local records or remote objects change.
    func verifyCloudArchive() async throws {
        guard !busy else { throw CloudVaultError.busy }
        let (api, key) = try credentials(requireWiFi: false)
        busy = true
        defer { busy = false }
        status = "Reading encrypted cloud manifest…"
        guard let sealedManifest = try await api.getManifest() else { throw CloudVaultError.cloud(404) }
        let manifest: VaultManifest
        do { manifest = try JSONDecoder().decode(VaultManifest.self,
                     from: VaultCipher.decrypt(sealedManifest, with: key)) }
        catch { throw CloudVaultError.badRecoveryKey }
        guard manifest.version == 1 else { throw CloudVaultError.incompatible }

        let decoder = JSONDecoder()
        var seen = Set<String>()
        var complete = 0
        for (index, chunk) in manifest.chunks.enumerated() {
            status = "Checking cloud texts · \(index + 1)/\(manifest.chunks.count)"
            let sealed = try await api.getObject(chunk.object)
            let plaintext = try VaultCipher.unpack(VaultCipher.decrypt(sealed, with: key))
            guard VaultCipher.digest(plaintext) == chunk.fingerprint else { throw CloudVaultError.integrity }
            let articles = try decoder.decode([NewsItem].self, from: plaintext)
            guard articles.count == chunk.count else { throw CloudVaultError.integrity }
            for article in articles {
                guard seen.insert(article.id).inserted else { throw CloudVaultError.integrity }
                if article.hasFullText { complete += 1 }
            }
        }
        for (index, pdf) in manifest.pdfs.enumerated() {
            status = "Checking saved PDFs · \(index + 1)/\(manifest.pdfs.count)"
            let sealed = try await api.getObject(pdf.object)
            let data = try VaultCipher.decrypt(sealed, with: key)
            guard data.count < 35_000_000, data.starts(with: Data("%PDF-".utf8))
            else { throw CloudVaultError.integrity }
        }
        lastVerification = .now
        defaults.set(lastVerification, forKey: "vaultLastVerification")
        lastVerifiedManifestDigest = VaultCipher.digest(sealedManifest)
        defaults.set(lastVerifiedManifestDigest, forKey: "vaultLastVerifiedDigest")
        status = "Cloud verified · \(seen.count) records · \(complete) complete texts · \(seen.count - complete) previews · \(manifest.pdfs.count) PDFs"
    }

    func restore(feed: NewsFeed, previous: Bool = false) async throws -> Int {
        guard !busy else { throw CloudVaultError.busy }
        let (api, key) = try credentials(requireWiFi: false)
        busy = true
        defer { busy = false }
        status = "Downloading private archive…"
        guard let remote = try await (previous ? api.getPreviousManifest() : api.getManifest())
        else { throw CloudVaultError.cloud(404) }
        let manifest: VaultManifest
        do { manifest = try JSONDecoder().decode(VaultManifest.self, from: VaultCipher.decrypt(remote, with: key)) }
        catch { throw CloudVaultError.badRecoveryKey }
        guard manifest.version == 1 else { throw CloudVaultError.incompatible }

        let decoder = JSONDecoder()
        var articles: [NewsItem] = []
        for (index, chunk) in manifest.chunks.enumerated() {
            status = "Restoring articles · \(index + 1)/\(manifest.chunks.count)"
            let sealed = try await api.getObject(chunk.object)
            let raw = try VaultCipher.unpack(VaultCipher.decrypt(sealed, with: key))
            guard VaultCipher.digest(raw) == chunk.fingerprint else { throw CloudVaultError.integrity }
            let entries = try decoder.decode([NewsItem].self, from: raw)
            guard entries.count == chunk.count else { throw CloudVaultError.integrity }
            articles.append(contentsOf: entries)
        }

        let oldCount = feed.archiveCount
        try feed.mergeCloudBackup(articles: articles, bookmarks: manifest.bookmarks)
        var byID: [String: NewsItem] = [:]
        for item in articles + manifest.bookmarks { byID[item.id] = item }
        if backupPDFs {
            for (index, pdf) in manifest.pdfs.enumerated() {
                guard let item = byID[pdf.id] else { continue }
                status = "Restoring PDFs · \(index + 1)/\(manifest.pdfs.count)"
                let sealed = try await api.getObject(pdf.object)
                let data = try VaultCipher.decrypt(sealed, with: key)
                try feed.restoreCloudPDF(data, article: item)
            }
        }
        lastRestore = .now
        defaults.set(lastRestore, forKey: "vaultLastRestore")
        let added = max(0, feed.archiveCount - oldCount)
        status = "Restored \(added) articles · bookmarks merged"
        return added
    }

    // A destination-independent backup. The Share sheet can send this file
    // to Files providers, local storage, AirDrop or a private server without
    // giving SITO any account credentials for those services.
    func exportPortable(feed: NewsFeed, includePDFs: Bool) async throws -> URL {
        guard !busy else { throw CloudVaultError.busy }
        let recovery = try recoveryKey()
        guard let keyData = Data(base64Encoded: recovery), keyData.count == 32
        else { throw CloudVaultError.noRecoveryKey }
        let pdfs: [PortableArchive.PDFSource] = includePDFs ? feed.completeItems.compactMap { entry in
            let url = feed.completePDFURL(for: entry)
            return FileManager.default.fileExists(atPath: url.path)
                ? PortableArchive.PDFSource(id: entry.id, url: url) : nil
        } : []
        let snapshot = PortableArchive.Snapshot(articles: try feed.completeArchiveForBackup().map { $0.cleanedForArchive() },
                                                bookmarks: feed.saved.values.map { (feed.archivedArticle(id: $0.id) ?? $0).cleanedForArchive() }, pdfs: pdfs)
        busy = true
        defer { busy = false }
        status = "Encrypting portable backup…"
        let exported = try await Task.detached(priority: .userInitiated) {
            try PortableArchive.write(snapshot: snapshot, key: SymmetricKey(data: keyData))
        }.value
        status = "Encrypted backup ready · save the recovery key somewhere safe"
        return exported
    }

    func importPortable(feed: NewsFeed, from url: URL) async throws -> Int {
        guard !busy else { throw CloudVaultError.busy }
        guard let recovery = VaultSecrets.read("recovery-key"),
              let keyData = Data(base64Encoded: recovery), keyData.count == 32
        else { throw CloudVaultError.noRecoveryKey }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        busy = true
        defer { busy = false }
        status = "Checking encrypted backup…"
        let restored = try await Task.detached(priority: .userInitiated) {
            try PortableArchive.read(url: url, key: SymmetricKey(data: keyData))
        }.value
        defer { try? FileManager.default.removeItem(at: restored.directory) }
        // Every encrypted record has been authenticated before any local
        // archive changes are made. A restore merges; it never clears data.
        let oldCount = feed.archiveCount
        try feed.mergeCloudBackup(articles: restored.manifest.articles,
                                  bookmarks: restored.manifest.bookmarks)
        var byID: [String: NewsItem] = [:]
        for item in restored.manifest.articles + restored.manifest.bookmarks {
            byID[item.id] = item
        }
        for (index, pdf) in restored.manifest.pdfs.enumerated() {
            guard let item = byID[pdf.id] else { continue }
            let path = restored.directory.appendingPathComponent("\(index).pdf")
            try feed.restoreCloudPDF(Data(contentsOf: path), article: item)
        }
        let added = max(0, feed.archiveCount - oldCount)
        status = "Imported \(added) articles · saved PDFs restored"
        return added
    }
}

// Portable v1 layout:
//   "SITOVLT1" | 8-byte big-endian length | AES-GCM(metadata JSON)
//   ... followed by length + AES-GCM(PDF bytes) for each metadata PDF ID.
// The manifest is authenticated before any PDF is trusted. PDFs are decrypted
// one at a time to a short-lived staging directory to avoid an enormous
// in-memory JSON or base64 archive.
private enum PortableArchive {
    enum FileError: LocalizedError {
        case tooLarge
        var errorDescription: String? {
            "Portable archive metadata exceeds 200 MB, or a saved PDF exceeds 35 MB."
        }
    }
    struct PDFSource: Sendable {
        let id: String
        let url: URL
    }
    struct Snapshot: Sendable {
        let articles: [NewsItem]
        let bookmarks: [NewsItem]
        let pdfs: [PDFSource]
    }
    struct PDFInfo: Codable, Sendable { let id: String }
    struct Manifest: Codable, Sendable {
        let version: Int
        let createdAt: Date
        let articles: [NewsItem]
        let bookmarks: [NewsItem]
        let pdfs: [PDFInfo]
    }
    struct Restored: Sendable {
        let manifest: Manifest
        let directory: URL
    }

    private static let magic = Data("SITOVLT1".utf8)
    private static let maxMetadata = 200_000_000
    private static let maxEncryptedPDF = 36_000_000

    static func write(snapshot: Snapshot, key: SymmetricKey) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let file = folder.appendingPathComponent("SITO-\(formatter.string(from: .now))-\(UUID().uuidString.prefix(4)).sitobackup")
        guard FileManager.default.createFile(atPath: file.path, contents: nil)
        else { throw CloudVaultError.integrity }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        do {
            let manifest = Manifest(version: 1, createdAt: .now,
                                    articles: snapshot.articles, bookmarks: snapshot.bookmarks,
                                    pdfs: snapshot.pdfs.map { PDFInfo(id: $0.id) })
            let encrypted = try VaultCipher.encrypt(VaultCipher.pack(JSONEncoder().encode(manifest)),
                                                    with: key)
            guard encrypted.count < maxMetadata else { throw FileError.tooLarge }
            try handle.write(contentsOf: magic)
            try writeLength(encrypted.count, to: handle)
            try handle.write(contentsOf: encrypted)
            for pdf in snapshot.pdfs {
                let raw = try Data(contentsOf: pdf.url)
                guard raw.count < 35_000_000 else { throw FileError.tooLarge }
                let sealed = try sealPDF(raw, articleID: pdf.id, key: key)
                try writeLength(sealed.count, to: handle)
                try handle.write(contentsOf: sealed)
            }
            try handle.synchronize()
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    static func read(url: URL, key: SymmetricKey) throws -> Restored {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try readExact(8, from: handle) == magic else { throw CloudVaultError.incompatible }
        let metaLength = try readLength(from: handle, limit: maxMetadata)
        let sealed = try readExact(metaLength, from: handle)
        let plain = try VaultCipher.unpack(VaultCipher.decrypt(sealed, with: key))
        let manifest = try JSONDecoder().decode(Manifest.self, from: plain)
        guard manifest.version == 1, manifest.pdfs.count <= 10_000,
              Set(manifest.pdfs.map(\.id)).count == manifest.pdfs.count
        else { throw CloudVaultError.incompatible }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SITO-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for (index, pdf) in manifest.pdfs.enumerated() {
                let length = try readLength(from: handle, limit: maxEncryptedPDF)
                let data = try openPDF(readExact(length, from: handle), articleID: pdf.id, key: key)
                guard data.count < 35_000_000 else { throw FileError.tooLarge }
                try data.write(to: directory.appendingPathComponent("\(index).pdf"), options: .atomic)
            }
            // A truncated or extended file is not a completed backup.
            if let extra = try handle.read(upToCount: 1), !extra.isEmpty {
                throw CloudVaultError.integrity
            }
            return Restored(manifest: manifest, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func writeLength(_ length: Int, to handle: FileHandle) throws {
        var bigEndian = UInt64(length).bigEndian
        try handle.write(contentsOf: withUnsafeBytes(of: &bigEndian) { Data($0) })
    }

    // Bind each PDF's authenticated ciphertext to its article identity. A
    // modified backup cannot silently swap two pages between news stories.
    private static func sealPDF(_ data: Data, articleID: String, key: SymmetricKey) throws -> Data {
        let context = Data(("SITO-portable-PDF-v1:" + articleID).utf8)
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: context).combined
        else { throw CloudVaultError.integrity }
        return combined
    }

    private static func openPDF(_ data: Data, articleID: String, key: SymmetricKey) throws -> Data {
        let context = Data(("SITO-portable-PDF-v1:" + articleID).utf8)
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key,
                                    authenticating: context)
        } catch { throw CloudVaultError.badRecoveryKey }
    }

    private static func readLength(from handle: FileHandle, limit: Int) throws -> Int {
        let raw = try readExact(8, from: handle)
        var value: UInt64 = 0
        for byte in raw { value = (value << 8) | UInt64(byte) }
        guard value > 0, value <= UInt64(limit) else { throw CloudVaultError.integrity }
        return Int(value)
    }

    private static func readExact(_ count: Int, from handle: FileHandle) throws -> Data {
        var output = Data()
        while output.count < count {
            guard let bytes = try handle.read(upToCount: count - output.count), !bytes.isEmpty
            else { throw CloudVaultError.integrity }
            output.append(bytes)
        }
        return output
    }
}
