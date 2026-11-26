import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum HistoryRange: Int, CaseIterable, Identifiable {
    case month = 30, threeMonths = 90, sixMonths = 180, year = 365, all = 0
    var id: Int { rawValue }
    func label(_ sr: Bool) -> String {
        switch self {
        case .month: return sr ? "30 dana" : "30 days"
        case .threeMonths: return sr ? "90 dana" : "90 days"
        case .sixMonths: return sr ? "6 meseci" : "6 months"
        case .year: return sr ? "Godinu dana" : "One year"
        case .all: return sr ? "Svu istoriju" : "All history"
        }
    }
    var cutoff: Date? { self == .all ? nil : Date().addingTimeInterval(-Double(rawValue) * 86_400) }
}

struct StorageView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var feed: NewsFeed
    @EnvironmentObject private var prefs: NewsPreferences
    @EnvironmentObject private var vault: CloudVault
    @State private var age = HistoryRange.threeMonths
    @State private var source = ""
    @State private var tokenInput = ""
    @State private var recoveryInput = ""
    @State private var visibleRecoveryKey: String?
    @AppStorage("portableBackupPDFs") private var portablePDFs = false
    @AppStorage("archiveAutoComplete") private var automaticText = true
    @AppStorage("archiveAutoWiFiOnly") private var automaticTextWiFiOnly = true
    @State private var captureDetailsExpanded = false
    @State private var portableImporting = false
    @State private var portableShare: SharePayload?
    @State private var temporaryExportURL: URL?
    @State private var confirmCleanup = false
    @State private var confirmRestore = false
    @State private var confirmPreviousRestore = false
    @State private var confirmRecoveryReplace = false
    @State private var error: String?
    @State private var showError = false

    private var sr: Bool { prefs.language == "sr" }
    private func tr(_ serbian: String, _ english: String) -> String { sr ? serbian : english }
    private var selectedSource: String? { source.isEmpty ? nil : source }
    private var removable: Int { feed.removableCount(olderThan: age.cutoff, sourceName: selectedSource) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(tr("Vesti u istoriji", "Stories in history"), value: "\(feed.archiveCount)")
                    LabeledContent(tr("Sačuvan ceo tekst", "Full text saved"),
                                   value: "\(feed.archiveFullTextCount) / \(feed.archiveCount)")
                    LabeledContent(tr("Baza i arhiva", "History database"),
                                   value: ByteCountFormatter.string(fromByteCount: feed.archiveStorageBytes, countStyle: .file))
                    LabeledContent(tr("Lokalni PDF-ovi", "Offline PDFs"),
                                   value: ByteCountFormatter.string(fromByteCount: feed.pdfStorageBytes, countStyle: .file))
                    LabeledContent(tr("Sačuvani članci", "Bookmarked stories"), value: "\(feed.saved.count)")
                    if let archiveError = feed.archiveError {
                        Text(archiveError).font(.footnote).foregroundStyle(.red)
                    }
                } header: { Text(tr("Na ovom iPhone-u", "On this iPhone")) }
                  footer: {
                    Text(tr("Tekst, naslov, datum, izvor, link, kategorije i dostupni metapodaci čuvaju se u SQLite bazi bez slika. Brojač razlikuje ceo tekst od RSS opisa.",
                            "Text, title, date, publisher, URL, categories and available metadata are stored in SQLite without images. The counter distinguishes full text from RSS previews."))
                }

                Section {
                    Toggle(tr("Automatski dopunjavaj tekstove", "Complete missing texts automatically"),
                           isOn: $automaticText).tint(Ink.red)
                    if automaticText {
                        Toggle(tr("Samo preko Wi-Fi mreže", "Wi-Fi only"), isOn: $automaticTextWiFiOnly)
                            .tint(Ink.red)
                    }
                    Button {
                        Task { await feed.completeMissingText(limit: 40) }
                    } label: {
                        Label(tr("Dopuni sledećih 40 tekstova", "Complete the next 40 articles"),
                              systemImage: "text.book.closed")
                    }
                    .disabled(feed.textCaptureActive || feed.archiveFullTextCount == feed.archiveCount)
                    if feed.textCaptureActive {
                        ProgressView(value: Double(feed.textCaptureDone),
                                     total: Double(max(1, feed.textCaptureTarget))) {
                            Text(tr("Dopunjavam arhivu · \(feed.textCaptureDone)/\(feed.textCaptureTarget)",
                                    "Enriching archive · \(feed.textCaptureDone)/\(feed.textCaptureTarget)"))
                        }.tint(Ink.red)
                        Button(tr("Zaustavi posle ove vesti", "Stop after this article")) {
                            feed.stopCompletingText()
                        }.font(.footnote).foregroundStyle(.secondary)
                    }
                    if let latest = feed.lastTextCapture {
                        LabeledContent(tr("Poslednja dopuna", "Last text batch")) {
                            Text("\(latest.completed)/\(latest.attempted) · " +
                                 latest.finishedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote.monospacedDigit())
                        }
                    }
                    if !feed.textCaptureStats.isEmpty {
                        DisclosureGroup(isExpanded: $captureDetailsExpanded) {
                            ForEach(feed.textCaptureStats.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { stat in
                                LabeledContent(stat.name, value: "\(stat.completed)/\(stat.attempts)")
                                    .font(.footnote)
                            }
                            Text(tr("Broj uspeha u pokušajima dopunjavanja, ne procenat svih vesti tog izvora.",
                                    "Successful attempts, not the percentage of all stories published by each source."))
                                .font(.caption2).foregroundStyle(.secondary)
                        } label: {
                            Label(tr("Uspešnost po izvoru", "Capture results by source"),
                                  systemImage: "chart.bar.xaxis")
                        }
                    }
                } header: { Text(tr("Puni tekst bez slika", "Full text without images")) }
                  footer: {
                    Text(tr("Najviše 24 automatska pokušaja dnevno, u malim razmacima, samo kada iOS dozvoli rad. Ušteda energije je prioritet. Neuspešne stranice pokušavaju se ponovo najviše jednom mesečno. Procena potpunosti teksta je pažljiva, ali nije garancija verne kopije stranice.",
                            "Up to 24 automatic attempts a day, in small batches, whenever iOS permits. Energy use stays low. Failed pages are retried at most monthly. Full-text detection is conservative, not a guarantee of perfect page fidelity."))
                }

                Section {
                    Toggle(tr("Dodaj ručno sačuvane PDF-ove (sa slikama)", "Include manually saved PDFs (with images)"),
                           isOn: $portablePDFs).tint(Ink.red)
                    Button {
                        Task {
                            do {
                                let url = try await vault.exportPortable(feed: feed, includePDFs: portablePDFs)
                                visibleRecoveryKey = try vault.recoveryKey()
                                temporaryExportURL = url
                                portableShare = SharePayload(files: [url])
                            } catch { report(error) }
                        }
                    } label: {
                        Label(tr("Sačuvaj šifrovani backup bilo gde", "Save encrypted backup anywhere"),
                              systemImage: "square.and.arrow.up")
                    }
                    .disabled(vault.busy || feed.textCaptureActive)
                    Button { portableImporting = true } label: {
                        Label(tr("Vrati iz backup fajla", "Restore from backup file"),
                              systemImage: "square.and.arrow.down")
                    }
                    .disabled(vault.busy)
                    if vault.busy { ProgressView(vault.status).tint(Ink.red) }
                } header: { Text(tr("Backup gde god želiš", "Backup anywhere")) }
                  footer: {
                    Text(tr("Tekst i svi dostupni metapodaci uvek su uključeni, bez preuzetih slika. Opcioni PDF-ovi sadrže originalnu stranicu i slike samo za članke koje si ručno sačuvao kao PDF. Šifrovani .sitobackup možeš smestiti u Files, cloud, na NAS ili Mac.",
                            "Full text and available metadata are always included, without downloaded images. Optional PDFs contain the original page and images only for articles you manually saved as PDF. Put the encrypted .sitobackup in Files, a cloud drive, NAS or Mac."))
                }

                Section {
                    HStack {
                        Text(tr("Ključ za oporavak", "Recovery key"))
                        Spacer()
                        Text(vault.hasKey ? tr("Sačuvan", "On device") : tr("Nedostaje", "Missing"))
                            .foregroundStyle(.secondary)
                    }
                    Button(vault.hasKey ? tr("Prikaži ključ", "Reveal recovery key") : tr("Napravi ključ", "Generate recovery key")) {
                        do { visibleRecoveryKey = try vault.recoveryKey() } catch { report(error) }
                    }
                    if let visibleRecoveryKey {
                        Text(visibleRecoveryKey).font(.caption.monospaced()).textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = visibleRecoveryKey
                        } label: { Label(tr("Kopiraj ključ", "Copy key"), systemImage: "doc.on.doc") }
                        Button(tr("Sakrij ključ", "Hide key")) { self.visibleRecoveryKey = nil }
                    }
                    SecureField(tr("Unesi postojeći ključ za vraćanje", "Paste recovery key to restore"), text: $recoveryInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(tr("Uvezi ključ", "Import recovery key")) {
                        if vault.hasKey { confirmRecoveryReplace = true }
                        else { importKey() }
                    }.disabled(recoveryInput.isEmpty || vault.busy)
                } header: { Text(tr("Ključ za oba načina backupa", "Recovery key for both backups")) }
                  footer: {
                    Text(tr("Isti privatni ključ štiti i .sitobackup fajlove i Cloudflare backup. Sačuvaj ga van telefona. Bez njega nije moguće dešifrovati arhivu.",
                            "The same private key protects .sitobackup files and Cloudflare backups. Save it outside your phone; without it, your archive cannot be decrypted."))
                }

                Section {
                    Toggle(tr("Automatski backup", "Automatic backup"), isOn: $vault.enabled).tint(Ink.red)
                    Toggle(tr("Automatski backup samo preko Wi-Fi", "Auto backup over Wi-Fi only"), isOn: $vault.wifiOnly).tint(Ink.red)
                    Toggle(tr("Dodaj PDF-ove sa slikama (više prostora)", "Include PDFs with images (more storage)"), isOn: $vault.backupPDFs).tint(Ink.red)
                    if let lastBackup = vault.lastBackup {
                        LabeledContent(tr("Poslednji backup", "Last backup")) { Text(lastBackup, style: .relative) }
                        LabeledContent(tr("Integritet backupa", "Backup integrity")) {
                            Label(vault.latestBackupFullyVerified ?
                                  tr("Potpuno provereno", "Fully verified") :
                                  tr("Čeka punu proveru", "Full check pending"),
                                  systemImage: vault.latestBackupFullyVerified ? "checkmark.shield.fill" : "clock")
                                .font(.footnote)
                                .foregroundStyle(vault.latestBackupFullyVerified ? Color.green : Color.secondary)
                        }
                    } else {
                        LabeledContent(tr("Poslednji backup", "Last backup"), value: tr("Još nije urađen", "Never"))
                    }
                    if let lastRestore = vault.lastRestore {
                        LabeledContent(tr("Poslednje vraćanje", "Last restore")) { Text(lastRestore, style: .relative) }
                    }
                    if let lastVerification = vault.lastVerification {
                        LabeledContent(tr("Poslednja puna provera", "Last full verification")) {
                            Text(lastVerification, style: .relative)
                        }
                    }
                    if vault.busy { ProgressView(vault.status).tint(Ink.red) }
                    else if !vault.status.isEmpty {
                        Text(vault.status).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { do { try await vault.backup(feed: feed) } catch { report(error) } }
                    } label: { Label(tr("Backup sada", "Back Up Now"), systemImage: "icloud.and.arrow.up") }
                    .disabled(vault.busy || feed.textCaptureActive || !vault.hasToken || !vault.hasKey)
                    Button {
                        Task { do { try await vault.verifyCloudArchive() } catch { report(error) } }
                    } label: {
                        Label(tr("Proveri cloud arhivu", "Verify Cloud Archive"), systemImage: "checkmark.shield")
                    }
                    .disabled(vault.busy || !vault.hasToken || !vault.hasKey)
                    Button { confirmRestore = true } label: {
                        Label(tr("Vrati arhivu iz clouda", "Restore from Cloud"), systemImage: "arrow.down.doc")
                    }
                    .disabled(vault.busy || !vault.hasToken || !vault.hasKey)
                    Button(tr("Vrati prethodni cloud backup", "Restore previous cloud backup")) {
                        confirmPreviousRestore = true
                    }
                    .disabled(vault.busy || !vault.hasToken || !vault.hasKey)
                } header: { Text(tr("Privatni Cloudflare D1", "Private Cloudflare D1")) }
                  footer: {
                    Text(tr("Svi pouzdano preuzeti tekstovi i metapodaci idu šifrovani u backup. Provera clouda ponovo preuzima i dešifruje sve pakete i proverava broj celih tekstova, bez menjanja ijednog podatka. PDF-ovi sa slikama su opcioni; D1 Free ima ograničen prostor.",
                            "All reliably captured text and metadata are encrypted in each backup. Verify Cloud Archive downloads and authenticates every package and counts complete texts without changing any data. Image-rich PDFs are optional; D1 Free has a storage limit."))
                }

                Section {
                    TextField("https://your-vault.workers.dev", text: $vault.endpointText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField(tr("Pristupni token Workera", "Worker access token"), text: $tokenInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(vault.hasToken ? tr("Promeni token", "Update access token") : tr("Sačuvaj token", "Save access token")) {
                        do { try vault.saveToken(tokenInput); tokenInput = "" }
                        catch { report(error) }
                    }.disabled(tokenInput.isEmpty)
                } header: { Text(tr("Povezivanje tvog clouda", "Connect your own cloud")) }
                  footer: {
                    Text(tr("Svako može da podesi sopstveni privatni Cloudflare Worker i D1 bazu bez kartice. SITO ne sadrži ugrađene pristupne tokene. Uputstvo je u cloudflare/README.md.",
                            "Everyone can set up their own private Cloudflare Worker and D1 database without a credit card. SITO includes no built-in access tokens. Setup: cloudflare/README.md."))
                }

                Section {
                    Picker(tr("Starost vesti", "Article age"), selection: $age) {
                        ForEach(HistoryRange.allCases) { range in Text(range.label(sr)).tag(range) }
                    }
                    Picker(tr("Izvor", "Source"), selection: $source) {
                        Text(tr("Svi izvori", "All sources")).tag("")
                        ForEach(feed.archiveSourceNames, id: \.self) { name in Text(name).tag(name) }
                    }
                    LabeledContent(tr("Može da se ukloni", "Eligible for removal"), value: "\(removable)")
                    Button(role: .destructive) { confirmCleanup = true } label: {
                        Label(tr("Oslobodi lokalni prostor", "Free Local Storage"), systemImage: "trash")
                    }
                    .disabled(removable == 0 && feed.archiveStorageBytes == 0)
                } header: { Text(tr("Upravljanje istorijom", "Manage history")) }
                  footer: {
                    Text(tr("Bookmarkovi i lokalni PDF-ovi se nikada ne brišu ovim postupkom. Preporučuje se proveren backup pre čišćenja. Nova osvežavanja mogu ponovo dodati najnovije vesti u istoriju.",
                            "Bookmarks and offline PDFs are always preserved. Verify a backup before cleaning up. Future feed refreshes may add recent articles to history again."))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Ink.paper(false).opacity(0.04))
            .navigationTitle(tr("Arhiva i backup", "Archive & Backup"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button(tr("Gotovo", "Done")) { dismiss() }.tint(Ink.red)
            } }
        }
        .confirmationDialog(tr("Obrisati izabrane lokalne vesti?", "Remove selected local history?"),
                            isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button(tr("Obriši \(removable) vesti", "Remove \(removable) stories"), role: .destructive) {
                do {
                    let removed = try feed.pruneArchive(olderThan: age.cutoff, sourceName: selectedSource)
                    reportText(tr("Uklonjeno je \(removed) vesti. Sačuvani članci i PDF-ovi su ostali.",
                                  "Removed \(removed) stories. Bookmarks and PDFs were preserved."))
                } catch { report(error) }
            }
        } message: {
            Text(tr("Ovaj postupak nije moguće poništiti bez prethodnog backupa. Cloud backup se ne briše.",
                    "This cannot be undone without a previous backup. The cloud backup will not be deleted."))
        }
        .confirmationDialog(tr("Vratiti privatnu cloud arhivu?", "Restore private cloud archive?"),
                            isPresented: $confirmRestore, titleVisibility: .visible) {
            Button(tr("Spoji sa lokalnom arhivom", "Merge into local archive")) {
                Task { do { _ = try await vault.restore(feed: feed) } catch { report(error) } }
            }
        } message: {
            Text(tr("Postojeće lokalne vesti i sačuvani članci neće biti obrisani.",
                    "Existing local news and bookmarks will not be removed."))
        }
        .confirmationDialog(tr("Zameniti postojeći ključ?", "Replace your recovery key?"),
                            isPresented: $confirmRecoveryReplace, titleVisibility: .visible) {
            Button(tr("Zameni ključ", "Replace key"), role: .destructive) { importKey() }
        } message: {
            Text(tr("Stari cloud backup možda neće moći da se dešifruje novim ključem.",
                    "An old cloud backup may be unreadable with a different key."))
        }
        .confirmationDialog(tr("Vratiti prethodnu verziju backupa?", "Restore the previous backup version?"),
                            isPresented: $confirmPreviousRestore, titleVisibility: .visible) {
            Button(tr("Spoji prethodnu verziju", "Merge previous backup")) {
                Task { do { _ = try await vault.restore(feed: feed, previous: true) }
                       catch { report(error) } }
            }
        } message: {
            Text(tr("Koristi stariji manifest, bez brisanja trenutne lokalne arhive.",
                    "Uses the previous manifest without deleting existing local articles."))
        }
        .sheet(item: $portableShare, onDismiss: {
            if let temporaryExportURL { try? FileManager.default.removeItem(at: temporaryExportURL) }
            temporaryExportURL = nil
        }) { payload in ActivitySheet(files: payload.files) }
        .fileImporter(isPresented: $portableImporting, allowedContentTypes: [.item]) { result in
            do {
                let file = try result.get()
                Task {
                    do {
                        let count = try await vault.importPortable(feed: feed, from: file)
                        reportText(tr("Uvezeno je \(count) novih vesti. Postojeća arhiva nije obrisana.",
                                      "Imported \(count) new stories. Existing history was preserved."))
                    } catch { report(error) }
                }
            } catch { report(error) }
        }
        .alert(tr("Arhiva", "Archive"), isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func importKey() {
        do { try vault.importRecoveryKey(recoveryInput); recoveryInput = ""; visibleRecoveryKey = nil }
        catch { report(error) }
    }
    private func report(_ failure: Error) { reportText(failure.localizedDescription) }
    private func reportText(_ message: String) { error = message; showError = true }
}
