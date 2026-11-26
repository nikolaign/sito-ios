import SwiftUI

// A private little puzzle behind the SITO wordmark. Every board starts from a
// valid randomized solution; digits are removed only if the solution remains unique.
private struct SudokuCell: Equatable {
    let row: Int
    let column: Int
}

private struct SudokuSession {
    let solution: [[Int]]
    let clues: [[Int]]
    var current: [[Int]]

    static var blank: SudokuSession {
        let empty = Array(repeating: Array(repeating: 0, count: 9), count: 9)
        return SudokuSession(solution: empty, clues: empty, current: empty)
    }

    // Show conflicts with the actual Sudoku rules (row, column, 3×3 box).
    // Do not reveal whether a guess matches the hidden answer grid.
    func hasConflict(row: Int, column: Int) -> Bool {
        let digit = current[row][column]
        guard digit != 0 else { return false }
        for c in 0..<9 where c != column && current[row][c] == digit { return true }
        for r in 0..<9 where r != row && current[r][column] == digit { return true }
        for r in (row / 3 * 3)..<(row / 3 * 3 + 3) {
            for c in (column / 3 * 3)..<(column / 3 * 3 + 3) {
                if (r != row || c != column) && current[r][c] == digit { return true }
            }
        }
        return false
    }

    static func new() -> SudokuSession {
        let numbers = Array(1...9).shuffled()
        let rowBands = Array(0..<3).shuffled()
        let columnStacks = Array(0..<3).shuffled()
        let rows = rowBands.flatMap { band in Array(0..<3).shuffled().map { band * 3 + $0 } }
        let columns = columnStacks.flatMap { stack in Array(0..<3).shuffled().map { stack * 3 + $0 } }
        let solution = rows.map { r in
            columns.map { c in numbers[(r * 3 + r / 3 + c) % 9] }
        }
        var clues = solution
        var removed = 0
        for index in Array(0..<81).shuffled() {
            guard removed < 43 else { break }
            let row = index / 9
            let column = index % 9
            let original = clues[row][column]
            clues[row][column] = 0
            var working = clues
            if countSolutions(&working, stopAt: 2) != 1 {
                clues[row][column] = original
            } else {
                removed += 1
            }
        }
        return SudokuSession(solution: solution, clues: clues, current: clues)
    }

    private static func countSolutions(_ grid: inout [[Int]], stopAt limit: Int) -> Int {
        var chosen: SudokuCell?
        var choices: [Int] = []
        for row in 0..<9 {
            for column in 0..<9 where grid[row][column] == 0 {
                var used = Set(grid[row])
                for r in 0..<9 { used.insert(grid[r][column]) }
                let firstRow = (row / 3) * 3
                let firstColumn = (column / 3) * 3
                for r in firstRow..<(firstRow + 3) {
                    for c in firstColumn..<(firstColumn + 3) { used.insert(grid[r][c]) }
                }
                let available = (1...9).filter { !used.contains($0) }
                if available.isEmpty { return 0 }
                if chosen == nil || available.count < choices.count {
                    chosen = SudokuCell(row: row, column: column)
                    choices = available
                    if choices.count == 1 { break }
                }
            }
            if choices.count == 1 { break }
        }
        guard let cell = chosen else { return 1 }
        var solutions = 0
        for number in choices {
            grid[cell.row][cell.column] = number
            solutions += countSolutions(&grid, stopAt: limit - solutions)
            if solutions >= limit { break }
        }
        grid[cell.row][cell.column] = 0
        return solutions
    }
}

struct DreamAtmosphere: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var shift = 0

    var body: some View {
        GeometryReader { frame in
            ZStack {
                Color.black
                Circle()
                    .fill(Ink.red.opacity(0.19))
                    .frame(width: 280, height: 280)
                    .blur(radius: 90)
                    .scaleEffect(breathing ? 1.25 : 0.7)
                    .offset(x: -frame.size.width * 0.36, y: frame.size.height * 0.27)
                ForEach(0..<7, id: \.self) { index in
                    let x = sin(Double(index * 13 + shift * 7) * 0.73)
                    let y = cos(Double(index * 9 + shift * 4) * 0.41)
                    Rectangle()
                        .fill(Ink.red.opacity(index.isMultiple(of: 2) ? 0.11 : 0.06))
                        .frame(width: CGFloat(10 + index * 9), height: CGFloat(1 + index % 3))
                        .rotationEffect(.degrees(Double(index * 23 - shift * 5)))
                        .offset(x: CGFloat(x) * frame.size.width * 0.39,
                                y: CGFloat(y) * frame.size.height * 0.44)
                }
                Rectangle()
                    .stroke(Ink.red.opacity(0.09), lineWidth: 1)
                    .frame(width: 210, height: 210)
                    .rotationEffect(.degrees(breathing ? 15 : -9))
                    .scaleEffect(breathing ? 1.04 : 0.86)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.7), value: shift)
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 5.5).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_850_000_000) }
                catch { break }
                shift += 1
            }
        }
        .accessibilityHidden(true)
    }
}

// The original Sudoku remains playable inside the ninth gate. The gate journey
// owns the title, clock, ambient text and transitions.
struct GateSudokuGame: View {
    @EnvironmentObject private var prefs: NewsPreferences
    let width: CGFloat
    let solved: () -> Void
    // A parent-owned countdown redraws once per second. Generate a randomized
    // Sudoku only on entry, never as part of a repeated View initializer.
    @State private var session = SudokuSession.blank
    @State private var selected: SudokuCell?

    private let ivory = Color(red: 0.89, green: 0.86, blue: 0.82)
    private let gridColor = Color(red: 0.64, green: 0.57, blue: 0.57)

    var body: some View {
        VStack(spacing: 12) {
            let dimension = width / 9
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(dimension), spacing: 0), count: 9), spacing: 0) {
                ForEach(0..<81, id: \.self) { index in
                    let row = index / 9
                    let column = index % 9
                    let clue = session.clues[row][column] != 0
                    let number = session.current[row][column]
                    let chosen = selected == SudokuCell(row: row, column: column)
                    Button { if !clue { selected = SudokuCell(row: row, column: column) } } label: {
                        ZStack {
                            Rectangle().fill(chosen ? Ink.red.opacity(0.31) : Color.black.opacity(0.6))
                            Text(number == 0 ? "" : "\(number)")
                                .font(.system(size: dimension * 0.49, weight: clue ? .semibold : .light, design: .serif))
                                .foregroundStyle(session.hasConflict(row: row, column: column) ? Ink.red : ivory)
                        }
                        .frame(width: dimension, height: dimension)
                        .overlay(Rectangle().stroke(gridColor.opacity(0.22), lineWidth: 0.5))
                        .overlay(alignment: .leading) {
                            if column.isMultiple(of: 3) { Rectangle().fill(gridColor.opacity(0.8)).frame(width: 1.3) }
                        }
                        .overlay(alignment: .top) {
                            if row.isMultiple(of: 3) { Rectangle().fill(gridColor.opacity(0.8)).frame(height: 1.3) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row + 1), \(column + 1), \(number)")
                }
            }
            .frame(width: width, height: width)
            .overlay(Rectangle().stroke(gridColor.opacity(0.8), lineWidth: 1.3))

            HStack(spacing: 0) {
                ForEach(1...9, id: \.self) { number in
                    Button { enter(number) } label: {
                        Text("\(number)")
                            .font(.system(size: 19, weight: .light, design: .serif))
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .foregroundStyle(selected == nil ? ivory.opacity(0.25) : ivory)
                    }
                    .disabled(selected == nil)
                }
            }
            .frame(width: width)
            Button { enter(0) } label: {
                Label(prefs.language == "sr" ? "OBRIŠI" : "ERASE", systemImage: "delete.left")
                    .font(.system(size: 10, design: .monospaced)).tracking(2)
                    .foregroundStyle(ivory.opacity(0.55))
            }
            .disabled(selected == nil)
        }
        .buttonStyle(.plain)
        .onAppear { session = SudokuSession.new() }
    }

    private func enter(_ number: Int) {
        guard let selected, session.clues[selected.row][selected.column] == 0 else { return }
        session.current[selected.row][selected.column] = number
        if session.current == session.solution { solved() }
    }
}

struct DreamSudokuView: View {
    @EnvironmentObject private var prefs: NewsPreferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var session = SudokuSession.new()
    @State private var selected: SudokuCell?
    @State private var completed = false
    @State private var visible = false
    @State private var completionPulse = false

    private let ivory = Color(red: 0.89, green: 0.86, blue: 0.82)
    private let gridColor = Color(red: 0.64, green: 0.57, blue: 0.57)
    private func tr(_ sr: String, _ en: String) -> String { prefs.language == "sr" ? sr : en }

    var body: some View {
        GeometryReader { geometry in
            let boardWidth = min(geometry.size.width - 38, geometry.size.height * 0.43, 345)
            let tight = geometry.size.height < 700
            ZStack {
                DreamAtmosphere()
                VStack(spacing: tight ? 12 : 22) {
                    HStack {
                        Text("SITO / 09")
                            .tracking(4)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(ivory.opacity(0.6))
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .light))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(tr("Zatvori slagalicu", "Close puzzle"))
                    }
                    .padding(.horizontal, 23)

                    Spacer(minLength: 2)
                    if completed {
                        completionScene
                            .frame(maxHeight: .infinity)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    } else {
                        VStack(spacing: tight ? 15 : 25) {
                            VStack(spacing: 8) {
                                Text(tr("DEVETA SOBA", "THE NINTH ROOM"))
                                    .font(.system(size: 12, weight: .light, design: .monospaced))
                                    .tracking(5)
                                Text("9 · 9 · 9")
                                    .font(.system(size: 10, design: .monospaced))
                                    .tracking(7)
                                    .foregroundStyle(ivory.opacity(0.35))
                            }
                            .foregroundStyle(ivory.opacity(0.8))
                            sudokuBoard(width: boardWidth)
                            numberPicker(width: boardWidth)
                        }
                        .transition(.opacity)
                    }
                    Spacer(minLength: 2)
                    Text(completed ? tr("OBRAZAC JE POTPUN", "THE PATTERN IS COMPLETE") :
                         tr("POSTOJI SAMO JEDAN PUT", "THERE IS ONLY ONE WAY THROUGH"))
                        .tracking(2.2)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(ivory.opacity(0.33))
                        .padding(.bottom, 30)
                }
                .opacity(visible ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 1.2), value: visible)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { visible = true }
        .onChange(of: completed) { _, solved in
            if solved {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 2.5)) { completionPulse = true }
            } else {
                completionPulse = false
            }
        }
        .sensoryFeedback(.success, trigger: completed)
    }

    private func sudokuBoard(width: CGFloat) -> some View {
        let dimension = width / 9
        let columns = Array(repeating: GridItem(.fixed(dimension), spacing: 0), count: 9)
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(0..<81, id: \.self) { index in
                let row = index / 9
                let column = index % 9
                let clue = session.clues[row][column] != 0
                let value = session.current[row][column]
                let chosen = selected == SudokuCell(row: row, column: column)
                Button { if !clue { selected = SudokuCell(row: row, column: column) } } label: {
                    ZStack {
                        Rectangle().fill(chosen ? Ink.red.opacity(0.29) : Color.black.opacity(0.54))
                        Text(value == 0 ? "" : String(value))
                            .font(.system(size: 18, weight: clue ? .semibold : .light, design: .serif))
                            .foregroundStyle(session.hasConflict(row: row, column: column)
                                             ? Ink.red : (clue ? ivory : ivory.opacity(0.7)))
                    }
                    .frame(width: dimension, height: dimension)
                    .overlay { Rectangle().stroke(gridColor.opacity(0.23), lineWidth: 0.45) }
                    .overlay(alignment: .leading) {
                        if column.isMultiple(of: 3) { Rectangle().fill(gridColor.opacity(0.8)).frame(width: 1.35) }
                    }
                    .overlay(alignment: .top) {
                        if row.isMultiple(of: 3) { Rectangle().fill(gridColor.opacity(0.8)).frame(height: 1.35) }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Red \(row + 1), kolona \(column + 1), \(value == 0 ? "prazno" : String(value))",
                                        "Row \(row + 1), column \(column + 1), \(value == 0 ? "empty" : String(value))"))
            }
        }
        .frame(width: width, height: width)
        .overlay { Rectangle().stroke(gridColor.opacity(0.85), lineWidth: 1.5) }
    }

    private func numberPicker(width: CGFloat) -> some View {
        VStack(spacing: 17) {
            HStack(spacing: 0) {
                ForEach(1...9, id: \.self) { number in
                    Button { enter(number) } label: {
                        Text(String(number))
                            .font(.system(size: 19, weight: .light, design: .serif))
                            .foregroundStyle(selected == nil ? ivory.opacity(0.3) : ivory)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                    }
                    .disabled(selected == nil)
                }
            }
            Button { enter(0) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "delete.left")
                    Text(tr("OBRIŠI", "ERASE"))
                }
                .font(.system(size: 10, design: .monospaced))
                .tracking(2)
                .foregroundStyle(ivory.opacity(0.48))
            }
            .disabled(selected == nil)
        }
        .buttonStyle(.plain)
        .frame(width: width)
    }

    private var completionScene: some View {
        VStack(spacing: 23) {
            ZStack {
                Circle().stroke(Ink.red.opacity(completionPulse ? 0.13 : 0.38), lineWidth: 1)
                    .frame(width: 196, height: 196)
                    .scaleEffect(completionPulse ? 1.65 : 0.4)
                ForEach(0..<9, id: \.self) { number in
                    Rectangle()
                        .fill(Ink.red.opacity(completionPulse ? 0.18 : 0.74))
                        .frame(width: 2, height: CGFloat(number.isMultiple(of: 2) ? 30 : 12))
                        .offset(y: completionPulse ? -132 : -18)
                        .rotationEffect(.degrees(Double(number * 40)))
                }
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Ink.red.opacity(0.72), lineWidth: 2)
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(completionPulse ? 135 : 45))
                Rectangle().fill(Ink.red).frame(width: 13, height: 13)
            }
            Text(tr("ČESTITAM", "CONGRATULATIONS"))
                .font(.system(size: 14, weight: .light, design: .monospaced))
                .tracking(3)
                .foregroundStyle(ivory)
            Text("09 / 09")
                .font(.system(size: 11, design: .monospaced))
                .tracking(6)
                .foregroundStyle(Ink.red)
            Button(tr("JOŠ JEDAN OBRAZAC", "ANOTHER PATTERN")) {
                session = SudokuSession.new()
                selected = nil
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.8)) { completed = false }
            }
            .font(.system(size: 10, design: .monospaced))
            .tracking(2)
            .foregroundStyle(ivory.opacity(0.65))
            .padding(.top, 22)
        }
    }

    private func enter(_ number: Int) {
        guard let cell = selected, session.clues[cell.row][cell.column] == 0 else { return }
        session.current[cell.row][cell.column] = number
        if session.current == session.solution {
            selected = nil
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 1.2)) { completed = true }
        }
    }
}
