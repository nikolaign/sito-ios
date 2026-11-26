import Foundation
import SwiftUI

enum NewsSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case serbia, world
    var id: String { rawValue }
    var localTitle: String { self == .serbia ? L.t("Srbija", "Serbia") : L.t("Svet", "World") }
}

struct NewsSource: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let website: String
    let feed: String?
    let section: NewsSection
    let defaultOn: Bool
    let custom: Bool

    static let curated: [NewsSource] = [
        .init(id: "n1", name: "N1", website: "https://n1info.rs", feed: "https://n1info.rs/feed/", section: .serbia, defaultOn: true, custom: false),
        .init(id: "danas", name: "Danas", website: "https://www.danas.rs", feed: "https://www.danas.rs/feed/", section: .serbia, defaultOn: true, custom: false),
        .init(id: "nova", name: "Nova.rs", website: "https://nova.rs", feed: "https://nova.rs/feed/", section: .serbia, defaultOn: true, custom: false),
        .init(id: "krik", name: "KRIK", website: "https://www.krik.rs", feed: "https://www.krik.rs/feed/", section: .serbia, defaultOn: true, custom: false),
        .init(id: "cins", name: "CINS", website: "https://www.cins.rs", feed: "https://www.cins.rs/feed/", section: .serbia, defaultOn: true, custom: false),
        .init(id: "bbc", name: "BBC World", website: "https://www.bbc.com/news/world", feed: "https://feeds.bbci.co.uk/news/world/rss.xml", section: .world, defaultOn: true, custom: false),
        .init(id: "dw", name: "DW English", website: "https://www.dw.com/en/", feed: "https://rss.dw.com/xml/rss-en-all", section: .world, defaultOn: true, custom: false),
        .init(id: "guardian", name: "The Guardian", website: "https://www.theguardian.com/world", feed: "https://www.theguardian.com/world/rss", section: .world, defaultOn: true, custom: false),
        .init(id: "raspad", name: "Raspad Sistema", website: "https://raspadsistema.com", feed: nil, section: .serbia, defaultOn: true, custom: false)
    ]
}

struct NewsItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let sourceID: String
    let sourceName: String
    let section: NewsSection
    let title: String
    let summary: String
    var imageURL: URL?
    let url: URL
    let published: Date
    // An external site's own label, never an independent fact-check by SITO.
    var sourceStatus: String? = nil
    // Optional so older saved-stories.json and archive.json remain decodable.
    var feedCategories: [String]? = nil
    // Plain text only. No image files, HTML, tracking pixels or page assets
    // are retained in the regular archive or encrypted metadata backup.
    // Optional fields preserve compatibility with every older SITO backup.
    var fullText: String? = nil
    var textCapturedAt: Date? = nil
    var textCheckedAt: Date? = nil
    var textOrigin: String? = nil  // "feed" or "original"
    var byline: String? = nil
    var canonicalURL: URL? = nil
    var languageCode: String? = nil
    var modifiedAt: Date? = nil
    // Some publishers place a teaser in content:encoded. Keep that text as
    // additional preview metadata, but never count it as a whole article.
    var previewText: String? = nil

    var hasFullText: Bool {
        guard let body = fullText?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return false }
        if textOrigin == "feed" {
            // RSS/Atom content is not proof of completeness. In real N1 and
            // Nova.rs feeds, content:encoded was only a 129–150-char teaser,
            // often identical to the summary. Require actual article prose.
            guard body.count >= 650, body.count >= summary.count + 180 else { return false }
            let paragraphs = body.components(separatedBy: "\n\n").filter { $0.count >= 65 }
            return paragraphs.count >= 2 || body.count >= 1_800
        }
        // Original-page extraction already has a conservative body selector.
        // Unattributed older data must pass at least a basic length check.
        return body.count >= 500
    }

    func cleanedForArchive() -> NewsItem {
        var result = self
        if !hasFullText, let short = fullText, !short.isEmpty {
            if result.previewText == nil || short.count > (result.previewText?.count ?? 0) {
                result.previewText = short
            }
            result.fullText = nil
            result.textCapturedAt = nil
            result.textOrigin = nil
            // A fake feed body must not suppress the attempt to fetch the
            // actual publisher page in the next background completion batch.
            result.textCheckedAt = nil
        }
        return result
    }

    // Restores, re-fetches and bookmarks must never replace a complete article
    // with a fresh RSS excerpt. Also keep the richer metadata in a merge.
    func merging(older: NewsItem) -> NewsItem {
        var result = cleanedForArchive()
        let previous = older.cleanedForArchive()
        if previous.hasFullText && (!result.hasFullText ||
            (previous.fullText?.count ?? 0) > (result.fullText?.count ?? 0)) {
            result.fullText = previous.fullText
            result.textCapturedAt = previous.textCapturedAt
            result.textOrigin = previous.textOrigin
        }
        if result.textCheckedAt == nil || (previous.textCheckedAt ?? .distantPast) > (result.textCheckedAt ?? .distantPast) {
            result.textCheckedAt = previous.textCheckedAt
        }
        if result.previewText == nil { result.previewText = previous.previewText }
        if result.byline == nil { result.byline = previous.byline }
        if result.canonicalURL == nil { result.canonicalURL = previous.canonicalURL }
        if result.languageCode == nil { result.languageCode = previous.languageCode }
        if result.modifiedAt == nil { result.modifiedAt = previous.modifiedAt }
        if result.imageURL == nil { result.imageURL = previous.imageURL }
        if result.feedCategories?.isEmpty ?? true { result.feedCategories = previous.feedCategories }
        if result.sourceStatus == nil { result.sourceStatus = previous.sourceStatus }
        return result
    }
}

// Editorial metadata is not always available in RSS. Topics are a local,
// transparent convenience filter, not an AI verdict on the article.
enum NewsTopic: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, politics, society, economy, technology, science
    case health, environment, culture, sport, entertainment
    var id: String { rawValue }

    func title(_ language: String) -> String {
        let sr = language == "sr"
        switch self {
        case .all: return sr ? "Sve" : "All"
        case .politics: return sr ? "Politika" : "Politics"
        case .society: return sr ? "Društvo" : "Society"
        case .economy: return sr ? "Ekonomija" : "Economy"
        case .technology: return sr ? "Tehnologija" : "Technology"
        case .science: return sr ? "Nauka" : "Science"
        case .health: return sr ? "Zdravlje" : "Health"
        case .environment: return sr ? "Priroda" : "Environment"
        case .culture: return sr ? "Kultura" : "Culture"
        case .sport: return "Sport"
        case .entertainment: return sr ? "Zabava" : "Entertainment"
        }
    }
}

enum NewsTaxonomy {
    // Publisher tags and section paths are stronger evidence than wording
    // inside a headline. They intentionally have separate vocabularies.
    // In particular, "vreme"/"weather" are NOT environmental topics:
    // "Vreme je da..." is not a climate article.
    private struct Rule {
        let topic: NewsTopic
        let metadata: [String]
        let headline: [String]
    }

    private static let rules: [Rule] = [
        Rule(topic: .sport,
             metadata: ["sport", "sports", "fudbal", "football", "soccer", "kosarka",
                        "basketball", "tenis", "tennis", "evroliga", "euroleague",
                        "nba", "uefa", "atp", "wta", "liga nacija", "formula 1"],
             headline: ["evroliga", "euroleague", "nba", "uefa", "fudbal",
                        "football", "kosarka", "basketball", "tenis", "tennis",
                        "teniser", "teniserka", "atp", "wta", "liga nacija",
                        "premier league", "formula 1", "world cup", "olympics"]),
        Rule(topic: .entertainment,
             metadata: ["showbiz", "zabava", "estrada", "celebrity",
                        "celebrities", "reality", "starleta", "lifestyle",
                        "trac", "gossip", "hollywood", "poznati"],
             headline: ["estrada", "showbiz", "rijaliti", "reality show",
                        "celebrity", "celebrities", "starleta"]),
        Rule(topic: .politics,
             metadata: ["politika", "politics", "political", "election",
                        "izbori", "skupstina", "parliament", "government",
                        "vlada", "president", "predsednik", "ministar", "minister"],
             headline: ["izbori", "election", "skupstina", "parliament",
                        "vlada", "government", "predsednik", "president",
                        "opozicija", "opposition", "diplomatija", "diplomacy"]),
        Rule(topic: .society,
             metadata: ["drustvo", "society", "hronika", "crime", "criminal",
                        "policija", "police", "education", "obrazovanje",
                        "studenti", "university", "civil rights"],
             headline: ["policija", "police", "tuzilastvo", "sudjenje",
                        "trial", "court", "studenti", "students",
                        "obrazovanje", "education", "ljudska prava"]),
        Rule(topic: .economy,
             metadata: ["ekonomija", "privreda", "economy", "business",
                        "inflacija", "inflation", "finansije", "finance",
                        "investicije", "investment", "stock market", "berza"],
             headline: ["inflacija", "inflation", "berza", "stock market",
                        "centralna banka", "central bank", "privreda",
                        "economy", "ekonomija", "ekonomski", "business"]),
        Rule(topic: .technology,
             metadata: ["tehnologija", "technology", "tech", "artificial intelligence",
                        "vestacka inteligencija", "software", "softver",
                        "cybersecurity", "sajber", "computer", "racunar"],
             headline: ["artificial intelligence", "vestacka inteligencija",
                        "ai", "nvidia", "microsoft", "google", "openai",
                        "iphone", "macbook", "smartphone", "cybersecurity",
                        "sajber", "software", "softver", "robot"]),
        Rule(topic: .science,
             metadata: ["nauka", "science", "scientific", "svemir",
                        "space", "astronomy", "astronomija", "physics",
                        "fizika", "arheologija", "archaeology"],
             headline: ["naucnici", "scientists", "nasa", "svemir",
                        "astronomija", "astronomy", "arheologija",
                        "archaeology", "physics", "fizika"]),
        Rule(topic: .health,
             metadata: ["zdravlje", "health", "medicine", "medicina",
                        "medical", "bolnica", "hospital", "vaccine", "vakcina"],
             headline: ["vakcina", "vaccine", "bolnica", "hospital",
                        "zdravstvo", "medicine", "medicina", "disease",
                        "epidemija", "epidemic"]),
        Rule(topic: .environment,
             metadata: ["ekologija", "environment", "environmental",
                        "climate", "klima", "nature", "priroda",
                        "zivotna sredina", "zagadjenje", "pollution",
                        "biodiversity", "biodiverzitet", "ecology"],
             headline: ["klimatske promene", "climate change",
                        "globalno zagrevanje", "global warming",
                        "zivotna sredina", "zagadjeni vazduh",
                        "zagadjenje", "pollution", "biodiversity",
                        "biodiverzitet", "ugljen dioksid", "carbon emissions",
                        "wildfire", "wildfires"]),
        Rule(topic: .culture,
             metadata: ["kultura", "culture", "arts", "umetnost", "film",
                        "cinema", "knjiga", "book", "literature", "pozoriste",
                        "theatre", "museum", "muzej", "music", "muzika"],
             headline: ["pozoriste", "theatre", "literature", "knjizevnost",
                        "umetnost", "art exhibition", "muzej", "museum",
                        "filmski festival", "film festival", "opera premiere"])
    ]

    static func labels(for article: NewsItem) -> Set<NewsTopic> {
        // Only use the first two path components (publisher sections). A full
        // article slug contains arbitrary words and is not a reliable tag.
        let sectionPath = article.url.path.split(separator: "/").prefix(2)
            .map(String.init).joined(separator: " ")
        let metadata = normalized((article.feedCategories ?? []).joined(separator: " ") + " " + sectionPath)
        let headline = normalized(article.title)
        // Prefer the publisher's explicit section/category over incidental
        // words in a headline. Only one primary topic is assigned to avoid a
        // celebrity or sports story spreading into unrelated categories.
        for rule in rules {
            if containsAny(metadata, terms: rule.metadata) { return [rule.topic] }
        }
        for rule in rules {
            if containsAny(headline, terms: rule.headline) { return [rule.topic] }
        }
        return []
    }

    private static func containsAny(_ text: String, terms: [String]) -> Bool {
        terms.contains { text.contains(" " + $0 + " ") }
    }

    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "sr_RS")).lowercased()
        let pieces = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
                             .filter { !$0.isEmpty }
        return " " + pieces.joined(separator: " ") + " "
    }
}

enum ReadingStyle: String, CaseIterable, Codable, Identifiable {
    case ribbon, snap
    var id: String { rawValue }
}

enum ColorPreference: String, CaseIterable, Codable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

@MainActor
final class NewsPreferences: ObservableObject {
    @Published var language: String { didSet { persist() } }
    @Published var readingStyle: ReadingStyle { didSet { persist() } }
    @Published var colorPreference: ColorPreference { didSet { persist() } }
    @Published var fontScale: Double { didSet { persist() } }
    @Published var showImages: Bool { didSet { persist() } }
    @Published var visibleTopicIDs: Set<String> { didSet { persist() } }
    @Published var enabledIDs: Set<String> { didSet { persist() } }
    @Published var customSources: [NewsSource] { didSet { persist() } }

    private let defaults = UserDefaults.standard
    private var ready = false

    init() {
        let d = UserDefaults.standard
        language = d.string(forKey: "language") ?? (Locale.preferredLanguages.first?.hasPrefix("sr") == true ? "sr" : "en")
        readingStyle = ReadingStyle(rawValue: d.string(forKey: "readingStyle") ?? "") ?? .ribbon
        colorPreference = ColorPreference(rawValue: d.string(forKey: "colorPreference") ?? "") ?? .dark
        fontScale = min(1.40, max(0.85, d.object(forKey: "fontScale") as? Double ?? 1.0))
        showImages = d.object(forKey: "showImages") as? Bool ?? true
        // Keep the ribbon quiet by default; all additional topics can be
        // enabled individually without deleting or changing the taxonomy.
        let defaultTopics = [NewsTopic.politics, .society, .technology, .science, .culture]
        visibleTopicIDs = Set(d.stringArray(forKey: "visibleTopicIDs") ?? defaultTopics.map(\.rawValue))
        customSources = (d.data(forKey: "customSources").flatMap { try? JSONDecoder().decode([NewsSource].self, from: $0) }) ?? []
        if let ids = d.stringArray(forKey: "enabledIDs") { enabledIDs = Set(ids) }
        else { enabledIDs = Set(NewsSource.curated.filter(\.defaultOn).map(\.id)) }
        ready = true
    }

    var sources: [NewsSource] { NewsSource.curated + customSources }
    var visibleTopics: [NewsTopic] { NewsTopic.allCases.filter { $0 == .all || visibleTopicIDs.contains($0.rawValue) } }
    func setTopicVisible(_ topic: NewsTopic, _ visible: Bool) {
        guard topic != .all else { return }
        if visible { visibleTopicIDs.insert(topic.rawValue) }
        else { visibleTopicIDs.remove(topic.rawValue) }
    }
    var activeSources: [NewsSource] { sources.filter { enabledIDs.contains($0.id) && ($0.feed != nil || $0.id == "raspad") } }
    var sourceSignature: String { activeSources.map { "\($0.id):\($0.feed ?? "")" }.sorted().joined(separator: "|") }
    var raspadEnabled: Bool { enabledIDs.contains("raspad") }

    func setEnabled(_ source: NewsSource, _ enabled: Bool) {
        if enabled { enabledIDs.insert(source.id) } else { enabledIDs.remove(source.id) }
    }
    func removeCustom(_ source: NewsSource) {
        customSources.removeAll { $0.id == source.id }
        enabledIDs.remove(source.id)
    }
    // A feed URL is a single subscription, even if it appeared in several
    // online directories or was already part of the default source selection.
    func sourceMatchingFeed(_ candidate: String) -> NewsSource? {
        guard let key = Self.feedKey(candidate) else { return nil }
        return sources.first { existing in
            guard let feed = existing.feed else { return false }
            return Self.feedKey(feed) == key
        }
    }
    static func feedKey(_ feed: String) -> String? {
        guard let url = DirectoryImporter.secureURL(feed) else { return nil }
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return host + "/" + path + (url.query.map { "?" + $0 } ?? "")
    }
    func addCustom(name: String, url: URL, section: NewsSection, website: String? = nil) {
        if let existing = sourceMatchingFeed(url.absoluteString) {
            enabledIDs.insert(existing.id)
            return
        }
        let homepage = website.flatMap { DirectoryImporter.secureURL($0)?.absoluteString }
            ?? url.host.map { "https://" + $0 } ?? url.absoluteString
        let source = NewsSource(id: UUID().uuidString, name: name, website: homepage,
                                feed: url.absoluteString, section: section, defaultOn: true, custom: true)
        customSources.append(source)
        enabledIDs.insert(source.id)
    }
    func resetSources() {
        enabledIDs = Set(NewsSource.curated.filter(\.defaultOn).map(\.id))
    }
    private func persist() {
        guard ready else { return }
        defaults.set(language, forKey: "language")
        defaults.set(readingStyle.rawValue, forKey: "readingStyle")
        defaults.set(colorPreference.rawValue, forKey: "colorPreference")
        defaults.set(fontScale, forKey: "fontScale")
        defaults.set(showImages, forKey: "showImages")
        defaults.set(Array(visibleTopicIDs), forKey: "visibleTopicIDs")
        defaults.set(Array(enabledIDs), forKey: "enabledIDs")
        if let data = try? JSONEncoder().encode(customSources) { defaults.set(data, forKey: "customSources") }
    }
}

struct LocalBackup: Codable {
    let formatVersion: Int
    let createdAt: Date
    let articles: [NewsItem]
    let savedArticles: [NewsItem]
}

struct StoredFullArticle: Codable, Identifiable {
    let id: String
    let title: String
    let sourceName: String
    let originalURL: URL
    let filename: String
    let savedAt: Date
}

// Deliberately small UI dictionary; original news content is never machine-translated.
enum L {
    static var lang = "sr"
    static func t(_ sr: String, _ en: String) -> String { lang == "sr" ? sr : en }
}

enum Ink {
    static let red = Color(red: 0.82, green: 0.16, blue: 0.18)
    static func paper(_ dark: Bool) -> Color { dark ? Color(red: 0.058, green: 0.060, blue: 0.065) : Color(red: 0.975, green: 0.967, blue: 0.943) }
    static func text(_ dark: Bool) -> Color { dark ? Color(red: 0.92, green: 0.91, blue: 0.88) : Color(red: 0.16, green: 0.17, blue: 0.18) }
    static func muted(_ dark: Bool) -> Color { dark ? Color(red: 0.57, green: 0.57, blue: 0.57) : Color(red: 0.44, green: 0.45, blue: 0.45) }
    static func rule(_ dark: Bool) -> Color { dark ? .white.opacity(0.14) : .black.opacity(0.11) }
}
