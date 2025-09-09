
import Foundation
import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            onResolve(v.window)
        }
        // la fenêtre arrive après attach
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

struct HistoryTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFirstResponder: Bool   // <- pilotage du focus
    var placeholder: String = ""
    var onCommit: (() -> Void)?
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tf.isBezeled = true
        tf.isBordered = true
        tf.bezelStyle = .roundedBezel
        tf.delegate = context.coordinator
        tf.target = context.coordinator
        tf.action = #selector(Coordinator.commitAction(_:))
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Sync texte si nécessaire
        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        // Pilotage du focus sans le "secouer" à chaque update
        guard let window = nsView.window else { return }

        // Le field editor utilisé par ce textField (NSTextView)
        let editor = window.fieldEditor(false, for: nsView)
        let hasFocus = (window.firstResponder === editor)

        if isFirstResponder {
            // Ne redemande le focus que si on ne l'a pas déjà
            if !hasFocus {
                window.makeFirstResponder(nsView)
                if let tv = window.fieldEditor(false, for: nsView) as? NSTextView {
                    // Place le caret à la fin, sans tout sélectionner
                    tv.selectedRange = NSRange(location: tv.string.count, length: 0)
                }
            }
        } else {
            // Si on ne veut pas le focus et qu'on l'a, on le relâche
            if hasFocus {
                window.makeFirstResponder(nil)
            }
        }
    }


    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: HistoryTextField
        init(_ parent: HistoryTextField) { self.parent = parent }

        @objc func commitAction(_ sender: NSTextField) {
            parent.text = sender.stringValue
            parent.onCommit?()
            parent.isFirstResponder = true // on garde le focus après Enter
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }
        
        

        // ↑ / ↓ / Enter via field editor
        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onUp?()
                DispatchQueue.main.async {
                    textView.string = self.parent.text
                    textView.moveToEndOfDocument(nil)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onDown?()
                DispatchQueue.main.async {
                    textView.string = self.parent.text
                    textView.moveToEndOfDocument(nil)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = textView.string
                parent.onCommit?()
                parent.isFirstResponder = true
                return true
            }
            
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.text = ""
                DispatchQueue.main.async { textView.string = "" }
                return true
            }
            return false
            
           

        }
        
    }
}




struct ConsoleView: View {//@StateObject private var keyMonitor = KeyEventMonitor()
    @StateObject private var interpreter = BasicInterpreter(program: BasicProgram())
    @State private var consoleText = ""
    @State private var input: String = ""
    @State private var output: String = "MSX BASIC version 1.0\nOk\n"
    @State private var wantsFocus: Bool = true

    private let CLS_MARKER = "__CLS__"
    @State private var history = CommandHistory()
    

@State private var hostWindow: NSWindow?
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(output)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button("Copier tout") { copyAllToClipboard() }
                        }
                        .font(.system(.title2, design: .monospaced))
                        .foregroundColor(.green)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("bottom")
                }
                .background(Color.black)
                
#if os(macOS)
.background(
    WindowAccessor { win in
        if hostWindow !== win {
            hostWindow = win
            mettreAJourTitreFenetre()
        }
    }
)
#endif
                

.onChange(of: output, initial: false) { _, _ in
    proxy.scrollTo("bottom", anchor: .bottom)
}

            }
            
            Divider()
            
            HStack {


                HistoryTextField(
                    text: $input,
                    isFirstResponder: $wantsFocus,
                    placeholder: "Commande BASIC...",
                    onCommit: { submit() },
                    onUp: { input = history.previous() },
                    onDown: { input = history.next() }
                )
                //.onAppear {
                    // Supprime l’historique qui aurait été laissé par les anciennes versions
                   // UserDefaults.standard.removeObject(forKey: "MSXHistory")
                //}

.textFieldStyle(RoundedBorderTextFieldStyle())
.font(.system(.title2, design: .monospaced))
.padding(.horizontal)
                
                Button("📂 CLOAD fichier") {
                    let result = ouvrirFichierBAS(avec: interpreter)
                    if result != "Cancelled" {
                        seedHistoryWithLoadedProgram()
                        output += "> CLOAD (via fichier)\n" + result + "\n"
                    }
                    //history.clear()
                    wantsFocus = true
                }
                .padding(.trailing)

                Button("💾 SAVE fichier") {
                    let result = sauvegarderFichierBAS(depuis: interpreter)
                    if result != "Cancelled" {
                        output += "> SAVE (vers fichier)\n" + result + "\n"
                    }
                    wantsFocus = true
                }
                .padding(.trailing)
            }
            .padding(.vertical, 6)
            .background(Color(white: 0.95))
        }
            .focusedSceneValue(
                \.consoleActions,
                ConsoleActions(
                    run: { runMenuCommand("RUN") },
                    list: { runMenuCommand("LIST") },
                    cls: {
                        let res = interpreter.execute(command: "CLS")
                        applyInterpreterResult(command: "CLS", result: res)
                        wantsFocus = true
                    },
                    clear: { clearHistory() },   // 👈
                    new: {
                        let res = interpreter.execute(command: "NEW")
                        applyInterpreterResult(command: "NEW", result: res)
                        wantsFocus = true }
                )
            )


        .frame(minWidth: 800, minHeight: 600)
        .onAppear { mettreAJourTitreFenetre() }
        .onChange(of: interpreter.nomFichierCharge, initial: false) {
            mettreAJourTitreFenetre()
        }
        

        

    }
    
    // Applique la sortie en gérant CLS (immédiat et RUN)
    private func applyInterpreterResult(command: String, result: String) {
        // 1) Cas immédiat : juste "CLS" → l'interpréteur retourne exactement "__CLS__"
        if result == CLS_MARKER {
            // Efface totalement et réaffiche l’invite standard après CLS immédiat
            output = "MSX BASIC version 1.0\nOk\n"
            return
        }
        
        // 2) Cas RUN / sortie complexe : la chaîne peut contenir le marqueur
        if let _ = result.range(of: CLS_MARKER) {
            // On efface et on affiche uniquement la partie après le DERNIER CLS
            if let lastRange = result.range(of: CLS_MARKER, options: .backwards) {
                let after = String(result[lastRange.upperBound...])
                output = after
                return
            }
        }
        
        // 3) Sortie normale (pas de CLS)
        output += "> " + command + "\n" + result + "\n"
    }
    
    private func mettreAJourTitreFenetre() {
        #if os(macOS)
        hostWindow?.title = interpreter.nomFichierCharge ?? "MSXBasicSimulator"
        #endif
    }

    
    private func copyAllToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(output, forType: .string)

    }
    
    private func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Multi-lignes : exécuter chaque ligne collée
        if trimmed.contains("\n") {
            let lines = trimmed
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for line in lines {
                runOne(line)
            }
            input = ""
            history.resetScroll()
            wantsFocus = true
            return
        }
        
        runOne(trimmed)
        input = ""
        history.resetScroll()
    }
    
    
    /// Met les lignes du programme courant dans l'historique (1 ligne = 1 entrée).
    /// On ajoute en ordre inverse pour que ↑ donne la 1ʳᵉ ligne du programme en premier.
    private func seedHistoryWithLoadedProgram() {
        let keys = interpreter.program.lines.keys.sorted()
        guard !keys.isEmpty else { return }

        history.clear() // si tu veux repartir d'un histo propre quand on charge un programme

        //for k in keys.reversed() {
        for k in keys {
            if let content = interpreter.program.lines[k] {
                history.add("\(k) \(content)")
            }
        }
        history.resetScroll()
    }
    private func runMenuCommand(_ cmd: String) {
            let res = interpreter.execute(command: cmd)
            applyInterpreterResult(command: cmd, result: res)
            wantsFocus = true
        }

    private func runOne(_ line: String) {
            history.add(line)
            let result = interpreter.execute(command: line)
            applyInterpreterResult(command: line, result: result)
        }




    private func clearHistory() {
        history.clear()
        history.resetScroll()
        wantsFocus = true
        // (optionnel) feedback :
        output += "> CLEAR HISTORY\nOk\n"
    }


}

