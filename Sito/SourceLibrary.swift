import Foundation
import SwiftUI

// Feed directories are suggestions, not subscriptions. Their contents never
// change the user's enabled sources without a deliberate tap.
struct DirectoryFeed: Codable, Hashable, Identifiable {
    let name: String
    let feedURL: String
    let websiteURL: String?
    let group: String
    let section: NewsSection

    var id: String { feedURL.lowercased() }
    var host: String { URL(string: feedURL)?.host ?? feedURL }
}

struct FeedDirectory: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var url: String
    var editable: Bool

    static let featured: [FeedDirectory] = [
        .init(id: "plenary-news", title: "World news", url: "https://raw.githubusercontent.com/spians/awesome-RSS-feeds/master/recommended/with_category/News.opml", editable: false),
        .init(id: "plenary-tech", title: "Technology", url: "https://raw.githubusercontent.com/spians/awesome-RSS-feeds/master/recommended/with_category/Tech.opml", editable: false),
        .init(id: "plenary-science", title: "Science", url: "https://raw.githubusercontent.com/spians/awesome-RSS-feeds/master/recommended/with_category/Science.opml", editable: false),
        .init(id: "plenary-economy", title: "Business", url: "https://raw.githubusercontent.com/spians/awesome-RSS-feeds/master/recommended/with_category/Business%20%26%20Economy.opml", editable: false),
        .init(id: "plenary-us", title: "United States", url: "https://raw.githubusercontent.com/spians/awesome-RSS-feeds/master/countries/with_category/United%20States.opml", editable: false),
        .init(id: "independent-global", title: "Global briefing", url: "https://raw.githubusercontent.com/ajdelaguila/opml-news-feeds/main/global-briefing.opml.xml", editable: false),
        .init(id: "independent-tech", title: "Tech & engineering", url: "https://raw.githubusercontent.com/ajdelaguila/opml-news-feeds/main/tech-en.opml.xml", editable: false)
    ]
}

enum DirectoryImportError: LocalizedError {
    case invalidURL, invalidFormat, empty, tooLarge, badResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid HTTPS URL, or a GitHub link to an OPML, JSON or text file."
        case .invalidFormat: return "This file isn't a supported OPML, JSON or plain URL list."
        case .empty: return "No usable HTTPS feeds were found in this list."
        case .tooLarge: return "The directory exceeds SITO's 1 MB import limit."
        case .badResponse: return "The directory server didn't return a successful response."
        }
    }
}

enum DirectoryImporter {
    static func secureURL(_ string: String) -> URL? {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let secure = raw.replacingOccurrences(of: "http://", with: "https://", options: [.anchored, .caseInsensitive])
        let address = secure.contains("://") ? secure : "https://" + secure
        guard var parts = URLComponents(string: address), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), host.contains("."),
              parts.user == nil, parts.password == nil else { return nil }
        parts.fragment = nil
        parts.host = host
        return parts.url
    }

    // GitHub's regular "blob" URL is a webpage. Convert it to its raw file
    // so people can paste the familiar URL directly from their browser.
    static func directoryURL(_ input: String) -> URL? {
        guard let url = secureURL(input) else { return nil }
        guard url.host == "github.com" else { return url }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 5, parts[2] == "blob" else { return nil }
        var raw = URLComponents()
        raw.scheme = "https"
        raw.host = "raw.githubusercontent.com"
        raw.path = "/" + ([parts[0], parts[1], parts[3]] + Array(parts.dropFirst(4))).joined(separator: "/")
        return raw.url
    }

    static func parse(_ data: Data) throws -> [DirectoryFeed] {
        guard data.count <= 1_000_000 else { throw DirectoryImportError.tooLarge }
        let prefix = String(decoding: data.prefix(180), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [DirectoryFeed]
        if prefix.hasPrefix("<") || prefix.hasPrefix("\u{FEFF}<") {
            let delegate = OPMLDirectoryParser()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            guard parser.parse(), delegate.sawOPML else { throw DirectoryImportError.invalidFormat }
            candidates = delegate.feeds
        } else if prefix.hasPrefix("[") || prefix.hasPrefix("{") {
            let object = try? JSONSerialization.jsonObject(with: data)
            let records: [[String: Any]]
            if let array = object as? [[String: Any]] { records = array }
            else if let dict = object as? [String: Any],
                    let array = (dict["feeds"] ?? dict["sources"] ?? dict["items"]) as? [[String: Any]] { records = array }
            else { throw DirectoryImportError.invalidFormat }
            candidates = records.compactMap { value in
                let feedText = (value["xmlUrl"] ?? value["xmlurl"] ?? value["feed_url"] ?? value["feedURL"] ?? value["feed"] ?? value["url"]) as? String
                guard let feedText, let url = secureURL(feedText) else { return nil }
                let name = (value["title"] ?? value["name"] ?? value["text"]) as? String ?? url.host ?? "Feed"
                let website = (value["htmlUrl"] ?? value["website"] ?? value["site_url"]) as? String
                let group = (value["category"] ?? value["group"]) as? String ?? ""
                let section = ((value["section"] as? String)?.lowercased() == "serbia") ? NewsSection.serbia : .world
                return DirectoryFeed(name: name, feedURL: url.absoluteString,
                                     websiteURL: website.flatMap { secureURL($0)?.absoluteString }, group: group, section: section)
            }
        } else {
            // Plain text: one feed URL per line, with optional # comments.
            guard let text = String(data: data, encoding: .utf8) else { throw DirectoryImportError.invalidFormat }
            candidates = text.components(separatedBy: .newlines).compactMap { line in
                let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.hasPrefix("#"), (raw.hasPrefix("http://") || raw.hasPrefix("https://")),
                      let url = secureURL(raw) else { return nil }
                return DirectoryFeed(name: url.host ?? "Feed", feedURL: url.absoluteString,
                                     websiteURL: nil, group: "", section: .world)
            }
        }
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.id).inserted }.prefix(1500)
        guard !unique.isEmpty else { throw DirectoryImportError.empty }
        return Array(unique)
    }
}

private final class OPMLDirectoryParser: NSObject, XMLParserDelegate {
    var feeds: [DirectoryFeed] = []
    var sawOPML = false
    private var groups: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let tag = elementName.lowercased()
        if tag == "opml" { sawOPML = true }
        guard tag == "outline" else { return }
        let title = (attributes["title"] ?? attributes["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let group = groups.last ?? ""
        if let address = attributes["xmlUrl"] ?? attributes["xmlurl"],
           let url = DirectoryImporter.secureURL(address) {
            feeds.append(DirectoryFeed(name: title.isEmpty ? (url.host ?? "Feed") : title,
                                       feedURL: url.absoluteString,
                                       websiteURL: attributes["htmlUrl"].flatMap { DirectoryImporter.secureURL($0)?.absoluteString },
                                       group: group, section: .world))
            groups.append(group)
        } else {
            groups.append(title.isEmpty ? group : title)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "outline", !groups.isEmpty { groups.removeLast() }
    }
}

@MainActor
final class FeedDirectoryStore: ObservableObject {
    @Published private(set) var customDirectories: [FeedDirectory] = []
    @Published private(set) var cache: [String: [DirectoryFeed]] = [:]
    @Published private(set) var refreshedAt: [String: Date] = [:]
    @Published private(set) var newCounts: [String: Int] = [:]
    @Published private(set) var updating: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published var autoUpdate: Bool { didSet { defaults.set(autoUpdate, forKey: "directoryAutoUpdate") } }

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()

    init() {
        let d = UserDefaults.standard
        customDirectories = (d.data(forKey: "feedDirectories").flatMap { try? JSONDecoder().decode([FeedDirectory].self, from: $0) }) ?? []
        cache = (d.data(forKey: "feedDirectoryCache").flatMap { try? JSONDecoder().decode([String: [DirectoryFeed]].self, from: $0) }) ?? [:]
        refreshedAt = (d.data(forKey: "feedDirectoryTimes").flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) }) ?? [:]
        autoUpdate = d.object(forKey: "directoryAutoUpdate") as? Bool ?? true
    }

    var directories: [FeedDirectory] { FeedDirectory.featured + customDirectories }

    func save(title: String, urlText: String, replacing: FeedDirectory? = nil) throws -> String {
        guard let url = DirectoryImporter.directoryURL(urlText) else { throw DirectoryImportError.invalidURL }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw DirectoryImportError.invalidFormat }
        if let duplicate = directories.first(where: { $0.url == url.absoluteString && $0.id != replacing?.id }) {
            return duplicate.id
        }
        let id = replacing?.id ?? UUID().uuidString
        if let index = customDirectories.firstIndex(where: { $0.id == id }) {
            if customDirectories[index].url != url.absoluteString {
                cache[id] = nil; refreshedAt[id] = nil; newCounts[id] = nil
            }
            customDirectories[index] = FeedDirectory(id: id, title: cleanTitle, url: url.absoluteString, editable: true)
        } else {
            customDirectories.append(FeedDirectory(id: id, title: cleanTitle, url: url.absoluteString, editable: true))
        }
        persist()
        return id
    }

    func remove(_ directory: FeedDirectory) {
        guard directory.editable else { return }
        customDirectories.removeAll { $0.id == directory.id }
        cache[directory.id] = nil; refreshedAt[directory.id] = nil; newCounts[directory.id] = nil
        persist()
    }

    func refresh(_ id: String) async {
        guard !updating.contains(id), let source = directories.first(where: { $0.id == id }),
              let url = DirectoryImporter.directoryURL(source.url) else { return }
        updating.insert(id)
        defer { updating.remove(id) }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/xml, text/xml, application/json, text/plain", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DirectoryImportError.badResponse
            }
            let fresh = try DirectoryImporter.parse(data)
            let existing = Set((cache[id] ?? []).map(\.id))
            newCounts[id] = existing.isEmpty ? 0 : fresh.filter { !existing.contains($0.id) }.count
            cache[id] = fresh
            refreshedAt[id] = .now
            errors[id] = nil
            persist()
        } catch {
            errors[id] = error.localizedDescription
            // A failed update cannot erase a previously downloaded directory.
        }
    }

    func refreshStale(_ id: String) async {
        // The library may offer hundreds of feeds across seven directories.
        // Opening its local picks should not download all remote directories.
        guard id != "picks", cache[id] == nil || (autoUpdate &&
            Date().timeIntervalSince(refreshedAt[id] ?? .distantPast) > 7 * 86_400)
        else { return }
        await refresh(id)
    }

    private func persist() {
        if let data = try? encoder.encode(customDirectories) { defaults.set(data, forKey: "feedDirectories") }
        if let data = try? encoder.encode(cache) { defaults.set(data, forKey: "feedDirectoryCache") }
        if let data = try? encoder.encode(refreshedAt) { defaults.set(data, forKey: "feedDirectoryTimes") }
    }
}

struct SourceLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var prefs: NewsPreferences
    @StateObject private var directory = FeedDirectoryStore()
    @State private var selectedID = "picks"
    @State private var query = ""
    @State private var importedSection: NewsSection = .world
    @State private var showNewCatalog = false
    @State private var editingCatalog: FeedDirectory?
    @State private var showManualSource = false

    private func tr(_ sr: String, _ en: String) -> String { prefs.language == "sr" ? sr : en }

    private var picks: [DirectoryFeed] { [
        .init(name: "N1", feedURL: "https://n1info.rs/feed/", websiteURL: "https://n1info.rs", group: "Serbia", section: .serbia),
        .init(name: "Danas", feedURL: "https://www.danas.rs/feed/", websiteURL: "https://www.danas.rs", group: "Serbia", section: .serbia),
        .init(name: "KRIK", feedURL: "https://www.krik.rs/feed/", websiteURL: "https://www.krik.rs", group: "Investigations", section: .serbia),
        .init(name: "CINS", feedURL: "https://www.cins.rs/feed/", websiteURL: "https://www.cins.rs", group: "Investigations", section: .serbia),
        .init(name: "BBC World", feedURL: "https://feeds.bbci.co.uk/news/world/rss.xml", websiteURL: "https://www.bbc.com/news/world", group: "World", section: .world),
        .init(name: "The Guardian", feedURL: "https://www.theguardian.com/world/rss", websiteURL: "https://www.theguardian.com/world", group: "World", section: .world),
        .init(name: "DW English", feedURL: "https://rss.dw.com/xml/rss-en-all", websiteURL: "https://www.dw.com/en/", group: "World", section: .world),
        .init(name: "Nature", feedURL: "https://www.nature.com/nature.rss", websiteURL: "https://www.nature.com", group: "Science", section: .world),
        .init(name: "Ars Technica", feedURL: "https://feeds.arstechnica.com/arstechnica/index", websiteURL: "https://arstechnica.com", group: "Technology", section: .world),
        .init(name: "TechRadar", feedURL: "https://www.techradar.com/rss", websiteURL: "https://www.techradar.com", group: "Technology", section: .world),
        .init(name: "ScienceDaily", feedURL: "https://www.sciencedaily.com/rss/all.xml", websiteURL: "https://www.sciencedaily.com", group: "Science", section: .world)
    ] }

    private var chosenDirectory: FeedDirectory? { directory.directories.first { $0.id == selectedID } }
    private var allFeeds: [DirectoryFeed] { selectedID == "picks" ? picks : directory.cache[selectedID] ?? [] }
    private var shownFeeds: [DirectoryFeed] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return allFeeds }
        return allFeeds.filter { $0.name.localizedCaseInsensitiveContains(term) ||
            $0.host.localizedCaseInsensitiveContains(term) || $0.group.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        let visible = shownFeeds
        // Match subscriptions once per rendered directory, rather than
        // reparsing every installed URL for each scrolling catalogue cell.
        let installed = Dictionary(prefs.sources.compactMap { source -> (String, NewsSource)? in
            guard let feed = source.feed, let key = NewsPreferences.feedKey(feed) else { return nil }
            return (key, source)
        }, uniquingKeysWith: { first, _ in first })
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introduction
                    directoryPicker
                    if let chosenDirectory { directoryStatus(chosenDirectory) }
                    if selectedID != "picks" {
                        Picker(tr("Dodaj u", "Add to"), selection: $importedSection) {
                            Text(tr("Srbija", "Serbia")).tag(NewsSection.serbia)
                            Text(tr("Svet", "World")).tag(NewsSection.world)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel(tr("Rubrika za nove izvore", "Section for new sources"))
                    }
                    HStack {
                        Text(tr("IZVORI", "SOURCES"))
                            .font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(visible.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if visible.isEmpty { emptyState }
                    else {
                        LazyVStack(spacing: 10) {
                            ForEach(visible) { candidate in
                                feedCard(candidate, existing: NewsPreferences.feedKey(candidate.feedURL).flatMap { installed[$0] })
                            }
                        }
                    }
                    Text(tr("Katalozi služe za pronalaženje izvora, ne za proveru istinitosti pojedinačnih vesti. Linkovi mogu zastareti.",
                            "Directories help discover feeds; they do not verify individual articles. Publisher links may change."))
                        .font(.footnote).foregroundStyle(.tertiary).padding(.vertical, 8)
                }
                .padding(18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(tr("Katalog izvora", "Source library"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text(tr("Naziv, domen ili tema", "Name, website or topic")))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button(tr("Dodaj svoj katalog", "Add an online directory"), systemImage: "link.badge.plus") { showNewCatalog = true }
                        Button(tr("Dodaj jedan RSS", "Add a single feed"), systemImage: "plus") { showManualSource = true }
                        Toggle(tr("Automatsko ažuriranje kataloga", "Automatic directory updates"), isOn: $directory.autoUpdate)
                        if let chosenDirectory, chosenDirectory.editable {
                            Button(tr("Izmeni katalog", "Edit directory"), systemImage: "pencil") { editingCatalog = chosenDirectory }
                            Button(role: .destructive) {
                                directory.remove(chosenDirectory); selectedID = "picks"
                            } label: { Label(tr("Ukloni katalog", "Remove directory"), systemImage: "trash") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button(tr("Gotovo", "Done")) { dismiss() }.tint(Ink.red) }
            }
            .task(id: selectedID) { await directory.refreshStale(selectedID) }
            .sheet(isPresented: $showNewCatalog) {
                DirectoryEditorView(store: directory) { id in selectedID = id }
                    .environmentObject(prefs)
            }
            .sheet(item: $editingCatalog) { item in
                DirectoryEditorView(store: directory, editing: item) { id in selectedID = id }
                    .environmentObject(prefs)
            }
            .sheet(isPresented: $showManualSource) { AddSourceView().environmentObject(prefs) }
        }
    }

    private var introduction: some View {
        HStack(alignment: .top, spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.black).frame(width: 52, height: 52)
                RoundedRectangle(cornerRadius: 2).fill(Ink.red).frame(width: 17, height: 17)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("Tvoje vesti. Tvoj izbor.", "Your feed. Your choice."))
                    .font(.system(.title3, design: .serif, weight: .semibold))
                Text(tr("Pronađi izvor i dodaj ga jednim dodirom. Ništa se ne uključuje samo.",
                        "Find a publisher, add it with one tap. Nothing is subscribed automatically."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    private var directoryPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(tr("KOLEKCIJE", "COLLECTIONS"))
                    .font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                Spacer()
                Button { showNewCatalog = true } label: {
                    Label(tr("Svoj katalog", "My list"), systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                }.tint(Ink.red)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pill(tr("SITO izbor", "SITO picks"), id: "picks")
                    ForEach(directory.directories) { item in pill(item.title, id: item.id) }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func pill(_ title: String, id: String) -> some View {
        let active = selectedID == id
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedID = id }
            query = ""
        } label: {
            Text(title).font(.subheadline.weight(active ? .semibold : .medium))
                .foregroundStyle(active ? Color.white : Color.primary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(active ? Color(red: 0.14, green: 0.14, blue: 0.16) : Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    private func directoryStatus(_ item: FeedDirectory) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(Ink.red)
            VStack(alignment: .leading, spacing: 3) {
                if let date = directory.refreshedAt[item.id] {
                    Text(tr("Ažurirano", "Updated") + " " + date.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                } else { Text(tr("Katalog još nije preuzet", "Directory not downloaded yet")).font(.subheadline) }
                if let error = directory.errors[item.id] {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else if let added = directory.newCounts[item.id], added > 0 {
                    Text(tr("\(added) novih predloga", "\(added) new suggestions"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(directory.autoUpdate ?
                         tr("Osvežava se na 7 dana · dostupan i offline", "Refreshes every 7 days · cached offline") :
                         tr("Automatsko ažuriranje je isključeno", "Automatic updates are off"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                Task { await directory.refresh(item.id) }
            } label: {
                if directory.updating.contains(item.id) { ProgressView().tint(Ink.red) }
                else { Image(systemName: "arrow.clockwise").font(.headline) }
            }
            .disabled(directory.updating.contains(item.id))
            .accessibilityLabel(tr("Ažuriraj katalog", "Update directory"))
            .tint(Ink.red)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 15).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.secondary)
            Text(directory.updating.contains(selectedID) ? tr("Preuzimam izvore…", "Loading sources…") :
                 (query.isEmpty ? tr("Nema preuzetih izvora", "No sources downloaded yet") : tr("Nema rezultata", "No matches")))
                .font(.subheadline).foregroundStyle(.secondary)
            if let item = chosenDirectory, !directory.updating.contains(item.id) {
                Button(tr("Preuzmi katalog", "Download directory")) { Task { await directory.refresh(item.id) } }
                    .buttonStyle(.borderedProminent).tint(Ink.red)
            }
        }
        .frame(maxWidth: .infinity).padding(28)
    }

    private func feedCard(_ candidate: DirectoryFeed, existing: NewsSource?) -> some View {
        let active = existing.map { prefs.enabledIDs.contains($0.id) } ?? false
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(Ink.red.opacity(0.09)).frame(width: 43, height: 43)
                Text(String(candidate.name.prefix(1)).uppercased())
                    .font(.system(.headline, design: .serif)).foregroundStyle(Ink.red)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(candidate.host.replacingOccurrences(of: "www.", with: ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !candidate.group.isEmpty {
                    Text(candidate.group).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button {
                if let existing { prefs.setEnabled(existing, true) }
                else if let url = DirectoryImporter.secureURL(candidate.feedURL) {
                    prefs.addCustom(name: candidate.name, url: url,
                                    section: selectedID == "picks" ? candidate.section : importedSection,
                                    website: candidate.websiteURL)
                }
            } label: {
                Image(systemName: active ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(active ? Color.green : Ink.red)
                    .frame(width: 36, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(active)
            .accessibilityLabel(active ? tr("\(candidate.name) je već dodat", "\(candidate.name) already added") :
                                    tr("Dodaj \(candidate.name)", "Add \(candidate.name)"))
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }
}

struct DirectoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var prefs: NewsPreferences
    @ObservedObject var store: FeedDirectoryStore
    var editing: FeedDirectory? = nil
    var onSave: (String) -> Void
    @State private var title = ""
    @State private var urlText = ""
    @State private var failure: String?

    private func tr(_ sr: String, _ en: String) -> String { prefs.language == "sr" ? sr : en }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(tr("Naziv kolekcije", "Collection name"), text: $title)
                    TextField("https://github.com/.../feeds.opml", text: $urlText)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text(tr("Podržani su OPML, JSON liste i TXT fajlovi sa jednim URL-om po redu. Možeš nalepiti običan GitHub link do fajla; SITO će ga preuzeti kao raw sadržaj.",
                            "Supports OPML, JSON arrays and text files with one URL per line. A normal GitHub link to a file is fine; SITO converts it to raw content."))
                }
                Section {
                    Toggle(tr("Automatski proveravaj ažuriranja", "Automatically check for updates"), isOn: $store.autoUpdate)
                        .tint(Ink.red)
                } footer: {
                    Text(tr("Provera na 7 dana kada otvoriš katalog. Samo se lista predloga ažurira — tvoji izvori ostaju isti.",
                            "Checked every 7 days when you open the library. Only suggestions update; your subscriptions stay as you chose."))
                }
                if let failure { Text(failure).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle(editing == nil ? tr("Svoj katalog", "Add directory") : tr("Izmeni katalog", "Edit directory"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { title = editing?.title ?? ""; urlText = editing?.url ?? "" }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(tr("Otkaži", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(tr("Sačuvaj", "Save")) {
                        do {
                            let id = try store.save(title: title, urlText: urlText, replacing: editing)
                            onSave(id); dismiss()
                        } catch { failure = error.localizedDescription }
                    }
                    .fontWeight(.semibold).tint(Ink.red)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
