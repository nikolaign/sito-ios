import SwiftUI

// The last room uses only real stories already present in the user's SITO
// feed or private archive. Nothing is manufactured or sent to a game server.
// The immutable snapshot prevents an RSS refresh changing the answer mid-test.
enum RealityArchive {
    static func sample(_ articles: [NewsItem], count: Int = 7) -> [NewsItem] {
        var seen = Set<String>()
        let sorted = articles.filter {
            $0.title.count >= 24 && $0.published > Date(timeIntervalSince1970: 1_577_836_800)
        }.sorted { $0.published > $1.published }
        let candidates = sorted.filter { seen.insert($0.title.lowercased()).inserted }
        let freshest = candidates.filter { $0.published > Date().addingTimeInterval(-5 * 86_400) }
        let pool = freshest.count >= 4 ? freshest : candidates
        var chosen: [NewsItem] = []
        var sources = Set<String>()
        // First make the screen resemble SITO's interleaved front page.
        for story in pool where chosen.count < count && sources.insert(story.sourceID).inserted {
            chosen.append(story)
        }
        for story in pool where chosen.count < count && !chosen.contains(where: { $0.id == story.id }) {
            chosen.append(story)
        }
        return chosen
    }
}

private enum RealityStage { case reading, examination }

private struct RealityQuestion {
    enum Kind { case witness, missingWord, preceding, position }
    let kind: Kind
    let titleSR: String
    let titleEN: String
    let reference: String
    let choices: [String]
    let answer: String
}

private enum RealityExam {
    static func make(stories: [NewsItem]) -> [RealityQuestion] {
        guard stories.count >= 4 else { return [] }
        let allSources = (stories.map(\.sourceName) + NewsSource.curated.map(\.name))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let tokens: [String] = stories.flatMap { headlineWords($0.title) }
        var questions: [RealityQuestion] = []

        if Set(stories.map(\.sourceID)).count >= 3 {
            for index in stride(from: 0, to: stories.count, by: 2) {
                let article = stories[index]
                let alternatives = allSources.filter { $0 != article.sourceName }.shuffled()
                let options = ([article.sourceName] + Array(alternatives.prefix(3))).shuffled()
                guard options.count == 4 else { continue }
                questions.append(RealityQuestion(kind: .witness,
                    titleSR: "KO JE BIO SVEDOK?", titleEN: "WHO WAS THE WITNESS?",
                    reference: article.title, choices: options, answer: article.sourceName))
            }
        }

        for story in stories.shuffled() {
            let words = headlineWords(story.title).filter { $0.count >= 5 && $0.count <= 18 }
            guard let hidden = words.shuffled().first(where: { word in
                tokens.filter { $0.caseInsensitiveCompare(word) == .orderedSame }.count == 1
            }), let range = story.title.range(of: hidden, options: [.caseInsensitive]) else { continue }
            var masked = story.title
            masked.replaceSubrange(range, with: "▯▯▯▯▯")
            let choices = tokens.filter { candidate in
                candidate.caseInsensitiveCompare(hidden) != .orderedSame &&
                abs(candidate.count - hidden.count) <= 3 &&
                !story.title.localizedCaseInsensitiveContains(candidate)
            }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.shuffled()
            guard choices.count >= 3 else { continue }
            questions.append(RealityQuestion(kind: .missingWord,
                titleSR: "KOJU REČ SI VIDEO?", titleEN: "WHICH WORD DID YOU SEE?",
                reference: masked, choices: ([hidden] + Array(choices.prefix(3))).shuffled(), answer: hidden))
        }

        for index in stride(from: 2, to: stories.count, by: 2) {
            let answer = stories[index - 1].title
            let alternatives = stories.enumerated()
                .filter { $0.offset != index && $0.offset != index - 1 }
                .map { $0.element.title }.shuffled()
            let choices = ([answer] + Array(alternatives.prefix(3))).shuffled()
            guard choices.count >= 3 else { continue }
            questions.append(RealityQuestion(kind: .preceding,
                titleSR: "ŠTA JE DOŠLO NEPOSREDNO PRE?", titleEN: "WHAT CAME IMMEDIATELY BEFORE?",
                reference: stories[index].title, choices: choices, answer: answer))
        }
        // Positional recall keeps the challenge meaningful even when someone
        // has enabled only one publisher (source attribution would be trivial).
        for index in stride(from: 0, to: stories.count, by: 2) {
            let answer = stories[index].title
            let alternatives = stories.map(\.title).filter { $0 != answer }.shuffled()
            let choices = ([answer] + Array(alternatives.prefix(3))).shuffled()
            guard choices.count == 4 else { continue }
            let screen = String(format: "%02d", index + 1)
            questions.append(RealityQuestion(kind: .position,
                titleSR: "ŠTA JE BILO NA EKRANU \(screen)?",
                titleEN: "WHAT WAS ON SCREEN \(screen)?",
                reference: "SITO / \(screen)", choices: choices, answer: answer))
        }
        return Array(questions.shuffled().prefix(12))
    }

    private static func headlineWords(_ text: String) -> [String] {
        let ignored: Set<String> = ["about", "after", "before", "their", "there", "where", "which", "would", "could", "these", "those", "today", "because", "between", "through", "prema", "nakon", "između", "jedan", "jedna", "jednog", "svoje", "samo", "kako", "zašto", "izjavio", "rekao", "rekao", "novom", "novi", "neće"]
        return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 && !ignored.contains($0.lowercased()) && !$0.allSatisfy(\.isNumber) }
    }
}

struct RealityWitnessView: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let articles: [NewsItem]
    let compact: Bool
    let onComplete: (Int, Int, String) -> Void
    let onFail: () -> Void
    let penalize: (Int) -> Void
    let leave: () -> Void

    @State private var stage: RealityStage = .reading
    @State private var page = 0
    @State private var ready = false
    @State private var questions: [RealityQuestion] = []
    @State private var correct = 0
    @State private var errors = 0
    @State private var marked = false
    @State private var lastAnswerCorrect: Bool? = nil

    private var sr: Bool { prefs.language == "sr" }
    private var ivory: Color { GateStyle.chalk }
    private var passThreshold: Int { max(1, Int(ceil(Double(questions.count) * 0.82))) }

    var body: some View {
        ScrollView(.vertical) {
          VStack(spacing: compact ? 8 : 12) {
            HStack(spacing: 12) {
                Rectangle().fill(Ink.red).frame(width: 6, height: 6).rotationEffect(.degrees(45))
                Text(sr ? "POSLE POSLEDNJE KAPIJE" : "AFTER THE LAST GATE")
                    .font(.system(size: 10, design: .monospaced)).tracking(2.2)
                    .foregroundStyle(Ink.red)
            }
            GateCaption(title: "REALITY / HELL / HEAVEN",
                        instruction: stage == .reading
                            ? (sr ? "Svet koji si napustio nije nestao. Čitaj pažljivo: novinski naslovi su stvarni, a ispit dolazi bez ponovnog gledanja." : "The world you left is still here. Read carefully: these are real news headlines, and the test will not let you look back.")
                            : (sr ? "Sada rekonstruiši ono što si video. Odgovor se prihvata samo jednom." : "Now reconstruct what you saw. Every answer is final."))

            if articles.count < 4 {
                noStories
            } else if stage == .reading {
                readingPanel
            } else {
                examinationPanel
            }
          }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: 350)
        .padding(.horizontal, compact ? 10 : 21)
        .onAppear { if questions.isEmpty { questions = RealityExam.make(stories: articles) } }
        .task(id: page) {
            guard stage == .reading else { return }
            ready = false
            do { try await Task.sleep(nanoseconds: 4_300_000_000) } catch { return }
            if !Task.isCancelled { ready = true }
        }
    }

    private var noStories: some View {
        VStack(spacing: 18) {
            Text(sr ? "NEMA DOVOLJNO VESTI U LOKALNOJ MEMORIJI" : "NOT ENOUGH STORIES IN LOCAL MEMORY")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(ivory.opacity(0.7))
                .multilineTextAlignment(.center)
            Text(sr ? "Ova soba ne izmišlja svet. Vrati se u SITO i osveži vesti; sačuvana arhiva radi i bez mreže." : "This room will not invent the world. Return to SITO to refresh; cached articles also work offline.")
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(GateStyle.faint)
                .multilineTextAlignment(.center)
            Button(sr ? "VRATI SE U SITO" : "RETURN TO SITO", action: leave)
                .buttonStyle(.plain).foregroundStyle(Ink.red)
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(25)
    }

    private var readingPanel: some View {
        let article = articles[min(page, articles.count - 1)]
        return VStack(spacing: 13) {
            HStack {
                Text(String(format: "%02d / %02d", page + 1, articles.count))
                Spacer()
                Text(sr ? "PROČITAJ · UPAMTI" : "READ · REMEMBER")
            }
            .font(.system(size: 10, design: .monospaced)).tracking(2)
            .foregroundStyle(GateStyle.faint)

            ZStack(alignment: .bottom) {
                Rectangle().fill(Color(red: 0.065, green: 0.065, blue: 0.075))
                VStack(alignment: .leading, spacing: compact ? 7 : 12) {
                    HStack {
                        Text("SITO").font(.system(size: 16, weight: .bold, design: .serif)).tracking(3)
                        Spacer()
                        Text(article.section == .world ? "WORLD" : "SRBIJA")
                            .font(.system(size: 9, design: .monospaced)).tracking(2)
                    }
                    .foregroundStyle(ivory.opacity(0.6))
                    Rectangle().fill(Ink.red.opacity(0.7)).frame(height: 1)
                    if let image = article.imageURL {
                        AsyncImage(url: image) { phase in
                            if case .success(let visual) = phase {
                                visual.resizable().scaledToFill()
                            } else {
                                Rectangle().fill(Ink.red.opacity(0.09))
                            }
                        }
                        .frame(height: compact ? 47 : 74).clipped()
                        .accessibilityHidden(true)
                    }
                    Text(article.title)
                        .font(.system(size: compact ? 16 : 18, weight: .regular, design: .serif))
                        .foregroundStyle(ivory)
                        .lineLimit(compact ? 3 : 5).minimumScaleFactor(0.8)
                    Text(article.summary.isEmpty ? article.url.host ?? "" : article.summary)
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(ivory.opacity(0.58))
                        .lineLimit(compact ? 2 : 3)
                    Spacer(minLength: 0)
                    Rectangle().fill(GateStyle.chalk.opacity(0.2)).frame(height: 1)
                    HStack {
                        Text(article.sourceName)
                        Spacer()
                        Text(article.published.formatted(date: .abbreviated, time: .omitted))
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ivory.opacity(0.55))
                }
                .padding(compact ? 12 : 17)
            }
            .frame(height: compact ? 213 : 285)
            .overlay(Rectangle().stroke(GateStyle.chalk.opacity(0.24), lineWidth: 0.8))
            .rotation3DEffect(.degrees(2.5), axis: (x: 1, y: -0.4, z: 0))
            HStack(spacing: 8) {
                Circle().fill(ready ? Ink.red : ivory.opacity(0.3)).frame(width: 5, height: 5)
                Text(sr ? "NASLOV · IZVOR · REDOSLED · JEDNA REČ" : "HEADLINE · SOURCE · ORDER · ONE WORD")
                    .font(.system(size: 9, design: .monospaced)).tracking(0.4)
                    .foregroundStyle(GateStyle.faint)
            }
            Button {
                guard ready else { return }
                if page + 1 == articles.count {
                    stage = .examination
                    page = 0
                } else {
                    ready = false
                    page += 1
                }
            } label: {
                Text(page + 1 == articles.count
                     ? (sr ? "PREĐI NA ISPIT" : "ENTER THE EXAMINATION")
                     : (sr ? "SLEDEĆI EKRAN" : "NEXT SCREEN"))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(1.5)
                    .frame(maxWidth: .infinity).frame(height: 45)
                    .overlay(Rectangle().stroke(ready ? Ink.red.opacity(0.8) : GateStyle.chalk.opacity(0.15), lineWidth: 0.7))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ready ? ivory : GateStyle.faint)
            .disabled(!ready)
        }
    }

    private var examinationPanel: some View {
        VStack(spacing: 16) {
            if questions.indices.contains(page) {
                let question = questions[page]
                HStack {
                    Text(String(format: "%02d / %02d", page + 1, questions.count))
                    Spacer()
                    Text("\(correct) / \(passThreshold)")
                }
                .font(.system(size: 10, design: .monospaced)).tracking(2)
                .foregroundStyle(Ink.red)
                Text(sr ? question.titleSR : question.titleEN)
                    .font(.system(size: 11, design: .monospaced)).tracking(2)
                    .foregroundStyle(GateStyle.faint)
                Text(question.reference)
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(ivory)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, minHeight: 85)
                VStack(spacing: 8) {
                    ForEach(Array(question.choices.enumerated()), id: \.offset) { entry in
                        let choice = entry.element
                        let headlineChoice = question.kind == .preceding || question.kind == .position
                        Button { respond(choice, to: question) } label: {
                            Text(choice)
                                .font(.system(size: headlineChoice ? 11 : 13, design: headlineChoice ? .serif : .monospaced))
                                .foregroundStyle(ivory)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .padding(.horizontal, 10)
                                .background(ivory.opacity(0.045))
                                .overlay(Rectangle().stroke(Ink.red.opacity(0.29), lineWidth: 0.7))
                        }
                        .buttonStyle(.plain)
                        .disabled(marked)
                    }
                }
                Text(lastAnswerCorrect.map { correct in
                    correct ? (sr ? "ZAPAMĆENO." : "REMEMBERED.")
                            : (sr ? "SEĆANJE JE PROMAŠILO." : "THE MEMORY MISSED.")
                } ?? (sr ? "ODGOVOR JE KONAČAN · GREŠKA −25s" : "ANSWERS ARE FINAL · ERROR −25s"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(lastAnswerCorrect == false ? Ink.red : GateStyle.faint)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func respond(_ choice: String, to question: RealityQuestion) {
        guard !marked else { return }
        marked = true
        let matched = choice == question.answer
        lastAnswerCorrect = matched
        if matched { correct += 1 }
        else { errors += 1; penalize(25) }
        Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 480_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            if page + 1 == questions.count {
                if correct >= passThreshold { onComplete(correct, questions.count, articles.first?.title ?? "") }
                else { onFail() }
            } else {
                page += 1
                marked = false
                lastAnswerCorrect = nil
            }
        }
    }
}
