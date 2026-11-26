import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SharePayload: Identifiable {
    let id = UUID()
    let files: [URL]
}

struct ActivitySheet: UIViewControllerRepresentable {
    let files: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: files, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var prefs: NewsPreferences
    @EnvironmentObject private var feed: NewsFeed
    @State private var showNewSource = false
    @State private var showSourceLibrary = false
    @State private var importing = false
    @State private var share: SharePayload?
    @State private var errorMessage = ""
    @State private var showMessage = false
    @State private var visiting: WebDestination?
    @State private var showArchive = false
    @State private var showStorage = false
    @State private var showDiagnostics = false
    @State private var topicsExpanded = false
    @State private var sourcesExpanded = false
    @AppStorage("advancedOptionsEnabled") private var advancedOptions = false

    private func tr(_ sr: String, _ en: String) -> String { prefs.language == "sr" ? sr : en }

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("Čitanje", "Reading")) {
                    Picker(tr("Način skrolovanja", "Scroll mode"), selection: $prefs.readingStyle) {
                        Text(tr("Neprekidno", "Continuous")).tag(ReadingStyle.ribbon)
                        Text(tr("Ekran po ekran", "Page by page")).tag(ReadingStyle.snap)
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Text(tr("Veličina teksta", "Text size"))
                            Spacer()
                            Text("\(Int(prefs.fontScale * 100)) %").foregroundStyle(.secondary)
                        }
                        Slider(value: $prefs.fontScale, in: 0.85...1.4, step: 0.05).tint(Ink.red)
                        Text(tr("Primer čitljivog teksta u režimu knjige.", "An example of comfortable book-like reading."))
                            .font(.system(size: 17 * prefs.fontScale, design: .serif))
                            .foregroundStyle(.secondary)
                    }
                    Toggle(tr("Fotografije uz vesti", "Show story photos"), isOn: $prefs.showImages)
                        .tint(Ink.red)
                    Text(tr("Podrazumevano: miran prikaz poput e-knjige. Ceo članak se otvara uz Reader način kada ga izvor podržava.",
                            "Default: calm ebook-like typography. Full articles open in Reader mode whenever supported by the publisher."))
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section(tr("Izgled i jezik", "Appearance & language")) {
                    Picker(tr("Tema", "Theme"), selection: $prefs.colorPreference) {
                        Text(tr("Sistem", "System")).tag(ColorPreference.system)
                        Text(tr("Svetla", "Light")).tag(ColorPreference.light)
                        Text(tr("Tamna", "Dark")).tag(ColorPreference.dark)
                    }
                    .pickerStyle(.segmented)
                    Picker(tr("Jezik aplikacije", "Interface language"), selection: $prefs.language) {
                        Text("Srpski").tag("sr")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                    Text(tr("Naslovi i tekstovi ostaju na jeziku originalnog izvora.",
                            "Article titles and text stay in the original publisher language."))
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup(isExpanded: $sourcesExpanded) {
                        Text(tr("Srbija", "Serbia")).font(.caption).foregroundStyle(.secondary)
                        ForEach(prefs.sources.filter { $0.section == .serbia }) { source in sourceRow(source) }
                        Text(tr("Svet", "World")).font(.caption).foregroundStyle(.secondary)
                        ForEach(prefs.sources.filter { $0.section == .world }) { source in sourceRow(source) }
                    } label: {
                        HStack {
                            Label(tr("Izvori vesti", "News sources"), systemImage: "dot.radiowaves.left.and.right")
                            Spacer()
                            Text("\(prefs.activeSources.count)").font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Toggle(isOn: $advancedOptions) {
                        Label(tr("Napredna podešavanja", "Advanced Options"), systemImage: "slider.horizontal.3")
                    }
                    .tint(Ink.red)
                } footer: {
                    Text(tr("Dodatni alati za izvore, kategorije, skladište i privatni cloud. Svakodnevno čitanje ostaje jednostavno.",
                            "Extra tools for feeds, categories, storage and private cloud. Everyday reading stays simple."))
                }

                if advancedOptions {
                Section {
                    DisclosureGroup(isExpanded: $topicsExpanded) {
                        ForEach(NewsTopic.allCases.filter { $0 != .all }) { topic in
                            Toggle(topic.title(prefs.language), isOn: Binding(
                                get: { prefs.visibleTopicIDs.contains(topic.rawValue) },
                                set: { prefs.setTopicVisible(topic, $0) }
                            )).tint(Ink.red)
                        }
                    } label: {
                        HStack {
                            Label(tr("Kategorije", "Categories"), systemImage: "square.grid.2x2")
                            Spacer()
                            Text("\(prefs.visibleTopics.count)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text(tr("Prikaz tema", "Topics")) }

                Section {
                    Button { showSourceLibrary = true } label: {
                        Label(tr("Otkrij izvore · katalog", "Discover sources · library"), systemImage: "square.stack.3d.up")
                    }
                    Button { showNewSource = true } label: {
                        Label(tr("Ručno dodaj RSS", "Add a feed manually"), systemImage: "plus.circle")
                    }
                    Button { showDiagnostics = true } label: {
                        Label(tr("Status i dijagnostika izvora", "Source status & diagnostics"),
                              systemImage: "waveform.path.ecg")
                    }
                    Button(tr("Vrati početni izbor izvora", "Reset default sources")) { prefs.resetSources() }
                } footer: {
                    Text(tr("Pretraži ugrađene predloge ili osveži OPML katalog sa GitHuba. Nijedan izvor se ne dodaje bez tvog izbora.",
                            "Browse built-in picks or refresh OPML directories from GitHub. No feed is added without your choice."))
                }
                }

                Section(tr("Lokalna arhiva i backup", "Local archive & backup")) {
                    LabeledContent(tr("Arhiviranih vesti", "Archived stories"), value: "\(feed.archiveCount)")
                    Button { showArchive = true } label: {
                        Label(tr("Pretraži istoriju vesti", "Search article history"), systemImage: "archivebox")
                    }
                    if advancedOptions {
                    LabeledContent(tr("Kompletnih PDF članaka", "Complete PDF articles"), value: "\(feed.completeArticles.count)")
                    Button { showStorage = true } label: {
                        Label(tr("Skladište i backup", "Storage & Backups"), systemImage: "externaldrive.badge.icloud")
                    }
                    Button { makeJSON() } label: {
                        Label(tr("Izvezi arhivu · JSON", "Export archive · JSON"), systemImage: "square.and.arrow.up")
                    }
                    Button { makePDF() } label: {
                        Label(tr("Izvezi pregled · PDF", "Export reading digest · PDF"), systemImage: "doc.richtext")
                    }
                    Button { shareCompletePDFs() } label: {
                        Label(tr("Izvezi pune sačuvane PDF-ove", "Export saved full PDFs"), systemImage: "doc.on.doc")
                    }
                    .disabled(feed.completeArticles.isEmpty)
                    Button { importing = true } label: {
                        Label(tr("Uvezi arhivu · JSON", "Import archive · JSON"), systemImage: "square.and.arrow.down")
                    }
                    Text(tr("Arhivu možeš šifrovano izvesti u bilo koji Files servis ili koristiti automatski Cloudflare D1. Stara istorija se može obrisati bez brisanja sačuvanih članaka; JSON i PDF izvoz ostaju zasebno.",
                            "Export an encrypted archive to any Files destination, or use automatic Cloudflare D1 backup. Old history can be cleaned without touching saved articles; JSON and PDF exports remain available."))
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section(tr("O aplikaciji", "About")) {
                    HStack(spacing: 6) {
                        Text("developed by").foregroundStyle(.secondary)
                        Link(destination: URL(string: "mailto:seraphiheaven@gmail.com")!) {
                            SeraphiMark()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("Kontaktiraj seraphi mejlom", "Email seraphi"))
                    }
                    .font(.system(size: 14, design: .monospaced))
                    LabeledContent(tr("Verzija", "Version"), value: "0.9.4")
                }
            }
            .navigationTitle(tr("Podešavanja", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(tr("Gotovo", "Done")) { dismiss() }.tint(Ink.red)
                }
            }
        }
        .sheet(isPresented: $showNewSource) { AddSourceView() }
        .sheet(isPresented: $showSourceLibrary) { SourceLibraryView() }
        .sheet(isPresented: $showArchive) { ArchiveView() }
        .sheet(isPresented: $showStorage) { StorageView() }
        .sheet(isPresented: $showDiagnostics) { SourceDiagnosticsView() }
        .sheet(item: $share) { payload in ActivitySheet(files: payload.files) }
        .sheet(item: $visiting) { destination in SafariReader(url: destination.url) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let added = try feed.importJSON(try result.get())
                inform(tr("Uvoz završen. Dodato je \(added) novih vesti.", "Import complete. Added \(added) stories."))
            } catch { inform(error.localizedDescription) }
        }
        .alert(tr("Arhiva", "Archive"), isPresented: $showMessage) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage) }
    }

    @ViewBuilder private func sourceRow(_ source: NewsSource) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { prefs.enabledIDs.contains(source.id) },
                                 set: { prefs.setEnabled(source, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                    Text(source.id == "raspad" ? tr("veb", "web") :
                            (source.feed == nil ? tr("sajt", "website") : (source.custom ? tr("moj izvor", "custom feed") : "RSS")))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(Ink.red)
            if source.custom {
                Button(role: .destructive) { prefs.removeCustom(source) } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Ukloni izvor", "Remove source"))
            } else if source.feed == nil && source.id != "raspad" {
                Button {
                    if let url = URL(string: source.website) { visiting = WebDestination(url: url) }
                } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.plain)
            }
        }
    }

    private func inform(_ message: String) { errorMessage = message; showMessage = true }
    private func makeJSON() {
        do { share = SharePayload(files: [try feed.exportJSON()]) }
        catch { inform(error.localizedDescription) }
    }
    private func makePDF() {
        do { share = SharePayload(files: [try DigestPDF.create(items: feed.archivedItems)]) }
        catch { inform(error.localizedDescription) }
    }
    private func shareCompletePDFs() {
        let urls = feed.completeItems.map { feed.completePDFURL(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { inform(tr("Nema lokalnih PDF fajlova.", "No local PDF files found.")) }
        else { share = SharePayload(files: urls) }
    }
}

struct SourceDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var prefs: NewsPreferences
    @EnvironmentObject private var feed: NewsFeed
    @State private var copied = false

    private var sr: Bool { prefs.language == "sr" }
    private var report: String {
        let lines = prefs.activeSources.map { source in
            guard let check = feed.sourceHealth[source.id] else { return "\(source.name): not checked" }
            return "\(source.name): \(check.failure ?? "OK (\(check.count) items)")"
        }
        return (["SITO 0.9.4 — feed diagnostics",
                 "Updated: \(feed.lastUpdated?.description ?? "No successful refresh")"] + lines).joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let refreshed = feed.lastUpdated {
                        LabeledContent(sr ? "Poslednje uspešno ažuriranje" : "Last successful update") {
                            Text(refreshed, style: .relative)
                        }
                    }
                    Text(sr
                         ? "Statusi potiču sa poslednjeg pokušaja učitavanja. HTTP 403/429, timeout i neispravan XML imaju različite uzroke. Ranije sačuvane vesti ostaju dostupne."
                         : "These are the results of the last refresh. HTTP 403/429, timeouts and malformed XML have different causes. Previously cached articles remain available.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(sr ? "Aktivni izvori" : "Enabled sources") {
                    ForEach(prefs.activeSources) { source in
                        let check = feed.sourceHealth[source.id]
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: check == nil ? "circle.dotted" :
                                  (check?.failure == nil ? "checkmark.circle.fill" : "exclamationmark.circle"))
                                .foregroundStyle(check?.failure == nil && check != nil ? Color.green :
                                                 (check == nil ? Color.secondary : Ink.red))
                                .font(.system(size: 17))
                                .frame(width: 23)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name).font(.system(size: 15, weight: .medium))
                                if let check {
                                    if let error = check.failure {
                                        Text(error)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(sr ? "\(check.count) učitanih vesti" : "\(check.count) articles loaded")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(sr ? "Još nije provereno" : "Not checked yet")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(sr ? "Status izvora" : "Source status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(sr ? "Osveži" : "Retry") {
                        Task { await feed.refresh(sources: prefs.activeSources) }
                    }
                    .disabled(feed.loading).tint(Ink.red)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = report
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_600_000_000)
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(sr ? "Kopiraj dijagnostiku" : "Copy diagnostics")
                    .tint(Ink.red)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(sr ? "Gotovo" : "Done") { dismiss() }.tint(Ink.red)
                }
            }
        }
    }
}

struct AddSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var prefs: NewsPreferences
    @State private var sourceName = ""
    @State private var urlText = ""
    @State private var section: NewsSection = .serbia
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                TextField(prefs.language == "sr" ? "Naziv izvora" : "Source name", text: $sourceName)
                TextField("https://www.techradar.com/rss", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                Picker(prefs.language == "sr" ? "Rubrika" : "Section", selection: $section) {
                    Text(prefs.language == "sr" ? "Srbija" : "Serbia").tag(NewsSection.serbia)
                    Text(prefs.language == "sr" ? "Svet" : "World").tag(NewsSection.world)
                }
                Text(prefs.language == "sr" ? "RSS, Atom, JSON Feed ili adresa sajta sa feedom. Koristi se isključivo HTTPS; možeš uneti adresu i bez https://." : "RSS, Atom, JSON Feed, or a website with feed discovery. HTTPS only; you can omit the https:// prefix.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle(prefs.language == "sr" ? "Novi izvor" : "New source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(prefs.language == "sr" ? "Otkaži" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(prefs.language == "sr" ? "Dodaj" : "Add") {
                        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let secure = raw.replacingOccurrences(of: "http://", with: "https://", options: [.anchored, .caseInsensitive])
                        let normalized = secure.contains("://") ? secure : "https://" + secure
                        guard let url = URL(string: normalized),
                              url.scheme == "https", url.host?.contains(".") == true,
                              !sourceName.trimmingCharacters(in: .whitespaces).isEmpty else { invalid = true; return }
                        prefs.addCustom(name: sourceName.trimmingCharacters(in: .whitespacesAndNewlines), url: url, section: section)
                        dismiss()
                    }
                    .fontWeight(.semibold).tint(Ink.red)
                }
            }
        }
        .alert(prefs.language == "sr" ? "Unesi naziv i ispravan HTTPS URL." : "Enter a name and valid HTTPS URL.", isPresented: $invalid) { Button("OK", role: .cancel) {} }
    }
}

struct SeraphiMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glitch = false

    var body: some View {
        ZStack {
            Text("seraphi").foregroundStyle(.primary)
            if glitch && !reduceMotion {
                Text("seraphi")
                    .foregroundStyle(Ink.red.opacity(0.85))
                    .offset(x: 1.2, y: -0.7)
                    .mask(alignment: .center) { Rectangle().frame(height: 3).offset(y: -2) }
            }
        }
        .accessibilityLabel("seraphi")
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64.random(in: 4...9) * 1_000_000_000) }
                catch { break }
                if reduceMotion { continue }
                glitch = true
                do { try await Task.sleep(nanoseconds: UInt64.random(in: 60...110) * 1_000_000) }
                catch { break }
                glitch = false
            }
        }
    }
}
