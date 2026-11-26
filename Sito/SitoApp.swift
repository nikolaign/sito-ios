import SwiftUI
import SafariServices

@main
struct SitoApp: App {
    @UIApplicationDelegateAdaptor(SitoBackgroundDelegate.self) private var backgroundDelegate
    @StateObject private var preferences = NewsPreferences()
    @StateObject private var feed = NewsFeed()
    @StateObject private var cloudVault = CloudVault()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(preferences)
                .environmentObject(feed)
                .environmentObject(cloudVault)
                .preferredColorScheme(preferences.colorPreference.scheme)
                .environment(\.locale, Locale(identifier: preferences.language))
        }
    }
}

struct WebDestination: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariReader: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = true
        let controller = SFSafariViewController(url: url, configuration: config)
        controller.preferredControlTintColor = UIColor(Ink.red)
        return controller
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

struct SitoGlyph: View {
    var size: CGFloat = 24
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.06)
                .stroke(.primary, lineWidth: size * 0.095)
                .frame(width: size * 0.68, height: size * 0.68)
            Rectangle().fill(Ink.red)
                .frame(width: size * 0.27, height: size * 0.27)
                .offset(x: size * 0.34, y: -size * 0.33)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct HomeView: View {
    @EnvironmentObject private var prefs: NewsPreferences
    @EnvironmentObject private var feed: NewsFeed
    @EnvironmentObject private var cloudVault: CloudVault
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: NewsSection = .serbia
    @State private var settingsPresented = false
    @State private var savedPresented = false
    @State private var visiting: WebDestination?
    @State private var fullArticle: NewsItem?
    @State private var showSplash = true
    @State private var showRefreshNotice = false
    @State private var diagnosticsPresented = false
    @State private var sourceRefreshTask: Task<Void, Never>?
    @State private var sourcesBeforeSettings = ""
    @State private var dreamPresented = false
    @State private var topReset = 0
    @State private var brandTapCount = 0
    @State private var lastBrandTap = Date.distantPast
    @AppStorage("compactFeedMode") private var compactMode = false
    @AppStorage("topicSerbia") private var serbiaTopic = NewsTopic.all.rawValue
    @AppStorage("topicWorld") private var worldTopic = NewsTopic.all.rawValue
    @AppStorage("sourceSerbia") private var serbiaSource = ""
    @AppStorage("sourceWorld") private var worldSource = ""
    @Namespace private var topicHighlight

    private var dark: Bool { scheme == .dark }
    private var selectedTopic: NewsTopic {
        let stored = NewsTopic(rawValue: section == .serbia ? serbiaTopic : worldTopic) ?? .all
        return prefs.visibleTopics.contains(stored) ? stored : .all
    }
    private var selectedSourceID: String? {
        let stored = section == .serbia ? serbiaSource : worldSource
        return prefs.activeSources.contains(where: { $0.id == stored && $0.section == section }) ? stored : nil
    }
    private var selectedSourceName: String? {
        prefs.activeSources.first(where: { $0.id == selectedSourceID })?.name
    }
    private var sectionStories: [NewsItem] {
        feed.items.filter { $0.section == section && prefs.enabledIDs.contains($0.sourceID) }
    }
    private var stories: [NewsItem] {
        let filtered = sectionStories.filter {
            (selectedSourceID == nil || $0.sourceID == selectedSourceID) &&
            // Selecting a publisher is a complete, unclassified publisher stream.
            // Topic chips apply only when mixing several publishers.
            (selectedSourceID != nil || feed.matchesTopic($0, topic: selectedTopic))
        }
        return selectedSourceID == nil ? feed.mixedStories(filtered) : filtered.sorted { $0.published > $1.published }
    }
    private func chooseTopic(_ topic: NewsTopic) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)) {
            if section == .serbia { serbiaTopic = topic.rawValue }
            else { worldTopic = topic.rawValue }
        }
    }
    private func chooseSource(_ id: String?) {
        withAnimation(.easeInOut(duration: 0.22)) {
            if section == .serbia { serbiaSource = id ?? "" }
            else { worldSource = id ?? "" }
        }
    }
    private func shiftTopic(_ step: Int) {
        let topics = prefs.visibleTopics
        guard let index = topics.firstIndex(of: selectedTopic) else { return }
        let next = index + step
        if topics.indices.contains(next) { chooseTopic(topics[next]) }
    }
    private func tapBrand() {
        let now = Date()
        brandTapCount = now.timeIntervalSince(lastBrandTap) < 1.05 ? brandTapCount + 1 : 1
        lastBrandTap = now
        if brandTapCount >= 5 {
            brandTapCount = 0
            dreamPresented = true
        } else {
            topReset += 1
            Task { await feed.refresh(sources: prefs.activeSources) }
        }
    }

    private func scheduleSourceRefresh() {
        sourceRefreshTask?.cancel()
        sourceRefreshTask = Task {
            do { try await Task.sleep(nanoseconds: 900_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            await feed.refresh(sources: prefs.activeSources)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            sectionSelector
            if selectedSourceID == nil { topicSelector }
            Rectangle().fill(Ink.rule(dark)).frame(height: 1)
            ZStack(alignment: .top) {
                if stories.isEmpty {
                    emptyState
                        .transition(.opacity)
                } else if compactMode {
                    compactFeed
                        .transition(.opacity)
                } else {
                    reader
                        .transition(.opacity)
                }
                if showRefreshNotice && !feed.failedSources.isEmpty {
                    Button { diagnosticsPresented = true } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.circle")
                            Text(prefs.language == "sr"
                                 ? "\(feed.failedSources.count) izvora nije osveženo · Detalji"
                                 : "\(feed.failedSources.count) sources not refreshed · Details")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Ink.text(dark))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 48).onEnded { gesture in
                let horizontal = gesture.translation.width
                guard selectedSourceID == nil, abs(horizontal) > 80,
                      abs(horizontal) > abs(gesture.translation.height) * 1.7 else { return }
                shiftTopic(horizontal < 0 ? 1 : -1)
            })
        }
        .background(Ink.paper(dark).ignoresSafeArea())
        .foregroundStyle(Ink.text(dark))
        .sheet(isPresented: $settingsPresented) { SettingsView() }
        .sheet(isPresented: $savedPresented) { SavedArticlesView() }
        .sheet(isPresented: $diagnosticsPresented) { SourceDiagnosticsView() }
        .sheet(item: $visiting) { destination in SafariReader(url: destination.url).ignoresSafeArea() }
        .sheet(item: $fullArticle) { item in OfflineArticleView(item: item) }
        .fullScreenCover(isPresented: $dreamPresented) { DreamGateJourneyView() }
        .overlay {
            if showSplash { SignatureSplash { showSplash = false } }
        }
        .task {
            await feed.refresh(sources: prefs.activeSources)
            await cloudVault.automaticBackupIfDue(feed: feed)
        }
        .onChange(of: cloudVault.wifiAvailable) { _, available in
            if available {
                Task {
                    await cloudVault.automaticBackupIfDue(feed: feed)
                    await feed.autoCompleteMissingText(wifiAvailable: available)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await feed.autoCompleteMissingText(wifiAvailable: cloudVault.wifiAvailable) }
            }
        }
        .task(id: feed.archiveRevision) {
            guard feed.archiveRevision > 0 else { return }
            await cloudVault.automaticBackupIfDue(feed: feed)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                guard !Task.isCancelled else { break }
                await cloudVault.automaticBackupIfDue(feed: feed)
                await feed.autoCompleteMissingText(wifiAvailable: cloudVault.wifiAvailable)
            }
        }
        .onChange(of: prefs.sourceSignature) { _, _ in
            // While the source picker is open, leave the reader undisturbed.
            // Refresh once after Settings closes, not after every RSS tap.
            if !settingsPresented { scheduleSourceRefresh() }
        }
        .onChange(of: settingsPresented) { _, presented in
            if presented { sourcesBeforeSettings = prefs.sourceSignature }
            else if sourcesBeforeSettings != prefs.sourceSignature { scheduleSourceRefresh() }
        }
        .onChange(of: feed.refreshRevision) { _, _ in
            Task(priority: .utility) {
                await feed.autoCompleteMissingText(wifiAvailable: cloudVault.wifiAvailable)
            }
        }
        .onChange(of: prefs.visibleTopicIDs) { _, _ in
            if !prefs.visibleTopics.contains(NewsTopic(rawValue: serbiaTopic) ?? .all) { serbiaTopic = NewsTopic.all.rawValue }
            if !prefs.visibleTopics.contains(NewsTopic(rawValue: worldTopic) ?? .all) { worldTopic = NewsTopic.all.rawValue }
        }
        .task(id: feed.refreshRevision) {
            guard feed.refreshRevision > 0 else { return }
            withAnimation(.easeInOut(duration: 0.24)) {
                showRefreshNotice = !feed.failedSources.isEmpty
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.3)) { showRefreshNotice = false }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 13) {
            Button(action: tapBrand) {
                HStack(spacing: 13) {
                    SitoGlyph(size: 27)
                    Text("SITO")
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .tracking(4.1)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(prefs.language == "sr" ? "Na početak i osveži" : "Back to top and refresh")
            Spacer()
            if feed.loading { ProgressView().controlSize(.small).tint(Ink.red) }
            Button { withAnimation(.easeInOut(duration: 0.2)) { compactMode.toggle() } } label: {
                Image(systemName: compactMode ? "text.alignleft" : "list.bullet")
                    .font(.system(size: 18, weight: .regular))
            }
            .accessibilityLabel(compactMode
                                ? (prefs.language == "sr" ? "Prebaci na Reader prikaz" : "Switch to reader view")
                                : (prefs.language == "sr" ? "Prebaci na listu vesti" : "Switch to compact list"))
            Button { savedPresented = true } label: {
                Image(systemName: "bookmark")
                    .font(.system(size: 18, weight: .regular))
            }
            .accessibilityLabel(prefs.language == "sr" ? "Sačuvane vesti" : "Bookmarks")
            Button { settingsPresented = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 19))
            }
            .accessibilityLabel(prefs.language == "sr" ? "Podešavanja" : "Settings")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 23)
        .frame(height: 61)
    }

    private var sectionSelector: some View {
        HStack(spacing: 20) {
            ForEach(NewsSection.allCases) { choice in
                Button { withAnimation(.easeInOut(duration: 0.22)) { section = choice } } label: {
                    VStack(spacing: 7) {
                        Text(prefs.language == "sr" ? (choice == .serbia ? "SRBIJA" : "SVET") : (choice == .serbia ? "SERBIA" : "WORLD"))
                            .font(.system(size: 11, weight: section == choice ? .semibold : .medium))
                            .tracking(2.0)
                            .foregroundStyle(section == choice ? Ink.text(dark) : Ink.muted(dark))
                        Rectangle().fill(section == choice ? Ink.red : .clear).frame(height: 2)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            Spacer()
            Menu {
                Button { chooseSource(nil) } label: {
                    if selectedSourceID == nil { Label(prefs.language == "sr" ? "Svi izvori" : "All sources", systemImage: "checkmark") }
                    else { Text(prefs.language == "sr" ? "Svi izvori" : "All sources") }
                }
                ForEach(prefs.activeSources.filter { $0.section == section }) { source in
                    Button { chooseSource(source.id) } label: {
                        if selectedSourceID == source.id { Label(source.name, systemImage: "checkmark") }
                        else { Text(source.name) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text(selectedSourceName ?? (prefs.language == "sr" ? "Svi izvori" : "All sources"))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selectedSourceID == nil ? Ink.muted(dark) : Ink.red)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 25)
        .frame(height: 43, alignment: .bottom)
    }

    private var topicSelector: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(prefs.visibleTopics) { topic in
                    let chosen = topic == selectedTopic
                    Button { chooseTopic(topic) } label: {
                        Text(topic.title(prefs.language))
                            .font(.system(size: 11, weight: chosen ? .semibold : .regular))
                            .tracking(0.25)
                            .foregroundStyle(chosen ? Ink.text(dark) : Ink.muted(dark))
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background {
                                if chosen {
                                    Capsule().fill(Ink.red.opacity(dark ? 0.24 : 0.11))
                                        .matchedGeometryEffect(id: "selectedTopic", in: topicHighlight)
                                } else {
                                    Capsule().fill(Ink.rule(dark).opacity(0.24))
                                }
                            }
                            .overlay {
                                Capsule().stroke(chosen ? Ink.red.opacity(0.6) : .clear, lineWidth: 0.75)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(.horizontal, 23)
            .padding(.vertical, 9)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: selectedTopic)
    }

    private var reader: some View {
        GeometryReader { viewport in
            if prefs.readingStyle == .snap {
                storyScroll(viewport: viewport.size.height).scrollTargetBehavior(.paging)
            } else {
                storyScroll(viewport: viewport.size.height)
            }
        }
    }

    private var compactFeed: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(stories) { article in
                    CompactStoryRow(item: article,
                                    onRead: { visiting = WebDestination(url: article.url) },
                                    onCapture: { fullArticle = article })
                    Rectangle().fill(Ink.rule(dark)).frame(height: 1).padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .refreshable { await feed.refresh(sources: prefs.activeSources) }
        .id("\(section.rawValue)-\(selectedTopic.rawValue)-\(selectedSourceID ?? "all")-\(topReset)")
    }

    private func storyScroll(viewport: CGFloat) -> some View {
        // Freeze this derived list for the current render. Accessing
        // `stories[index]` inside ForEach used to re-filter and re-mix the
        // entire feed for every visible card during a scroll.
        let rendered = stories
        return ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rendered.enumerated()), id: \.element.id) { entry in
                        let index = entry.offset
                        let article = entry.element
                        StoryCard(item: article, ordinal: index + 1, total: rendered.count,
                                  viewport: viewport, snap: prefs.readingStyle == .snap,
                                  onRead: { visiting = WebDestination(url: article.url) },
                                  onCapture: { fullArticle = article })
                        .frame(height: prefs.readingStyle == .snap ? viewport : nil)
                        .clipped()
                        if prefs.readingStyle == .ribbon {
                            Rectangle().fill(Ink.rule(dark)).frame(height: 1).padding(.horizontal, 25)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .refreshable { await feed.refresh(sources: prefs.activeSources) }
            .id("\(section.rawValue)-\(prefs.readingStyle.rawValue)-\(selectedTopic.rawValue)-\(selectedSourceID ?? "all")-\(topReset)")
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            SitoGlyph(size: 42).opacity(0.7)
            Text(sectionStories.isEmpty
                 ? (prefs.language == "sr" ? "Ovde će se pojaviti vesti." : "News will appear here.")
                 : selectedSourceID != nil
                 ? (prefs.language == "sr" ? "Ovaj izvor trenutno nema vesti." : "No stories from this source yet.")
                 : (prefs.language == "sr" ? "Još nema vesti u ovoj kategoriji." : "No stories in this category yet."))
                .font(.system(size: 23, design: .serif))
                .multilineTextAlignment(.center)
            Text(sectionStories.isEmpty
                 ? (prefs.language == "sr" ? "Osveži ili proveri uključene izvore." : "Refresh or review enabled sources.")
                 : selectedSourceID != nil
                 ? (prefs.language == "sr" ? "Osveži ili izaberi sve izvore." : "Refresh or return to all sources.")
                 : (prefs.language == "sr" ? "Probaj drugu temu ili prikaži sve članke." : "Choose another topic or see every story."))
                .font(.system(size: 13)).foregroundStyle(Ink.muted(dark))
            Button(sectionStories.isEmpty
                   ? (prefs.language == "sr" ? "Osveži" : "Refresh")
                   : (prefs.language == "sr" ? "Prikaži sve" : "Show all")) {
                if sectionStories.isEmpty {
                    Task { await feed.refresh(sources: prefs.activeSources) }
                } else if selectedSourceID != nil { chooseSource(nil); chooseTopic(.all) }
                else { chooseTopic(.all) }
            }
            .buttonStyle(.borderedProminent).tint(Ink.red)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(34)
    }
}

struct CompactStoryRow: View {
    @EnvironmentObject private var prefs: NewsPreferences
    @EnvironmentObject private var feed: NewsFeed
    @Environment(\.colorScheme) private var scheme
    let item: NewsItem
    let onRead: () -> Void
    let onCapture: () -> Void

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button(action: onRead) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle().fill(Ink.red).frame(width: 4, height: 4)
                            Text(item.sourceName.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(1.2)
                                .foregroundStyle(Ink.red)
                            Spacer(minLength: 1)
                            if item.published > Date(timeIntervalSince1970: 1_000_000_000) {
                                Text(item.published, style: .date)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Ink.muted(dark))
                            }
                        }
                        Text(item.title)
                            .font(.system(size: 20 * prefs.fontScale, weight: .medium, design: .serif))
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(Ink.text(dark))
                        if !item.summary.isEmpty {
                            Text(item.summary)
                                .font(.system(size: 14.5 * prefs.fontScale, design: .serif))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(Ink.muted(dark))
                        }
                    }
                    if prefs.showImages && (item.imageURL != nil || item.section == .world || item.sourceID == "raspad") {
                        ArticleThumbnail(item: item, dark: dark, small: true)
                            .frame(width: 94, height: 92)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 22) {
                if let status = item.sourceStatus {
                    Text(prefs.language == "sr" ? "IZVOR: \(status.uppercased())" :
                            (status == "zvanično" ? "SOURCE: OFFICIAL" : "SOURCE: CONFIRMED"))
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(Ink.red)
                }
                Spacer(minLength: 0)
                ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel(prefs.language == "sr" ? "Podeli link" : "Share link")
                Button(action: onCapture) { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel(prefs.language == "sr" ? "Sačuvaj pun PDF" : "Save full PDF")
                Button { feed.toggleSaved(item) } label: {
                    Image(systemName: feed.isSaved(item) ? "bookmark.fill" : "bookmark")
                }
                .accessibilityLabel(prefs.language == "sr" ? "Sačuvaj članak" : "Save article")
            }
            .font(.system(size: 16))
            .foregroundStyle(Ink.text(dark))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }
}

struct StoryCard: View {
    @EnvironmentObject private var prefs: NewsPreferences
    @EnvironmentObject private var feed: NewsFeed
    @Environment(\.colorScheme) private var scheme
    let item: NewsItem
    let ordinal: Int
    let total: Int
    let viewport: CGFloat
    let snap: Bool
    let onRead: () -> Void
    let onCapture: () -> Void

    private var dark: Bool { scheme == .dark }
    private var compact: Bool { viewport < 630 }
    private var relativeDate: String {
        guard item.published > Date(timeIntervalSince1970: 1_000_000_000) else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: prefs.language)
        return formatter.localizedString(for: item.published, relativeTo: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onRead) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        HStack(spacing: 8) {
                            Circle().fill(Ink.red).frame(width: 5, height: 5)
                            Text(item.sourceName.uppercased()).foregroundStyle(Ink.text(dark))
                        }
                        Spacer()
                        Text(relativeDate).foregroundStyle(Ink.muted(dark))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Ink.muted(dark))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .padding(.top, snap ? 24 : 35)

                    if let status = item.sourceStatus {
                        Text((prefs.language == "sr" ? "STATUS IZVORA: " : "SOURCE STATUS: ") +
                             (prefs.language == "sr" ? status.uppercased() : (status == "zvanično" ? "OFFICIAL" : "CONFIRMED")))
                            .font(.system(size: 9, weight: .medium))
                            .tracking(1.1)
                            .foregroundStyle(Ink.red)
                            .padding(.top, 10)
                    }

                    if prefs.showImages && (item.imageURL != nil || item.section == .world || item.sourceID == "raspad") {
                        ArticleThumbnail(item: item, dark: dark)
                            .frame(maxWidth: .infinity)
                            .frame(height: compact ? 120 : (snap ? min(230, viewport * 0.28) : min(300, viewport * 0.32)))
                            .clipped()
                            .overlay(alignment: .bottom) {
                                LinearGradient(colors: [.clear, Ink.paper(dark).opacity(0.17)], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 42)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .padding(.top, compact ? 15 : 24)
                            .accessibilityHidden(true)
                    }

                    Text(item.title)
                        .font(.system(size: (compact ? 25 : 31) * prefs.fontScale, weight: .medium, design: .serif))
                        .tracking(-0.6)
                        .lineSpacing(3)
                        .lineLimit(snap ? (compact ? 4 : 5) : nil)
                        .minimumScaleFactor(snap ? 0.89 : 1)
                        .fixedSize(horizontal: false, vertical: !snap)
                        .padding(.top, compact ? 16 : 23)

                    Rectangle().fill(Ink.red).frame(width: 24, height: 2).padding(.top, compact ? 13 : 20)

                    if !item.summary.isEmpty {
                        Text(item.summary)
                            .font(.system(size: (compact ? 15.5 : 17.5) * prefs.fontScale, weight: .regular, design: .serif))
                            .lineSpacing(5)
                            .foregroundStyle(Ink.text(dark).opacity(0.84))
                            .lineLimit(snap ? (compact ? 3 : 6) : nil)
                            .fixedSize(horizontal: false, vertical: !snap)
                            .padding(.top, compact ? 13 : 19)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel((prefs.language == "sr" ? "Otvori: " : "Open: ") + item.title)

            Spacer(minLength: snap ? 10 : 36)
            HStack(spacing: 13) {
                Spacer()
                ShareLink(item: item.url) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 18))
                }
                .accessibilityLabel(prefs.language == "sr" ? "Podeli link" : "Share link")
                Button(action: onCapture) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 18))
                }
                .accessibilityLabel(prefs.language == "sr" ? "Sačuvaj punu vest kao PDF" : "Save complete article as PDF")
                Button { withAnimation(.easeOut(duration: 0.2)) { feed.toggleSaved(item) } } label: {
                    Image(systemName: feed.isSaved(item) ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 19))
                }
                .accessibilityLabel(prefs.language == "sr" ? "Sačuvaj vest" : "Save article")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.text(dark))
            .padding(.vertical, 19)
            Rectangle().fill(Ink.rule(dark)).frame(height: 1)
            HStack {
                Text(String(format: "%02d", ordinal))
                    .foregroundStyle(Ink.text(dark))
                Text("/")
                Text(String(format: "%02d", total))
                Spacer()
                Text(prefs.language == "sr" ? "IZVOR: \(item.sourceName.uppercased())" : "SOURCE: \(item.sourceName.uppercased())")
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(1.0)
            .foregroundStyle(Ink.muted(dark))
            .padding(.top, 13)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, compact ? 24 : 29)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .frame(minHeight: snap ? nil : viewport)
        .frame(height: snap ? viewport : nil, alignment: .top)
        .background(Ink.paper(dark))
        .clipped()
    }
}

struct ArticleThumbnail: View {
    let item: NewsItem
    let dark: Bool
    var small: Bool = false
    @State private var resolvedURL: URL?
    @State private var triedFallback = false

    var body: some View {
        Group {
            if let url = resolvedURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure:
                        placeholder.task { await lookUpImage() }
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .task(id: item.id) {
            resolvedURL = item.imageURL
            triedFallback = false
            if resolvedURL == nil { await lookUpImage() }
        }
    }

    private func lookUpImage() async {
        guard !triedFallback else { return }
        triedFallback = true
        if let alternative = await ThumbnailResolver.shared.resolve(for: item.url) {
            resolvedURL = alternative
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: dark
                ? [Color(red: 0.20, green: 0.20, blue: 0.23), Color(red: 0.10, green: 0.10, blue: 0.12)]
                : [Color(red: 0.88, green: 0.86, blue: 0.83), Color(red: 0.76, green: 0.76, blue: 0.75)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            if small {
                SitoGlyph(size: 23).opacity(0.32)
            } else {
                HStack(alignment: .center) {
                    Rectangle().fill(Ink.red).frame(width: 3, height: 36)
                    Text(item.sourceName.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(dark ? Color.white.opacity(0.65) : Color.black.opacity(0.52))
                    Spacer()
                    SitoGlyph(size: 30).opacity(0.25)
                }
                .padding(.horizontal, 22)
            }
        }
    }
}

struct SignatureSplash: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let finish: () -> Void
    @State private var phase = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if phase > 0 {
                ZStack {
                    Rectangle().fill(Ink.red)
                        .frame(width: 34, height: 34)
                        .offset(x: phase == 2 ? 2 : 0, y: phase == 3 ? -1 : 0)
                    if phase == 2 || phase == 3 {
                        Rectangle().fill(.black).frame(width: 39, height: 2).offset(y: -7)
                        Rectangle().fill(Ink.red.opacity(0.6)).frame(width: 15, height: 3).offset(x: 17, y: 10)
                    }
                }
            }
        }
        .accessibilityHidden(true)
        .task {
            if reduceMotion {
                try? await Task.sleep(nanoseconds: 160_000_000)
                finish(); return
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            phase = 1
            try? await Task.sleep(nanoseconds: 170_000_000)
            phase = 2
            try? await Task.sleep(nanoseconds: 72_000_000)
            phase = 1
            try? await Task.sleep(nanoseconds: 126_000_000)
            phase = 3
            try? await Task.sleep(nanoseconds: 65_000_000)
            phase = 1
            try? await Task.sleep(nanoseconds: 150_000_000)
            finish()
        }
    }
}
