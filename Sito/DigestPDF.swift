import UIKit

enum DigestPDF {
    static func create(items: [NewsItem]) throws -> URL {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let output = renderer.pdfData { context in
            var y: CGFloat = 54
            let margin: CGFloat = 49
            let width = page.width - 2 * margin
            let regular = UIFont(name: "Georgia", size: 11.8) ?? .systemFont(ofSize: 11.8)
            let headline = UIFont(name: "Georgia-Bold", size: 17.5) ?? .boldSystemFont(ofSize: 17.5)
            let small = UIFont.systemFont(ofSize: 9, weight: .medium)

            func beginPage() {
                context.beginPage()
                y = 47
                ("SITO   /   LOCAL READING ARCHIVE" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [
                    .font: small, .foregroundColor: UIColor.darkGray
                ])
                y += 33
                UIColor(white: 0.78, alpha: 1).setFill()
                UIBezierPath(rect: CGRect(x: margin, y: y, width: width, height: 0.6)).fill()
                y += 21
            }

            func draw(_ value: String, font: UIFont, color: UIColor, space: CGFloat) {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: color,
                    .paragraphStyle: {
                        let p = NSMutableParagraphStyle(); p.lineSpacing = 3; return p
                    }()
                ]
                let box = (value as NSString).boundingRect(
                    with: CGSize(width: width, height: 15_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil
                )
                if y + box.height + space > page.height - 65 { beginPage() }
                (value as NSString).draw(in: CGRect(x: margin, y: y, width: width, height: box.height + 2), withAttributes: attrs)
                y += box.height + space
            }

            beginPage()
            draw("SITO — News archive", font: UIFont(name: "Georgia-Bold", size: 28) ?? .boldSystemFont(ofSize: 28),
                 color: UIColor.black, space: 11)
            draw("Generated \(Date().formatted(date: .abbreviated, time: .shortened)) · \(items.count) items. Publisher-owned preview text; complete web pages are separate PDFs.",
                 font: small, color: .darkGray, space: 32)
            for (index, item) in items.enumerated() {
                draw("\(index + 1)   /   \(item.sourceName.uppercased())   /   \(item.published.formatted(date: .abbreviated, time: .omitted))",
                     font: small, color: UIColor(red: 0.67, green: 0.14, blue: 0.16, alpha: 1), space: 10)
                draw(item.title, font: headline, color: .black, space: 10)
                if !item.summary.isEmpty { draw(item.summary, font: regular, color: .darkGray, space: 10) }
                draw(item.url.absoluteString, font: small, color: .gray, space: 23)
            }
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("SITO-reading-archive-\(stamp.string(from: .now)).pdf")
        try output.write(to: target, options: .atomic)
        return target
    }
}
