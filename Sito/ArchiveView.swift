import SwiftUI
import QuickLook

// A dedicated bookshelf. It does not change the selected Serbia/World feed.
struct SavedArticlesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var prefs: NewsPreferences
    @EnvironmentObject private var feed: NewsFeed
    @State private var search = ""
    @State private var offlineOnly = false
    @State private var visiting: WebDestination?
    @State private var capture: NewsItem?
    @State private var previewURL: URL?

    private var savedItems: [NewsItem] {
        var combined = feed.saved
        for file in feed.completeItems {
            if let article = feed.archive[file.id] { combined[file.id] = article }
        }
        return combined.values
            .filter { !offlineOnly || feed.completeArticles[$0.id] != nil }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || $0.sourceName.localizedCaseInsensitiveContains(search) }
            .sorted { $0.published > $1.published }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $offlineOnly) {
                    Text(prefs.language == "sr" ? "Sve sačuvano" : "All saved").tag(false)
                    Text(prefs.language == "sr" ? "Dostupno offline" : "Available offline").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18).padding(.vertical, 12)

                if savedItems.isEmpty {
                    ContentUnavailableView {
                        Label(prefs.language == "sr" ? "Nema sačuvanih vesti" : "No saved articles",
                              systemImage: offlineOnly ? "doc.text" : "bookmark")
                    } description: {
                        Text(offlineOnly
                             ? (prefs.language == "sr" ? "Za offline čitanje sačuvaj PDF sa kartice vesti." : "Save an article's PDF from its news card to read offline.")
                             : (prefs.language == "sr" ? "Dodirni bookmark na vesti. Sačuvane vesti iz Srbije i sveta videćeš zajedno ovde." : "Tap a story's bookmark. Stories from Serbia and the world appear together here."))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(savedItems) { article in
                        Button { open(article) } label: {
                            SavedArticleRow(article: article, offline: feed.completeArticles[article.id] != nil)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                visiting = WebDestination(url: article.url)
                            } label: {
                                Label(prefs.language == "sr" ? "Otvori original" : "Open original", systemImage: "safari")
                            }
                            Button {
                                capture = article
                            } label: {
                                Label(prefs.language == "sr" ? "Sačuvaj pun PDF" : "Save full PDF", systemImage: "square.and.arrow.down")
                            }
                            if feed.isSaved(article) {
                                Button(role: .destructive) {
                                    feed.toggleSaved(article)
                                } label: {
                                    Label(prefs.language == "sr" ? "Ukloni bookmark" : "Remove bookmark", systemImage: "bookmark.slash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $search, prompt: prefs.language == "sr" ? "Pretraži sačuvano" : "Search saved articles")
                }
            }
            .navigationTitle(prefs.language == "sr" ? "Sačuvani članci" : "Saved articles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button(prefs.language == "sr" ? "Gotovo" : "Done") { dismiss() }.tint(Ink.red)
            }}
        }
        .sheet(item: $visiting) { destination in SafariReader(url: destination.url) }
        .sheet(item: $capture) { article in OfflineArticleView(item: article) }
        .quickLookPreview($previewURL)
    }

    private func open(_ article: NewsItem) {
        if let full = feed.completeArticles[article.id] {
            let path = feed.completePDFURL(for: full)
            if FileManager.default.fileExists(atPath: path.path) { previewURL = path; return }
        }
        visiting = WebDestination(url: article.url)
    }
}

struct SavedArticleRow: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let article: NewsItem
    let offline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(article.sourceName.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Ink.red)
                Spacer()
                if offline {
                    Label("OFFLINE PDF", systemImage: "doc.text")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if article.published > Date(timeIntervalSince1970: 1_000_000_000) {
                    Text(article.published, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                if prefs.showImages, let url = article.imageURL {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.08) }
                        .frame(width: 72, height: 66).clipped().cornerRadius(3)
                }
                Text(article.title)
                    .font(.system(size: 18 * prefs.fontScale, weight: .medium, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

// History is a search tool, accessed from Settings, not a competing main feed.
struct ArchiveView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var prefs: NewsPreferences
    @EnvironmentObject private var feed: NewsFeed
    @State private var search = ""
    @State private var visiting: WebDestination?
    @State private var capture: NewsItem?

    private var filtered: [NewsItem] {
        feed.searchArchive(search)
    }

    var body: some View {
        NavigationStack {
            List(filtered) { article in
                Button { visiting = WebDestination(url: article.url) } label: {
                    SavedArticleRow(article: article, offline: feed.completeArticles[article.id] != nil)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        if !feed.isSaved(article) { feed.toggleSaved(article) }
                    } label: {
                        Label(prefs.language == "sr" ? "Sačuvaj bookmark" : "Bookmark", systemImage: "bookmark")
                    }
                    Button {
                        capture = article
                    } label: {
                        Label(prefs.language == "sr" ? "Sačuvaj PDF" : "Save PDF", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: prefs.language == "sr" ? "Pretraži sve preuzete vesti" : "Search downloaded headlines")
            .navigationTitle(prefs.language == "sr" ? "Arhiva · \(feed.archiveCount)" : "Archive · \(feed.archiveCount)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button(prefs.language == "sr" ? "Gotovo" : "Done") { dismiss() }.tint(Ink.red)
            }}
        }
        .sheet(item: $visiting) { destination in SafariReader(url: destination.url) }
        .sheet(item: $capture) { article in OfflineArticleView(item: article) }
    }
}

