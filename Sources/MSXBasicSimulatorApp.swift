// MSXBasicSimulatorApp.swift
import SwiftUI

@main
struct MSXBasicSimulatorApp: App {
    //@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        UserDefaults.standard.removeObject(forKey: "MSXHistory")
    }

    var body: some Scene {
        WindowGroup { ConsoleView() }
            .commands { MSXCommands() }
    }
}


struct MSXCommands: Commands {
    // On récupère les actions de la fenêtre/scène actuellement focalisée
    @FocusedValue(\.consoleActions) var actions
   
    
    var body: some Commands {
        CommandMenu("MSX") {
            Button("RUN")   { actions?.run()  }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(actions == nil)

            Button("LIST")  { actions?.list() }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(actions == nil)
            
            Button("NEW")   { actions?.new() }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(actions == nil)

            Button("CLS")   { actions?.cls()  }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(actions == nil)
            
            Button("CLEAR_HISTORY")   { actions?.clear() }
                .keyboardShortcut("h", modifiers: [.command])
                .disabled(actions == nil)
            
            
        }
    }
}
