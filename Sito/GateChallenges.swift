import SwiftUI

// A perfect maze has a single path between any two open cells. Additional
// seals force exploration of dead ends, not just following the exit corridor.
private struct MistMaze {
    let open: Set<Int>
    let start: Int
    let exit: Int
    let seals: Set<Int>
    static let width = 17

    static func make() -> MistMaze {
        func neighbours(_ tile: Int) -> [(Int, Int)] {
            let r = tile / width, c = tile % width
            return [(-2,0),(2,0),(0,-2),(0,2)].compactMap { dr, dc in
                let nr = r + dr, nc = c + dc
                guard (1..<width-1).contains(nr), (1..<width-1).contains(nc) else { return nil }
                return (nr*width+nc, (r+dr/2)*width+c+dc/2)
            }
        }
        let start = width + 1
        var open = Set([start])
        var visited = Set([start])
        var stack = [start]
        while let last = stack.last {
            let unvisited = neighbours(last).filter { !visited.contains($0.0) }.shuffled()
            if let (next, midpoint) = unvisited.first {
                visited.insert(next)
                open.insert(next)
                open.insert(midpoint)
                stack.append(next)
            } else { stack.removeLast() }
        }
        var distance = [start: 0]
        var queue = [start]
        var cursor = 0
        while cursor < queue.count {
            let tile = queue[cursor]
            cursor += 1
            let r = tile / width, c = tile % width
            for (dr, dc) in [(-1,0),(1,0),(0,-1),(0,1)] {
                let next = (r+dr)*width+c+dc
                if open.contains(next), distance[next] == nil {
                    distance[next] = distance[tile, default: 0] + 1
                    queue.append(next)
                }
            }
        }
        let exit = distance.max(by: { $0.value < $1.value })?.key ?? start
        let candidates = distance.filter { $0.key != start && $0.key != exit && $0.value > 24 }
            .sorted { $0.value > $1.value }
        var seals = Set<Int>()
        for (tile, _) in candidates.shuffled() {
            if seals.count == 3 { break }
            let r = tile / width, c = tile % width
            if seals.allSatisfy({ abs($0/width-r) + abs($0%width-c) >= 7 }) { seals.insert(tile) }
        }
        if seals.count < 3 {
            for (tile, _) in distance.sorted(by: { $0.value > $1.value })
                where seals.count < 3 && tile != start && tile != exit {
                seals.insert(tile)
            }
        }
        return MistMaze(open: open, start: start, exit: exit, seals: seals)
    }
}

struct FogMazeGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let compact: Bool
    let solved: () -> Void
    @State private var maze = MistMaze(open: [], start: 18, exit: 18, seals: [])
    @State private var position = 18
    @State private var recentSteps: [Int] = []
    @State private var collected = Set<Int>()
    @State private var wallPulse = false
    private let window = 7
    private var sr: Bool { prefs.language == "sr" }

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            GateCaption(title: sr ? "ZIDOVI KOJI PAMTE" : "THE REMEMBERING WALLS",
                        instruction: sr ? "Proždrljivost želi svaki put. Nema mape; vidiš samo dva koraka. Zapamti raskrsnice, pronađi tri pečata i izlaz." : "Gluttony wants every path. There is no map; you see only two steps. Remember the turns, find three seals and the exit.")
            Text("\(collected.count) / 3")
                .font(.system(size: 11, design: .monospaced)).tracking(4).foregroundStyle(Ink.red)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: window), spacing: 2) {
                ForEach(0..<(window * window), id: \.self) { index in
                    let dr = index / window - window / 2
                    let dc = index % window - window / 2
                    let row = position / MistMaze.width + dr
                    let column = position % MistMaze.width + dc
                    let inside = (0..<MistMaze.width).contains(row) && (0..<MistMaze.width).contains(column)
                    let tile = row * MistMaze.width + column
                    let radius = abs(dr) + abs(dc)
                    let seen = inside && radius <= 2
                    let passage = inside && maze.open.contains(tile)
                    ZStack {
                        Rectangle().fill(!seen ? Color.black :
                                         (passage ? GateStyle.chalk.opacity(radius == 2 ? 0.09 : 0.20) : Ink.red.opacity(0.075)))
                        if radius == 0 {
                            Circle().fill(Ink.red).frame(width: 12, height: 12)
                                .shadow(color: Ink.red.opacity(0.8), radius: 9)
                        } else if seen && maze.seals.contains(tile) && !collected.contains(tile) {
                            Text("✦").font(.system(size: 14)).foregroundStyle(Ink.red)
                        } else if seen && tile == maze.exit {
                            Text("◇").font(.system(size: 14))
                                .foregroundStyle(collected.count == 3 ? GateStyle.chalk : Ink.red.opacity(0.5))
                        } else if seen && passage && recentSteps.contains(tile) {
                            Circle().fill(GateStyle.chalk.opacity(0.19)).frame(width: 3, height: 3)
                        }
                    }
                    .frame(height: compact ? 29 : 35)
                }
            }
            .frame(maxWidth: 275)
            .overlay(Rectangle().stroke(Ink.red.opacity(wallPulse ? 0.55 : 0.2), lineWidth: 0.6))
            VStack(spacing: 3) {
                arrow("arrow.up", dr: -1, dc: 0)
                HStack(spacing: 5) {
                    arrow("arrow.left", dr: 0, dc: -1)
                    arrow("arrow.down", dr: 1, dc: 0)
                    arrow("arrow.right", dr: 0, dc: 1)
                }
            }
        }
        .onAppear {
            maze = MistMaze.make()
            position = maze.start
            recentSteps = [position]
            collected = []
        }
    }

    private func arrow(_ icon: String, dr: Int, dc: Int) -> some View {
        Button { move(dr: dr, dc: dc) } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(GateStyle.chalk)
                .frame(width: 62, height: compact ? 29 : 35)
                .background(GateStyle.chalk.opacity(0.08))
        }.buttonStyle(.plain)
    }

    private func move(dr: Int, dc: Int) {
        let r = position / MistMaze.width + dr, c = position % MistMaze.width + dc
        guard (0..<MistMaze.width).contains(r), (0..<MistMaze.width).contains(c) else { return }
        let next = r*MistMaze.width+c
        guard maze.open.contains(next) else {
            withAnimation(.easeOut(duration: 0.25)) { wallPulse = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                wallPulse = false
            }
            return
        }
        position = next
        recentSteps.append(next)
        if recentSteps.count > 7 { recentSteps.removeFirst() }
        if maze.seals.contains(next) { collected.insert(next) }
        if next == maze.exit && collected.count == maze.seals.count { solved() }
    }
}

struct ShatteredLightsGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let solved: () -> Void
    @State private var lights = Array(repeating: false, count: 16)
    @State private var moves = 0

    var body: some View {
        VStack(spacing: 17) {
            GateCaption(title: prefs.language == "sr" ? "ŠESNAEST PLAMENOVA" : "SIXTEEN FLAMES",
                        instruction: prefs.language == "sr" ? "Gnev ne staje na jednom plamenu. Ugasi 4×4 mrežu: dodir menja polje i četiri suseda." : "Wrath never stops at one flame. Extinguish the 4×4 field: a touch changes its tile and four neighbours.")
            Text(prefs.language == "sr" ? "DODIRA: \(moves)" : "TOUCHES: \(moves)")
                .font(.system(size: 10, design: .monospaced)).tracking(2).foregroundStyle(GateStyle.faint)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                ForEach(0..<16, id: \.self) { index in
                    Button { tap(index) } label: {
                        Rectangle().fill(lights[index] ? Ink.red.opacity(0.83) : GateStyle.chalk.opacity(0.06))
                            .frame(height: 62)
                            .overlay(Rectangle().stroke(Ink.red.opacity(lights[index] ? 0.75 : 0.24), lineWidth: 0.9))
                            .shadow(color: Ink.red.opacity(lights[index] ? 0.28 : 0), radius: 12)
                    }.buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 280)
        }
        .onAppear {
            var board = Array(repeating: false, count: 16)
            for index in Array(0..<16).shuffled().prefix(Int.random(in: 11...14)) { toggle(index, on: &board) }
            if !board.contains(true) { toggle(6, on: &board) }
            lights = board
        }
    }

    private func toggle(_ index: Int, on board: inout [Bool]) {
        let r = index / 4, c = index % 4
        for (dr, dc) in [(0,0),(-1,0),(1,0),(0,-1),(0,1)] {
            let nr = r+dr, nc = c+dc
            if (0..<4).contains(nr), (0..<4).contains(nc) { board[nr*4+nc].toggle() }
        }
    }
    private func tap(_ index: Int) {
        moves += 1
        toggle(index, on: &lights)
        if !lights.contains(true) { solved() }
    }
}

private struct CodeGuess: Identifiable {
    let id = UUID()
    let digits: [Int]
    let exact: Int
    let displaced: Int
}

struct CipherLockGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let solved: () -> Void
    let penalize: (Int) -> Void
    @State private var code = Array(0...5).shuffled().prefix(4).map { $0 }
    @State private var input: [Int] = []
    @State private var guesses: [CodeGuess] = []
    private var sr: Bool { prefs.language == "sr" }

    var body: some View {
        VStack(spacing: 12) {
            GateCaption(title: sr ? "ŠIFRA SA DVA LICA" : "THE TWO-FACED CIPHER",
                        instruction: sr ? "Obmana koristi istinite, ali nepotpune tragove. Četiri različite cifre (0–5): koliko ih je na svom, a koliko na tuđem mestu?" : "Fraud speaks in true but incomplete clues. Four distinct digits (0–5): how many are exact, and how many belong elsewhere?")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(guesses.suffix(6)) { guess in
                    HStack(spacing: 13) {
                        Text(guess.digits.map(String.init).joined(separator: " "))
                            .foregroundStyle(GateStyle.chalk)
                        Spacer()
                        Text(sr ? "TAČNO \(guess.exact) · DRUGDE \(guess.displaced)" : "EXACT \(guess.exact) · ELSEWHERE \(guess.displaced)")
                            .foregroundStyle(Ink.red.opacity(0.78))
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
            .frame(height: 124, alignment: .bottom)
            .padding(.horizontal, 5)
            HStack(spacing: 13) {
                ForEach(0..<4, id: \.self) { index in
                    Text(index < input.count ? "\(input[index])" : "_")
                        .font(.system(size: 28, weight: .light, design: .monospaced))
                        .foregroundStyle(GateStyle.chalk)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 5) {
                ForEach(0...5, id: \.self) { digit in
                    GateKey(text: "\(digit)", active: input.contains(digit)) {
                        if input.count < 4 && !input.contains(digit) { input.append(digit) }
                    }
                }
            }
            HStack(spacing: 20) {
                Button { if !input.isEmpty { input.removeLast() } } label: {
                    Label(sr ? "OBRIŠI" : "ERASE", systemImage: "delete.left")
                }
                Button { submit() } label: {
                    Label(sr ? "PROVERI" : "TEST", systemImage: "arrow.right")
                }
                .disabled(input.count != 4)
            }
            .font(.system(size: 11, design: .monospaced)).tracking(1.5)
            .foregroundStyle(GateStyle.chalk.opacity(0.78))
            .buttonStyle(.plain)
        }
    }

    private func submit() {
        guard input.count == 4 else { return }
        let exact = zip(code, input).filter { $0.0 == $0.1 }.count
        let displaced = input.filter { code.contains($0) }.count - exact
        if exact == 4 { solved(); return }
        guesses.append(CodeGuess(digits: input, exact: exact, displaced: displaced))
        input = []
        if guesses.count > 7 { penalize(12) }
    }
}

private struct NumberRiddle {
    let terms: [Int]
    let answer: Int

    static func make(round: Int) -> NumberRiddle {
        var terms: [Int]
        var answer: Int
        switch round {
        case 0:
            let a = Int.random(in: 2...4), b = Int.random(in: 1...5), c = Int.random(in: 2...10)
            func term(_ n: Int) -> Int { a*n*n + b*n + c }
            terms = (0..<5).map(term)
            answer = term(5)
        case 1:
            let a = Int.random(in: 3...12), b = Int.random(in: 30...55)
            let stepA = Int.random(in: 5...9), stepB = Int.random(in: -8 ... -3)
            terms = (0..<6).map { $0.isMultiple(of: 2) ? a + ($0/2)*stepA : b + ($0/2)*stepB }
            answer = a + 3*stepA
        case 2:
            let shift = Int.random(in: 2...8)
            terms = [Int.random(in: 2...7), Int.random(in: 8...15)]
            for _ in 0..<3 { terms.append(terms[terms.count-1] + terms[terms.count-2] + shift) }
            answer = terms[4] + terms[3] + shift
        default:
            let a = Int.random(in: 1...3), b = Int.random(in: 2...9)
            func term(_ n: Int) -> Int { a*n*n*n + b*n + 7 }
            terms = (0..<5).map(term)
            answer = term(5)
        }
        return NumberRiddle(terms: terms, answer: answer)
    }
}

struct PatternSequencesGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let compact: Bool
    let solved: () -> Void
    let penalize: (Int) -> Void
    @State private var round = 0
    @State private var challenge = NumberRiddle.make(round: 0)
    @State private var mistakes = 0
    @State private var input = ""
    @State private var clueUsed = false
    private var sr: Bool { prefs.language == "sr" }

    var body: some View {
        VStack(spacing: 12) {
            GateCaption(title: sr ? "NIZOVI KOJI LAŽU" : "THE LYING SEQUENCES",
                        instruction: sr ? "Jeres počinje sumnjom u očigledno pravilo. Upiši sledeći broj bez ponuđenih odgovora; svaka greška odnosi više vremena." : "Heresy begins by doubting the obvious rule. Enter the next number without choices; every mistake takes more time.")
            Text("\(round + 1) / 4")
                .font(.system(size: 12, design: .monospaced)).tracking(4)
                .foregroundStyle(Ink.red)
            HStack(spacing: 5) {
                ForEach(challenge.terms.indices, id: \.self) { index in
                    Text("\(challenge.terms[index])")
                        .font(.system(size: 19, weight: .light, design: .serif))
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)
                        .foregroundStyle(GateStyle.chalk)
                        .frame(maxWidth: .infinity)
                }
                Text("?").font(.system(size: 23, design: .serif)).foregroundStyle(Ink.red)
            }
            .padding(.vertical, 6)
            HStack(spacing: 12) {
                Text(input.isEmpty ? "_" : input)
                    .font(.system(size: 28, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(GateStyle.chalk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 43)
                    .overlay(Rectangle().stroke(GateStyle.chalk.opacity(0.2), lineWidth: 0.7))
                Button { useClue() } label: {
                    Text(sr ? "TRAG · −18s" : "CLUE · −18s")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(clueUsed ? GateStyle.faint : Ink.red)
                }
                .disabled(clueUsed)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(0..<12, id: \.self) { index in
                    let label = index == 9 ? "⌫" : index == 11 ? "↵" : "\(index == 10 ? 0 : index + 1)"
                    Button { key(index) } label: {
                        Text(label).font(.system(size: 20, weight: .light, design: .monospaced))
                            .foregroundStyle(index == 11 ? Ink.red : GateStyle.chalk)
                            .frame(maxWidth: .infinity).frame(height: compact ? 33 : 38)
                            .background(GateStyle.chalk.opacity(0.055))
                            .overlay(Rectangle().stroke(GateStyle.chalk.opacity(0.18), lineWidth: 0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            if clueUsed {
                Text(clue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(GateStyle.faint)
                    .multilineTextAlignment(.center)
            }
            Text(mistakes == 0 ? " " : (sr ? "POGREŠNI ODGOVORI: \(mistakes) · CENA RASTE" : "WRONG ANSWERS: \(mistakes) · THE COST RISES"))
                .font(.system(size: 10, design: .monospaced)).tracking(2)
                .foregroundStyle(Ink.red.opacity(0.65))
        }
    }

    private var clue: String {
        let srClues = ["Pogledaj razlike između razlika.", "Dva niza smenjuju se, jedan po jedan.", "Svaki član čuje prethodna dva i isti šapat.", "Treće razlike ostaju nepromenjene."]
        let enClues = ["Look at the differences between differences.", "Two sequences alternate, one by one.", "Each term hears the previous two and one constant whisper.", "The third differences do not change."]
        return (sr ? srClues : enClues)[round]
    }

    private func useClue() {
        guard !clueUsed else { return }
        clueUsed = true
        penalize(18)
    }

    private func key(_ index: Int) {
        if index == 9 { if !input.isEmpty { input.removeLast() }; return }
        if index == 11 { submit(); return }
        if input.count < 5 { input.append(index == 10 ? "0" : "\(index + 1)") }
    }

    private func submit() {
        guard let value = Int(input), !input.isEmpty else { return }
        input = ""
        guard value == challenge.answer else {
            mistakes += 1
            penalize(min(54, 24 + mistakes * 10))
            return
        }
        if round == 3 { solved() }
        else {
            round += 1
            challenge = NumberRiddle.make(round: round)
            mistakes = 0
            clueUsed = false
        }
    }
}

struct MirrorMemoryGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    @Environment(\.scenePhase) private var scenePhase
    let compact: Bool
    let solved: () -> Void
    let penalize: (Int) -> Void
    @State private var cards = Array(0..<12).flatMap { [$0, $0] }.shuffled()
    @State private var showing: [Int] = []
    @State private var matched = Set<Int>()
    @State private var waiting = false
    @State private var previewing = true
    @State private var secondLookUsed = false
    @State private var errors = 0

    private let faces = ["◯", "△", "□", "◇", "✕", "✦", "⊕", "◈", "⌁", "⌘", "⋈", "✧"]
    private var sr: Bool { prefs.language == "sr" }

    var body: some View {
        VStack(spacing: 11) {
            GateCaption(title: sr ? "DVANAEST OGLEDALA" : "TWELVE MIRRORS",
                        instruction: sr ? "Pohlepa želi svih dvanaest parova. Vidiš ih šest sekundi; zatim svaki pogrešan par plaćaš vremenom." : "Greed wants all twelve pairs. You see them for six seconds; after that, every wrong pair costs time.")
            HStack {
                Text("\(matched.count / 2) / 12")
                Spacer()
                if previewing { Text(sr ? "ZAPAMTI" : "REMEMBER").foregroundStyle(Ink.red) }
                else if !secondLookUsed {
                    Button(sr ? "JOŠ JEDAN POGLED · −30s" : "ONE MORE LOOK · −30s") { replay() }
                        .buttonStyle(.plain)
                }
            }
                .font(.system(size: 11, design: .monospaced)).tracking(3)
                .foregroundStyle(GateStyle.faint)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(0..<24, id: \.self) { index in
                    let faceUp = previewing || showing.contains(index) || matched.contains(index)
                    Button { reveal(index) } label: {
                        Text(faceUp ? faces[cards[index]] : "·")
                            .font(.system(size: 21, weight: .ultraLight))
                            .foregroundStyle(matched.contains(index) ? Ink.red : GateStyle.chalk)
                            .frame(maxWidth: .infinity).frame(height: compact ? 37 : 43)
                            .background(GateStyle.chalk.opacity(faceUp ? 0.10 : 0.035))
                            .overlay(Rectangle().stroke(matched.contains(index) ? Ink.red.opacity(0.65) : GateStyle.chalk.opacity(0.18), lineWidth: 0.7))
                    }
                    .buttonStyle(.plain)
                    .disabled(waiting || previewing || matched.contains(index))
                }
            }
            .frame(maxWidth: 295)
        }
        .task { await showForActiveSeconds(6) }
    }

    private func replay() {
        guard !secondLookUsed, !waiting, !previewing else { return }
        secondLookUsed = true
        showing = []
        previewing = true
        penalize(30)
        Task { @MainActor in await showForActiveSeconds(4) }
    }

    private func showForActiveSeconds(_ total: Int) async {
        var remaining = total
        while remaining > 0 {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            if scenePhase == .active { remaining -= 1 }
        }
        if !Task.isCancelled { previewing = false }
    }

    private func reveal(_ index: Int) {
        guard !waiting, !matched.contains(index), !showing.contains(index) else { return }
        showing.append(index)
        guard showing.count == 2 else { return }
        if cards[showing[0]] == cards[showing[1]] {
            matched.formUnion(showing)
            showing = []
            if matched.count == 16 { solved() }
        } else {
            waiting = true
            errors += 1
            penalize(min(17, 6 + errors * 2))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                showing = []
                waiting = false
            }
        }
    }
}

struct PrimeTwinsGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let solved: () -> Void
    let penalize: (Int) -> Void
    @State private var numbers: [Int] = []
    @State private var answer: [Int] = []
    @State private var progress = 0
    @State private var missed = false

    var body: some View {
        VStack(spacing: 15) {
            GateCaption(title: prefs.language == "sr" ? "BLIZANCI U PRAZNINI" : "TWINS IN THE VOID",
                        instruction: prefs.language == "sr" ? "Nasilje razdvaja ono što pripada zajedno. Pronađi pet parova prostih brojeva s razlikom dva; biraj manje pa veće, parove uzlazno." : "Violence separates what belongs together. Find five twin-prime pairs two apart; tap low-to-high, pairs in ascending order.")
            Text("\(progress / 2) / 5")
                .font(.system(size: 12, design: .monospaced)).tracking(4)
                .foregroundStyle(missed ? Ink.red : GateStyle.faint)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(numbers, id: \.self) { digit in
                    GateKey(text: "\(digit)", active: answer.prefix(progress).contains(digit)) {
                        choose(digit)
                    }
                    .disabled(answer.prefix(progress).contains(digit))
                }
            }
            .frame(maxWidth: 285)
            Text(missed ? (prefs.language == "sr" ? "PAROVI SU SE RAZDVOJILI. KRENI PONOVO." : "THE PAIRS HAVE SEPARATED. BEGIN AGAIN.") : " ")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Ink.red)
                .multilineTextAlignment(.center)
        }
        .onAppear {
            let possible = [[11,13],[17,19],[29,31],[41,43],[59,61],[71,73],[101,103]]
            let selected = possible.shuffled().prefix(5).sorted { $0[0] < $1[0] }
            answer = selected.flatMap { $0 }
            let decoys = [4,8,14,21,25,27,33,35,39,49,51,57,67,79,89]
            numbers = (answer + decoys.shuffled().prefix(10)).shuffled()
        }
    }

    private func choose(_ number: Int) {
        guard progress < answer.count else { return }
        if number == answer[progress] {
            progress += 1
            missed = false
            if progress == answer.count { solved() }
        } else {
            progress = 0
            missed = true
            penalize(12)
        }
    }
}

// Four-by-four skyscrapers: each row/column is a permutation of 1...4;
// outside clues count towers visible from that edge. The generator searches
// all 576 Latin squares and removes clues only while a unique solution remains.
private struct SkylinePuzzle {
    let solution: [Int]
    let clues: [Int?] // top, bottom, left, right; four entries each.
    let givens: Set<Int>

    private static func startingCells() -> Set<Int> {
        // One given in every row and column, plus three scattered anchors.
        // This leaves nine deductions to make under the final minute.
        let columns = Array(0..<4).shuffled()
        var fixed = Set((0..<4).map { $0 * 4 + columns[$0] })
        for index in Array(0..<16).shuffled() where fixed.count < 7 { fixed.insert(index) }
        return fixed
    }

    private static let boards: [[Int]] = {
        var permutations = [[Int]]()
        func permute(_ rest: [Int], _ chosen: [Int]) {
            if rest.isEmpty { permutations.append(chosen); return }
            for digit in rest { permute(rest.filter { $0 != digit }, chosen + [digit]) }
        }
        permute([1,2,3,4], [])
        var boards = [[Int]]()
        func extend(_ rows: [[Int]]) {
            if rows.count == 4 { boards.append(rows.flatMap { $0 }); return }
            for candidate in permutations {
                if (0..<4).allSatisfy({ column in !rows.contains(where: { $0[column] == candidate[column] }) }) {
                    extend(rows + [candidate])
                }
            }
        }
        extend([])
        return boards
    }()
    private static let labeledBoards: [([Int], [Int])] = boards.map { ($0, allClues(for: $0)) }

    static func seen(_ line: [Int]) -> Int {
        var tallest = 0
        var count = 0
        for value in line where value > tallest { tallest = value; count += 1 }
        return count
    }

    private static func allClues(for board: [Int]) -> [Int] {
        var top = [Int](), bottom = [Int](), left = [Int](), right = [Int]()
        for column in 0..<4 {
            let line = (0..<4).map { board[$0*4+column] }
            top.append(seen(line))
            bottom.append(seen(Array(line.reversed())))
        }
        for row in 0..<4 {
            let line = (0..<4).map { board[row*4+$0] }
            left.append(seen(line))
            right.append(seen(Array(line.reversed())))
        }
        return top + bottom + left + right
    }

    private static func uniquelyDetermines(_ clues: [Int?]) -> Bool {
        var matches = 0
        for (_, values) in labeledBoards {
            if clues.indices.allSatisfy({ clues[$0] == nil || clues[$0] == values[$0] }) {
                matches += 1
                if matches > 1 { return false }
            }
        }
        return matches == 1
    }

    static func make() -> SkylinePuzzle {
        var best: SkylinePuzzle?
        for _ in 0..<22 {
            let solution = boards.randomElement()!
            var clues = allClues(for: solution).map { Optional($0) }
            guard uniquelyDetermines(clues) else { continue }
            for index in Array(clues.indices).shuffled() {
                // The final gate has only a minute. Nine edge clues plus seven
                // fixed cells still demand deductions without becoming a lottery.
                if clues.compactMap({ $0 }).count <= 9 { break }
                let saved = clues[index]
                clues[index] = nil
                if !uniquelyDetermines(clues) { clues[index] = saved }
            }
            let proposal = SkylinePuzzle(solution: solution, clues: clues, givens: startingCells())
            if best == nil || proposal.clues.compactMap({ $0 }).count < best!.clues.compactMap({ $0 }).count {
                best = proposal
            }
            if clues.compactMap({ $0 }).count <= 9 { break }
        }
        if let best { return best }
        let fallback = boards.first(where: { uniquelyDetermines(allClues(for: $0).map { Optional($0) }) })!
        return SkylinePuzzle(solution: fallback, clues: allClues(for: fallback).map { Optional($0) }, givens: startingCells())
    }
}

struct SkyscraperGate: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let compact: Bool
    let solved: () -> Void
    @State private var puzzle: SkylinePuzzle?
    @State private var numbers = Array(repeating: 0, count: 16)
    @State private var selected = 0

    private var sr: Bool { prefs.language == "sr" }
    private var square: CGFloat { compact ? 41 : 47 }

    var body: some View {
        VStack(spacing: 11) {
            GateCaption(title: sr ? "ARHITEKTURA TIŠINE" : "THE ARCHITECTURE OF SILENCE",
                        instruction: sr ? "Izdaja je ono što ostane zaklonjeno. U svakom redu i koloni 1–4 samo jednom. Ivice broje vidljive kule; više skrivaju niže." : "Treachery is what remains concealed. Each row and column uses 1–4 once. Edge clues count visible towers; taller ones hide the rest.")
            if let puzzle {
                VStack(spacing: 3) {
                    HStack(spacing: 3) {
                        clueSpacer
                        ForEach(0..<4, id: \.self) { column in
                            clue(puzzle.clues[column], violated: violates(column, puzzle: puzzle))
                        }
                        clueSpacer
                    }
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: 3) {
                            clue(puzzle.clues[8+row], violated: violates(8+row, puzzle: puzzle), side: true)
                            ForEach(0..<4, id: \.self) { column in
                                let index = row*4+column
                                Button { selected = index } label: {
                                    Text(numbers[index] == 0 ? "·" : "\(numbers[index])")
                                        .font(.system(size: 24, weight: puzzle.givens.contains(index) ? .semibold : .light, design: .serif))
                                        .foregroundStyle(conflict(index) ? Ink.red : GateStyle.chalk.opacity(puzzle.givens.contains(index) ? 0.65 : 1.0))
                                        .frame(width: square, height: square)
                                        .background(selected == index ? Ink.red.opacity(0.25) : GateStyle.chalk.opacity(0.06))
                                        .overlay(Rectangle().stroke(selected == index ? Ink.red.opacity(0.8) : GateStyle.chalk.opacity(0.16), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .disabled(puzzle.givens.contains(index))
                                .accessibilityLabel("\(row+1), \(column+1), \(numbers[index])")
                            }
                            clue(puzzle.clues[12+row], violated: violates(12+row, puzzle: puzzle), side: true)
                        }
                    }
                    HStack(spacing: 3) {
                        clueSpacer
                        ForEach(0..<4, id: \.self) { column in
                            clue(puzzle.clues[4+column], violated: violates(4+column, puzzle: puzzle))
                        }
                        clueSpacer
                    }
                }
                HStack(spacing: 7) {
                    ForEach(1...4, id: \.self) { digit in
                        GateKey(text: "\(digit)") { enter(digit) }
                    }
                }
                .frame(maxWidth: 260)
                Button { enter(0) } label: {
                    Label(sr ? "OBRIŠI POLJE" : "ERASE CELL", systemImage: "delete.left")
                        .font(.system(size: 10, design: .monospaced)).tracking(2)
                        .foregroundStyle(GateStyle.faint)
                }
                .buttonStyle(.plain)
            } else {
                ProgressView().tint(Ink.red).frame(height: 260)
            }
        }
        .onAppear {
            let next = SkylinePuzzle.make()
            puzzle = next
            numbers = (0..<16).map { next.givens.contains($0) ? next.solution[$0] : 0 }
            selected = (0..<16).first(where: { !next.givens.contains($0) }) ?? 0
        }
    }

    private var clueSpacer: some View { Color.clear.frame(width: 28, height: 23) }

    private func clue(_ value: Int?, violated: Bool, side: Bool = false) -> some View {
        Text(value.map(String.init) ?? "·")
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(violated ? Ink.red : GateStyle.chalk.opacity(value == nil ? 0.14 : 0.71))
            .frame(width: side ? 28 : square, height: side ? square : 23)
    }

    private func conflict(_ index: Int) -> Bool {
        let digit = numbers[index]
        guard digit != 0 else { return false }
        let r = index/4, c = index%4
        for i in 0..<16 where i != index {
            if (i/4 == r || i%4 == c) && numbers[i] == digit { return true }
        }
        return false
    }

    private func violates(_ side: Int, puzzle: SkylinePuzzle) -> Bool {
        guard let expected = puzzle.clues[side] else { return false }
        let column = side % 4
        let line: [Int]
        switch side/4 {
        case 0: line = (0..<4).map { numbers[$0*4+column] }
        case 1: line = (0..<4).reversed().map { numbers[$0*4+column] }
        case 2: line = (0..<4).map { numbers[column*4+$0] }
        default: line = (0..<4).reversed().map { numbers[column*4+$0] }
        }
        return !line.contains(0) && SkylinePuzzle.seen(line) != expected
    }

    private func enter(_ digit: Int) {
        guard let puzzle, !puzzle.givens.contains(selected) else { return }
        numbers[selected] = digit
        if numbers == puzzle.solution { solved() }
    }
}
