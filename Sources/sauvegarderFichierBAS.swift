import UniformTypeIdentifiers
import AppKit
@MainActor
func sauvegarderFichierBAS(depuis interpreter: BasicInterpreter) -> String {
    let panel = NSSavePanel()
    panel.title = "Enregistrer le fichier BASIC"
    panel.allowedContentTypes = [UTType(filenameExtension: "bas") ?? .plainText]
    panel.nameFieldStringValue = "programme.bas"

    let response = panel.runModal()
    if response == .OK, let url = panel.url {
        return interpreter.saveBAS(toPath: url.path)
    } else {
        print("❌ Enregistrement annulé")
        return "Cancelled"
    }
}
