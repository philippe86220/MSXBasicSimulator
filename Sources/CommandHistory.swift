import Foundation

final class CommandHistory {
    private(set) var items: [String] = []
    private var index: Int = -1   // -1 => position après le dernier (champ vide)
    private let maxCount = 200
    private let key = "MSXHistory"

    init(loadFromUserDefaults: Bool = true) {
        if loadFromUserDefaults {
            items = UserDefaults.standard.stringArray(forKey: key) ?? []
        }
    }

    func add(_ cmd: String) {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // dédup en tête
        if items.first == trimmed {
            index = -1
            return
        }
        items.removeAll(where: { $0 == trimmed })
        items.insert(trimmed, at: 0)
        if items.count > maxCount { items.removeLast(items.count - maxCount) }
        index = -1

        UserDefaults.standard.set(items, forKey: key)
    }

    func previous() -> String {
        guard !items.isEmpty else { return "" }
        if index + 1 < items.count { index += 1 }
        return items[safe: index] ?? ""
    }

    func next() -> String {
        guard !items.isEmpty else { return "" }
        if index >= 0 { index -= 1 }
        return (index >= 0) ? (items[safe: index] ?? "") : ""
    }

    func resetScroll() { index = -1 }

    // Optionnel : pour vider l’historique
    func clear() {
        items.removeAll()
        index = -1
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? {
        return (i >= 0 && i < count) ? self[i] : nil
    }
}
