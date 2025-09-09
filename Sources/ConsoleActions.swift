import SwiftUI

struct ConsoleActions {
    var run: () -> Void
    var list: () -> Void
    var cls: () -> Void
    var clear: () -> Void
    var new: () -> Void
}

private struct ConsoleActionsKey: FocusedValueKey {
    typealias Value = ConsoleActions
}

extension FocusedValues {
    var consoleActions: ConsoleActions? {
        get { self[ConsoleActionsKey.self] }
        set { self[ConsoleActionsKey.self] = newValue }
    }
}

