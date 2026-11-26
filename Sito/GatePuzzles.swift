import SwiftUI

// Eight self-contained games behind the ninth room. Each creates a solvable
// state and reports completion; the surrounding story owns time and progression.
enum GateStyle {
    static let chalk = Color(red: 0.89, green: 0.86, blue: 0.82)
    static let faint = chalk.opacity(0.47)
    static let marks = ["◯", "△", "□", "◇", "✕", "✦"]
}

struct GateCaption: View {
    let title: String
    let instruction: String

    var body: some View {
        VStack(spacing: 11) {
            Text(title)
                .font(.system(size: 18, weight: .light, design: .serif))
                .tracking(3)
                .foregroundStyle(GateStyle.chalk)
            Text(instruction)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(GateStyle.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
    }
}

struct GateKey: View {
    let text: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 23, weight: .light, design: .monospaced))
                .foregroundStyle(active ? Ink.red : GateStyle.chalk)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(Color.white.opacity(active ? 0.11 : 0.045))
                .overlay(Rectangle().stroke(active ? Ink.red.opacity(0.8) : GateStyle.chalk.opacity(0.2), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

struct GatePuzzlesView: View {
    let room: Int
    let cycle: Int
    let compact: Bool
    let solved: () -> Void
    let penalize: (Int) -> Void

    var body: some View {
        Group {
            switch room {
            case 8: EchoGate(solved: solved)
            case 7: FogMazeGate(compact: compact, solved: solved)
            case 6: MirrorMemoryGate(compact: compact, solved: solved, penalize: penalize)
            case 5: ShatteredLightsGate(solved: solved)
            case 4: PatternSequencesGate(compact: compact, solved: solved, penalize: penalize)
            case 3: PrimeTwinsGate(solved: solved, penalize: penalize)
            case 2: CipherLockGate(solved: solved, penalize: penalize)
            default: SkyscraperGate(compact: compact, solved: solved)
            }
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 23)
    }
}

private struct EchoGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let solved: () -> Void
    @State private var pattern = (0..<7).map { _ in Int.random(in: 0..<4) }
    @State private var attempt: [Int] = []
    @State private var showing = true
    @State private var mistake = false
    @State private var round = 0

    private var sr: Bool { prefs.language == "sr" }

    var body: some View {
        VStack(spacing: 19) {
            GateCaption(title: sr ? "ODJEK" : "THE ECHO",
                        instruction: showing ? (sr ? "Požuda želi ponavljanje. Zapamti redosled pre nego što nestane." : "Desire asks for repetition. Remember the order before it vanishes.") : (sr ? "Ponovi \(pattern.count) znakova, bez izostavljanja." : "Repeat all \(pattern.count) signs without omission."))
            Text("\(round + 1) / 4")
                .font(.system(size: 11, design: .monospaced)).tracking(4)
                .foregroundStyle(Ink.red.opacity(0.75))
            HStack(spacing: 3) {
                ForEach(pattern.indices, id: \.self) { index in
                    Text(showing ? GateStyle.marks[pattern[index]] : (index < attempt.count ? GateStyle.marks[attempt[index]] : "·"))
                        .font(.system(size: 20, weight: .ultraLight))
                        .foregroundStyle(mistake ? Ink.red : GateStyle.chalk)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 75)
            HStack(spacing: 9) {
                ForEach(0..<4, id: \.self) { index in
                    GateKey(text: GateStyle.marks[index]) { choose(index) }
                }
            }
            .disabled(showing)
        }
        .task { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { showing = false } }
    }

    private func choose(_ number: Int) {
        guard !showing && !mistake else { return }
        attempt.append(number)
        guard attempt.count == pattern.count else { return }
        if attempt == pattern {
            if round == 3 { solved() }
            else {
                round += 1
                pattern = (0..<(7 + round)).map { _ in Int.random(in: 0..<4) }
                attempt = []
                showing = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_500_000_000)
                    if !Task.isCancelled { showing = false }
                }
            }
        }
        else {
            mistake = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 850_000_000)
                attempt = []
                showing = true
                mistake = false
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                showing = false
            }
        }
    }
}

private struct LabyrinthGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let rotation: Int
    let solved: () -> Void
    @State private var position = 0

    private let original: [[Character]] = ["S...#", "###.#", "#...#", "#.###", "#...E"].map { Array($0) }
    private var grid: [[Character]] {
        var result = original
        for _ in 0..<rotation { result = (0..<5).map { r in (0..<5).map { c in result[4-c][r] } } }
        return result
    }
    private var sr: Bool { prefs.language == "sr" }

    var body: some View {
        VStack(spacing: 20) {
            GateCaption(title: sr ? "LAVIRINT" : "THE LABYRINTH",
                        instruction: sr ? "Pronađi izlaz. Zidovi pamte svaki pogrešan smer." : "Find the exit. The walls remember every wrong turn.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 5), spacing: 3) {
                ForEach(0..<25, id: \.self) { index in
                    let tile = grid[index / 5][index % 5]
                    ZStack {
                        Rectangle().fill(tile == "#" ? Ink.red.opacity(0.08) : GateStyle.chalk.opacity(0.11))
                        if position == index { Circle().fill(Ink.red).frame(width: 17, height: 17) }
                        else if tile == "E" { Text("◇").foregroundStyle(GateStyle.chalk) }
                    }
                    .frame(height: 48)
                }
            }
            .frame(maxWidth: 270)
            VStack(spacing: 5) {
                direction("arrow.up", dr: -1, dc: 0)
                HStack(spacing: 5) {
                    direction("arrow.left", dr: 0, dc: -1)
                    direction("arrow.down", dr: 1, dc: 0)
                    direction("arrow.right", dr: 0, dc: 1)
                }
            }
        }
        .onAppear {
            if let index = grid.flatMap({ $0 }).firstIndex(of: "S") { position = index }
        }
    }

    private func direction(_ symbol: String, dr: Int, dc: Int) -> some View {
        Button { move(dr: dr, dc: dc) } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(GateStyle.chalk)
                .frame(width: 65, height: 43)
                .background(GateStyle.chalk.opacity(0.08))
        }.buttonStyle(.plain)
    }

    private func move(dr: Int, dc: Int) {
        let r = position / 5 + dr
        let c = position % 5 + dc
        guard (0..<5).contains(r), (0..<5).contains(c), grid[r][c] != "#" else { return }
        position = r * 5 + c
        if grid[r][c] == "E" { solved() }
    }
}

private struct LightsGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let solved: () -> Void
    @State private var lights = Array(repeating: false, count: 9)

    var body: some View {
        VStack(spacing: 26) {
            GateCaption(title: prefs.language == "sr" ? "DEVET PLAMENOVA" : "NINE FLAMES",
                        instruction: prefs.language == "sr" ? "Ugasi sva svetla. Svaki dodir menja susede." : "Extinguish every light. Each touch changes its neighbours.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                ForEach(0..<9, id: \.self) { index in
                    Button { move(index) } label: {
                        Rectangle()
                            .fill(lights[index] ? Ink.red.opacity(0.72) : GateStyle.chalk.opacity(0.055))
                            .frame(height: 79)
                            .overlay(Rectangle().stroke(Ink.red.opacity(0.4), lineWidth: 0.6))
                            .shadow(color: Ink.red.opacity(lights[index] ? 0.4 : 0), radius: 18)
                    }.buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 277)
        }
        .onAppear {
            var board = Array(repeating: false, count: 9)
            for _ in 0..<Int.random(in: 5...9) { flip(Int.random(in: 0..<9), board: &board) }
            if !board.contains(true) { flip(4, board: &board) }
            lights = board
        }
    }

    private func flip(_ index: Int, board: inout [Bool]) {
        let r = index / 3, c = index % 3
        for (dr, dc) in [(0,0),(-1,0),(1,0),(0,-1),(0,1)] {
            let nr = r + dr, nc = c + dc
            if (0..<3).contains(nr) && (0..<3).contains(nc) { board[nr*3+nc].toggle() }
        }
    }
    private func move(_ index: Int) {
        flip(index, board: &lights)
        if !lights.contains(true) { solved() }
    }
}

private struct CipherGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let solved: () -> Void
    @State private var key = Array(0...5).shuffled()
    @State private var symbols = (0..<4).map { _ in Int.random(in: 0...5) }
    @State private var entered: [Int] = []
    @State private var mistake = false

    var body: some View {
        VStack(spacing: 23) {
            GateCaption(title: prefs.language == "sr" ? "PISMO BEZ GLASA" : "THE VOICELESS LETTER",
                        instruction: prefs.language == "sr" ? "Prevedi znakove u brojeve. Redosled je važan." : "Translate the signs into numbers. Order is everything.")
            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    VStack(spacing: 5) {
                        Text(GateStyle.marks[index]).font(.system(size: 20))
                        Rectangle().fill(Ink.red.opacity(0.4)).frame(height: 1)
                        Text("\(key[index])").font(.system(size: 15, design: .monospaced))
                    }
                    .foregroundStyle(GateStyle.chalk.opacity(0.78))
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { index in
                    Text(GateStyle.marks[symbols[index]])
                        .font(.system(size: 34, weight: .ultraLight))
                        .foregroundStyle(Ink.red)
                }
            }
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { index in
                    Text(index < entered.count ? "\(entered[index])" : "_")
                        .font(.system(size: 24, design: .monospaced))
                        .foregroundStyle(mistake ? Ink.red : GateStyle.chalk)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { number in
                    GateKey(text: "\(number)") { enter(number) }
                }
            }
        }
    }

    private func enter(_ number: Int) {
        guard !mistake else { return }
        entered.append(number)
        guard entered.count == symbols.count else { return }
        if entered == symbols.map({ key[$0] }) { solved() }
        else {
            mistake = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                entered = []
                mistake = false
            }
        }
    }
}

private struct SequenceGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let solved: () -> Void
    @State private var start = Int.random(in: 2...10)
    @State private var step = Int.random(in: 3...7)
    @State private var round = 0
    @State private var choices: [Int] = []
    private var correct: Int { start + step * 4 }

    var body: some View {
        VStack(spacing: 25) {
            GateCaption(title: prefs.language == "sr" ? "REDOSLED" : "THE SEQUENCE",
                        instruction: prefs.language == "sr" ? "Tri niza. Pronađi broj koji nedostaje." : "Three sequences. Find the missing number.")
            Text("\(round + 1) / 3")
                .foregroundStyle(Ink.red).tracking(4)
                .font(.system(size: 11, design: .monospaced))
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { index in
                    Text("\(start + step*index)")
                        .font(.system(size: 23, design: .serif))
                        .frame(maxWidth: .infinity)
                }
                Text("?").font(.system(size: 28)).foregroundStyle(Ink.red)
            }
            .foregroundStyle(GateStyle.chalk)
            HStack(spacing: 8) {
                ForEach(choices, id: \.self) { number in
                    GateKey(text: "\(number)") { choose(number) }
                }
            }
        }
        .onAppear { options() }
    }

    private func options() {
        choices = [correct - step, correct, correct + step, correct + step*2].shuffled()
    }
    private func choose(_ number: Int) {
        guard number == correct else { return }
        if round == 2 { solved() }
        else {
            round += 1
            start = Int.random(in: 3...14)
            step = Int.random(in: 4...10)
            options()
        }
    }
}

private struct MirrorGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let solved: () -> Void
    @State private var cards = [0,0,1,1,2,2,3,3].shuffled()
    @State private var shown: [Int] = []
    @State private var found = Set<Int>()
    @State private var waiting = false

    var body: some View {
        VStack(spacing: 25) {
            GateCaption(title: prefs.language == "sr" ? "OGLEDALA" : "THE MIRRORS",
                        instruction: prefs.language == "sr" ? "Četiri para. Otkrij ih pre nego što te ugledaju." : "Four pairs. Find them before they find you.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(0..<8, id: \.self) { index in
                    let revealed = found.contains(index) || shown.contains(index)
                    GateKey(text: revealed ? GateStyle.marks[cards[index]] : "·", active: found.contains(index)) { reveal(index) }
                        .disabled(waiting || found.contains(index))
                }
            }
        }
    }

    private func reveal(_ index: Int) {
        guard !shown.contains(index), !waiting else { return }
        shown.append(index)
        guard shown.count == 2 else { return }
        if cards[shown[0]] == cards[shown[1]] {
            found.formUnion(shown)
            shown = []
            if found.count == 8 { solved() }
        } else {
            waiting = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                shown = []
                waiting = false
            }
        }
    }
}

private struct PrimeGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let solved: () -> Void
    @State private var numbers = [2,3,5,7,11,4,6,8,9,10,12,15].shuffled()
    @State private var progress = 0
    @State private var mistake = false
    private let answer = [2,3,5,7,11]

    var body: some View {
        VStack(spacing: 22) {
            GateCaption(title: prefs.language == "sr" ? "LAŽNI BROJEVI" : "THE FALSE NUMBERS",
                        instruction: prefs.language == "sr" ? "Dodirni proste brojeve, od najmanjeg do najvećeg. Pogrešan izbor briše trag." : "Touch the primes, smallest to largest. A wrong choice erases the trail.")
            Text("\(progress) / 5")
                .font(.system(size: 11, design: .monospaced)).tracking(4)
                .foregroundStyle(mistake ? Ink.red : GateStyle.faint)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(numbers, id: \.self) { number in
                    GateKey(text: "\(number)", active: answer.prefix(progress).contains(number)) { choose(number) }
                        .disabled(answer.prefix(progress).contains(number))
                }
            }
        }
    }

    private func choose(_ number: Int) {
        if number == answer[progress] {
            progress += 1
            mistake = false
            if progress == answer.count { solved() }
        } else { progress = 0; mistake = true }
    }
}

private struct DialGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let solved: () -> Void
    @State private var positions = (0..<4).map { _ in Int.random(in: 0..<4) }
    private let targets = [3, 0, 2, 1]

    var body: some View {
        VStack(spacing: 26) {
            GateCaption(title: prefs.language == "sr" ? "POSLEDNJA BRAVA" : "THE LAST LOCK",
                        instruction: prefs.language == "sr" ? "Okreći četiri pečata. Neka odgovaraju senkama ispod njih." : "Turn the four seals. Match the shadows beneath them.")
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { index in
                    VStack(spacing: 14) {
                        GateKey(text: GateStyle.marks[positions[index]], active: positions[index] == targets[index]) {
                            positions[index] = (positions[index] + 1) % 4
                            if positions == targets { solved() }
                        }
                        Text(GateStyle.marks[targets[index]])
                            .font(.system(size: 18))
                            .foregroundStyle(Ink.red.opacity(0.5))
                    }
                }
            }
            Text(prefs.language == "sr" ? "DODIRNI DA OKRENEŠ" : "TOUCH TO ROTATE")
                .font(.system(size: 10, design: .monospaced)).tracking(3)
                .foregroundStyle(GateStyle.faint)
        }
    }
}
