import UniformTypeIdentifiers
import AppKit
@MainActor
func ouvrirFichierBAS(avec interpreter: BasicInterpreter) -> String {
    let panel = NSOpenPanel()
    panel.title = "Choisir un fichier BASIC (.bas)"
    panel.allowedContentTypes = [UTType(filenameExtension: "bas") ?? .plainText]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canCreateDirectories = false

    let response = panel.runModal()
    if response == .OK, let url = panel.url {
        print("📁 Fichier sélectionné : \(url.path)")
        return interpreter.loadBAS(fromPath: url.path)
    } else {
        print("❌ Aucune sélection effectuée")
        return "Cancelled"
    }
}
