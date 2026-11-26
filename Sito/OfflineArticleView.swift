import SwiftUI
import WebKit

private final class OriginalPagePrintRenderer: UIPrintPageRenderer {
    override var paperRect: CGRect { CGRect(x: 0, y: 0, width: 595, height: 842) }
    override var printableRect: CGRect { paperRect.insetBy(dx: 30, dy: 34) }
}

// Capture explicitly requested by the reader. The original publisher's page is
// rendered to a private on-device PDF; the app does not scrape/republish it.
struct OfflineArticleView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var prefs: NewsPreferences
    @EnvironmentObject private var feed: NewsFeed
    let item: NewsItem

    @State private var browser = WKWebView(frame: .zero)
    @State private var loaded = false
    @State private var working = false
    @State private var failure: String?
    @State private var share: SharePayload?

    private var lang: Bool { prefs.language == "sr" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(Ink.red)
                    Text(lang ? "Sačuvaj originalnu učitanu stranicu kao lokalni PDF. Sačekaj da se fotografije učitaju; sadržaj iza pretplate ostaje zaštićen." : "Save the loaded original page as a local PDF. Allow photos to load; paywalled content remains protected.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(14)
                ArticleWebFrame(webView: browser, url: item.url, didLoad: {
                    loaded = true; failure = nil
                }, didFail: { text in failure = text })
                HStack(spacing: 12) {
                    if working { ProgressView().tint(Ink.red) }
                    Button {
                        savePDF()
                    } label: {
                        Label(lang ? "SAČUVAJ CELO U PDF" : "SAVE FULL PAGE PDF", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .semibold)).tracking(0.5)
                    }
                    .disabled(!loaded || working)
                    Spacer()
                    if let complete = feed.completeArticles[item.id] {
                        ShareLink(item: feed.completePDFURL(for: complete)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(lang ? "Izvezi postojeći PDF" : "Export saved PDF")
                    }
                }
                .buttonStyle(.borderedProminent).tint(Ink.red)
                .padding(15)
            }
            .navigationTitle(item.sourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button(lang ? "Gotovo" : "Done") { dismiss() }.tint(Ink.red)
            }}
        }
        .sheet(item: $share) { payload in ActivitySheet(files: payload.files) }
        .alert(lang ? "PDF arhiva" : "PDF archive", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(failure ?? "") }
    }

    private func savePDF() {
        working = true
        // A print formatter paginates the entire loaded document. A plain
        // WKWebView.createPDF call may capture only the visible bounds.
        Task { @MainActor in
            await Task.yield()
            let renderer = OriginalPagePrintRenderer()
            let formatter = browser.viewPrintFormatter()
            renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
            let pages = renderer.numberOfPages
            guard pages > 0 else {
                working = false
                failure = lang ? "Stranica još nije spremna za štampu." : "Page is not ready for PDF capture."
                return
            }
            let pdf = UIGraphicsPDFRenderer(bounds: renderer.paperRect).pdfData { context in
                for index in 0..<pages {
                    context.beginPage()
                    renderer.drawPage(at: index, in: renderer.paperRect)
                }
            }
            do {
                let url = try feed.saveCompletePDF(pdf, for: item)
                share = SharePayload(files: [url])
            } catch { failure = error.localizedDescription }
            working = false
        }
    }
}

struct ArticleWebFrame: UIViewRepresentable {
    let webView: WKWebView
    let url: URL
    let didLoad: () -> Void
    let didFail: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(didLoad: didLoad, didFail: didFail) }
    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let didLoad: () -> Void
        let didFail: (String) -> Void
        init(didLoad: @escaping () -> Void, didFail: @escaping (String) -> Void) {
            self.didLoad = didLoad; self.didFail = didFail
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { didLoad() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            didFail(error.localizedDescription)
        }
    }
}
