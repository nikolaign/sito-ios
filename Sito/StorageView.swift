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
    @State private var showTextOptions = false
    @State private var showRecovery = false
    @State private var showCloudOptions = false
    @State private var showCloudConnection = false
    @State private var showCloudDiagnostics = false
    @State private var showCleanup = false
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
                    Text(tr("Arhiva čuva tekst i podatke o izvoru bez slika. Pun tekst je odvojen od kratkih RSS opisa.",
                            "Text and source details are kept without images. Full articles are counted separately from RSS previews."))
                }

                Section {
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
                    DisclosureGroup(isExpanded: $showTextOptions) {
                        Toggle(tr("Automatski dopunjavaj tekstove", "Complete missing texts automatically"),
                               isOn: $automaticText).tint(Ink.red)
                        if automaticText {
                            Toggle(tr("Samo preko Wi-Fi mreže", "Wi-Fi only"), isOn: $automaticTextWiFiOnly)
                                .tint(Ink.red)
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
                    } label: {
                        Label(tr("Podešavanja dopune teksta", "Text capture settings"), systemImage: "slider.horizontal.3")
                    }
                } header: { Text(tr("Puni tekst bez slika", "Full text without images")) }
                  footer: {
                    Text(tr("Neki sajtovi dozvoljavaju samo kratak pregled. Original možeš posebno sačuvati kao PDF.",
                            "Some publishers only allow a preview. Save an original PDF when you need the full page."))
                }

                Section {
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
                    Toggle(tr("Dodaj i sačuvane PDF-ove", "Include saved PDFs"), isOn: $portablePDFs)
                        .tint(Ink.red)
                    if vault.busy { ProgressView(vault.status).tint(Ink.red) }
                } header: { Text(tr("Backup gde god želiš", "Backup anywhere")) }
                  footer: {
                    Text(tr("Šifrovani .sitobackup možeš sačuvati u Files, na NAS, Mac ili u bilo koji cloud drive.",
                            "Save an encrypted .sitobackup to Files, a NAS, your Mac or any cloud drive."))
                }

                Section {
                    DisclosureGroup(isExpanded: $showRecovery) {
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
                    } label: {
                        Label(vault.hasKey ? tr("Ključ za oporavak · sačuvan", "Recovery key · saved") :
                            tr("Ključ za oporavak · potrebno podesiti", "Recovery key · setup needed"),
                              systemImage: "key.horizontal")
                    }
                } header: { Text(tr("Bezbednost", "Security")) }
                  footer: {
                    Text(tr("Čuvaj ključ van telefona. Bez njega nema vraćanja šifrovanih backupova.",
                            "Keep your key somewhere safe. Encrypted backups cannot be recovered without it."))
                }

                Section {
                    if let lastBackup = vault.lastBackup {
                        LabeledContent(tr("Poslednji backup", "Last backup")) { Text(lastBackup, style: .relative) }
                        if vault.latestBackupFullyVerified {
                            Label(tr("Backup je proveren", "Backup verified"), systemImage: "checkmark.shield.fill")
                                .font(.footnote).foregroundStyle(Color.green)
                        }
                    } else {
                        LabeledContent(tr("Poslednji backup", "Last backup"), value: tr("Još nije urađen", "Never"))
                    }
                    if vault.busy { ProgressView(vault.status).tint(Ink.red) }
                    else if !vault.status.isEmpty {
                        Text(vault.status).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button {
                        Task {
                            do {
                                try await vault.backup(feed: feed)
                                try await vault.verifyCloudArchive()
                            } catch { report(error) }
                        }
                    } label: { Label(tr("Backup sada", "Back Up Now"), systemImage: "icloud.and.arrow.up") }
                    .disabled(vault.busy || feed.textCaptureActive || !vault.hasToken || !vault.hasKey)
                    Button { confirmRestore = true } label: {
                        Label(tr("Vrati arhivu iz clouda", "Restore from Cloud"), systemImage: "arrow.down.doc")
                    }
                    .disabled(vault.busy || !vault.hasToken || !vault.hasKey)
                    DisclosureGroup(isExpanded: $showCloudOptions) {
                        Toggle(tr("Automatski backup", "Automatic backup"), isOn: $vault.enabled).tint(Ink.red)
                        Toggle(tr("Samo preko Wi-Fi", "Wi-Fi only"), isOn: $vault.wifiOnly).tint(Ink.red)
                        Toggle(tr("Uključi PDF-ove", "Include saved PDFs"), isOn: $vault.backupPDFs).tint(Ink.red)
                    } label: {
                        Label(tr("Automatski backup i PDF", "Automatic backup & PDFs"), systemImage: "slider.horizontal.3")
                    }
                    DisclosureGroup(isExpanded: $showCloudDiagnostics) {
                        if let lastVerification = vault.lastVerification {
                            LabeledContent(tr("Poslednja provera", "Last integrity check")) {
                                Text(lastVerification, style: .relative)
                            }
                        }
                        Button(tr("Ponovi proveru integriteta", "Check backup integrity")) {
                            Task { do { try await vault.verifyCloudArchive() } catch { report(error) } }
                        }.disabled(vault.busy || !vault.hasToken || !vault.hasKey)
                        Button(tr("Vrati prethodni backup", "Restore previous backup")) {
                            confirmPreviousRestore = true
                        }.disabled(vault.busy || !vault.hasToken || !vault.hasKey)
                    } label: {
                        Label(tr("Dodatne cloud radnje", "More cloud actions"), systemImage: "ellipsis")
                    }
                } header: { Text(tr("Privatni cloud backup", "Private cloud backup")) }
                  footer: {
                    Text(tr("Opcioni šifrovani backup na tvom Cloudflare Worker-u. Ručni backup se automatski proverava.",
                            "Optional encrypted backup on your own Cloudflare Worker. Manual backups are checked automatically."))
                }

                Section {
                    DisclosureGroup(isExpanded: $showCloudConnection) {
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
                    } label: {
                        Label(tr("Povezivanje i pristup", "Connection & access"), systemImage: "lock.icloud")
                    }
                } header: { Text(tr("Cloud podešavanja", "Cloud setup")) }
                  footer: {
                    Text(tr("Podržan je sopstveni Cloudflare Worker, ne direktan nalog na drugim cloud servisima. Za bilo koji servis koristi .sitobackup fajl.",
                            "Connect your own Cloudflare Worker here. For other cloud drives, export a .sitobackup file."))
                }

                Section {
                    DisclosureGroup(isExpanded: $showCleanup) {
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
                    } label: {
                        Label(tr("Oslobodi lokalni prostor", "Free local storage"), systemImage: "trash")
                    }
                } header: { Text(tr("Upravljanje istorijom", "Manage history")) }
                  footer: {
                    Text(tr("Sačuvani članci i PDF-ovi ostaju netaknuti.",
                            "Bookmarked articles and saved PDFs stay untouched."))
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
