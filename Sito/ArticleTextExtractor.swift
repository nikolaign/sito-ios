import Foundation

// Best-effort original-page text, with no WebView, external readability service,
// image download or persisted HTML. Publisher-provided full feeds take priority.
// A paywall, client-side page, or weak extraction yields a preview-only record.
struct ExtractedArticle: Sendable {
    var text: String?
    var author: String?
    var canonical: URL?
    var language: String?
    var modified: Date?
}

enum ArticleTextExtractor {
    static func fetch(_ item: NewsItem) async -> ExtractedArticle? {
        guard var parts = URLComponents(url: item.url, resolvingAgainstBaseURL: false),
              parts.host != nil, ["https", "http"].contains(parts.scheme?.lowercased() ?? "") else { return nil }
        parts.scheme = "https"
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("SITO/0.9.4 (private text archive; iOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode), data.count <= 6_000_000,
                  (http.value(forHTTPHeaderField: "Content-Type") ?? "text/html").lowercased().contains("html") else { return nil }
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return extract(html, baseURL: http.url ?? url, preview: item.summary)
        } catch { return nil }
    }

    static func extract(_ html: String, baseURL: URL, preview: String) -> ExtractedArticle {
        var result = ExtractedArticle(text: nil, author: meta("author", in: html), canonical: nil,
                                      language: nil, modified: nil)
        result.author = result.author ?? meta("article:author", in: html)
        result.language = meta("og:locale", in: html) ?? capture(#"<html\b[^>]*lang\s*=\s*['\"]([^'\"]+)"#, in: html)
        result.modified = (meta("article:modified_time", in: html) ?? meta("dateModified", in: html))
            .flatMap(RSSParser.date)
        if let href = capture(#"<link\b(?=[^>]*\brel\s*=\s*['\"]canonical['\"])[^>]*\bhref\s*=\s*['\"]([^'\"]+)"#, in: html),
           let resolved = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: baseURL)?.absoluteURL,
           resolved.scheme?.lowercased() == "https" { result.canonical = resolved }

        // Prefer the publisher's explicitly identified article body. Do not
        // choose the longest block: that often selects a <main> element full
        // of recommendations, navigation and unrelated stories.
        var structuredBodies: [String] = []
        for block in captures(#"<script\b[^>]*type\s*=\s*['\"]application/ld\+json['\"][^>]*>(.*?)</script>"#, in: html) {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            for article in articleObjects(in: json) {
                if let body = article["articleBody"] as? String { structuredBodies.append(body) }
                if result.author == nil {
                    if let author = article["author"] as? String { result.author = author }
                    else if let author = article["author"] as? [String: Any] { result.author = author["name"] as? String }
                    else if let authors = article["author"] as? [[String: Any]] {
                        result.author = authors.compactMap { $0["name"] as? String }.joined(separator: ", ")
                    }
                }
                if result.modified == nil { result.modified = (article["dateModified"] as? String).flatMap(RSSParser.date) }
                if result.language == nil { result.language = article["inLanguage"] as? String }
            }
        }

        // Each tier has its own quality threshold. A generic <main> is the
        // least trustworthy container and requires noticeably stronger prose
        // evidence and a low proportion of linked navigation text.
        let tiers: [(blocks: [String], strength: Int)] = [
            (structuredBodies, 0),
            (captures(#"<(?:div|section)\b[^>]*(?:class|id)\s*=\s*['\"][^'\"]*(?:entry-content|article-body|article__body|story-body|post-content|content__article)[^'\"]*['\"][^>]*>(.*?)</(?:div|section)>"#, in: html), 1),
            (captures(#"<article\b[^>]*>(.*?)</article>"#, in: html), 1),
            (captures(#"<main\b[^>]*>(.*?)</main>"#, in: html), 2)
        ]
        for tier in tiers {
            let usable = tier.blocks.map { raw in (raw, plainText(from: raw)) }
                .filter { passesQuality($0.1, html: $0.0, preview: preview, strength: tier.strength) }
                .sorted { $0.1.count > $1.1.count }
            if let selected = usable.first {
                result.text = selected.1
                break
            }
        }
        return result
    }

    // Heuristic, not a claim that every original-page extraction is perfect.
    // Reject obvious feed teasers and HTML containers mostly made of links.
    private static func passesQuality(_ text: String, html: String, preview: String, strength: Int) -> Bool {
        let descriptionLength = preview.trimmingCharacters(in: .whitespacesAndNewlines).count
        let minimum = max(strength == 2 ? 1_200 : 600, min(1_000, descriptionLength + 180))
        guard text.count >= minimum, text.count <= 250_000,
              text.count >= descriptionLength + 180 else { return false }
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 70 }
        guard paragraphs.count >= (strength == 2 ? 4 : 2) ||
              (strength != 2 && text.count >= 1_800) else { return false }
        let sentences = text.reduce(into: 0) { count, character in
            if character == "." || character == "!" || character == "?" || character == "…" { count += 1 }
        }
        guard sentences >= (strength == 2 ? 5 : 3) else { return false }

        let linked = captures(#"<a\b[^>]*>(.*?)</a>"#, in: html)
            .reduce(0) { $0 + plainText(from: $1).count }
        let proportion = Double(linked) / Double(max(text.count, 1))
        guard proportion < (strength == 2 ? 0.23 : 0.50) else { return false }

        let lower = text.lowercased()
        let boilerplate = ["privacy policy", "cookie preferences", "all rights reserved",
                           "enable javascript", "terms of service", "subscribe to our newsletter",
                           "najnovije vesti", "prijavite se na newsletter", "pratite nas na"]
        return boilerplate.filter { lower.contains($0) }.count < 3
    }

    // Preserve paragraph boundaries for ebook reading; never save raw HTML.
    static func plainText(from source: String, isHTML: Bool = true) -> String {
        var text = source
        if isHTML {
            text = replace(#"<!--[\s\S]*?-->"#, in: text, with: "")
            for tag in ["script", "style", "noscript", "nav", "footer", "aside", "form", "svg", "figure", "iframe", "button"] {
                let pattern = "<" + tag + #"\b[^>]*>[\s\S]*?</"# + tag + #"\s*>"#
                text = replace(pattern, in: text, with: "")
            }
            text = replace(#"(?i)<br\s*/?>"#, in: text, with: "\n")
            text = replace(#"(?i)</?(?:p|div|section|article|h[1-6]|blockquote|ul|ol|table|tr)\b[^>]*>"#, in: text, with: "\n\n")
            text = replace(#"(?i)<li\b[^>]*>"#, in: text, with: "\n• ")
            text = replace(#"<[^>]+>"#, in: text, with: "")
        }
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&apos;", "'"),
            ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&rsquo;", "’"),
            ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”")
        ]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let whole = Range(match.range, in: text), let part = Range(match.range(at: 1), in: text) else { continue }
                let number = String(text[part]); let hex = number.lowercased().hasPrefix("x")
                if let value = UInt32(hex ? String(number.dropFirst()) : number, radix: hex ? 16 : 10),
                   let scalar = UnicodeScalar(value) { text.replaceSubrange(whole, with: String(scalar)) }
            }
        }
        text = replace(#"[\t ]+"#, in: text, with: " ")
        text = replace(#" *\n *"#, in: text, with: "\n")
        text = replace(#"\n{3,}"#, in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func articleObjects(in json: Any) -> [[String: Any]] {
        if let objects = json as? [Any] { return objects.flatMap { articleObjects(in: $0) } }
        guard let dict = json as? [String: Any] else { return [] }
        let kinds = (dict["@type"] as? [String]) ?? (dict["@type"] as? String).map { [$0] } ?? []
        var found: [[String: Any]] = kinds.contains(where: {
            let name = $0.lowercased()
            return ["article", "newsarticle", "blogposting", "reportagenewsarticle"].contains(where: { name.hasSuffix($0) })
        }) ? [dict] : []
        if let graph = dict["@graph"] { found += articleObjects(in: graph) }
        return found
    }

    private static func meta(_ name: String, in html: String) -> String? {
        let quoted = NSRegularExpression.escapedPattern(for: name)
        return capture(#"<meta\b(?=[^>]*(?:name|property)\s*=\s*['\"]"# + quoted + #"['\"])[^>]*\bcontent\s*=\s*['\"]([^'\"]+)"#, in: html)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text).first
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func replace(_ pattern: String, in text: String, with value: String) -> String {
        text.replacingOccurrences(of: pattern, with: value, options: [.regularExpression, .caseInsensitive])
    }
}
