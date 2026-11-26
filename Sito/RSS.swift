import Foundation
import Combine

private struct RSSDraft {
    var title = ""
    var description = ""
    var summary = ""
    var link = ""
    var guid = ""
    var date = ""
    var image = ""
    var contentHTML = ""
    var contentIsHTML = true
    var author = ""
    var categories: [String] = []
}

// A dependency-free RSS 2.0 / Atom parser. Retain complete content:encoded
// bodies when publishers include them, separate from short feed summaries.
final class RSSParser: NSObject, XMLParserDelegate {
    private var source: NewsSource!
    private var items: [NewsItem] = []
    private var draft: RSSDraft?
    private var field: String?
    private var fieldText = ""
    private var fieldDepth = 0
    private var depth = 0
    private(set) var parseError: String?

    func parse(_ data: Data, source: NewsSource) -> [NewsItem] {
        self.source = source
        items = []; draft = nil; field = nil; fieldText = ""; depth = 0; parseError = nil
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        if !parser.parse() {
            parseError = parser.parserError?.localizedDescription ?? "Invalid XML"
        }
        if items.isEmpty && parseError != nil {
            // Retry feeds whose namespace declarations are incompatible with
            // the strict XMLParser mode. didStartElement strips prefixes in
            // either mode, so the same field parser can be reused safely.
            items = []; draft = nil; field = nil; fieldText = ""; depth = 0
            let relaxed = XMLParser(data: data)
            relaxed.delegate = self
            relaxed.shouldProcessNamespaces = false
            if relaxed.parse() { parseError = nil }
            else { parseError = relaxed.parserError?.localizedDescription ?? parseError }
        }
        // Some publishers append malformed trailing XML. Retain already
        // completed <item> entries instead of discarding the entire feed.
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        depth += 1
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        if name == "item" || name == "entry" { draft = RSSDraft(); return }
        guard draft != nil else { return }

        if name == "thumbnail" || name == "content" || name == "enclosure" {
            if let raw = attributes["url"], let url = RSSParser.normalizedImage(raw) {
                let medium = attributes["medium"]?.lowercased()
                let type = attributes["type"]?.lowercased() ?? ""
                if name == "thumbnail" || medium == "image" || type.hasPrefix("image/") {
                    if draft?.image.isEmpty == true { draft?.image = url.absoluteString }
                }
            }
        }
        if name == "link", let href = attributes["href"], (attributes["rel"] ?? "alternate") == "alternate" {
            draft?.link = href
        }
        if name == "category", let term = attributes["term"], !term.isEmpty {
            draft?.categories.append(term)
        }
        if field == nil && (["title", "description", "summary", "encoded", "pubdate", "published", "updated", "link", "guid", "id", "category", "creator", "author"].contains(name) ||
            (name == "content" && attributes["url"] == nil && attributes["medium"] == nil)) {
            if name == "content" { draft?.contentIsHTML = attributes["type"]?.lowercased() != "text" }
            field = name; fieldText = ""; fieldDepth = depth
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { fieldText += string }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if field != nil { fieldText += String(data: CDATABlock, encoding: .utf8) ?? "" }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        if let field, field == name, fieldDepth == depth {
            let value = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field {
            case "title": draft?.title = value
            case "description": draft?.description = value
            case "summary": draft?.summary = value
            case "encoded": draft?.contentHTML = value
            case "content": if draft?.contentHTML.isEmpty == true { draft?.contentHTML = value }
            case "creator", "author": draft?.author = value
            case "link": if draft?.link.isEmpty == true { draft?.link = value }
            case "guid", "id": draft?.guid = value
            case "pubdate", "published", "updated": draft?.date = value
            case "category": if !value.isEmpty { draft?.categories.append(value) }
            default: break
            }
            self.field = nil; fieldText = ""
        }
        if (name == "item" || name == "entry"), let d = draft {
            if let url = URL(string: d.link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                let title = RSSParser.clean(d.title)
                let rawSummary = d.description.isEmpty ? d.summary : d.description
                let description = RSSParser.clean(rawSummary, limit: 850)
                let imageString = d.image.isEmpty ? (RSSParser.firstImage(in: rawSummary) ?? RSSParser.firstImage(in: d.contentHTML)) : d.image
                let imageURL = imageString.flatMap { RSSParser.normalizedImage($0) }
                if !title.isEmpty {
                    let identity = d.guid.isEmpty ? url.absoluteString : d.guid
                    var item = NewsItem(id: source.id + "|" + identity,
                                        sourceID: source.id, sourceName: source.name,
                                        section: source.section, title: title, summary: description,
                                        imageURL: imageURL, url: url,
                                        published: RSSParser.date(d.date) ?? Date(timeIntervalSince1970: 0))
                    item.feedCategories = Array(Set(d.categories))
                    if !d.author.isEmpty { item.byline = RSSParser.clean(d.author, limit: 300) }
                    if !d.contentHTML.isEmpty {
                        let full = ArticleTextExtractor.plainText(from: d.contentHTML, isHTML: d.contentIsHTML)
                        if full.count >= 120 {
                            item.fullText = full
                            item.textOrigin = "feed"
                            item.textCapturedAt = .now
                        }
                    }
                    items.append(item.cleanedForArchive())
                }
            }
            draft = nil
        }
        depth -= 1
    }

    static func normalizedImage(_ raw: String) -> URL? {
        let cleaned = raw.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if cleaned.hasPrefix("//") { candidate = "https:" + cleaned }
        else if cleaned.hasPrefix("http://") { candidate = "https://" + String(cleaned.dropFirst(7)) }
        else { candidate = cleaned }
        guard let url = URL(string: candidate), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    static func firstImage(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<img[^>]+src\s*=\s*['\"]([^'\"]+)['\"]"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).replacingOccurrences(of: "&amp;", with: "&")
    }
    static func clean(_ raw: String, limit: Int = 10_000) -> String {
        var text = raw.replacingOccurrences(of: #"(?i)<(br|/p|/div)[^>]*>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        let replacements: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&apos;", "'"),
            ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&rsquo;", "’"), ("&ldquo;", "“"), ("&rdquo;", "”")
        ]
        for (entity, replacement) in replacements { text = text.replacingOccurrences(of: entity, with: replacement) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let r = Range(match.range, in: text), let nr = Range(match.range(at: 1), in: text) else { continue }
                let num = String(text[nr]); let isHex = num.lowercased().hasPrefix("x")
                if let number = UInt32(isHex ? String(num.dropFirst()) : num, radix: isHex ? 16 : 10),
                   let scalar = UnicodeScalar(number) { text.replaceSubrange(r, with: String(scalar)) }
            }
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > limit { return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" }
        return text
    }
    static func date(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: raw) { return d }
        }
        return nil
    }
}

// JSON Feed 1.0/1.1 is a first-class feed format, not a remote service.
// JSON Feed's content_text/content_html contain the actual entry body.
private struct JSONFeedDocument: Decodable {
    struct Entry: Decodable {
        struct Author: Decodable { let name: String? }
        let id: String?
        let url: String?
        let externalURL: String?
        let title: String?
        let summary: String?
        let contentText: String?
        let contentHTML: String?
        let image: String?
        let bannerImage: String?
        let datePublished: String?
        let dateModified: String?
        let tags: [String]?
        let author: Author?
        let authors: [Author]?

        enum CodingKeys: String, CodingKey {
            case id, url, title, summary, image, tags, author, authors
            case externalURL = "external_url"
            case contentText = "content_text"
            case contentHTML = "content_html"
            case bannerImage = "banner_image"
            case datePublished = "date_published"
            case dateModified = "date_modified"
        }
    }
    let version: String?
    let items: [Entry]
}

enum JSONFeedParser {
    static func parse(_ data: Data, source: NewsSource) -> [NewsItem] {
        guard let document = try? JSONDecoder().decode(JSONFeedDocument.self, from: data),
              document.version?.contains("jsonfeed.org/version/1") == true else { return [] }
        return document.items.compactMap { entry in
            guard let address = entry.url ?? entry.externalURL,
                  let url = URL(string: address),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            let body = entry.summary ?? entry.contentText ?? entry.contentHTML ?? ""
            let title = RSSParser.clean(entry.title ?? String(body.prefix(140)), limit: 180)
            guard !title.isEmpty else { return nil }
            let summary = RSSParser.clean(body, limit: 850)
            let image = (entry.image ?? entry.bannerImage).flatMap(RSSParser.normalizedImage)
            var item = NewsItem(id: source.id + "|" + (entry.id ?? url.absoluteString),
                                sourceID: source.id, sourceName: source.name,
                                section: source.section, title: title, summary: summary,
                                imageURL: image, url: url,
                                published: RSSParser.date(entry.datePublished ?? entry.dateModified ?? "")
                                    ?? Date(timeIntervalSince1970: 0))
            item.feedCategories = entry.tags
            let people = (entry.authors ?? (entry.author.map { [$0] } ?? []))
                .compactMap(\.name).filter { !$0.isEmpty }
            if !people.isEmpty { item.byline = people.joined(separator: ", ") }
            if let raw = entry.contentText ?? entry.contentHTML {
                let full = entry.contentText == nil ? ArticleTextExtractor.plainText(from: raw)
                    : ArticleTextExtractor.plainText(from: raw, isHTML: false)
                if full.count >= 120 {
                    item.fullText = full
                    item.textOrigin = "feed"
                    item.textCapturedAt = .now
                }
            }
            return item.cleanedForArchive()
        }
    }
}

// A publisher may redirect its HTTPS feed to an old http:// URL. Follow the
// same destination over HTTPS instead of disabling ATS for every source.
private final class SecureFeedRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, let scheme = target.scheme?.lowercased() else {
            completionHandler(nil); return
        }
        if scheme == "https" { completionHandler(request); return }
        guard scheme == "http", var parts = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
            completionHandler(nil); return
        }
        parts.scheme = "https"
        guard let secure = parts.url else { completionHandler(nil); return }
        var updated = request
        updated.url = secure
        completionHandler(updated)
    }
}

private enum FeedLinkDiscovery {
    static func find(in data: Data, at page: URL) -> URL? {
        let head = String(decoding: data.prefix(180_000), as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive) else { return nil }
        for result in regex.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
            guard let range = Range(result.range, in: head) else { continue }
            let tag = String(head[range])
            let rel = attribute("rel", in: tag)?.lowercased() ?? ""
            let type = attribute("type", in: tag)?.lowercased() ?? ""
            guard rel.split(separator: " ").contains("alternate"),
                  ["application/rss+xml", "application/atom+xml", "application/feed+json", "application/json"]
                    .contains(where: { type.hasPrefix($0) }),
                  let raw = attribute("href", in: tag)?.replacingOccurrences(of: "&amp;", with: "&"),
                  let candidate = URL(string: raw, relativeTo: page)?.absoluteURL,
                  var parts = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else { continue }
            if parts.scheme == "http" { parts.scheme = "https" }
            if parts.scheme == "https", let url = parts.url { return url }
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*['\"]([^'\"]+)['\"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }
}

// The site publishes no established RSS endpoint. Its public confirmed/official
// HTML listing is intentionally parsed conservatively: unknown statuses are excluded.
final class RaspadParser {
    func parse(_ data: Data, source: NewsSource) -> [NewsItem] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        let pattern = #"<li\s+([^>]+)>(.*?)</li>"#
        let parts = matches(pattern, in: html)
        var day = 0
        var month = 0
        var output: [NewsItem] = []

        for part in parts {
            guard let attributes = capture(part, at: 1, in: html),
                  let body = capture(part, at: 2, in: html) else { continue }
            if attributes.contains(#"class="dayhdr""#) {
                let text = RSSParser.clean(body)
                if let date = matches(#"(\d{1,2})\.\s*([A-Za-zčćžđšČĆŽĐŠ]+)"#, in: text).first,
                   let rawDay = capture(date, at: 1, in: text),
                   let name = capture(date, at: 2, in: text),
                   let number = Int(rawDay), let index = Self.months[name.lowercased()] {
                    day = number; month = index
                }
                continue
            }
            guard attributes.contains(#"class="item""#),
                  let idMatch = matches(#"id="(c-[a-zA-Z0-9]+)""#, in: attributes).first,
                  let key = capture(idMatch, at: 1, in: attributes),
                  let statusMatch = matches(#"<span\s+class="st\s+(zvanicno|potvrdjeno)"[^>]*>"#, in: body).first,
                  let rawStatus = capture(statusMatch, at: 1, in: body),
                  let title = extractDiv("title", from: body), !title.isEmpty else { continue }

            let status = rawStatus == "zvanicno" ? "zvanično" : "potvrđeno"
            let description = extractDiv("text", from: body) ?? ""
            let linkHTML = extractDivHTML("srcline", from: body) ?? ""
            let link = matches(#"<a\s+href="(https://[^"]+)""#, in: linkHTML).first
                .flatMap { capture($0, at: 1, in: linkHTML) }
            let destination = link.flatMap(URL.init(string:))
                ?? URL(string: "https://raspadsistema.com/?status=potvrdjeno#" + key)!
            let rawTime = extractDiv("time", from: body) ?? "12:00"
            let date = Self.date(day: day, month: month, time: rawTime)

            var article = NewsItem(id: "raspad|" + key, sourceID: source.id,
                                   sourceName: source.name, section: .serbia,
                                   title: title, summary: description, imageURL: nil,
                                   url: destination, published: date)
            article.sourceStatus = status
            output.append(article)
        }
        return output
    }

    private static let months: [String: Int] = [
        "januar": 1, "februar": 2, "mart": 3, "april": 4, "maj": 5, "jun": 6,
        "jul": 7, "avgust": 8, "septembar": 9, "oktobar": 10, "novembar": 11, "decembar": 12
    ]

    private static func date(day: Int, month: Int, time: String) -> Date {
        let current = Date()
        let zone = TimeZone(identifier: "Europe/Belgrade") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let comps = time.split(separator: ":")
        guard day >= 1, day <= 31, month >= 1, month <= 12, comps.count == 2 else { return current }
        let year = calendar.component(.year, from: current)
        let dc = DateComponents(timeZone: zone, year: year, month: month, day: day,
                                hour: Int(comps[0]) ?? 12, minute: Int(comps[1]) ?? 0)
        guard let preliminary = calendar.date(from: dc) else { return current }
        if preliminary > current.addingTimeInterval(2 * 86400) {
            var prior = dc; prior.year = year - 1
            return calendar.date(from: prior) ?? preliminary
        }
        return preliminary
    }

    private func extractDiv(_ name: String, from body: String) -> String? {
        extractDivHTML(name, from: body).map { RSSParser.clean($0, limit: 900) }
    }
    private func extractDivHTML(_ name: String, from body: String) -> String? {
        let pattern = #"<div\s+class=""# + NSRegularExpression.escapedPattern(for: name) + #""[^>]*>(.*?)</div>"#
        guard let result = matches(pattern, in: body).first else { return nil }
        return capture(result, at: 1, in: body)
    }
    private func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private func capture(_ result: NSTextCheckingResult, at index: Int, in text: String) -> String? {
        guard result.numberOfRanges > index, let r = Range(result.range(at: index), in: text) else { return nil }
        return String(text[r])
    }
}

// Only fetches open-graph image metadata when a feed has no usable media URL.
// Results (including misses) are memoized for the current app process.
actor ThumbnailResolver {
    static let shared = ThumbnailResolver()
    private enum Match { case found(URL), missing }
    private var results: [String: Match] = [:]

    func resolve(for articleURL: URL) async -> URL? {
        let key = articleURL.absoluteString
        if let result = results[key] {
            switch result { case .found(let url): return url; case .missing: return nil }
        }
        guard articleURL.scheme == "https" else { results[key] = .missing; return nil }
        var request = URLRequest(url: articleURL)
        request.timeoutInterval = 12
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  data.count < 8_000_000 else {
                results[key] = .missing; return nil
            }
            let html = String(decoding: data.prefix(262_144), as: UTF8.self)
            let head = String(html.prefix(120_000))
            guard let regex = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: .caseInsensitive) else {
                results[key] = .missing; return nil
            }
            for match in regex.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
                guard let r = Range(match.range, in: head) else { continue }
                let tag = String(head[r])
                let name = Self.attribute("property", in: tag) ?? Self.attribute("name", in: tag) ?? ""
                guard ["og:image", "og:image:secure_url", "twitter:image", "twitter:image:src"].contains(name.lowercased()),
                      let image = Self.attribute("content", in: tag),
                      let imageURL = RSSParser.normalizedImage(image) else { continue }
                results[key] = .found(imageURL)
                return imageURL
            }
        } catch { }
        results[key] = .missing
        return nil
    }

    private static func attribute(_ name: String, in element: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*['\"]([^'\"]+)['\"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: element, range: NSRange(element.startIndex..., in: element)),
              let r = Range(match.range(at: 1), in: element) else { return nil }
        return String(element[r])
    }
}

private struct CacheEnvelope: Codable {
    var items: [NewsItem]
    var updated: Date?
}

struct SourceCheck: Identifiable, Sendable {
    let id: String
    let name: String
    let checkedAt: Date
    let count: Int
    let failure: String?
}

struct TextCaptureSourceStat: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var attempts: Int
    var completed: Int
}

struct TextCaptureReport: Codable, Sendable {
    let finishedAt: Date
    let automatic: Bool
    let attempted: Int
    let completed: Int
}

private struct FeedLoad: Sendable {
    let source: NewsSource
    let entries: [NewsItem]
    let failure: String?
    var wasCancelled = false
}

@MainActor
final class NewsFeed: ObservableObject {
    // Refresh belongs to the feed service, not to the lifespan of a
    // SwiftUI ScrollView. A pull-to-refresh task can be cancelled when its
    // view changes identity; that must not cancel all publisher requests.
    private struct RefreshJob {
        let id: UUID
        let sourceSignature: String
        let task: Task<Void, Never>
    }
    private var refreshJob: RefreshJob?
    @Published private(set) var items: [NewsItem] = []
    @Published private(set) var saved: [String: NewsItem] = [:]
    @Published private(set) var archive: [String: NewsItem] = [:]
    @Published private(set) var archiveCount = 0
    @Published private(set) var archiveFullTextCount = 0
    @Published private(set) var archiveRevision = 0
    @Published private(set) var archiveError: String?
    @Published private(set) var completeArticles: [String: StoredFullArticle] = [:]
    @Published private(set) var loading = false
    @Published private(set) var textCaptureActive = false
    @Published private(set) var textCaptureDone = 0
    @Published private(set) var textCaptureTarget = 0
    @Published private(set) var lastTextCapture: TextCaptureReport?
    @Published private(set) var textCaptureStats: [String: TextCaptureSourceStat] = [:]
    private var stopTextCapture = false
    @Published private(set) var failedSources: [String] = []
    @Published private(set) var sourceHealth: [String: SourceCheck] = [:]
    @Published private(set) var refreshRevision = 0
    @Published private(set) var lastUpdated: Date?
    private var topicLabels: [String: Set<NewsTopic>] = [:]
    private var archiveDB: ArchiveStore?
    private let visibleHistoryLimit = 2500

    init() {
        let defaults = UserDefaults.standard
        lastTextCapture = defaults.data(forKey: "archiveCaptureLast")
            .flatMap { try? JSONDecoder().decode(TextCaptureReport.self, from: $0) }
        textCaptureStats = defaults.data(forKey: "archiveCaptureSources")
            .flatMap { try? JSONDecoder().decode([String: TextCaptureSourceStat].self, from: $0) } ?? [:]
        do { archiveDB = try ArchiveStore(url: path("news-history.sqlite")) }
        catch { archiveError = error.localizedDescription }
        if let data = try? Data(contentsOf: path("feed-cache.json")),
           let decoded = try? JSONDecoder().decode(CacheEnvelope.self, from: data) {
            items = decoded.items; lastUpdated = decoded.updated
        }
        if let data = try? Data(contentsOf: path("saved-stories.json")),
           let decoded = try? JSONDecoder().decode([String: NewsItem].self, from: data) { saved = decoded }
        if let data = try? Data(contentsOf: path("archive.json")),
           let decoded = try? JSONDecoder().decode([String: NewsItem].self, from: data) {
            if let archiveDB {
                do {
                    try archiveDB.insert(Array(decoded.values))
                    // Keep the original file as a recoverable migration copy.
                    // Storage cleanup removes it only after explicit confirmation.
                    if !FileManager.default.fileExists(atPath: path("archive-migration-copy.json").path) {
                        try FileManager.default.moveItem(at: path("archive.json"),
                                                         to: path("archive-migration-copy.json"))
                    }
                } catch {
                    archiveError = error.localizedDescription
                    self.archiveDB = nil
                    archive = decoded
                }
            } else { archive = decoded }
        }
        if let data = try? Data(contentsOf: path("complete-index.json")),
           let decoded = try? JSONDecoder().decode([String: StoredFullArticle].self, from: data) { completeArticles = decoded }
        if let archiveDB,
           let data = try? Data(contentsOf: path("archive-pending.json")),
           let pending = try? JSONDecoder().decode([String: NewsItem].self, from: data) {
            do {
                try archiveDB.insert(Array(pending.values))
                try FileManager.default.removeItem(at: path("archive-pending.json"))
            } catch { archiveError = error.localizedDescription }
        }
        refreshArchiveCache()
        rebuildTopics()
    }

    private func refreshArchiveCache() {
        guard let archiveDB else {
            archiveCount = archive.count
            archiveFullTextCount = archive.values.filter(\.hasFullText).count
            return
        }
        let latest = (try? archiveDB.latest(limit: visibleHistoryLimit)) ?? []
        var cache = Dictionary(uniqueKeysWithValues: latest.map { ($0.id, $0) })
        // The hidden game and Saved screen still receive a recent slice.
        // Explicitly saved articles are always visible, even when years old.
        for id in Set(saved.keys).union(completeArticles.keys) {
            if cache[id] == nil, let item = try? archiveDB.article(id: id) { cache[id] = item }
        }
        archive = cache
        archiveCount = archiveDB.count
        archiveFullTextCount = archiveDB.fullTextCount
    }

    private func keepInArchive(_ articles: [NewsItem]) {
        guard !articles.isEmpty else { return }
        if let archiveDB {
            do {
                let pending = (try? Data(contentsOf: path("archive-pending.json")))
                    .flatMap { try? JSONDecoder().decode([String: NewsItem].self, from: $0) } ?? [:]
                try archiveDB.insert(Array(pending.values) + articles)
                if !pending.isEmpty { try? FileManager.default.removeItem(at: path("archive-pending.json")) }
                refreshArchiveCache()
                archiveError = nil
            } catch {
                archiveError = error.localizedDescription
                // Keep failed writes on disk so they survive a force-quit.
                var pending = (try? Data(contentsOf: path("archive-pending.json")))
                    .flatMap { try? JSONDecoder().decode([String: NewsItem].self, from: $0) } ?? [:]
                for item in articles { pending[item.id] = item }
                write(pending, name: "archive-pending.json")
                for item in articles { archive[item.id] = item.merging(older: archive[item.id] ?? item) }
            }
        } else {
            for item in articles { archive[item.id] = item.merging(older: archive[item.id] ?? item) }
            archiveCount = archive.count
            archiveFullTextCount = archive.values.filter(\.hasFullText).count
            write(archive, name: "archive.json")
        }
        archiveRevision += 1
    }

    var archiveStorageBytes: Int64 {
        if let archiveDB {
            return archiveDB.byteSize + sizeOfFile("archive-migration-copy.json")
        }
        return sizeOfFile("archive.json")
    }

    var pdfStorageBytes: Int64 {
        completeArticles.values.reduce(Int64(0)) { size, article in
            let attrs = try? FileManager.default.attributesOfItem(atPath: completePDFURL(for: article).path)
            return size + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private func sizeOfFile(_ filename: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path(filename).path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    var archiveSourceNames: [String] {
        if let archiveDB { return (try? archiveDB.sourceNames()) ?? [] }
        return Array(Set(archivedItems.map(\.sourceName))).sorted()
    }

    private var protectedArchiveIDs: Set<String> { Set(saved.keys).union(completeArticles.keys) }

    func removableCount(olderThan date: Date?, sourceName: String?) -> Int {
        if let archiveDB {
            return (try? archiveDB.eligibleCount(olderThan: date, sourceName: sourceName,
                protecting: protectedArchiveIDs)) ?? 0
        }
        return archive.values.filter { item in
            !protectedArchiveIDs.contains(item.id) && (date.map { item.published < $0 } ?? true) &&
            (sourceName == nil || item.sourceName == sourceName)
        }.count
    }

    @discardableResult func pruneArchive(olderThan date: Date?, sourceName: String?) throws -> Int {
        let removed: Int
        if let archiveDB {
            removed = try archiveDB.prune(olderThan: date, sourceName: sourceName,
                                           protecting: protectedArchiveIDs)
            // The legacy copy belongs to this database, not a separate backup.
            // A manual cleanup authorizes its removal after successful migration.
            if FileManager.default.fileExists(atPath: path("archive-migration-copy.json").path) {
                try FileManager.default.removeItem(at: path("archive-migration-copy.json"))
            }
            refreshArchiveCache()
        } else {
            let ids = archive.values.filter { item in
                !protectedArchiveIDs.contains(item.id) && (date.map { item.published < $0 } ?? true) &&
                (sourceName == nil || item.sourceName == sourceName)
            }.map(\.id)
            ids.forEach { archive.removeValue(forKey: $0) }
            removed = ids.count
            archiveCount = archive.count
            archiveFullTextCount = archive.values.filter(\.hasFullText).count
            write(archive, name: "archive.json")
        }
        archiveRevision += 1
        return removed
    }

    func searchArchive(_ query: String) -> [NewsItem] {
        if let archiveDB { return (try? archiveDB.search(query)) ?? [] }
        if query.isEmpty { return archivedItems }
        return archivedItems.filter { $0.title.localizedCaseInsensitiveContains(query) ||
            $0.summary.localizedCaseInsensitiveContains(query) ||
            $0.sourceName.localizedCaseInsensitiveContains(query) }
    }

    func matchesTopic(_ item: NewsItem, topic: NewsTopic) -> Bool {
        if topic == .all { return true }
        let labels = topicLabels[item.id] ?? NewsTaxonomy.labels(for: item)
        return labels.contains(topic)
    }

    // A recent prolific publisher should not occupy every card. Keep news
    // roughly chronological in six-hour windows, but interleave publishers
    // inside each window and cap their contribution to the combined feed.
    // Selecting one publisher bypasses this mixer in HomeView.
    func mixedStories(_ articles: [NewsItem]) -> [NewsItem] {
        let sorted = articles.sorted { $0.published > $1.published }
        let sourceCount = max(1, Set(sorted.map(\.sourceID)).count)
        let perSourceLimit = sourceCount == 1 ? 700 : max(20, 180 / sourceCount)
        var counts: [String: Int] = [:]
        var windows: [Int: [NewsItem]] = [:]
        for article in sorted {
            let used = counts[article.sourceID, default: 0]
            guard used < perSourceLimit else { continue }
            counts[article.sourceID] = used + 1
            let window = Int(article.published.timeIntervalSince1970 / 21_600)
            windows[window, default: []].append(article)
        }
        var output: [NewsItem] = []
        for window in windows.keys.sorted(by: >) {
            guard let group = windows[window] else { continue }
            let queues = Dictionary(grouping: group, by: \.sourceID)
            let sourceOrder = queues.keys.sorted { left, right in
                let a = queues[left]?.first?.published ?? .distantPast
                let b = queues[right]?.first?.published ?? .distantPast
                return a == b ? left < right : a > b
            }
            var offsets: [String: Int] = [:]
            var remaining = group.count
            while remaining > 0 {
                for source in sourceOrder {
                    let offset = offsets[source, default: 0]
                    guard let queue = queues[source], offset < queue.count else { continue }
                    output.append(queue[offset])
                    offsets[source] = offset + 1
                    remaining -= 1
                }
            }
        }
        return output
    }

    private func rebuildTopics() {
        topicLabels = [:]
        for item in items { topicLabels[item.id] = NewsTaxonomy.labels(for: item) }
    }

    func isSaved(_ item: NewsItem) -> Bool { saved[item.id] != nil }
    func toggleSaved(_ item: NewsItem) {
        if saved[item.id] == nil { saved[item.id] = archivedArticle(id: item.id) ?? item }
        else { saved.removeValue(forKey: item.id) }
        write(saved, name: "saved-stories.json")
        keepInArchive([item])
    }

    var archivedItems: [NewsItem] {
        if let archiveDB { return (try? archiveDB.all()) ?? [] }
        return archive.values.sorted { $0.published > $1.published }
    }

    func archivedArticle(id: String) -> NewsItem? {
        if let archiveDB { return (try? archiveDB.article(id: id)) ?? archive[id] }
        return archive[id]
    }

    // Reading is always local first; if only a feed preview exists we make
    // one polite request to the original HTTPS article, without images.
    @discardableResult func fetchFullText(for article: NewsItem) async -> NewsItem {
        let current = archivedArticle(id: article.id) ?? article
        if current.hasFullText { return current }
        let result = await ArticleTextExtractor.fetch(current)
        if Task.isCancelled { return current }
        var updated = current
        updated.textCheckedAt = .now
        if let text = result?.text, !text.isEmpty {
            updated.fullText = text
            updated.textCapturedAt = .now
            updated.textOrigin = "original"
        }
        if let byline = result?.author, !byline.isEmpty { updated.byline = byline }
        if let canonical = result?.canonical { updated.canonicalURL = canonical }
        if let language = result?.language { updated.languageCode = language }
        if let modified = result?.modified { updated.modifiedAt = modified }
        keepInArchive([updated])
        if saved[article.id] != nil {
            saved[article.id] = archivedArticle(id: article.id) ?? updated
            write(saved, name: "saved-stories.json")
        }
        return archivedArticle(id: article.id) ?? updated
    }

    // At most 24 automatic original-page requests per day, in small batches
    // separated by 45 minutes. User-initiated batches are independent.
    // Wi-Fi is the default for automatic enrichment; the switch is in the
    // Advanced archive settings. Never run on Low Power Mode.
    func autoCompleteMissingText(wifiAvailable: Bool, limit: Int = 8) async {
        let defaults = UserDefaults.standard
        guard (defaults.object(forKey: "archiveAutoComplete") as? Bool ?? true),
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              !(defaults.object(forKey: "archiveAutoWiFiOnly") as? Bool ?? true) || wifiAvailable,
              !textCaptureActive else { return }
        let today = Date()
        if let previous = defaults.object(forKey: "archiveAutoBudgetDay") as? Date {
            if !Calendar.current.isDate(previous, inSameDayAs: today) {
                defaults.set(today, forKey: "archiveAutoBudgetDay")
                defaults.set(0, forKey: "archiveAutoBudgetUsed")
            }
        } else {
            defaults.set(today, forKey: "archiveAutoBudgetDay")
            defaults.set(0, forKey: "archiveAutoBudgetUsed")
        }
        let remaining = max(0, 24 - defaults.integer(forKey: "archiveAutoBudgetUsed"))
        guard remaining > 0, limit > 0,
              today.timeIntervalSince(defaults.object(forKey: "archiveAutoLastBatch") as? Date ?? .distantPast) >= 45 * 60 else { return }
        defaults.set(today, forKey: "archiveAutoLastBatch")
        await completeMissingText(limit: min(limit, remaining), automatic: true)
    }

    // An explicit batch in Advanced Options gradually fills older records.
    // Unsuccessful pages are retried no more than monthly by the queue.
    func completeMissingText(limit: Int = 40, automatic: Bool = false) async {
        guard !textCaptureActive else { return }
        let candidates = (try? archiveDB?.missingText(limit: limit)) ?? archive.values
            .filter { !$0.hasFullText && ($0.textCheckedAt ?? .distantPast) < Date().addingTimeInterval(-30 * 86_400) }
            .sorted { $0.published > $1.published }.prefix(limit).map { $0 }
        guard !candidates.isEmpty else { return }
        textCaptureActive = true
        stopTextCapture = false
        textCaptureDone = 0
        textCaptureTarget = candidates.count
        var successful = 0
        defer {
            textCaptureActive = false
            let report = TextCaptureReport(finishedAt: .now, automatic: automatic,
                                           attempted: textCaptureDone, completed: successful)
            lastTextCapture = report
            if let saved = try? JSONEncoder().encode(report) {
                UserDefaults.standard.set(saved, forKey: "archiveCaptureLast")
            }
            if let saved = try? JSONEncoder().encode(textCaptureStats) {
                UserDefaults.standard.set(saved, forKey: "archiveCaptureSources")
            }
            archiveRevision += 1 // triggers a deferred automatic backup, if due
        }
        for article in candidates {
            if Task.isCancelled || stopTextCapture { break }
            let outcome = await fetchFullText(for: article)
            let completed = outcome.hasFullText
            if completed { successful += 1 }
            var stat = textCaptureStats[article.sourceID]
                ?? TextCaptureSourceStat(id: article.sourceID, name: article.sourceName,
                                         attempts: 0, completed: 0)
            stat.name = article.sourceName
            stat.attempts += 1
            if completed { stat.completed += 1 }
            textCaptureStats[article.sourceID] = stat
            textCaptureDone += 1
            if automatic {
                let defaults = UserDefaults.standard
                defaults.set(defaults.integer(forKey: "archiveAutoBudgetUsed") + 1,
                             forKey: "archiveAutoBudgetUsed")
            }
            do { try await Task.sleep(nanoseconds: automatic ? 1_200_000_000 : 350_000_000) }
            catch { break }
        }
    }

    func stopCompletingText() { stopTextCapture = true }

    func completeArchiveForBackup() throws -> [NewsItem] {
        if let archiveDB {
            var stored = Dictionary(uniqueKeysWithValues: try archiveDB.all().map { ($0.id, $0) })
            if let pendingData = try? Data(contentsOf: path("archive-pending.json")),
               let pending = try? JSONDecoder().decode([String: NewsItem].self, from: pendingData) {
                for article in pending.values {
                    stored[article.id] = article.merging(older: stored[article.id] ?? article)
                }
            }
            return stored.values.sorted { $0.published > $1.published }
        }
        return archivedItems.map { $0.cleanedForArchive() }
    }

    var completeItems: [StoredFullArticle] { completeArticles.values.sorted { $0.savedAt > $1.savedAt } }

    func completePDFURL(for entry: StoredFullArticle) -> URL {
        fullArticlesFolder().appendingPathComponent(entry.filename)
    }

    func saveCompletePDF(_ data: Data, for item: NewsItem) throws -> URL {
        guard data.count < 35_000_000 else { throw BackupError.tooLarge }
        let filename = UUID().uuidString + ".pdf"
        let url = fullArticlesFolder().appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        // Replacing a personal saved copy removes only the obsolete copy for this same article.
        if let previous = completeArticles[item.id] {
            try? FileManager.default.removeItem(at: completePDFURL(for: previous))
        }
        completeArticles[item.id] = StoredFullArticle(id: item.id, title: item.title,
                  sourceName: item.sourceName, originalURL: item.url,
                  filename: filename, savedAt: .now)
        write(completeArticles, name: "complete-index.json")
        keepInArchive([item])
        return url
    }

    func exportJSON() throws -> URL {
        let backup = LocalBackup(formatVersion: 1, createdAt: .now,
                                 articles: try completeArchiveForBackup(),
                                 savedArticles: saved.values.map {
                                     (archivedArticle(id: $0.id) ?? $0).cleanedForArchive()
                                 })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("SITO-archive-\(Self.stamp()).json")
        try data.write(to: file, options: .atomic)
        return file
    }

    func importJSON(_ url: URL) throws -> Int {
        let permitted = url.startAccessingSecurityScopedResource()
        defer { if permitted { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count < 200_000_000 else { throw BackupError.tooLarge }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LocalBackup.self, from: data)
        guard backup.formatVersion == 1 else { throw BackupError.unsupportedFormat }
        let oldCount = archiveCount
        for item in backup.savedArticles { saved[item.id] = item.cleanedForArchive() }
        write(saved, name: "saved-stories.json")
        keepInArchive(backup.articles + backup.savedArticles)
        return archiveCount - oldCount
    }

    func mergeCloudBackup(articles: [NewsItem], bookmarks: [NewsItem]) throws {
        if let archiveDB {
            try archiveDB.insert(articles + bookmarks)
        } else {
            for item in articles + bookmarks { archive[item.id] = item.merging(older: archive[item.id] ?? item) }
            write(archive, name: "archive.json")
        }
        for item in bookmarks { saved[item.id] = (archivedArticle(id: item.id) ?? item).merging(older: saved[item.id] ?? item) }
        write(saved, name: "saved-stories.json")
        refreshArchiveCache()
        archiveRevision += 1
    }

    func restoreCloudPDF(_ data: Data, article: NewsItem) throws {
        if let existing = completeArticles[article.id],
           FileManager.default.fileExists(atPath: completePDFURL(for: existing).path) { return }
        _ = try saveCompletePDF(data, for: article)
    }

    enum BackupError: LocalizedError {
        case tooLarge, unsupportedFormat
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Archive import exceeds 200 MB, or a saved PDF exceeds 35 MB."
            case .unsupportedFormat: return "Unsupported backup format."
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; return f.string(from: .now)
    }

    func refresh(sources: [NewsSource]) async {
        let requested = sources.map { "\($0.id):\($0.feed ?? "")" }.sorted().joined(separator: "|")
        let job: RefreshJob
        if let ongoing = refreshJob {
            job = ongoing
        } else {
            // Task.init creates an unstructured task. In contrast to a task
            // group child, it is not cancelled when the initiating SwiftUI
            // .refreshable handler disappears.
            let newJob = RefreshJob(id: UUID(), sourceSignature: requested, task: Task {
                await self.performRefresh(sources: sources)
            })
            refreshJob = newJob
            job = newJob
        }
        await job.task.value
        if refreshJob?.id == job.id { refreshJob = nil }
        // If the selection changed while another refresh ran, fetch the
        // requested publishers instead of silently keeping the old result.
        if job.sourceSignature != requested && !Task.isCancelled {
            await refresh(sources: sources)
        }
    }

    private func performRefresh(sources: [NewsSource]) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let available = sources.filter { $0.feed != nil || $0.id == "raspad" }
        guard !available.isEmpty else {
            items = []; topicLabels = [:]; failedSources = []; sourceHealth = [:]; refreshRevision += 1
            return
        }

        var fetched: [NewsItem] = []
        var bad: [String] = []
        var checks: [String: SourceCheck] = [:]
        // Four publishers at a time limits connection pressure without
        // delaying refresh as much as fully sequential downloads.
        for start in stride(from: 0, to: available.count, by: 4) {
            let batch = Array(available[start..<min(start + 4, available.count)])
            await withTaskGroup(of: FeedLoad.self) { group in
                for source in batch {
                    group.addTask { await Self.load(source) }
                }
                for await result in group {
                    if result.wasCancelled {
                        // Cancellation is not evidence that the publisher is
                        // unavailable; record it for diagnostics, but never
                        // count it as a failed source in the feed banner.
                        checks[result.source.id] =
                            SourceCheck(id: result.source.id, name: result.source.name,
                                        checkedAt: .now, count: 0,
                                        failure: "Cancelled locally (-999), not a publisher error")
                        continue
                    }
                    let check = SourceCheck(id: result.source.id, name: result.source.name,
                                            checkedAt: .now, count: result.entries.count,
                                            failure: result.failure)
                    checks[result.source.id] = check
                    if result.failure == nil {
                        fetched.append(contentsOf: result.entries)
                    } else {
                        bad.append(result.source.name)
                    }
                }
            }
        }

        let successfulIDs = Set(fetched.map(\.sourceID))
        let failedIDs = Set(available.map(\.id)).subtracting(successfulIDs)
        // Saved history is the safety net even if a failed source was pushed
        // out of the previous 350-item on-screen feed.
        let oldForFailedSources = archive.values.filter { failedIDs.contains($0.sourceID) }
            .sorted { $0.published > $1.published }
            .prefix(160)
        let previousForFailed = items.filter { failedIDs.contains($0.sourceID) }
        var unique: [String: NewsItem] = [:]
        for item in fetched + previousForFailed + Array(oldForFailedSources) {
            // Aggregator notes deserve their own source identity even if the
            // linked publisher article is present in an editorial RSS feed.
            let dedupeKey = item.sourceID == "raspad" ? item.id :
                (item.url.absoluteString.components(separatedBy: "?").first ?? item.id)
            if unique[dedupeKey] == nil { unique[dedupeKey] = item }
        }
        var retainedPerSource: [String: Int] = [:]
        items = unique.values.sorted { $0.published > $1.published }.filter { article in
            let used = retainedPerSource[article.sourceID, default: 0]
            guard used < 120 else { return false }
            retainedPerSource[article.sourceID] = used + 1
            return true
        }.prefix(700).map { $0 }
        rebuildTopics()
        keepInArchive(fetched)
        failedSources = bad.sorted()
        sourceHealth = checks
        if !fetched.isEmpty { lastUpdated = .now }
        write(CacheEnvelope(items: items, updated: lastUpdated), name: "feed-cache.json")
        refreshRevision += 1
        // Foreground/background entry points decide whether automatic text
        // enrichment may run, using actual connectivity and power conditions.
    }

    nonisolated private static func load(_ source: NewsSource) async -> FeedLoad {
        let address = source.id == "raspad" ? "https://raspadsistema.com/?status=potvrdjeno" : source.feed
        guard let address, let url = URL(string: address) else {
            return FeedLoad(source: source, entries: [], failure: "Invalid URL")
        }
        // Keep App Transport Security enabled. The delegate upgrades any
        // legacy http:// redirect to HTTPS before iOS follows it.
        let session = URLSession(configuration: .ephemeral,
                                 delegate: SecureFeedRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 16)
        request.setValue(source.id == "raspad" ? "text/html" :
                         "application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml, text/html",
                         forHTTPHeaderField: "Accept")
        request.setValue("SITO/0.9.4 (personal feed reader; iOS)", forHTTPHeaderField: "User-Agent")
        do {
            var (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return FeedLoad(source: source, entries: [], failure: "No HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                return FeedLoad(source: source, entries: [], failure: "HTTP \(http.statusCode)")
            }
            guard data.count < 5_000_000 else {
                return FeedLoad(source: source, entries: [], failure: "Feed larger than 5 MB")
            }
            if source.id == "raspad" {
                let entries = RaspadParser().parse(data, source: source)
                return FeedLoad(source: source, entries: entries,
                                failure: entries.isEmpty ? "Site format changed or no confirmed entries" : nil)
            }
            var contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let opening = String(decoding: data.prefix(180), as: UTF8.self).lowercased()
            let looksXML = opening.contains("<?xml") || opening.contains("<rss") || opening.contains("<feed")
            if !looksXML && (contentType.contains("text/html") || opening.contains("<!doctype html") || opening.contains("<html")) {
                guard let link = FeedLinkDiscovery.find(in: data, at: response.url ?? url) else {
                    return FeedLoad(source: source, entries: [],
                                    failure: "No RSS, Atom or JSON Feed link on this page")
                }
                var discoveryRequest = URLRequest(url: link, cachePolicy: .reloadIgnoringLocalCacheData,
                                                  timeoutInterval: 16)
                discoveryRequest.setValue("application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml", forHTTPHeaderField: "Accept")
                discoveryRequest.setValue("SITO/0.9.4 (personal feed reader; iOS)", forHTTPHeaderField: "User-Agent")
                (data, response) = try await session.data(for: discoveryRequest)
                guard let discoveredResponse = response as? HTTPURLResponse,
                      (200...299).contains(discoveredResponse.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    return FeedLoad(source: source, entries: [], failure: "Feed discovery HTTP \(code)")
                }
                guard data.count < 5_000_000 else {
                    return FeedLoad(source: source, entries: [], failure: "Feed larger than 5 MB")
                }
                contentType = discoveredResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            }
            if contentType.contains("json") || String(decoding: data.prefix(64), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                let entries = JSONFeedParser.parse(data, source: source)
                return FeedLoad(source: source, entries: entries,
                                failure: entries.isEmpty ? "No readable JSON Feed articles" : nil)
            }
            let parser = RSSParser()
            let entries = parser.parse(data, source: source)
            return FeedLoad(source: source, entries: entries,
                            failure: entries.isEmpty ? (parser.parseError ?? "No readable RSS articles") : nil)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return FeedLoad(source: source, entries: [],
                                failure: "Request cancelled (not a source error)",
                                wasCancelled: true)
            }
            let reason: String
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut: reason = "Timeout (16 s)"
                case .notConnectedToInternet: reason = "No internet connection"
                case .cannotFindHost, .dnsLookupFailed: reason = "DNS / host unavailable"
                case .secureConnectionFailed, .serverCertificateUntrusted: reason = "TLS / certificate error"
                case .appTransportSecurityRequiresSecureConnection: reason = "ATS blocked an insecure redirect; use an HTTPS feed URL"
                case .networkConnectionLost: reason = "Connection interrupted"
                default: reason = "Network \(urlError.errorCode): \(urlError.localizedDescription)"
                }
            } else {
                reason = error.localizedDescription
            }
            return FeedLoad(source: source, entries: [], failure: reason)
        }
    }

    private func path(_ filename: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Sito", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }
    private func fullArticlesFolder() -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SITO-Full-Articles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func write<T: Encodable>(_ data: T, name: String) {
        if let encoded = try? JSONEncoder().encode(data) { try? encoded.write(to: path(name), options: .atomic) }
    }
}
