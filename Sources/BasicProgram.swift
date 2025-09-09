import Foundation

class BasicProgram: ObservableObject {
    @Published var lines: [Int: String] = [:]

    func insert(line: String) -> String {
        if let (number, content) = parseLine(line) {
            lines[number] = content
            return "Ok"
        }
        return "Syntax error"
    }

    func list() -> String {
        lines.sorted(by: { $0.key < $1.key })
             .map { "\($0.key) \($0.value)" }
             .joined(separator: "\n")
    }

    func clear() {
        lines.removeAll()
    }

    private func parseLine(_ line: String) -> (Int, String)? {
        let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        if parts.count >= 2, let number = Int(parts[0]) {
            return (number, String(parts[1]))
        }
        return nil
    }
}



