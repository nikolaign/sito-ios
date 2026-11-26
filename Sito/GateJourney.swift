import SwiftUI

private enum GatePhase: String {
    case playing, passage, reckoning, revelation, failed, collapse, aftermath
}

private enum GateWords {
    static func room(_ number: Int, sr: Bool) -> String {
        let names = sr
            ? ["IZA KAPIJE", "ARHITEKTURA TIŠINE", "ŠIFRA SA DVA LICA", "BLIZANCI U PRAZNINI", "NIZOVI KOJI LAŽU", "ŠESNAEST PLAMENOVA", "DVANAEST OGLEDALA", "LAVIRINT", "ODJEK", "DEVETA KAPIJA"]
            : ["BEYOND THE GATE", "THE ARCHITECTURE OF SILENCE", "THE TWO-FACED CIPHER", "TWINS IN THE VOID", "THE LYING SEQUENCES", "SIXTEEN FLAMES", "TWELVE MIRRORS", "THE LABYRINTH", "THE ECHO", "THE NINTH GATE"]
        return names[number]
    }

    static func circle(_ number: Int, sr: Bool) -> String {
        let names = sr
            ? ["PRAG", "IZDAJA", "OBMANA", "NASILJE", "JERES", "GNEV", "POHLEPA", "PROŽDRLJIVOST", "POŽUDA", "LIMBO"]
            : ["THE THRESHOLD", "TREACHERY", "FRAUD", "VIOLENCE", "HERESY", "WRATH", "GREED", "GLUTTONY", "LUST", "LIMBO"]
        return names[number]
    }

    static func whisper(sr: Bool, room: Int, cycle: Int, serial: Int, used: inout Set<String>) -> String {
        let line = GateNarration.next(room: room, sr: sr, preferRoom: serial == 1 || serial.isMultiple(of: 4))
        used.insert(line)
        return line
    }
}

struct DreamGateJourneyView: View {
    @EnvironmentObject private var prefs: NewsPreferences
    @EnvironmentObject private var feed: NewsFeed
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("seraphiGateCycle") private var cycle = 0
    @AppStorage("seraphiLastPortal") private var lastPortal = ""

    @State private var room = 9
    @State private var phase: GatePhase = .playing
    @State private var secondsRemaining = 540
    @State private var whisper = ""
    @State private var whisperOpacity = 0.9
    @State private var transcript: [String] = []
    @State private var heard = Set<String>()
    @State private var serial = 0
    @State private var tremor = false
    @State private var witnessArticles: [NewsItem] = []
    @State private var performance: [Int: Int] = [:]
    @State private var penalties = 0
    @State private var failures = 0
    @State private var witnessScore = 0
    @State private var witnessTotal = 0
    @State private var echoHeadline = ""
    @State private var doorChoice: Int? = nil
    @State private var endingSeed = Int.random(in: 0..<10_000)

    private let ivory = Color(red: 0.89, green: 0.86, blue: 0.82)
    private var sr: Bool { prefs.language == "sr" }
    private func tr(_ a: String, _ b: String) -> String { sr ? a : b }
    private var sceneKey: String { "\(room)-\(cycle)-\(phase.rawValue)" }
    private var clockText: String { String(format: "%02d:%02d", secondsRemaining / 60, secondsRemaining % 60) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DreamAtmosphere()
                switch phase {
                case .playing, .reckoning:
                    playing(in: geometry.size)
                        .transition(.opacity)
                case .passage, .revelation:
                    GateRitual(room: room, cycle: cycle, failure: false)
                        .transition(.opacity)
                case .failed:
                    failureScene
                        .transition(.opacity)
                case .collapse:
                    collapseScene
                        .transition(.opacity)
                case .aftermath:
                    aftermathScene
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task(id: sceneKey) { await runClock() }
        .task(id: sceneKey) { await speak() }
        .task(id: sceneKey) { await advanceStory() }
        .sensoryFeedback(.success, trigger: phase == .passage || phase == .revelation)
        .sensoryFeedback(.error, trigger: phase == .failed)
    }

    private func playing(in size: CGSize) -> some View {
        let narrow = size.height < 700
        let board = min(size.width - 44, max(200, min(size.height * (narrow ? 0.32 : 0.365), 305)))
        return VStack(spacing: narrow ? 10 : 16) {
            HStack(alignment: .center) {
                Text(String(format: "SITO / %02d", room))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(ivory.opacity(0.65))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .light))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(tr("Napusti kapije", "Leave the gates"))
                .buttonStyle(.plain)
                .foregroundStyle(ivory.opacity(0.75))
            }
            .padding(.horizontal, 22)
            HStack(spacing: 5) {
                ForEach(1...9, id: \.self) { index in
                    Rectangle()
                        .fill(index >= room ? Ink.red.opacity(0.8) : ivory.opacity(0.18))
                        .frame(height: 2)
                }
            }
            .padding(.horizontal, 25)
            VStack(spacing: 8) {
                Text(room == 0 ? "∅ / 09" : String(format: "%02d / 09", room))
                    .font(.system(size: 11, weight: .light, design: .monospaced))
                    .tracking(5).foregroundStyle(ivory.opacity(0.53))
                Text(clockText)
                    .font(.system(size: narrow ? 28 : 36, weight: .ultraLight, design: .monospaced))
                    .monospacedDigit().tracking(5)
                    .foregroundStyle(secondsRemaining <= 30 ? Ink.red : ivory)
                    .accessibilityLabel(tr("Preostalo vreme \(clockText)", "Time remaining \(clockText)"))
            }

            Spacer(minLength: 1)
            if room == 0 {
                VStack(spacing: 8) {
                    Text(GateWords.circle(room, sr: sr))
                        .font(.system(size: 9, design: .monospaced))
                        .tracking(3).foregroundStyle(Ink.red.opacity(0.7))
                    RealityWitnessView(articles: witnessArticles, compact: narrow,
                        onComplete: { correct, total, headline in
                            witnessScore = correct
                            witnessTotal = total
                            echoHeadline = headline
                            win()
                        },
                        onFail: { fail() }, penalize: loseTime,
                        leave: { dismiss() })
                        .id("reality-\(cycle)")
                        .frame(height: min(narrow ? 360 : 515, size.height * 0.63))
                }
            } else if room == 9 {
                VStack(spacing: 12) {
                    Text(GateWords.circle(room, sr: sr))
                        .font(.system(size: 9, design: .monospaced))
                        .tracking(3).foregroundStyle(Ink.red.opacity(0.7))
                    Text(GateWords.room(room, sr: sr))
                        .font(.system(size: 12, weight: .light, design: .monospaced))
                        .tracking(4).foregroundStyle(ivory.opacity(0.82))
                    GateSudokuGame(width: board, solved: win)
                        .id("sudoku-\(room)-\(cycle)")
                }
            } else {
                VStack(spacing: 8) {
                    Text(GateWords.circle(room, sr: sr))
                        .font(.system(size: 9, design: .monospaced))
                        .tracking(3).foregroundStyle(Ink.red.opacity(0.7))
                    GatePuzzlesView(room: room, cycle: cycle, compact: narrow, solved: win, penalize: loseTime)
                        .id("puzzle-\(room)-\(cycle)")
                }
            }
            Spacer(minLength: 1)

            HStack(alignment: .top, spacing: 11) {
                Rectangle().fill(Ink.red.opacity(0.72)).frame(width: 2)
                VStack(alignment: .leading, spacing: 7) {
                    if !narrow, let previous = transcript.last {
                        Text(previous)
                            .foregroundStyle(ivory.opacity(0.27))
                            .lineLimit(2)
                    }
                    Text(whisper.isEmpty ? "▌" : whisper + "▌")
                        .foregroundStyle(ivory.opacity(whisperOpacity))
                        .lineLimit(3)
                }
                .font(.system(size: narrow ? 10 : 11, weight: .light, design: .monospaced))
                .tracking(0.2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: narrow ? 62 : 83)
            .padding(.horizontal, 26)
            .padding(.bottom, narrow ? 2 : 12)
        }
    }

    private var failureScene: some View {
        ZStack {
            GateRitual(room: room, cycle: cycle, failure: true)
            VStack(spacing: 17) {
                Spacer()
                Text(tr("NISI PROŠAO", "YOU FAILED"))
                    .font(.system(size: 31, weight: .ultraLight, design: .serif))
                    .tracking(5).foregroundStyle(Ink.red)
                Text(room == 0
                     ? tr("EKRAN NIJE ZAPAMTIO TVOJE ODGOVORE.", "THE SCREEN DID NOT REMEMBER YOUR ANSWERS.")
                     : room == 9
                     ? tr("DEVETA KAPIJA TE NIJE PUSTILA.", "THE NINTH GATE DID NOT LET YOU PASS.")
                     : tr("KAPIJA \(room) TE NIJE PUSTILA.", "GATE \(room) DID NOT LET YOU PASS."))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(2).multilineTextAlignment(.center)
                    .foregroundStyle(ivory)
                Text(room == 0
                     ? tr("Vesti su ostale iste. Ono što si zapamtio — nije.", "The news remained unchanged. What you remembered did not.")
                     : tr("Vreme je isteklo. Nešto sa druge strane sada zna tvoje ime.",
                          "Time ran out. Something on the other side now knows your name."))
                    .font(.system(size: 16, design: .serif))
                    .multilineTextAlignment(.center).foregroundStyle(ivory.opacity(0.6))
                    .padding(.horizontal, 42)
                Spacer()
                Button(tr("POKUŠAJ PONOVO", "TRY AGAIN")) { restartRoom() }
                    .buttonStyle(GateOutlineButton())
                Button(tr("VRATI SE U SVET", "RETURN TO THE WORLD")) { dismiss() }
                    .font(.system(size: 10, design: .monospaced)).tracking(2)
                    .foregroundStyle(ivory.opacity(0.4)).padding(.top, 10)
                Spacer().frame(height: 55)
            }
        }
    }

    private var collapseScene: some View {
        ZStack {
            GateRitual(room: 0, cycle: cycle, failure: false)
                .offset(x: tremor && !reduceMotion ? 3 : -3)
                .opacity(tremor ? 0.75 : 0.15)
            VStack(spacing: 24) {
                Text(tr("NIŠTA SE NIJE ZAVRŠILO", "NOTHING HAS ENDED"))
                    .font(.system(size: 14, design: .monospaced)).tracking(4)
                    .foregroundStyle(Ink.red)
                Text(tr("DEVETI KRUG NEMA PLAMEN. SAMO LED.", "THE NINTH CIRCLE HAS NO FLAME. ONLY ICE."))
                    .font(.system(size: 21, design: .serif)).foregroundStyle(ivory.opacity(0.65))
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.11).repeatCount(12, autoreverses: true)) { tremor = true }
        }
    }

    private var aftermathScene: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
              VStack(spacing: 21) {
                Spacer(minLength: 28)
                Rectangle().fill(Ink.red).frame(width: 9, height: 9)
                    .rotationEffect(.degrees(45))
                Text(tr("DEVET KRUGOVA. JEDAN EKRAN.", "NINE CIRCLES. ONE SCREEN."))
                    .font(.system(size: 16, weight: .light, design: .serif))
                    .tracking(3).lineSpacing(10)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Ink.red.opacity(0.95))
                    .padding(.horizontal, 30)
                Text(endingPrelude)
                    .font(.system(size: 17, weight: .light, design: .serif))
                    .multilineTextAlignment(.center).lineSpacing(5)
                    .foregroundStyle(ivory.opacity(0.85))
                    .padding(.horizontal, 33)
                Rectangle().fill(Ink.red.opacity(0.45)).frame(width: 28, height: 1)
                Text(tr("Na poslednjem ekranu ostao je naslov:", "One headline remained on the last screen:"))
                    .font(.system(size: 11, weight: .light, design: .monospaced))
                    .foregroundStyle(ivory.opacity(0.45))
                Text(echoHeadline)
                    .font(.system(size: 13, design: .serif))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ivory.opacity(0.65)).padding(.horizontal, 36)

                if doorChoice == nil {
                    Text(tr("Nema sudije. Nema ocene duše. Samo jedna odluka koju igra ne može doneti umesto tebe.",
                            "No judge. No score for a soul. Just one choice the game cannot make for you."))
                        .font(.system(size: 12, design: .serif))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ivory.opacity(0.56)).padding(.horizontal, 30)
                    Button(tr("OSTAVI VRATA OTVORENA", "LEAVE THE DOOR OPEN")) {
                        withAnimation(.easeInOut(duration: 0.8)) { doorChoice = 0 }
                    }
                    .buttonStyle(GateOutlineButton())
                    Button(tr("ZATVORI IH", "CLOSE THEM")) {
                        withAnimation(.easeInOut(duration: 0.8)) { doorChoice = 1 }
                    }
                    .buttonStyle(GateOutlineButton())
                } else {
                    Text(endingReflection)
                        .font(.system(size: 15, design: .serif))
                        .multilineTextAlignment(.center).lineSpacing(6)
                        .foregroundStyle(ivory.opacity(0.84))
                        .padding(.horizontal, 32)
                    Text(endingCoda)
                        .font(.system(size: 11, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Ink.red.opacity(0.76))
                        .padding(.horizontal, 30)
                    Button(tr("OTVORI SLEDEĆI CIKLUS", "OPEN THE NEXT CYCLE")) { newCycle() }
                        .buttonStyle(GateOutlineButton())
                    Button(tr("PRATI PUKOTINU · NASUMIČAN PORTAL", "FOLLOW THE CRACK · RANDOM PORTAL")) { openRandomPortal() }
                        .font(.system(size: 10, design: .monospaced))
                        .tracking(1).foregroundStyle(Ink.red.opacity(0.8))
                    Text(tr("Izvan SITO-a. Nezavisan eksperimentalni umetnički sajt.",
                            "Outside SITO. An independent experimental art site."))
                        .font(.system(size: 10, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ivory.opacity(0.36))
                    Button(tr("VRATI SE VESTIMA", "RETURN TO THE NEWS")) { dismiss() }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ivory.opacity(0.42))
                }
                Spacer(minLength: 24)
              }
              .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }

    // The game never assigns moral value to speed. Performance changes which
    // question the ending asks; the player's last choice changes its answer.
    private var endingRegister: Int {
        let fraction = (1...9).reduce(0.0) { $0 + Double(performance[$1, default: 0]) / Double(allowance($1)) } / 9.0
        if failures >= 3 { return 3 }
        if fraction > 0.6 && penalties <= 4 && witnessScore == witnessTotal { return 0 }
        if fraction > 0.39 { return 1 }
        return 2
    }

    private var endingPrelude: String {
        let srLines = [
            "Prošao si brzo. To ne znači da si video sve. Brzina je samo još jedan način da se nešto propusti.",
            "Dovoljno si se sećao da stigneš dovde. Niko ti nije rekao da sećanje mora biti potpuno.",
            "Vreme se osipalo. Ti si ostao. Od onoga što nisi razumeo napravio si prolaz.",
            "Vrata su te vraćala, a ti si ponovo ulazio. Ovo nije pobeda nad paklom. Ovo je razgovor s njim."
        ]
        let enLines = [
            "You crossed quickly. That does not mean you saw everything. Speed is another way to miss what matters.",
            "You remembered enough to arrive here. Nobody promised that memory had to be complete.",
            "Time fell away. You remained. You built a passage from what you could not understand.",
            "The doors sent you back, and you entered again. This is not a victory over hell. It is a conversation with it."
        ]
        return (sr ? srLines : enLines)[endingRegister]
    }

    private var endingReflection: String {
        let openSR = [
            "Ostavio si vrata otvorena. Sa one strane nema prestola. Samo drugi ljudi koji u istom trenutku biraju kuda će gledati.",
            "Vrata ostaju otvorena. Sve što si video može postati strah, saosećanje ili ništa. Ne odlučuje ekran.",
            "U sobu ulazi vazduh spolja. Pakao nije nestao; samo si prestao da ga zoveš jedinim mogućim svetom.",
            "Neko drugi će proći tvojim tragovima. Hoće li tvoja vrata biti zamka ili put? To je pitanje koje si ostavio."
        ]
        let closedSR = [
            "Zatvorio si vrata. Tišina nije prazna. U njoj prvi put čuješ misao koja nije došla sa ekrana.",
            "Vrata su se zatvorila, ali slika je ostala u tebi. Nije te progonila vest — nego način na koji si je gledao.",
            "Ovde nema ni plamena ni anđela. Samo pažnja, mala i neumorna, koja bira čemu će dati oblik.",
            "Zatvorio si prolaz za svet, ne i prolaz u sebi. Neke brave postoje samo dok ih držimo."
        ]
        let openEN = [
            "You left the door open. There is no throne beyond it. Only other people, choosing what to look at in this same moment.",
            "The door remains open. Everything you saw may become fear, compassion, or nothing. The screen does not decide.",
            "Air enters from outside. Hell did not vanish; you simply stopped calling it the only possible world.",
            "Someone else will follow your footprints. Will your door be a trap or a passage? That is the question you left."
        ]
        let closedEN = [
            "You closed the door. Silence is not empty. For the first time you hear a thought that did not come from a screen.",
            "The door closed, but the image remained inside you. The headline did not haunt you; your way of looking did.",
            "There are no flames and no angels here. Only attention, small and tireless, choosing what to bring into being.",
            "You closed a passage to the world, not the passage within yourself. Some locks exist only while we hold them."
        ]
        let index = (endingSeed + endingRegister + cycle) % 4
        if doorChoice == 0 { return (sr ? openSR : openEN)[index] }
        return (sr ? closedSR : closedEN)[index]
    }

    private var endingCoda: String {
        let srLines = [
            "Ako si tražio Boga iza poslednjih vrata, možda si sve vreme stajao na mestu sa kog se ona otvaraju.",
            "Raj i pakao nisu dve adrese. Ponekad su dva načina da odgovoriš na isti prizor.",
            "Misao nije ceo svet. Ali menja način na koji ćeš u njega zakoračiti.",
            "Nisi dobio mapu. Dobio si ruku koja može da je nacrta.",
            "Iza svake kapije čekao je drugi oblik tvog izbora. Iza poslednje — njegov odjek.",
            "Niko ti ne može oduzeti pogled. Samo ga možeš predati."
        ]
        let enLines = [
            "If you sought God behind the last door, perhaps you stood all along where doors are opened.",
            "Heaven and hell are not two addresses. Sometimes they are two responses to the same sight.",
            "A thought is not the whole world. But it changes how you step into it.",
            "You were not given a map. You were given the hand that could draw one.",
            "Behind each gate waited another shape of your choosing. Behind the last, its echo.",
            "Nobody can take your gaze. You can only give it away."
        ]
        return (sr ? srLines : enLines)[(endingSeed + cycle * 3 + endingRegister) % srLines.count]
    }

    private func win() {
        guard phase == .playing || phase == .reckoning else { return }
        performance[room] = secondsRemaining
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.8)) {
            phase = room == 0 ? .revelation : .passage
        }
    }

    private func loseTime(_ seconds: Int) {
        guard phase == .playing || phase == .reckoning else { return }
        penalties += 1
        secondsRemaining = max(0, secondsRemaining - seconds)
        if secondsRemaining == 0 { fail() }
    }

    private func fail() {
        guard phase == .playing || phase == .reckoning else { return }
        failures += 1
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.8)) { phase = .failed }
    }

    private func openRandomPortal() {
        let destinations = [
            "https://www.fallingfalling.com/",
            "https://www.psychedelicio.us/",
            "https://psilly.com/experiments/polygons.html",
            "https://hotdoom.com/",
            "https://thaer.no/",
            "https://zoomquilt.org/",
            "https://zoomquilt2.com/"
        ]
        let choices = destinations.filter { $0 != lastPortal }
        if let chosen = choices.randomElement(), let url = URL(string: chosen) {
            lastPortal = chosen
            openURL(url)
        }
    }

    private func restartRoom() {
        // Force a new puzzle identity even on retry.
        cycle += 1
        secondsRemaining = allowance(room)
        serial = 0
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) {
            phase = room == 0 ? .reckoning : .playing
        }
    }

    private func newCycle() {
        cycle += 1
        heard = []
        serial = 0
        room = 9
        secondsRemaining = allowance(9)
        tremor = false
        witnessArticles = []
        performance = [:]
        penalties = 0
        failures = 0
        witnessScore = 0
        witnessTotal = 0
        echoHeadline = ""
        doorChoice = nil
        endingSeed = Int.random(in: 0..<10_000)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) { phase = .playing }
    }

    private func allowance(_ room: Int) -> Int {
        // The non-numbered witness room lends seven minutes beyond the gates.
        if room == 0 { return 7 * 60 }
        return max(1, min(9, room)) * 60
    }

    private var epilogueLine: String {
        let srLines = [
            "Vrata su opet tamo. Nisu ista.",
            "Neko je zauzeo tvoje mesto dok te nije bilo.",
            "Sada postoji deseta senka. Brojao si devet.",
            "Prošao si kroz vrata, ali se ona nisu pomerila.",
            "Sledeći put možda ćeš se setiti zašto si došao."
        ]
        let enLines = [
            "The door is there again. It is not the same door.",
            "Someone took your place while you were away.",
            "There are ten shadows now. You counted nine.",
            "You crossed the door. The door did not move.",
            "Perhaps next time you will remember why you came."
        ]
        return (sr ? srLines : enLines)[cycle % srLines.count]
    }

    private func runClock() async {
        guard phase == .playing || phase == .reckoning else { return }
        while !Task.isCancelled && (phase == .playing || phase == .reckoning) {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard !Task.isCancelled, phase == .playing || phase == .reckoning else { return }
            // An inactive app doesn't silently consume puzzle time.
            if scenePhase == .active { secondsRemaining -= 1 }
            if secondsRemaining <= 0 {
                fail()
                return
            }
        }
    }

    private func speak() async {
        guard phase == .playing || phase == .reckoning else { return }
        while !Task.isCancelled && (phase == .playing || phase == .reckoning) {
            serial += 1
            let line = GateWords.whisper(sr: sr, room: room, cycle: cycle, serial: serial, used: &heard)
            whisperOpacity = 0.9
            whisper = ""
            if reduceMotion { whisper = line }
            else {
                for character in line {
                    guard !Task.isCancelled, phase == .playing || phase == .reckoning else { return }
                    whisper.append(character)
                    do { try await Task.sleep(nanoseconds: 42_000_000) } catch { return }
                }
            }
            // Let the whole thought remain clear before it slowly withdraws.
            do { try await Task.sleep(nanoseconds: UInt64(line.contains("—") ? 15 : 11) * 1_000_000_000) }
            catch { return }
            guard !Task.isCancelled, phase == .playing || phase == .reckoning else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 4.0)) { whisperOpacity = 0.32 }
            do { try await Task.sleep(nanoseconds: UInt64(Int.random(in: 12...17)) * 1_000_000_000) }
            catch { return }
            guard !Task.isCancelled, phase == .playing || phase == .reckoning else { return }
            transcript.append(line)
            if transcript.count > 60 { transcript.removeFirst(transcript.count - 60) }
            whisper = ""
        }
    }

    private func advanceStory() async {
        if phase == .passage {
            do { try await Task.sleep(nanoseconds: 3_200_000_000) } catch { return }
            guard !Task.isCancelled, phase == .passage else { return }
            if room == 1 {
                witnessArticles = RealityArchive.sample(feed.items + Array(feed.archive.values))
                room = 0
                secondsRemaining = allowance(0)
                serial = 0
                whisper = ""
                withAnimation(reduceMotion ? nil : .easeOut(duration: 1.0)) { phase = .reckoning }
            } else {
                room -= 1
                secondsRemaining = allowance(room)
                serial = 0
                whisper = ""
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) { phase = .playing }
            }
        } else if phase == .revelation {
            do { try await Task.sleep(nanoseconds: 3_800_000_000) } catch { return }
            guard !Task.isCancelled, phase == .revelation else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 1.0)) { phase = .collapse }
        } else if phase == .collapse {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard !Task.isCancelled, phase == .collapse else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 2.0)) { phase = .aftermath }
        }
    }
}

private struct GateOutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(2)
            .foregroundStyle(Color(red: 0.89, green: 0.86, blue: 0.82))
            .padding(.horizontal, 25).padding(.vertical, 15)
            .overlay(Rectangle().stroke(Ink.red.opacity(configuration.isPressed ? 0.95 : 0.5), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.62 : 1)
    }
}

private struct GateRitual: View {
    @EnvironmentObject private var prefs: NewsPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let room: Int
    let cycle: Int
    let failure: Bool
    @State private var moving = false

    private var shapeCount: Int { 7 + room % 3 }
    private var ivory: Color { Color(red: 0.89, green: 0.86, blue: 0.82) }
    private var sr: Bool { prefs.language == "sr" }

    var body: some View {
        GeometryReader { dimensions in
            ZStack {
                Color.black
                Circle().fill(Ink.red.opacity(failure ? 0.25 : 0.13))
                    .frame(width: 235, height: 235)
                    .blur(radius: failure ? 48 : 88)
                    .scaleEffect(moving ? 1.25 : 0.8)
                if failure {
                    // A slow, abstract descent rather than a flashing jump scare.
                    ForEach(0..<13, id: \.self) { index in
                        Rectangle()
                            .fill(LinearGradient(colors: [Ink.red.opacity(0.0), Ink.red.opacity(Double(index % 4 + 1) * 0.09), .black],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: CGFloat(9 + index % 5 * 8), height: CGFloat(150 + index * 17))
                            .rotationEffect(.degrees(Double(index * 29 - 160)))
                            .offset(x: CGFloat(sin(Double(index * 11 + cycle) * 0.83)) * dimensions.size.width * 0.43,
                                    y: dimensions.size.height * (moving ? 0.31 : 0.46))
                    }
                    Rectangle().fill(Ink.red.opacity(0.13))
                        .frame(height: 2)
                        .offset(y: moving ? -dimensions.size.height * 0.2 : dimensions.size.height * 0.11)
                }
                ForEach(0..<shapeCount, id: \.self) { index in
                    let angle = Double(index) * 360 / Double(shapeCount)
                    ornament(index: index)
                        .rotationEffect(.degrees(angle + (moving ? Double(room * 19) : Double(cycle * 23))))
                        .offset(y: moving ? CGFloat(-112 - index * 7) : CGFloat(-25 - index * 5))
                        .rotationEffect(.degrees(angle))
                        .opacity(moving ? 0.7 : 0.23)
                }
                Rectangle().stroke(Ink.red.opacity(0.32), lineWidth: 1)
                    .frame(width: 79, height: 79)
                    .rotationEffect(.degrees(moving ? 135 : 45))
                Rectangle().fill(Ink.red).frame(width: 9, height: 9)
                if !failure {
                    VStack(spacing: 14) {
                        Spacer()
                        Text(room == 0 ? "SITO / ∅" : String(format: "%02d → %02d", room, max(0, room - 1)))
                            .font(.system(size: 11, design: .monospaced))
                            .tracking(5).foregroundStyle(ivory.opacity(0.5))
                        Text(room == 0
                             ? (sr ? "EKRAN SE UGASIO" : "THE SCREEN WENT DARK")
                             : (sr ? "KAPIJA JE POPUSTILA" : "THE GATE HAS YIELDED"))
                            .font(.system(size: 13, weight: .light, design: .serif))
                            .tracking(4).foregroundStyle(ivory.opacity(0.8))
                        if room > 1 {
                            Text(GateWords.circle(room - 1, sr: sr))
                                .font(.system(size: 10, design: .monospaced))
                                .tracking(3).foregroundStyle(Ink.red.opacity(0.68))
                        }
                        Text(passageLine)
                            .font(.system(size: 12, design: .serif))
                            .foregroundStyle(Ink.red.opacity(0.78))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                        Spacer().frame(height: 66)
                    }
                }
            }
            .frame(width: dimensions.size.width, height: dimensions.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: failure ? 1.6 : 2.6).repeatForever(autoreverses: true)) {
                moving = true
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var passageLine: String {
        let lines = sr
            ? ["Voda pamti obrise.", "Niko ovde ne broji unazad.", "Svetlost nije oproštaj.", "Ispod poda je drugo nebo.", "Ogledalo je trepnulo prvo.", "Sada čuješ i tišinu.", "Neko je ušao dok si gledao.", "Vrati se samo ako moraš.", "I na početku je kraj."]
            : ["The water remembers outlines.", "Nobody counts backward here.", "Light is not forgiveness.", "There is another sky beneath the floor.", "The mirror blinked first.", "Now you can hear silence.", "Someone entered while you watched.", "Return only if you must.", "Even the beginning has an end."]
        return lines[max(0, min(8, 9 - max(room, 1)))]
    }

    @ViewBuilder private func ornament(index: Int) -> some View {
        switch room {
        case 9:
            ZStack {
                Rectangle().fill(Ink.red.opacity(0.55)).frame(width: 2, height: CGFloat(12 + index*7))
                Rectangle().fill(Ink.red.opacity(0.55)).frame(width: CGFloat(12 + index*7), height: 2)
            }
        case 8:
            Circle().stroke(Ink.red.opacity(0.55), lineWidth: 1)
                .frame(width: CGFloat(14 + index * 9), height: CGFloat(14 + index * 9))
        case 7:
            Rectangle().fill(Ink.red.opacity(0.55))
                .frame(width: CGFloat(2 + index % 3), height: CGFloat(25 + index * 6))
        case 6:
            Capsule().fill(Ink.red.opacity(0.65))
                .frame(width: CGFloat(36 + index*5), height: CGFloat(2 + index % 2))
        case 5:
            Rectangle().stroke(Ink.red.opacity(0.6), lineWidth: 0.9)
                .frame(width: CGFloat(12 + index * 7), height: CGFloat(12 + index * 7))
        case 4:
            Rectangle().stroke(Ink.red.opacity(0.5), lineWidth: 1)
                .frame(width: CGFloat(18 + index*6), height: CGFloat(18 + index*6))
                .rotationEffect(.degrees(45))
        case 3:
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Ink.red.opacity(0.54)).frame(width: 3, height: 3)
                }
            }
            .rotationEffect(.degrees(Double(index * 23)))
        case 2:
            Capsule().fill(Ink.red.opacity(0.52))
                .frame(width: CGFloat(25 + index * 5), height: CGFloat(1 + index % 3))
        case 1:
            Circle().stroke(Ink.red.opacity(0.48), lineWidth: CGFloat(index % 3 + 1))
                .frame(width: CGFloat(24 + index*8), height: CGFloat(24 + index*8))
                .scaleEffect(x: 1.0, y: 0.4)
        default:
            Rectangle().fill(Ink.red.opacity(0.6))
                .frame(width: CGFloat(8 + index*4), height: CGFloat(8 + index*4))
                .rotationEffect(.degrees(Double(index * 17)))
        }
    }
}
