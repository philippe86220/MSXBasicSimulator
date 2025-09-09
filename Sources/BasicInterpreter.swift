import Foundation

class BasicInterpreter: ObservableObject  {
    let program: BasicProgram
    var variables: [String: Double] = [:]
    var inputVariable: String?
    var awaitingInput = false
    var pendingPrompt: String?
    private var gotoTarget: Int?
    private var resumeIndex: Int?
    var lastRunOutput = ""
    
    private var rndSeed: UInt64 = 1
    private var rndLast: Double = 0.5

    private let CLS_MARKER = "__CLS__"
    private var deferredEnd = false
    private var deferredEndFromMultiStmt = false
    var userFunctions: [String: (params: [String], body: String)] = [:]
    var userStringFunctions: [String: (params: [String], body: String)] = [:]

    // au niveau global
    private var redimAllowedAfterClear = Set<String>()
    private var isRunning = false
    private var preloadedDataFromProgram = false


    
    struct GosubFrame { let lineIndex: Int; let nextStmtIndex: Int }
    var gosubStack: [GosubFrame] = []

    private var resumeStatementIndex: Int? = nil
    private var forcedStatementIndex: Int? = nil

    var varText: [String: String] = [:]
    @Published var nomFichierCharge: String? = nil
    
    private var fnExpandDepth = 0

    // MARK: - DATA / READ
    var dataPool: [String] = []
    var dataPointer: Int = 0

    // MARK: - Tableaux DIM
    var arrays: [String: [Double]] = [:]
    var stringArrays: [String: [String]] = [:]
    // Dimensions (bornes sup. inclusives, comme en MSX BASIC)
    // Exemple: DIM A(3,2)  -> arrayDims["A"] = [3,2]   (tailles réelles: [4,3])
    var arrayDims: [String: [Int]] = [:]
    var stringArrayDims: [String: [Int]] = [:]

    // Contexte d'INPUT multi-variables
    struct InputContext {
        var vars: [String]
        var next: Int
        var prompt: String
    }
    var inputCtx: InputContext? = nil

    // Contexte de boucle FOR (conforme à ta spec)
    struct ForLoopContext {
        let varName: String
        let limit: Double
        let step: Double
        var returnIndex: Int      // >= 0 en RUN, -1 en immédiat
        var resumeSidx: Int?      // index de la sous-instr. après le FOR
    }
    var forStack: [ForLoopContext] = []

    init(program: BasicProgram) {
        self.program = program
    }
    
    // MARK: - Dumps
    /// Snapshot d’un tableau BASIC (nom, dimensions et stockage à plat).
    struct ArrayDump<T: Codable>: Codable {
        let name: String       // ex: "A" ou "F$"
        let dims: [Int]        // ex: [10, 20]
        let flat: [T]          // ex: 10*20 éléments

        var elementCountProduct: Int { dims.reduce(1, *) }
        var isConsistent: Bool { elementCountProduct == flat.count }
    }

    /// Snapshot d’une DEF FN (numérique ou chaîne)
    struct DefFnDump: Codable {
        let params: [String]
        let body: String
    }

    /// État sérialisable de l’environnement BASIC (scalaires, tableaux, DEF FN, DATA).
    struct SavedState: Codable {
        let version: Int

        // Scalaires
        let scalarsN: [String: Double]      // variables
        let scalarsS: [String: String]      // varText

        // Tableaux
        let arraysN: [ArrayDump<Double>]    // arrays + arrayDims
        let arraysS: [ArrayDump<String>]    // stringArrays + stringArrayDims

        // Fonctions DEF FN  (optionnelles pour compat v1)
        let defFnsN: [String: DefFnDump]?
        let defFnsS: [String: DefFnDump]?

        // DATA (optionnel pour compat)
        let dataPool: [String]?
        let dataPointer: Int?

        init(version: Int = 2,
             scalarsN: [String: Double] = [:],
             scalarsS: [String: String] = [:],
             arraysN: [ArrayDump<Double>] = [],
             arraysS: [ArrayDump<String>] = [],
             defFnsN: [String: DefFnDump]? = nil,
             defFnsS: [String: DefFnDump]? = nil,
             dataPool: [String]? = nil,
             dataPointer: Int? = nil) {
            self.version = version
            self.scalarsN = scalarsN
            self.scalarsS = scalarsS
            self.arraysN = arraysN
            self.arraysS = arraysS
            self.defFnsN = defFnsN
            self.defFnsS = defFnsS
            self.dataPool = dataPool
            self.dataPointer = dataPointer
        }
    }



    // ===== DEBUG LOGGER =====
    var debugEval = true
    private var evalDepth = 0
    @inline(__always)
    private func elog(_ s: @autoclosure () -> String) {
        guard debugEval else { return }
        let pad = String(repeating: "  ", count: evalDepth)
        print(pad + s())
    }
    
    //TIME
    // --- MSX TIME (ticks) ---
    private var timeTicksPerSec: Double = 50.0   // PAL; mets 60.0 si tu veux NTSC
    private var timeSetMoment: Date = Date()     // moment de la dernière affectation de TIME
    private var timeSetOffset: Int = 0           // valeur de TIME au moment de l’affectation

    private func readTIME() -> Int {
        let elapsed = Date().timeIntervalSince(timeSetMoment) // secondes
        let ticks = Int(floor(elapsed * timeTicksPerSec))
        return timeSetOffset + ticks
    }
    private func writeTIME(_ value: Int) {
        timeSetOffset = value
        timeSetMoment = Date()
    }

    // --- Throttle (émulation vitesse MSX) ---
    var msxThrottle: Bool = false
    var perNextDelay: TimeInterval = 0.0   // en secondes, ex: 0.002076 (~2.076 ms)

    // helper pratique
    func enableMsxThrottle(_ on: Bool, perNextMillis: Double = 2.076) {
        msxThrottle = on
        perNextDelay = perNextMillis / 1000.0
    }

    // --- SAVE / LOAD identiques ---
    func saveBAS(toPath path: String) -> String {
        elog("[SAVE] Sauvegarde du programme vers : \(path)")
        let keys = program.lines.keys.sorted()
        let lines = keys.compactMap { key in
            program.lines[key].map { "\(key) \($0)" }
        }
        let content = lines.joined(separator: "\n")
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            elog("[SAVE] Sauvegarde réussie.")
            nomFichierCharge = URL(fileURLWithPath: path).lastPathComponent
            return "Ok"
        } catch {
            elog("[SAVE] Erreur d'écriture : \(error)")
            return "Write error"
        }
    }

    func loadBAS(fromPath path: String) -> String {
        elog("[CLOAD] Chargement du fichier externe : \(path)")
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            elog("[CLOAD] Fichier introuvable : \(path)")
            return "File not found"
        }
        nomFichierCharge = url.lastPathComponent
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            elog("[CLOAD] Impossible de lire le fichier")
            return "Could not read file"
        }
        program.clear()
        clearAllUserState("LOAD")
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                elog("[CLOAD] Insertion ligne : \(t)")
                _ = execute(command: t)
            }
        }
        elog("[CLOAD] Chargement terminé depuis fichier externe.")
        return "Ok"
    }

    // MARK: - Exécution utilisateur (immédiat)
    func execute(command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        elog("[EXEC] reçu : [\(trimmed)]")
        
        // ----- PRIORITÉ ABSOLUE : si un INPUT est en cours, on consomme la saisie -----
        // (On s'appuie sur inputCtx, plus fiable que le seul booléen awaitingInput.)
        if var ctx = inputCtx {
            elog("[INPUT] Ligne saisie : '\(trimmed)'")
            elog("[INPUT] Contexte avant: vars=\(ctx.vars) next=\(ctx.next) prompt='\(ctx.prompt)' resumeIndex=\(String(describing: resumeIndex))")

            let parts = parseCsvLike(trimmed)  // respecte les guillemets pour les strings
            elog("[INPUT] Morceaux saisis (CSV-like) : \(parts)")

            if parts.isEmpty {
                elog("[INPUT] Ligne vide -> '??'")
                awaitingInput = true
                return "??"
            }

            var tempNum: [(String, Double)] = []
            var tempStr: [(String, String)] = []

            var i = 0
            while ctx.next < ctx.vars.count && i < parts.count {
                let varName = ctx.vars[ctx.next]
                var raw = parts[i].trimmingCharacters(in: .whitespaces)
                elog("[INPUT] Cible=\(varName)  brut='\(raw)'")

                // -- Détecter le type de cible
                let uName = varName.uppercased()
                let isStrArray = uName.range(of: #"^[A-Z][A-Z0-9]*\$\(.+\)$"#, options: .regularExpression) != nil
                //let isNumArray = uName.range(of: #"^[A-Z][A-Z0-9]*\(.+\)$"#,   options: .regularExpression) != nil
                let isStrScalar = uName.hasSuffix("$")
                //let isNumScalar = !isStrScalar && !isStrArray

                if isStrArray || isStrScalar {
                    // Nettoie guillemets optionnels pour les strings
                    if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                        raw = String(raw.dropFirst().dropLast())
                    }
                    tempStr.append((uName, raw))
                    elog("[INPUT] OK string  \(uName) = '\(raw)' (temp)")
                } else {
                    let numStr = raw.replacingOccurrences(of: ",", with: ".")
                    guard let v = Double(numStr) else {
                        elog("[INPUT] Type mismatch pour \(uName) -> REDO FROM START")
                        awaitingInput = true
                        inputVariable = nil
                        inputCtx?.next = 0
                        pendingPrompt = ctx.prompt
                        return "Redo from start"
                    }
                    tempNum.append((uName, v))
                    elog("[INPUT] OK number \(uName) = \(v) (temp)")
                }
                ctx.next += 1
                i += 1
            }

            // Regex réutilisées
            let rxNumArr = try! NSRegularExpression(pattern: #"^([A-Z][A-Z0-9]*)\((.+)\)$"#)
            let rxStrArr = try! NSRegularExpression(pattern: #"^([A-Z][A-Z0-9]*\$)\((.+)\)$"#)

            // Commit numériques
            for (n, v) in tempNum {
                if let m = rxNumArr.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
                   let nameR = Range(m.range(at: 1), in: n),
                   let idxR  = Range(m.range(at: 2), in: n) {

                    let arrName = String(n[nameR]).uppercased()
                    let inside  = String(n[idxR])
                    guard let idxs = parseIndicesList(inside) else { return "Syntax error" }
                    guard let dims = arrayDims[arrName], var arr = arrays[arrName] else { return "Undimensioned array" }
                    guard let off = linearIndex(from: idxs, dims: dims), off < arr.count else { return "Subscript out of range" }
                    arr[off] = v; arrays[arrName] = arr
                    elog("[INPUT] COMMIT num \(arrName)\(idxs) = \(v) (off=\(off))")
                } else {
                    variables[n] = v
                    elog("[INPUT] COMMIT num \(n) = \(v)")
                }
            }

            // Commit chaînes
            for (n, s) in tempStr {
                if let m = rxStrArr.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
                   let nameR = Range(m.range(at: 1), in: n),
                   let idxR  = Range(m.range(at: 2), in: n) {

                    let arrName = String(n[nameR]).uppercased()
                    let inside  = String(n[idxR])
                    guard let idxs = parseIndicesList(inside) else { return "Syntax error" }
                    guard let dims = stringArrayDims[arrName], var arr = stringArrays[arrName] else { return "Undimensioned array" }
                    guard let off = linearIndex(from: idxs, dims: dims), off < arr.count else { return "Subscript out of range" }
                    arr[off] = s; stringArrays[arrName] = arr
                    elog("[INPUT] COMMIT str \(arrName)\(idxs) = '\(s)' (off=\(off))")
                } else {
                    varText[n] = s
                    elog("[INPUT] COMMIT str \(n) = '\(s)'")
                }
            }


            inputCtx = ctx
            elog("[INPUT] Contexte après: next=\(ctx.next)/\(ctx.vars.count)  valeurs lues sur la ligne=\(i)")

            // Trop de valeurs
            if i < parts.count && ctx.next >= ctx.vars.count {
                elog("[INPUT] Trop de valeurs -> '? extra-ignored'")
                awaitingInput = false
                inputVariable = nil
                inputCtx = nil
                let msg = "? extra-ignored\n"
                return resumeIndex == nil ? msg : (msg + runProgram())
            }

            // Pas assez de valeurs : continuer
            if ctx.next < ctx.vars.count {
                elog("[INPUT] Incomplet -> '??'")
                awaitingInput = true
                inputVariable = nil
                return "??"
            }

            // Exact : terminé
            elog("[INPUT] Saisie complète pour cette instruction INPUT")
            awaitingInput = false
            inputVariable = nil
            inputCtx = nil
            return resumeIndex == nil ? "" : runProgram()
        }
        // ----- fin du bloc INPUT prioritaire -----

        // ----- Commandes immédiates ou édition du programme -----
        switch trimmed.uppercased() {
        case "LIST":
            elog("[EXEC] LIST")
            return program.list() + "\nOk"

        case "CLEAR":
            elog("[EXEC] CLEAR (immédiat)")
            clearAllUserState("immédiat")
            return "Ok"

        case "NEW":
            elog("[EXEC] NEW")
            program.clear()
            clearAllUserState("NEW")
            nomFichierCharge = nil
            return "Ok"

        case "RUN":
            elog("[EXEC] RUN")
            resumeIndex = nil
            return runProgram()

        default:
            // Ligne numérotée -> insertion dans le programme
            // (OK de garder simple: un début par chiffre = ligne)
            if let firstChar = trimmed.first, firstChar.isNumber {
                elog("[EXEC] Insertion de ligne")
                return program.insert(line: trimmed)
            }

            // Interprétation immédiate
            let result = interpretImmediate(trimmed, isInRun: false)
            elog("[EXEC] Résultat immédiat brut = '\(result)'")

            switch result {
            case "Syntax error",
                 "Undefined line number":     // ⬅️ ajoute cette ligne
                return result
                
            case CLS_MARKER:
                // On renvoie le marqueur tel quel : la UI efface l’écran et affiche "Ok".
                return CLS_MARKER


            case "__WAIT_INPUT__":
                let prompt = pendingPrompt ?? "?"
                elog("[EXEC] Attente INPUT -> prompt '\(prompt)'")
                pendingPrompt = nil
                return prompt

            case "__END__":
                elog("[EXEC] END -> Ok")
                return "Ok"

            case "":
                elog("[EXEC] Pas de sortie -> Ok")
                return "Ok"

            default:
                // Toujours mettre Ok sur une nouvelle ligne
                if result.hasSuffix("\n") {
                    return result + "Ok"
                } else {
                    return result + "\nOk"
                }
            }
        }
    }
    


    // MARK: - Exécution de programme
    private func runProgram() -> String {
        enableMsxThrottle(true, perNextMillis: 2.076)
        isRunning = true
        defer { isRunning = false }

        if resumeIndex == nil {
            clearAllUserState("RUN start")
            rebuildDataPoolFromProgram()
            elog("[runProgram] Réinitialisation complète")
        } else {
            elog("[runProgram] Reprise depuis resumeIndex = \(resumeIndex!)")
        }

        let keys = program.lines.keys.sorted()
        elog("[runProgram] Lignes = \(keys)")
        elog("[runProgram] Fonctions définies = \(userFunctions.keys.sorted())")

        var index = resumeIndex ?? 0
        var output = ""

    outer: while index < keys.count {
            let lineNumber = keys[index]
            guard let content = program.lines[lineNumber] else {
                index += 1
                continue
            }

            let trimmedContent = content.trimmingCharacters(in: .whitespaces)
            let u = trimmedContent.uppercased()
            // IF et REM ne sont pas splittés par ':'
            let statements: [String] = {
                if u.hasPrefix("IF ") {
                    elog("[runProgram] IF-line détectée -> pas de split ':'")
                    return [trimmedContent]
                } else if u.hasPrefix("REM") {
                    elog("[runProgram] REM-line détectée -> pas de split ':'")
                    return [trimmedContent]
                } else {
                    return splitStatements(trimmedContent)
                }
            }()

            var sidx = 0
            if let rs = resumeStatementIndex { sidx = rs; resumeStatementIndex = nil }
            if let fs = forcedStatementIndex  { sidx = fs; forcedStatementIndex  = nil }

            while sidx < statements.count {
                let stmt = statements[sidx]
                let stmtUpper = stmt.trimmingCharacters(in: .whitespaces).uppercased()
                let result = interpretImmediate(stmt, isInRun: true)

                // ⛔️ Arrêt immédiat en cas d'erreur fatale (format: "<msg> in <line>")
                let fatalErrors: Set<String> = [
                    "Syntax error",
                    "Duplicate parameter name",
                    "Incorrect number of arguments",
                    "Illegal function call",
                    "Subscript out of range",
                    "Undimensioned array",
                    "NEXT without FOR",
                    "RETURN without GOSUB",
                    "Undefined line number",
                    "Division by zero",
                    "Overflow",
                    "Type mismatch",
                    "Redimensioned array",
                    "Out of data"          // ⟵ ajouté
                ]
                let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if fatalErrors.contains(trimmedResult) {
                    elog("[runProgram] Fatal error '\(trimmedResult)' at line \(lineNumber)")
                    if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
                    output += "\(trimmedResult) in \(lineNumber)\n"
                    output += "Ok\n"
                    resumeIndex = nil
                    return output
                }

                // FOR en RUN : mémoriser la ligne et sidx+1 pour NEXT
                if stmtUpper.hasPrefix("FOR "), let lastIdx = forStack.indices.last {
                    if forStack[lastIdx].returnIndex == -1 { forStack[lastIdx].returnIndex = index }
                    if forStack[lastIdx].resumeSidx == nil { forStack[lastIdx].resumeSidx = sidx + 1 }
                }

                // Contrôles de flux spéciaux
                if result == "__GOTO__" || result == "__GOSUB__" {
                    if let target = gotoTarget, let newIndex = keys.firstIndex(of: target) {
                        if result == "__GOSUB__" {
                            gosubStack.append(GosubFrame(lineIndex: index, nextStmtIndex: sidx + 1))
                        }
                        gotoTarget = nil
                        resumeIndex = nil
                        index = newIndex
                        continue outer
                    } else {
                        // cible inexistante -> format MSX
                        if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
                        output += "Undefined line number in \(lineNumber)\n"
                        output += "Ok\n"
                        resumeIndex = nil
                        return output
                    }
                }

                switch result {
                case "__WAIT_INPUT__":
                    lastRunOutput = output
                    // 🟢 Reprendre sur la même ligne, juste après l’INPUT
                    resumeIndex = index
                    resumeStatementIndex = sidx + 1
                    let prompt = pendingPrompt ?? "?"
                    pendingPrompt = nil
                    return output + prompt

                case "__END__":
                    resumeIndex = nil
                    if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
                    output += "Ok\n"
                    return output

                case "__RESUME__":
                    if let ri = resumeIndex {
                        index = ri
                        resumeIndex = nil
                        continue outer
                    }

                case CLS_MARKER:
                    output += CLS_MARKER  // la vue se charge de nettoyer l’écran

                default:
                    if !result.isEmpty {
                        output += result   // PRINT décide déjà des \n
                        if deferredEnd {
                            deferredEnd = false
                            if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
                            output += "Ok\n"
                            return output
                        }
                    }
                }

                sidx += 1
            }

            index += 1
        }

        // Fin normale de RUN
        resumeIndex = nil
        if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
        output += "Ok\n"
        return output
    }

    // MARK: - Interprétation d'une ligne (stmt unique OU suite ':' traitée en amont)
    private func interpretImmediate(_ command: String, isInRun: Bool) -> String {
        elog("[interpretImmediate] commande = '\(command)'")
            // ⬇️ NOUVEAU : coupe les commentaires inline
            var trimmed = stripInlineComment(command).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return "" } // tout était un commentaire
            let upper = trimmed.uppercased()

        // IF prioritaire
        if trimmed.uppercased().hasPrefix("IF ") {
            return handleIf(trimmed, isInRun: isInRun)
        }

        // REM prioritaire : tout ce qui suit est ignoré (y compris ':')
        if upper.hasPrefix("REM") {
            return ""
        }


        // Séquences "stmt1:stmt2:..." —> **aucun \n injecté** entre sous-instructions
        let stmts = splitStatements(trimmed)
        if stmts.count > 1 {
            var acc = ""
            var i = 0
            while i < stmts.count {
                let s = stmts[i]
                let stmtUpper = s.trimmingCharacters(in: .whitespaces).uppercased()
                let r = interpretImmediate(s, isInRun: isInRun)

                // ⛔️ En mode immédiat, ces erreurs doivent STOPPER la séquence "stmt1:stmt2"
                let fatalImmediate: Set<String> = [
                    "Syntax error",
                    "Undefined line number",
                    "Type mismatch",
                    "Undimensioned array",
                    "Subscript out of range",
                    "NEXT without FOR",
                    "RETURN without GOSUB",
                    "Division by zero",
                    "Overflow"
                ]
                let rTrim = r.trimmingCharacters(in: .whitespacesAndNewlines)
                if fatalImmediate.contains(rTrim) { return r }

                // Si FOR en immédiat : mémoriser reprise après le FOR
                if !isInRun, stmtUpper.hasPrefix("FOR "),
                   let last = forStack.last, last.returnIndex == -1, last.resumeSidx == nil {
                    forStack[forStack.count - 1].resumeSidx = i + 1
                }

                if r == "Syntax error" { return r }
                
                
                // Si END survient alors qu'on a déjà du texte accumulé,
                // on renvoie d'abord ce texte, et on signalera END au niveau supérieur.
                if r == "__END__" {
                    if !acc.isEmpty {
                        deferredEnd = true
                        return acc          // on renvoie d'abord le texte accumulé
                    }
                    return r
                }


                // Les autres contrôles gardent l'ancien comportement
                if r == "__WAIT_INPUT__" || r == "__GOTO__" || r == "__GOSUB__" || r == "__RESUME__" {
                    return r
                }

                if r == "__NEXT_IMMEDIATE__" {
                    if let resume = forStack.last?.resumeSidx {
                        i = resume
                        continue
                    } else {
                        return "NEXT without FOR"
                    }
                }

                // 🔸 Pas de "\n" entre sous-instructions
                acc += r
                i += 1
            }
            return acc
        }

        if trimmed.uppercased().hasPrefix("LET ") {
            trimmed = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        // --- Alias PRINT sans espace : ?"...", ?expr, etc.
        if trimmed.hasPrefix("?") {
            let afterQ = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            return handlePrint("PRINT " + afterQ)
        }

        // --- PRINT sans espace : PRINT"...", PRINT(expr), etc.
        let upNoSpace = trimmed.uppercased()
        if upNoSpace.hasPrefix("PRINT") {
            let afterIdx = trimmed.index(trimmed.startIndex, offsetBy: min(5, trimmed.count))
            // Vérifier qu'on a bien le mot-clé PRINT (borne après PRINT)
            var boundaryOK = (afterIdx == trimmed.endIndex)
            if !boundaryOK {
                let ch = trimmed[afterIdx]
                boundaryOK = !(ch.isLetter || ch.isNumber || ch == "$")
            }
            if boundaryOK {
                let after = String(trimmed[afterIdx...]).trimmingCharacters(in: .whitespaces)
                return handlePrint("PRINT " + after)
            }
        }
        if upNoSpace.hasPrefix("INPUT") {
            let afterIdx = trimmed.index(trimmed.startIndex, offsetBy: min(5, trimmed.count))
            var boundaryOK = (afterIdx == trimmed.endIndex)
            if !boundaryOK {
                let ch = trimmed[afterIdx]
                boundaryOK = !(ch.isLetter || ch.isNumber || ch == "$")
            }
            if boundaryOK {
                let after = String(trimmed[afterIdx...]).trimmingCharacters(in: .whitespaces)
                return handleInput("INPUT " + after)
            }
        }


        let tokens = trimmed.components(separatedBy: .whitespaces)
        guard let first = tokens.first?.uppercased() else { return "Syntax error" }
        elog("[interpretImmediate] Instruction détectée : \(first)")

        switch first {
        case "?":
            // Transforme ? <truc> en PRINT <truc>
            let afterQ = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            return handlePrint("PRINT " + afterQ)
        case "DIM":   return handleDim(trimmed)
        case "DATA":
            if isInRun { return "" }
            return handleData(trimmed)
        case "READ":  return handleRead(trimmed)
        case "RESTORE": return handleRestore()
        case "PRINT": return handlePrint(trimmed)
        case "INPUT": return handleInput(trimmed)
        case "IF":    return handleIf(trimmed, isInRun: isInRun)
        case "GOTO":  return handleGoto(tokens)
        case "END":   return "__END__"
        case "LET":   return handleLet(tokens)
        case "FOR":   return handleFor(trimmed)
        case "NEXT":  return handleNext()
        case "REM":   return ""
        case "GOSUB":
            if tokens.count >= 2, let target = Int(tokens[1]) {
                gotoTarget = target
                return "__GOSUB__"
            } else {
                return "Syntax error"
            }
        case "RETURN":
            guard let frame = gosubStack.popLast() else { return "RETURN without GOSUB" }
            resumeIndex = frame.lineIndex
            resumeStatementIndex = frame.nextStmtIndex
            return "__RESUME__"

        case "CLEAR":
            clearAllUserState(isInRun ? "RUN" : "immédiat")
            return isInRun ? "__RESUME__" : ""


        case "CLOAD":
            let argument = tokens.dropFirst().joined(separator: " ").replacingOccurrences(of: "\"", with: "")
            let fullPath: String
            if argument.hasPrefix("/") {
                fullPath = argument
            } else {
                let downloads = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
                fullPath = downloads.appendingPathComponent("\(argument).bas").path
            }
            return loadBAS(fromPath: fullPath)

        case "SAVE":
            let argument = tokens.dropFirst().joined(separator: " ").replacingOccurrences(of: "\"", with: "")
            let fullPath: String
            if argument.hasPrefix("/") {
                fullPath = argument
            } else {
                let downloads = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
                fullPath = downloads.appendingPathComponent("\(argument).bas").path
            }
            return saveBAS(toPath: fullPath)
        case "CLS":
            return CLS_MARKER
            
        case "SAVEF":
            return handleSaveF(trimmed)

        case "LOADF":
            return handleLoadF(trimmed)

        case "DEF":
            if trimmed.uppercased().hasPrefix("DEF FN") {
                let up = trimmed.uppercased()
                if let eq = up.firstIndex(of: "="),
                   let fnIdx = up.range(of: "DEF FN")?.upperBound {
                    let namePart = up[fnIdx..<eq] // ex: "CUT$(S$,N)"
                    if namePart.contains("$") {
                        return handleDefFnString(trimmed)   // ⬅️ fonctions CHAÎNE
                    } else {
                        return handleDefFn(trimmed)         // ⬅️ fonctions NUM
                    }
                } else {
                    return "Syntax error"
                }
            } else {
                return "Syntax error"
            }

        case "ON":
            return handleOnStatement(trimmed, isInRun: isInRun)

        case "STOP":
            return "__END__"

        


        default:
            return handleAssignment(trimmed)
        }
    }

    // ON <expr> GOTO l1, l2, ...   ou   ON <expr> GOSUB l1, l2, ...
    private func handleOnStatement(_ full: String, isInRun: Bool) -> String {
        let up = full.uppercased()
        guard up.hasPrefix("ON ") else { return "Syntax error" }
        let afterOn = String(full.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        
        if afterOn.uppercased().hasPrefix("STOP") {
            return "Syntax error"
        }
        // Chercher GOTO ou GOSUB
        guard let goIdx = findKeywordTopLevel(afterOn, keyword: "GOTO")
            ?? findKeywordTopLevel(afterOn, keyword: "GOSUB") else {
            return "Syntax error"
        }
        let goWord = afterOn[goIdx...].uppercased().hasPrefix("GOSUB") ? "GOSUB" : "GOTO"
        let exprPart = String(afterOn[..<goIdx]).trimmingCharacters(in: .whitespaces)
        let afterGo = String(afterOn[afterOn.index(goIdx, offsetBy: goWord.count)...]).trimmingCharacters(in: .whitespaces)

        // Evaluer l’expression
        let exprValStr  = evaluateExpression(exprPart)
        if exprValStr == "Syntax error" { return "Syntax error" }
        let exprValNorm = exprValStr.replacingOccurrences(of: ",", with: ".")

        guard let d = Double(exprValNorm) else { return "Syntax error" }
        let n = Int(d) // tronque vers 0 (même effet que .rounded(.towardZero))

        // Extraire les cibles
        let targets = splitCsvTopLevelRespectingParens(afterGo)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if n < 1 || n > targets.count { return "" }

        guard let lineNum = Int(targets[n - 1]) else { return "Syntax error" }
        
        

        if isInRun {
            gotoTarget = lineNum
            return (goWord == "GOSUB") ? "__GOSUB__" : "__GOTO__"
        } else {
            // Mode immédiat
            if let line = program.lines[lineNum] {
                return interpretImmediate(line, isInRun: false)
            } else {
                return "Undefined line number"
            }
        }
    }


    
   
    // MARK: - Split utils
    private func splitStatements(_ line: String) -> [String] {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine.uppercased().hasPrefix("REM") { return [trimmedLine] }

        var out: [String] = []
        var cur = ""
        let chars = Array(line)
        let up    = Array(line.uppercased())
        var inStr = false
        var paren = 0
        var i = 0

        func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "$" }

        while i < chars.count {
            let ch = chars[i]

            if ch == "\"" { inStr.toggle(); cur.append(ch); i += 1; continue }
            if !inStr {
                if ch == "(" { paren += 1; cur.append(ch); i += 1; continue }
                if ch == ")" { paren = max(0, paren - 1); cur.append(ch); i += 1; continue }

                // ➜ Si on rencontre un IF top-level, on agrège tout le reste
                if paren == 0, i + 1 < up.count, String(up[i...i+1]) == "IF" {
                    let beforeIsId = (i > 0) && isIdentChar(chars[i-1])
                    let afterIsId  = (i + 2 < chars.count) && isIdentChar(chars[i+2])
                    if !beforeIsId && !afterIsId {
                        // Ajoute ce qui précède (s'il y en a), puis tout le IF jusqu'à la fin comme un seul statement
                        cur += String(chars[i...])
                        let stmt = cur.trimmingCharacters(in: .whitespaces)
                        if !stmt.isEmpty { out.append(stmt) }
                        return out
                    }
                }

                // coupures normales sur ':' / retours ligne au top-level
                if paren == 0 && (ch == ":" || ch == "\n" || ch == "\r") {
                    let stmt = cur.trimmingCharacters(in: .whitespaces)
                    if !stmt.isEmpty { out.append(stmt) }
                    cur.removeAll(keepingCapacity: true)
                    i += 1
                    continue
                }
            }

            cur.append(ch)
            i += 1
        }

        let last = cur.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { out.append(last) }
        return out
    }



    private func containsComparisonOutsideQuotes(_ s: String) -> Bool {
        var inStr = false
        let chars = Array(s)
        for i in 0..<chars.count {
            let ch = chars[i]
            if ch == "\"" { inStr.toggle(); continue }
            if !inStr {
                if ch == "<" || ch == ">" { return true }
                if ch == "=" { return true }
            }
        }
        return false
    }

    private func parseCsvLike(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inStr = false
        for ch in s {
            if ch == "\"" { inStr.toggle(); cur.append(ch); continue }
            if ch == "," && !inStr {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
                continue
            }
            cur.append(ch)
        }
        let t = cur.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }
    // Évalue "i,j,k" (ou "i") en [Int]
    private func parseIndicesList(_ inside: String) -> [Int]? {
        let parts = splitTopLevelArgs(inside).map { $0.trimmingCharacters(in: .whitespaces) }
        var idxs: [Int] = []
        for p in parts {
            let vStr = evaluateExpression(p).replacingOccurrences(of: ",", with: ".")
            guard let v = Int(vStr), v >= 0 else { return nil }
            idxs.append(v)
        }
        return idxs
    }

    // Calcule l'index linéaire row-major à partir des indices et des bornes sup.
    // dims = bornes sup inclusives, ex: [3,2] -> tailles = [4,3]
    private func linearIndex(from idxs: [Int], dims: [Int]) -> Int? {
        guard idxs.count == dims.count else { return nil }
        var strides: [Int] = []
        var acc = 1
        // tailles = dims[i] + 1
        let sizes = dims.map { $0 + 1 }
        // Strides row-major: dernier axe stride=1
        for s in sizes.reversed() {
            strides.insert(acc, at: 0)
            acc *= s
        }
        // bornes + offset
        for (i, idx) in idxs.enumerated() {
            if idx < 0 || idx > dims[i] { return nil }
        }
        // offset
        var off = 0
        for i in 0..<idxs.count { off += idxs[i] * strides[i] }
        return off
    }

    // MARK: - DATA / READ / RESTORE (inchangés sauf logs)
    private func handleData(_ line: String) -> String {
        if isRunning && preloadedDataFromProgram {
            return "" // on ignore les DATA rencontrées pendant l'exécution
        }

        guard let range = line.uppercased().range(of: "DATA") else { return "Syntax error" }
        let dataContent = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let parts = parseCsvLike(dataContent)
        for part in parts { if !part.isEmpty { dataPool.append(part) } }
        return ""
    }

    private func handleRead(_ trimmed: String) -> String {
        let afterRead = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)

        // Respecte les parenthèses / guillemets
        let targets = splitCsvTopLevelRespectingParens(String(afterRead))
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }

        elog("[READ] Cibles: \(targets)")
        if targets.isEmpty { return "Syntax error" }

        let rxNumArr = try! NSRegularExpression(pattern: #"^([A-Z][A-Z0-9]*)\((.+)\)$"#)
        let rxStrArr = try! NSRegularExpression(pattern: #"^([A-Z][A-Z0-9]*\$)\((.+)\)$"#)

        // === Helpers locaux ===
        func dataItemToString(_ raw: String) -> String? {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\"") {
                return decodeBasicStringLiteral(t)   // "..." BASIC -> décodage (guillemets doublés)
            } else {
                return t                              // texte non quoté (ex: bonjour)
            }
        }
        func looksLikeBareIdentifier(_ s: String) -> Bool {
            return s.range(of: #"^[A-Za-z][A-Za-z0-9]*\$?$"#, options: .regularExpression) != nil
        }

        for t in targets {
            if dataPointer >= dataPool.count {
                elog("[READ] Out of data avant '\(t)'"); return "Out of data"
            }
            let raw = dataPool[dataPointer]; dataPointer += 1
            elog("[READ] Consomme '\(raw)' pour \(t) (ptr=\(dataPointer)/\(dataPool.count))")

            // ---- Tableau chaîne ----
            if let m = rxStrArr.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let nameR = Range(m.range(at: 1), in: t),
               let idxR  = Range(m.range(at: 2), in: t) {

                let arrName = String(t[nameR]).uppercased()
                let inside  = String(t[idxR])
                guard let idxs = parseIndicesList(inside) else { elog("[READ] Index list invalide '\(inside)'"); return "Syntax error" }
                guard let dims = stringArrayDims[arrName], var arr = stringArrays[arrName] else { elog("[READ] '\(arrName)' non dimensionné"); return "Undimensioned array" }
                guard let off = linearIndex(from: idxs, dims: dims), off < arr.count else { elog("[READ] OOB \(arrName)\(idxs)"); return "Subscript out of range" }

                guard let val = dataItemToString(raw) else { elog("[READ] Littéral chaîne invalide"); return "Syntax error" }
                arr[off] = val; stringArrays[arrName] = arr
                elog("[READ] \(arrName)\(idxs) <- '\(val)' (off=\(off))")
                continue
            }

            // ---- Tableau numérique ----
            if let m = rxNumArr.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let nameR = Range(m.range(at: 1), in: t),
               let idxR  = Range(m.range(at: 2), in: t) {

                let arrName = String(t[nameR]).uppercased()
                let inside  = String(t[idxR])
                guard let idxs = parseIndicesList(inside) else { elog("[READ] Index list invalide '\(inside)'"); return "Syntax error" }
                guard let dims = arrayDims[arrName], var arr = arrays[arrName] else { elog("[READ] '\(arrName)' non dimensionné"); return "Undimensioned array" }
                guard let off = linearIndex(from: idxs, dims: dims), off < arr.count else { elog("[READ] OOB \(arrName)\(idxs)"); return "Subscript out of range" }

                let tRaw = raw.trimmingCharacters(in: .whitespaces)
                if tRaw.hasPrefix("\"") || looksLikeBareIdentifier(tRaw) {
                    elog("[READ] Num attendu mais item texte '\(tRaw)'"); return "Type mismatch"
                }
                let res = evaluateExpression(tRaw)
                if res == "Syntax error" || res == "__UNDIMENSIONED__" || res == "Subscript out of range" { return res }
                let numStr = res.replacingOccurrences(of: ",", with: ".")
                guard let v = Double(numStr) else { elog("[READ] Type mismatch '\(raw)' -> \(numStr)"); return "Type mismatch" }
                arr[off] = v; arrays[arrName] = arr
                elog("[READ] \(arrName)\(idxs) <- \(v) (off=\(off))")
                continue
            }

            // ---- Scalaire chaîne ----
            if t.hasSuffix("$") {
                guard let val = dataItemToString(raw) else { elog("[READ] Littéral chaîne invalide"); return "Syntax error" }
                varText[t] = val; elog("[READ] \(t) <- '\(val)'")
                continue
            }

            // ---- Scalaire numérique ----
            let tRaw = raw.trimmingCharacters(in: .whitespaces)
            if tRaw.hasPrefix("\"") || looksLikeBareIdentifier(tRaw) {
                elog("[READ] Num attendu mais item texte '\(tRaw)'"); return "Type mismatch"
            }
            let res = evaluateExpression(tRaw)
            if res == "Syntax error" || res == "__UNDIMENSIONED__" || res == "Subscript out of range" { return res }
            let numStr = res.replacingOccurrences(of: ",", with: ".")
            guard let v = Double(numStr) else { elog("[READ] Type mismatch '\(raw)' -> \(numStr)"); return "Type mismatch" }
            variables[t] = v; elog("[READ] \(t) <- \(v)")
        }

        return ""
    }

    private func handleRestore() -> String { dataPointer = 0; return "" }

    // MARK: - DIM
    private func handleDim(_ line: String) -> String {
        elog("[DIM] Ligne reçue : '\(line)'")
        guard let r = line.uppercased().range(of: "DIM") else { return "Syntax error" }
        let after = line[r.upperBound...].trimmingCharacters(in: .whitespaces)

        // Split top-level par virgules
        var decls: [String] = []
        var cur = "", inStr = false, paren = 0
        for ch in after {
            if ch == "\"" { inStr.toggle(); cur.append(ch); continue }
            if !inStr {
                if ch == "(" { paren += 1; cur.append(ch); continue }
                if ch == ")" { paren = max(0, paren - 1); cur.append(ch); continue }
                if paren == 0 && ch == "," {
                    let t = cur.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { decls.append(t) }
                    cur.removeAll(keepingCapacity: true)
                    continue
                }
            }
            cur.append(ch)
        }
        let tail = cur.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { decls.append(tail) }
        if decls.isEmpty { return "Syntax error" }

        for d in decls {
            guard let open = d.firstIndex(of: "("),
                  let close = d.lastIndex(of: ")"),
                  open < close else {
                elog("[DIM] Syntax error sur '\(d)'"); return "Syntax error"
            }

            let name   = String(d[..<open]).trimmingCharacters(in: .whitespaces).uppercased()
            let inside = String(d[d.index(after: open)..<close])

            guard let dims = parseIndicesList(inside), !dims.isEmpty else {
                elog("[DIM] Dimensions invalides pour '\(name)'"); return "Syntax error"
            }
            let total = dims.map { $0 + 1 }.reduce(1, *)

            // ⬇️ Consommer l’autorisation éventuelle de re-DIM (si le nom existait avant CLEAR)
            let hadAllowance = redimAllowedAfterClear.remove(name) != nil

            if name.hasSuffix("$") {
                // String array
                if let _ = stringArrayDims[name] {
                    // tableau déjà (re)défini après CLEAR
                    if !hadAllowance { return "Redimensioned array" }
                }
                stringArrayDims[name] = dims
                stringArrays[name]    = Array(repeating: "", count: total)
                elog("[DIM] String array '\(name)' dims=\(dims) total=\(total) allowance=\(hadAllowance)")
            } else {
                // Numeric array
                if let _ = arrayDims[name] {
                    if !hadAllowance { return "Redimensioned array" }
                }
                arrayDims[name] = dims
                arrays[name]    = Array(repeating: 0.0, count: total)
                elog("[DIM] Numeric array '\(name)' dims=\(dims) total=\(total) allowance=\(hadAllowance)")
            }
        }

        return ""
    }


           

    // MARK: - PRINT
    private func handlePrint(_ command: String) -> String {
        // "PRINT ..." ou "PRINT"
        var prevWasNumeric = false

        let printContent = command.count >= 5
            ? String(command.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            : ""

        if printContent.isEmpty {
            elog("[PRINT] Aucune expression, saut de ligne")
            return "\n"
        }

        let ZONE = 14 // largeur d’une zone MSX
        elog("[PRINT] Contenu brut : '\(printContent)'")

        var line = ""            // sortie en construction
        var col  = 0             // colonne courante (0-based, monospace)
        var cur  = ""            // segment courant (entre deux séparateurs)
        var inStr = false        // état guillemets
        var lastSep: Character? = nil // mémorise si la ligne se termine par ',' ou ';'

        func appendText(_ t: String) {
            line += t
            col += t.count
        }

        // Évalue et ajoute un segment
        // Évalue et ajoute un segment
        func emitValue(_ rawPart: String) -> String? {
            let trimmed = rawPart.trimmingCharacters(in: .whitespaces)
            elog("[PRINT] Traitement de : '\(trimmed)'")

            if trimmed.isEmpty { return nil } // segment vide -> rien à afficher
            lastSep = nil

            // 1) Littéral chaîne BASIC
            if let decoded = decodeBasicStringLiteral(trimmed) {
                // Espace si chaîne suit un nombre avec ';'
                if prevWasNumeric && lastSep != "," && col > 0 { appendText(" ") }
                appendText(decoded)
                prevWasNumeric = false
                elog("[PRINT] Chaîne directe : '\(decoded)'")
                return nil
            }

            // 2) Variable numérique
            if let value = variables[trimmed.uppercased()] {
                // Nombre → pas d’espace ici, mais on pose le flag
                let formatted = formatNumber(value)
                // Si tu as formatNumberForPrint(d), utilise-le:
                appendText(formatNumberForPrint(value))
                prevWasNumeric = true
                elog("[PRINT] Var num \(trimmed.uppercased()) = \(formatted)")
                return nil
            }

            // 3) Variable texte
            if trimmed.uppercased().hasSuffix("$") {
                let text = varText[trimmed.uppercased()] ?? ""
                // Espace si chaîne suit un nombre avec ';'
                if prevWasNumeric && lastSep != "," && col > 0 { appendText(" ") }
                appendText(text)
                prevWasNumeric = false
                elog("[PRINT] Var texte \(trimmed.uppercased()) = '\(text)'")
                return nil
            }

            // 4) Expression générale
            let result = evaluateExpression(trimmed)

            // ⛔️ Mapper le sentinelle interne vers le message MSX
            if result == "__UNDIMENSIONED__" { return "Undimensioned array" }

            // ⛔️ Propagation directe des erreurs fatales
            let fatalErrors: Set<String> = [
                "Syntax error",
                "Incorrect number of arguments",
                "Illegal function call",
                "Subscript out of range",
                "Undimensioned array",
            ]
            if fatalErrors.contains(result) {
                elog("[PRINT] Erreur fatale renvoyée par eval: \(result)")
                return result
            }

            if result.hasPrefix("\""), result.hasSuffix("\""), result.count >= 2 {
                // résultat chaîne (quoted)
                let cleaned = String(result.dropFirst().dropLast())
                // Espace si chaîne suit un nombre avec ';'
                if prevWasNumeric && lastSep != "," && col > 0 { appendText(" ") }
                appendText(cleaned)
                prevWasNumeric = false
                elog("[PRINT] Résultat chaîne : '\(cleaned)'")
            } else if let d = Double(result.trimmingCharacters(in: .whitespaces)) {
                // résultat numérique
                let formatted = formatNumber(d)
                // Si tu as formatNumberForPrint(d), garde-le :
                appendText(formatNumberForPrint(d))
                prevWasNumeric = true
                elog("[PRINT] Résultat numérique formaté : '\(formatted)'")
            } else {
                // résultat non-quoté non numérique -> traiter comme texte
                if prevWasNumeric && lastSep != "," && col > 0 { appendText(" ") }
                appendText(result)
                prevWasNumeric = false
                elog("[PRINT] Résultat : '\(result)'")
            }
            return nil
        }


        // Scan pour gérer , et ; hors guillemets ET hors parenthèses
        var paren = 0
        for ch in printContent {
            if ch == "\"" { inStr.toggle(); cur.append(ch); continue }
            if !inStr {
                if ch == "(" { paren += 1; cur.append(ch); continue }
                if ch == ")" { paren = max(0, paren - 1); cur.append(ch); continue }
            }
            if !inStr && paren == 0 && (ch == "," || ch == ";") {
                if let err = emitValue(cur) { return err }
                cur.removeAll(keepingCapacity: true)

                if ch == ";" {
                    elog("[PRINT] Séparateur ';' (pas d’espaces)")
                } else { // ','
                    let nextZone = ((col / ZONE) + 1) * ZONE
                    let pad = max(0, nextZone - col)
                    if pad > 0 { appendText(String(repeating: " ", count: pad)) }
                    elog("[PRINT] Séparateur ',' -> pad jusqu’à col \(col)")
                }
                lastSep = ch
                continue
            }

            cur.append(ch)
            lastSep = nil
        }

        // Dernier segment
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { lastSep = nil }
        if let err = emitValue(cur) { return err }

        elog("[PRINT] Résultat final affiché : '\(line)'")

        if line.isEmpty {
            elog("[PRINT] Sortie vide → ligne vide")
            return "\n"
        }

        // 👉 Laisser PRINT décider exactement ce qui s'affiche
        let noCR = (lastSep == ";" || lastSep == ",")
        return noCR ? line : (line + "\n")
    }


    // MARK: - INPUT (inchangé sauf logs)
    private func handleInput(_ trimmed: String) -> String {
        let afterInput = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)

        if afterInput.hasPrefix("\"") {
            var i = afterInput.startIndex
            var inStr = false
            var promptPart = ""
            var rest = ""
            while i < afterInput.endIndex {
                let ch = afterInput[i]
                if ch == "\"" { inStr.toggle(); promptPart.append(ch); i = afterInput.index(after: i); continue }
                if !inStr && (ch == ";" || ch == ",") {
                    let afterSep = afterInput.index(after: i)
                    rest = String(afterInput[afterSep...]).trimmingCharacters(in: .whitespaces)
                    break
                }
                promptPart.append(ch)
                i = afterInput.index(after: i)
            }
            let promptTrim = promptPart.trimmingCharacters(in: .whitespaces)
            guard promptTrim.hasPrefix("\""), promptTrim.hasSuffix("\"") else { elog("[INPUT] Prompt mal formé"); return "Syntax error" }
            guard !rest.isEmpty else { elog("[INPUT] Variables absentes"); return "Syntax error" }

            let base = String(promptTrim.dropFirst().dropLast())
            let finalPrompt = base.hasSuffix("?") ? base : "\(base)?"
            let varNames = parseCsvLike(rest).map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
            if varNames.isEmpty { elog("[INPUT] Aucune variable"); return "Syntax error" }

            inputCtx = InputContext(vars: varNames, next: 0, prompt: finalPrompt)
            awaitingInput = true
            pendingPrompt = finalPrompt
            elog("[INPUT] Prompt='\(finalPrompt)' vars=\(varNames)")
            return "__WAIT_INPUT__"
        }

        let list = parseCsvLike(String(afterInput)).map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
        if list.isEmpty { elog("[INPUT] Syntax error: pas de prompt ni de variables"); return "Syntax error" }

        inputCtx = InputContext(vars: list, next: 0, prompt: "?")
        awaitingInput = true
        pendingPrompt = "?"
        elog("[INPUT] Sans prompt: vars=\(list)")
        return "__WAIT_INPUT__"
    }

    // --- THEN/ELSE / IF GOTO (identique à ta version avec logs) ---
    private func findKeywordTopLevel(_ s: String, keyword: String) -> String.Index? {
        let kw = keyword.uppercased()
        let chars = Array(s)
        var inStr = false
        var i = 0
        func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "$" }
        while i <= chars.count - kw.count {
            let c = chars[i]
            if c == "\"" { inStr.toggle(); i += 1; continue }
            if !inStr {
                let slice = String(chars[i..<(i+kw.count)]).uppercased()
                if slice == kw {
                    let beforeIsId = (i > 0) && isIdentChar(chars[i-1])
                    let afterIsId  = (i + kw.count < chars.count) && isIdentChar(chars[i+kw.count])
                    if !beforeIsId && !afterIsId {
                        return s.index(s.startIndex, offsetBy: i)
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private func handleIf(_ trimmed: String, isInRun: Bool) -> String {
        if let thenIdx = findKeywordTopLevel(trimmed, keyword: "THEN") {
            let condPart = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<thenIdx]).trimmingCharacters(in: .whitespaces)
            let thenEnd = trimmed.index(thenIdx, offsetBy: 4)
            let afterThen = String(trimmed[thenEnd...]).trimmingCharacters(in: .whitespaces)
            var thenCmd = afterThen
            var elseCmd: String? = nil
            if let elseIdx = findKeywordTopLevel(afterThen, keyword: "ELSE") {
                let elseEnd = afterThen.index(elseIdx, offsetBy: 4)
                thenCmd = String(afterThen[..<elseIdx]).trimmingCharacters(in: .whitespaces)
                elseCmd = String(afterThen[elseEnd...]).trimmingCharacters(in: .whitespaces)
            }
            elog("[IF] Condition = '\(condPart)'")
            elog("[IF] THEN part = '\(thenCmd)'")
            elog("[IF] ELSE part = '\(elseCmd ?? "(none)")'")

            let condEval = evaluateExpression(condPart)
            elog("[IF] evaluateExpression(cond) = '\(condEval)'")
            if condEval == "Syntax error" { return "Syntax error" }

            let isTrue = (Double(condEval.replacingOccurrences(of: ",", with: ".")) ?? 0) != 0

            let branch = isTrue ? thenCmd : (elseCmd ?? "")
            if branch.isEmpty { return "" }

            let firstStmt = splitStatements(branch).first ?? branch
            if let ln = Int(firstStmt.trimmingCharacters(in: .whitespaces)) {
                elog("[IF] THEN/ELSE commence par un nombre nu → GOTO \(ln)")
                gotoTarget = ln
                return "__GOTO__"
            }
            return interpretImmediate(branch, isInRun: isInRun)
        }

        // --- forme: IF <cond> GOTO <line> (sans THEN) ---
        let afterIF = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard let gotoIdx = findKeywordTopLevel(String(afterIF), keyword: "GOTO") else {
            elog("[IF] Ni THEN ni GOTO -> Syntax error")
            return "Syntax error"
        }
        let condPart = String(afterIF[..<gotoIdx]).trimmingCharacters(in: .whitespaces)
        let linePart = String(afterIF[afterIF.index(gotoIdx, offsetBy: 4)...]).trimmingCharacters(in: .whitespaces)

        elog("[IF] (sans THEN) Condition='\(condPart)' GOTO='\(linePart)'")

        let condEval = evaluateExpression(condPart)
        elog("[IF] evaluateExpression(cond) = '\(condEval)'")
        if condEval == "Syntax error" { return "Syntax error" }

        // ✅ MSX : toute valeur non nulle est vraie
        let truthy = (Double(condEval.replacingOccurrences(of: ",", with: ".")) ?? 0) != 0

        if truthy {
            if let ln = Int(linePart) {
                elog("[IF] Condition vraie -> GOTO \(ln)")
                gotoTarget = ln
                return "__GOTO__"
            } else {
                elog("[IF] GOTO cible non numérique: '\(linePart)'")
                return "Syntax error"
            }
        } else {
            elog("[IF] Condition fausse -> pas d'action")
            return ""
        }

    }

    private func handleGoto(_ tokens: [String]) -> String {
        if tokens.count >= 2, let target = Int(tokens[1]) {
            gotoTarget = target
            return "__GOTO__"
        }
        return "Syntax error"
    }

    private func handleLet(_ tokens: [String]) -> String {
        let assignment = tokens.dropFirst().joined(separator: " ")
        let parts = assignment.components(separatedBy: "=")
        if parts.count == 2 {
            let varName = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
            let expr = parts[1].trimmingCharacters(in: .whitespaces)
            var resultStr = evaluateExpression(expr)

            if varName.hasSuffix("$") {
                if resultStr.hasPrefix("\"") && resultStr.hasSuffix("\"") && resultStr.count >= 2 {
                    resultStr = String(resultStr.dropFirst().dropLast())
                }
                varText[varName] = resultStr
                return ""
            } else {
                if let value = Double(resultStr) {
                    variables[varName] = value
                    return ""
                }
            }
        }
        return "Syntax error"
    }

    private func handleAssignment(_ trimmed: String) -> String {
        guard let equalIndex = trimmed.firstIndex(of: "=") else { return "Syntax error" }
        let lhs = trimmed[..<equalIndex].trimmingCharacters(in: .whitespaces)
        let rhs = trimmed[trimmed.index(after: equalIndex)...].trimmingCharacters(in: .whitespaces)

        let lhsU = lhs.uppercased()

        // --- Variable système TIME ---
        if lhsU == "TIME" {
            let valueStr = evaluateExpression(String(rhs))
            if valueStr == "__UNDIMENSIONED__" { return "Undimensioned array" }
            if valueStr == "Subscript out of range" { return valueStr }
            if valueStr == "Syntax error" { return "Syntax error" }
            let valueNorm = valueStr.replacingOccurrences(of: ",", with: ".")
            guard let value = Double(valueNorm) else { return "Syntax error" }
            writeTIME(Int(value))
            elog("[assign] TIME <- \(Int(value))")
            return ""
        }

        // Valider LHS
        let isVar    = lhsU.range(of: #"^[A-Z][A-Z0-9]*\$?$"#,     options: .regularExpression) != nil
        let isNumArr = lhsU.range(of: #"^[A-Z][A-Z0-9]*\(.+\)$"#,   options: .regularExpression) != nil
        let isStrArr = lhsU.range(of: #"^[A-Z][A-Z0-9]*\$\(.+\)$"#, options: .regularExpression) != nil
        guard isVar || isNumArr || isStrArr else {
            elog("[assign] LHS invalide: '\(lhs)'")
            return "Syntax error"
        }

        elog("[assign] lhs='\(lhs)' rhs='\(rhs)'")

        // --- Tableau chaîne multi-d : NAME$(i[,j...]) = <expr$> (STRICT MSX)
        if let match = try? NSRegularExpression(pattern: #"^([A-Z][A-Z0-9]*\$)\((.+)\)$"#)
            .firstMatch(in: String(lhs), range: NSRange(lhs.startIndex..., in: lhs)),
           let nameRange = Range(match.range(at: 1), in: lhs),
           let insideRange = Range(match.range(at: 2), in: lhs) {

            let varName = String(lhs[nameRange]).uppercased()
            let inside  = String(lhs[insideRange])

            guard let idxs = parseIndicesList(inside) else { return "Syntax error" }
            guard let dims = stringArrayDims[varName], var arr = stringArrays[varName] else { return "Undimensioned array" }
            guard let off = linearIndex(from: idxs, dims: dims), off < arr.count else { return "Subscript out of range" }

            // STRICT MSX : RHS doit être une expression CHAÎNE (détection syntaxique)
            if !looksStringExpr(String(rhs)) { return "Type mismatch" }

            let evaluated = evaluateExpression(String(rhs))
            if evaluated == "__UNDIMENSIONED__" { return "Undimensioned array" }
            if evaluated == "Subscript out of range" { return evaluated }
            if evaluated == "Syntax error" { return "Syntax error" }

            // Nettoyage guillemets si présents, sinon prendre tel quel
            let cleaned: String
            if evaluated.hasPrefix("\""), evaluated.hasSuffix("\""), evaluated.count >= 2 {
                cleaned = String(evaluated.dropFirst().dropLast())
            } else {
                cleaned = evaluated
            }

            arr[off] = cleaned
            stringArrays[varName] = arr
            elog("[assign] Affectation chaîne \(varName)\(idxs) = '\(cleaned)' (off=\(off))")
            return ""
        }

        // --- Scalaire chaîne : NAME$ = <expr$> (STRICT MSX)
        if lhs.hasSuffix("$") {
            // STRICT MSX : RHS doit être une expression CHAÎNE (détection syntaxique)
            if !looksStringExpr(String(rhs)) { return "Type mismatch" }

            let evaluated = evaluateExpression(String(rhs))
            elog("[assign] Résultat évalué : '\(evaluated)'")

            if evaluated == "__UNDIMENSIONED__" { return "Undimensioned array" }
            if evaluated == "Subscript out of range" { return evaluated }
            if evaluated == "Syntax error" { return "Syntax error" }

            let cleaned: String
            if evaluated.hasPrefix("\""), evaluated.hasSuffix("\""), evaluated.count >= 2 {
                cleaned = String(evaluated.dropFirst().dropLast())
            } else {
                cleaned = evaluated
            }

            let varName = lhs.uppercased()
            varText[varName] = cleaned
            elog("[assign] Affectation chaîne : \(varName) = '\(cleaned)'")
            return ""
        }

        // --- Tableau numérique multi-d : NAME(i[,j...]) = <expr>
        if let match = try? NSRegularExpression(pattern: #"^([A-Z][A-Z0-9]*)\((.+)\)$"#)
            .firstMatch(in: String(lhs), range: NSRange(lhs.startIndex..., in: lhs)),
           let nameRange = Range(match.range(at: 1), in: lhs),
           let insideRange = Range(match.range(at: 2), in: lhs) {

            let varName = String(lhs[nameRange]).uppercased()
            let inside = String(lhs[insideRange])

            guard let dims = arrayDims[varName], var arr = arrays[varName] else { elog("[assign] '\(varName)' non dimensionné"); return "Undimensioned array" }
            guard let idxs = parseIndicesList(inside) else { return "Syntax error" }
            guard let off = linearIndex(from: idxs, dims: dims), off < arr.count else { return "Subscript out of range" }

            let valueStr = evaluateExpression(String(rhs))
            if valueStr == "__UNDIMENSIONED__" { return "Undimensioned array" }
            if valueStr == "Subscript out of range" { return valueStr }
            if valueStr == "Syntax error" { elog("[assign] RHS = syntax error"); return "Syntax error" }
            let valueNorm = valueStr.replacingOccurrences(of: ",", with: ".")
            guard let value = Double(valueNorm) else { return "Syntax error" }

            arr[off] = value
            arrays[varName] = arr
            elog("[assign] Affectation num \(varName)\(idxs) = \(value) (off=\(off))")
            return ""
        }

        // --- Scalaire numérique : NAME = <expr>
        let valueStr = evaluateExpression(String(rhs))
        if valueStr == "__UNDIMENSIONED__" { return "Undimensioned array" }
        if valueStr == "Subscript out of range" { return valueStr }
        if valueStr == "Syntax error" { elog("[assign] RHS = syntax error"); return "Syntax error" }

        let valueNorm = valueStr.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(valueNorm) else {
            elog("[assign] RHS non numérique : '\(valueStr)'")
            return "Syntax error"
        }
        let varName = lhs.uppercased()
        variables[varName] = value
        elog("[assign] Affectation numérique : \(varName) = \(value)")
        return ""
    }

    private func looksStringExpr(_ raw: String) -> Bool {
        // Uppercase en ignorant ce qui est entre guillemets
        let u = uppercaseOutsideQuotes(raw).trimmingCharacters(in: .whitespaces)

        // 1) Présence explicite de guillemets -> chaîne
        if u.contains("\"") { return true }

        // 2) Tableau chaîne : NAME$( ... )
        if u.range(of: #"(?<![A-Z0-9\$])[A-Z][A-Z0-9]*\$\s*\("#, options: .regularExpression) != nil {
            return true
        }

        // 3) Variable chaîne scalaire : NAME$ (isolé, pas collé à d'autres identifiants)
        if u.range(of: #"(?<![A-Z0-9\$])[A-Z][A-Z0-9]*\$(?![A-Z0-9\$])"#, options: .regularExpression) != nil {
            return true
        }

        // 4) Fonctions chaîne builtin
        if u.range(of: #"\b(LEFT\$|RIGHT\$|MID\$|CHR\$|STR\$|HEX\$|BIN\$|OCT\$|STRING\$|SPACE\$)\s*\("#,
                   options: .regularExpression) != nil {
            return true
        }

        // 5) Fonctions utilisateur chaîne : FNNAME$(...)
        if u.range(of: #"(?<![A-Z0-9\$])FN[A-Z0-9]*\$\s*\("#, options: .regularExpression) != nil {
            return true
        }

        return false
    }





    // MARK: - FOR/NEXT
    private func handleFor(_ trimmed: String) -> String {
        let afterFor = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard let toParts = splitTopLevel(String(afterFor), keyword: "TO"), toParts.count == 2 else { return "Syntax error" }
        let left = toParts[0]
        let right = toParts[1]

        func topLevelEqualIndex(_ s: String) -> String.Index? {
            var inStr = false, paren = 0
            for (ofs, ch) in s.enumerated() {
                if ch == "\"" { inStr.toggle(); continue }
                if !inStr {
                    if ch == "(" { paren += 1; continue }
                    if ch == ")" { paren = max(0, paren - 1); continue }
                    if paren == 0 && ch == "=" {
                        return s.index(s.startIndex, offsetBy: ofs)
                    }
                }
            }
            return nil
        }

        guard let eq = topLevelEqualIndex(left) else { return "Syntax error" }
        let varName = left[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
        let startExpr = left[left.index(after: eq)...].trimmingCharacters(in: .whitespaces)

        var limitExpr = right
        var stepExpr: String? = nil
        if let stepParts = splitTopLevel(right, keyword: "STEP") {
            guard stepParts.count == 2 else { return "Syntax error" }
            limitExpr = stepParts[0]
            stepExpr  = stepParts[1]
        }

        guard varName.range(of: #"^[A-Z][A-Z0-9]*$"#, options: .regularExpression) != nil else { return "Syntax error" }
        guard let start = Double(evaluateExpression(startExpr)),
              let limit = Double(evaluateExpression(limitExpr)) else { return "Syntax error" }

        let stepStr = stepExpr ?? "1"
        guard let step = Double(evaluateExpression(stepStr)), step != 0 else { return "Syntax error" }

        variables[varName] = start
        forStack.append(ForLoopContext(varName: varName, limit: limit, step: step, returnIndex: -1, resumeSidx: nil))
        return ""
    }

    private func handleNext() -> String {
        guard let context = forStack.last else { return "NEXT without FOR" }
        let varName = context.varName
        let currentValue = variables[varName] ?? 0
        let newValue = currentValue + context.step
        variables[varName] = newValue
        
        if msxThrottle, perNextDelay > 0 {
            // Usleep pour ne pas monopoliser le thread (≈2ms)
            usleep(useconds_t(perNextDelay * 1_000_000))
        }


        // continues = (step>=0 ? v<=limit : v>=limit)
        let continues = (context.step >= 0) ? (newValue <= context.limit) : (newValue >= context.limit)

        if !continues {
            _ = forStack.popLast()
            return ""
        } else {
            if context.returnIndex >= 0 {
                // MODE PROGRAMME : retour à la ligne du FOR + reprise après FOR
                if let rs = context.resumeSidx { forcedStatementIndex = rs }
                let keys = program.lines.keys.sorted()
                gotoTarget = keys[context.returnIndex]
                return "__GOTO__"
            } else {
                // MODE IMMÉDIAT : rembobine i sur resumeSidx
                return "__NEXT_IMMEDIATE__"
            }
        }
    }

    // MARK: - Utilitaires
    private func formatNumber(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Inf" : "-Inf" }
        if value == 0 { return "0" }
        let towardZero = value.rounded(.towardZero)
        if abs(value - towardZero) < 1e-12 { return String(Int(towardZero)) }

        struct F { static let n: NumberFormatter = {
            let f = NumberFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.numberStyle = .decimal
            f.decimalSeparator = "."
            f.usesGroupingSeparator = false
            f.usesSignificantDigits = true
            f.minimumSignificantDigits = 1
            f.maximumSignificantDigits = 14
            return f
        }() }
        return F.n.string(from: NSNumber(value: value)) ?? String(format: "%.14g", value)
    }

    private func formatNumberForPrint(_ value: Double) -> String {
        let core = formatNumber(value)        // ton formatteur actuel (sans espace)
        return value >= 0 ? " " + core : core // espace de signe pour >= 0
    }



    private func splitTopLevel(_ s: String, keyword: String) -> [String]? {
        let kw = keyword.uppercased()
        let chars = Array(s)
        let kwChars = Array(kw)
        var inStr = false
        var paren = 0
        var parts: [String] = []
        var start = 0
        var i = 0
        func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "$" }
        while i <= chars.count - kwChars.count {
            let c = chars[i]
            if c == "\"" { inStr.toggle(); i += 1; continue }
            if !inStr {
                if c == "(" { paren += 1; i += 1; continue }
                if c == ")" { paren = max(0, paren - 1); i += 1; continue }
                if paren == 0 {
                    let slice = String(chars[i..<(i+kwChars.count)]).uppercased()
                    if slice == kw {
                        let beforeIsId = (i > 0) && isIdentChar(chars[i-1])
                        let afterIsId  = (i + kwChars.count < chars.count) && isIdentChar(chars[i+kwChars.count])
                        if !beforeIsId && !afterIsId {
                            let seg = String(chars[start..<i]).trimmingCharacters(in: .whitespaces)
                            parts.append(seg)
                            start = i + kwChars.count
                            i = start
                            continue
                        }
                    }
                }
            }
            i += 1
        }
        if parts.isEmpty { return nil }
        let last = String(chars[start..<chars.count]).trimmingCharacters(in: .whitespaces)
        parts.append(last)
        return parts
    }

    private func stripOuterParentheses(_ s: String) -> String {
        var str = s.trimmingCharacters(in: .whitespaces)
        while str.hasPrefix("(") && str.hasSuffix(")") {
            let chars = Array(str)
            var inStr = false
            var paren = 0
            var ok = true
            for i in 0..<chars.count {
                let c = chars[i]
                if c == "\"" { inStr.toggle(); continue }
                if inStr { continue }
                if c == "(" { paren += 1; continue }
                if c == ")" {
                    paren -= 1
                    if paren == 0 && i != chars.count - 1 { ok = false; break }
                }
            }
            if !ok || paren != 0 { break }
            str = String(str.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return str
    }

    private func toMSX16(_ s: String) -> Int16? {
        let d = Double(s.replacingOccurrences(of: ",", with: ".")) ?? Double.nan
        if d.isNaN { return nil }
        let n = Int(d)
        return Int16(truncatingIfNeeded: n)
    }

    private func foldMSX16(_ parts: [String], _ op: (Int16, Int16) -> Int16) -> String {
        guard let first = toMSX16(evaluateExpression(parts[0])) else { return "Type mismatch" }
        var acc = first
        for i in 1..<parts.count {
            guard let v = toMSX16(evaluateExpression(parts[i])) else { return "Type mismatch" }
            acc = op(acc, v)
        }
        return formatNumber(Double(acc))
    }
    // Quote un texte pour un littéral BASIC : "a" -> "\"a\"" ; gère les guillemets doublés
    private func basicQuoted(_ s: String) -> String {
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // Développe un seul appel FN<NAME>[ $ ](args...) au niveau top (hors guillemets).
    // Retourne l'expression avec CET appel remplacé par "(corps_substitué)",
    // ou un message d'erreur ("Syntax error\n" / "Incorrect number of arguments\n" / "__UNDIMENSIONED__" / "Subscript out of range").
    private func expandUserFnOnce(_ s: String) -> String? {
        let chars = Array(s)
        var inStr = false
        var i = 0

        func isAlnum(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        while i < chars.count {
            let c = chars[i]
            if c == "\"" { inStr.toggle(); i += 1; continue }
            if !inStr {
                // Cherche "FN"
                if i + 1 < chars.count, String(chars[i...i+1]).uppercased() == "FN" {
                    var j = i + 2
                    var nameCore = ""
                    while j < chars.count, isAlnum(chars[j]) { nameCore.append(chars[j]); j += 1 }
                    if nameCore.isEmpty { i += 1; continue }

                    // Optionnel '$' pour les fonctions chaîne
                    var isStringFn = false
                    if j < chars.count, chars[j] == "$" { isStringFn = true; j += 1 }

                    // Doit être suivi de '('
                    guard j < chars.count, chars[j] == "(" else { i += 1; continue }

                    // Trouver la parenthèse fermante appariée
                    var k = j + 1, paren = 1, inStr2 = false
                    while k < chars.count {
                        let ck = chars[k]
                        if ck == "\"" { inStr2.toggle(); k += 1; continue }
                        if !inStr2 {
                            if ck == "(" { paren += 1 }
                            else if ck == ")" { paren -= 1; if paren == 0 { break } }
                        }
                        k += 1
                    }
                    guard k < chars.count, paren == 0 else { return "Syntax error\n" }

                    // Récupère la définition
                    let fnKey = (nameCore + (isStringFn ? "$" : "")).uppercased()
                    let defNum = userFunctions[fnKey]              // numériques
                    let defStr = userStringFunctions[fnKey]        // chaînes

                    // Si la clé n'existe pas -> erreur
                    guard defNum != nil || defStr != nil else { return "Syntax error\n" }

                    let inside = String(chars[(j+1)..<k])

                    // Split des arguments top-level
                    let argExprs = splitTopLevelArgs(inside).map { $0.trimmingCharacters(in: .whitespaces) }
                    elog("[FN call] \(fnKey) args=\(argExprs.count) expected=" +
                         "\(defNum?.params.count ?? defStr?.params.count ?? -1)")

                    if let def = defNum {
                        // --- Fonction NUMÉRIQUE ---
                        if argExprs.count != def.params.count { return "Incorrect number of arguments" }
                        // Évalue les args → numérique obligatoire
                        var body = def.body
                        // Remplacer noms les plus longs d'abord pour éviter collisions (AB avant A)
                        let ordered = def.params.enumerated().sorted { $0.element.count > $1.element.count }
                        for (idx, p) in ordered {
                            let vStr = evaluateExpression(argExprs[idx])
                            if vStr == "Syntax error" || vStr == "__UNDIMENSIONED__" || vStr == "Subscript out of range" {
                                return vStr
                            }
                            guard Double(vStr.replacingOccurrences(of: ",", with: ".")) != nil else { return "Syntax error\n" }
                            let pEsc = NSRegularExpression.escapedPattern(for: p)
                            let regex = try! NSRegularExpression(pattern: "(?<!\\w)\(pEsc)(?!\\w)")
                            let range = NSRange(location: 0, length: body.utf16.count)
                            body = regex.stringByReplacingMatches(in: body, options: [], range: range, withTemplate: vStr)
                        }

                        // Remplace l'appel par "(body)"
                        let start = s.index(s.startIndex, offsetBy: i)
                        let end   = s.index(s.startIndex, offsetBy: k+1)
                        return String(s[..<start]) + "(" + body + ")" + String(s[end...])
                    } else if let def = defStr {
                        // --- Fonction CHAÎNE ---
                        if argExprs.count != def.params.count { return "Incorrect number of arguments" }
                        var body = def.body
                        let ordered = def.params.enumerated().sorted { $0.element.count > $1.element.count }
                        for (idx, p) in ordered {
                            let v = evaluateExpression(argExprs[idx])
                            if v == "Syntax error" || v == "__UNDIMENSIONED__" || v == "Subscript out of range" {
                                return v
                            }
                            // Si l'arg ressemble à un nombre → on insère tel quel ; sinon on l'insère comme littéral BASIC "..."
                            let asNum = Double(v.replacingOccurrences(of: ",", with: "."))
                            let replacement = (asNum != nil) ? v : basicQuoted(v)
                            let pEsc = NSRegularExpression.escapedPattern(for: p)
                            let regex = try! NSRegularExpression(pattern: "(?<!\\w)\(pEsc)(?!\\w)")
                            let range = NSRange(location: 0, length: body.utf16.count)
                            body = regex.stringByReplacingMatches(in: body, options: [], range: range, withTemplate: replacement)
                        }

                        // Remplace l'appel par "(body)". Le corps pourra produire une chaîne, un nombre, etc.
                        let start = s.index(s.startIndex, offsetBy: i)
                        let end   = s.index(s.startIndex, offsetBy: k+1)
                        return String(s[..<start]) + "(" + body + ")" + String(s[end...])
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private func isReservedKeyword(_ u: String) -> Bool {
        let K: Set<String> = [
            "PRINT","INPUT","GOTO","GOSUB","RETURN","IF","THEN","ELSE","FOR","NEXT",
            "DIM","DATA","READ","RESTORE","ON","STOP","END","CLEAR","CLOAD","SAVE",
            "CLS","DEF","TIME","REM","LET","RUN"
        ]
        return K.contains(u)
    }
    
    private func substituteMsxNumericFunctions(in expr: String) -> String {
        var s = expr

        func splitArgsTopLevel(_ inside: String) -> [String] {
            var out: [String] = [], cur = ""
            var inStr = false, paren = 0
            for ch in inside {
                if ch == "\"" { inStr.toggle(); cur.append(ch); continue }
                if !inStr {
                    if ch == "(" { paren += 1; cur.append(ch); continue }
                    if ch == ")" { paren = max(0, paren - 1); cur.append(ch); continue }
                    if paren == 0 && ch == "," {
                        out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue
                    }
                }
                cur.append(ch)
            }
            let tail = cur.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty || !inside.isEmpty { out.append(tail) }
            return out
        }

        @inline(__always) func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "$" }

        // Remplace la première occurrence sûre de NAME(...)
        func replaceFirst(name: String, _ compute: ([String]) -> String?) -> Bool {
            let chars = Array(s)
            var inStr = false
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c == "\"" { inStr.toggle(); i += 1; continue }
                if !inStr, i + name.count < chars.count {
                    let slice = String(chars[i..<(i + name.count)]).uppercased()
                    // Vérifie les bornes d’identifiant et la présence de '('
                    if slice == name,
                       (i == 0 || !isIdentChar(chars[i - 1])),
                       i + name.count < chars.count, chars[i + name.count] == "(" {

                        var j = i + name.count + 1, paren = 1, inStr2 = false
                        while j < chars.count {
                            let cj = chars[j]
                            if cj == "\"" { inStr2.toggle(); j += 1; continue }
                            if !inStr2 {
                                if cj == "(" { paren += 1 }
                                else if cj == ")" { paren -= 1; if paren == 0 { break } }
                            }
                            j += 1
                        }
                        if j >= chars.count { return false }

                        let inside = String(chars[(i + name.count + 1)..<j])
                        let args = splitArgsTopLevel(inside)

                        guard let rep = compute(args) else {
                            s = "Syntax error"
                            return true
                        }
                        // On remplace l’appel par le résultat (littéral numérique ou message d’erreur)
                        s = String(chars[0..<i]) + rep + String(chars[(j + 1)...])
                        return true
                    }
                }
                i += 1
            }
            return false
        }

        // Évalue en Double avec propagation des erreurs MSX
        func toNum(_ x: String) -> (ok: Bool, val: Double, err: String?) {
            let out = evaluateExpression(x)
            let fatals: Set<String> = [
                "Syntax error","Incorrect number of arguments","Illegal function call",
                "Subscript out of range","__UNDIMENSIONED__","Division by zero",
                "Overflow","Type mismatch"
            ]
            if fatals.contains(out) { return (false, 0.0, out) }
            let norm = out.replacingOccurrences(of: ",", with: ".")
            guard let d = Double(norm) else { return (false, 0.0, "Type mismatch") }
            return (true, d, nil)
        }

        while true {
            var did = false

            did = replaceFirst(name: "ABS") { a in
                guard a.count == 1 else { return nil }
                let r = toNum(a[0]); if !r.ok { return r.err }
                return formatNumber(abs(r.val))
            } || did

            did = replaceFirst(name: "SGN") { a in
                guard a.count == 1 else { return nil }
                let r = toNum(a[0]); if !r.ok { return r.err }
                let v = r.val > 0 ? 1.0 : (r.val < 0 ? -1.0 : 0.0)
                return formatNumber(v)
            } || did

            did = replaceFirst(name: "INT") { a in
                guard a.count == 1 else { return nil }
                let r = toNum(a[0]); if !r.ok { return r.err }
                return formatNumber(floor(r.val))
            } || did

            did = replaceFirst(name: "FIX") { a in
                guard a.count == 1 else { return nil }
                let r = toNum(a[0]); if !r.ok { return r.err }
                return formatNumber(r.val < 0 ? ceil(r.val) : floor(r.val))
            } || did

            did = replaceFirst(name: "SQR") { a in
                guard a.count == 1 else { return nil }
                let r = toNum(a[0]); if !r.ok { return r.err }
                return r.val < 0 ? "Illegal function call" : formatNumber(sqrt(r.val))
            } || did

            did = replaceFirst(name: "RND") { a in
                guard a.count == 1 else { return nil }
                let r = toNum(a[0]); if !r.ok { return r.err }
                return formatNumber(msxRND(r.val))
            } || did

            did = replaceFirst(name: "SIN") { a in
                guard a.count == 1 else { return nil }
                let r = toNum(a[0]); if !r.ok { return r.err }
                return formatNumber(sin(r.val))
            } || did

            did = replaceFirst(name: "COS") { a in
                guard a.count == 1 else { return nil }
                let r = toNum(a[0]); if !r.ok { return r.err }
                return formatNumber(cos(r.val))
            } || did

            did = replaceFirst(name: "TAN") { a in
                guard a.count == 1 else { return nil }
                let r = toNum(a[0]); if !r.ok { return r.err }
                return formatNumber(tan(r.val))
            } || did

            did = replaceFirst(name: "EXP") { a in
                guard a.count == 1 else { return nil }
                let r = toNum(a[0]); if !r.ok { return r.err }
                let v = exp(r.val)
                return v.isInfinite || v.isNaN ? "Overflow" : formatNumber(v)
            } || did

            did = replaceFirst(name: "LOG") { a in
                guard a.count == 1 else { return nil }
                let r = toNum(a[0]); if !r.ok { return r.err }
                return r.val <= 0 ? "Illegal function call" : formatNumber(log(r.val))
            } || did

            did = replaceFirst(name: "ATN") { a in
                guard a.count == 1 else { return nil }
                let r = toNum(a[0]); if !r.ok { return r.err }
                return formatNumber(atan(r.val))
            } || did

            if !did { break }
        }

        return s
    }

    // MARK: - evaluateExpression
    // Évalue une expression MSX-BASIC en renvoyant soit une chaîne (sans guillemets),
    // soit un nombre formaté (via formatNumber), soit un message d’erreur.
    //
    // Pipeline (chapitres) :
    //  1) Littéral chaîne BASIC pur
    //  2) Nettoyages/normalisations
    //  3) Comparaison chaîne simple  A$="HELLO"
    //  4) Appels "purs" LEFT$/RIGHT$/MID$/LEN (retour direct)
    //  5) Vérifs parenthèses
    //  6) Substitutions tableaux
    //  7) Substitutions variables (texte puis numériques)
    //  7.4) Fonctions chaîne (CHR$/LEFT$/RIGHT$/MID$/STR$) → "..."
    //
    //  7.5) Fonctions numériques (VAL/LEN/ASC/INSTR) → littéraux
    //  8) Normalisation opérateurs (= → ==, <> → !=)
    //  9) Fins/débuts invalides
    // 10) Quotes appariées
    // 10.1) Retrait parenthèses englobantes
    // 10.5) Concaténation de chaînes top-level "a"+"b"
    // 10.6) Logique bitwise 16-bit : IMP/EQV/XOR/OR/AND/NOT
    // 10.7) Comparaisons top-level (numériques ou chaînes)
    // 14) Identifiants nus (texte / numérique)
    // 15) Évaluation arithmétique finale (promotion entiers → flottants)
    // MARK: - evaluateExpression
    // Évalue une expression MSX-BASIC en renvoyant soit une chaîne (sans guillemets),
    // soit un nombre formaté (via formatNumber), soit un message d’erreur.
    func evaluateExpression(_ expr: String) -> String {
        elog("[eval] Reçu : '\(expr)'")
        evalDepth += 1
        defer { evalDepth -= 1 }
        
        // ⚠️ Propagation immédiate de messages d'erreur déjà formés
        let fatalErrors: Set<String> = [
            "Syntax error",
            "Incorrect number of arguments",
            "Illegal function call",
            "Subscript out of range",
            "__UNDIMENSIONED__"
        ]
        if fatalErrors.contains(expr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            elog("[eval] Erreur fatale propagée telle quelle: '\(expr)'")
            return expr.trimmingCharacters(in: .whitespacesAndNewlines)
        }


        // 1) Littéral chaîne BASIC pur ("" interne autorisé)
        if let decoded = decodeBasicStringLiteral(expr) {
            elog("[eval] Littéral chaîne BASIC -> '\(decoded)'")
            return decoded
        }

        // 2) Nettoyages / normalisations (espaces, × ÷)
        var cleanedExpr = expr
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .trimmingCharacters(in: .whitespaces)

        

        // Normalisation d’appels (LEFT/RIGHT/MID/LEN/CHR$/ASC/STR$/VAL/INSTR) avec espaces optionnels
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"LEFT\$\s*\("#,  with: "LEFT$(",  options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"RIGHT\$\s*\("#, with: "RIGHT$(", options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"MID\$\s*\("#,   with: "MID$(",   options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"LEN\s*\("#,     with: "LEN(",    options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"CHR\$\s*\("#,   with: "CHR$(",   options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"ASC\s*\("#,     with: "ASC(",    options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"STR\$\s*\("#,   with: "STR$(",   options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"VAL\s*\("#,     with: "VAL(",    options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"INSTR\s*\("#,   with: "INSTR(",  options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"HEX\$\s*\("#, with: "HEX$(", options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"BIN\$\s*\("#, with: "BIN$(", options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"OCT\$\s*\("#, with: "OCT$(", options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"STRING\$\s*\("#, with: "STRING$(", options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"SPACE\$\s*\("#, with: "SPACE$(", options: .regularExpression)

        // alias sans $
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"(?<![A-Z0-9\$])LEFT\s*\("#,  with: "LEFT$(", options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"(?<![A-Z0-9\$])RIGHT\s*\("#, with: "RIGHT$(", options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"(?<![A-Z0-9\$])CHR\s*\("#,   with: "CHR$(", options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"(?<![A-Z0-9\$])STR\s*\("#,   with: "STR$(", options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"(?<![A-Z0-9\$])OCT\s*\("#, with: "OCT$(", options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"(?<![A-Z0-9\$])STRING\s*\("#, with: "STRING$(", options: .regularExpression)
        cleanedExpr = cleanedExpr.replacingOccurrences(of: #"(?<![A-Z0-9\$])SPACE\s*\("#,  with: "SPACE$(",  options: .regularExpression)

        cleanedExpr = uppercaseOutsideQuotes(cleanedExpr)
        elog("[eval] cleanedExpr = '\(cleanedExpr)'")
        
        // 2.6) Concaténation implicite : "ABC"SPACE$(10)"DEF" -> "ABC"+SPACE$(10)+"DEF"
        var implicitConcat2 = ""
        var lastChar: Character? = nil
        var inQuotes = false

        for ch in cleanedExpr {
            if !inQuotes, let prev = lastChar {
                if prev == "\"" && (ch.isLetter || ch == "\"" || ch == "(") {
                    implicitConcat2.append("+")
                }
                if prev == ")" && (ch.isLetter || ch == "\"") {
                    implicitConcat2.append("+")
                }
            }
            implicitConcat2.append(ch)
            if ch == "\"" {
                inQuotes.toggle()
            }
            lastChar = ch
        }


        cleanedExpr = implicitConcat2
        elog("[eval] Après concat implicite = '\(cleanedExpr)'")






        // 3) Comparaison chaîne simple A$="HELLO" (égalité simple au niveau top)
        let quoteCountInitial = cleanedExpr.filter { $0 == "\"" }.count
        if quoteCountInitial == 2,                // exactement deux guillemets
           !cleanedExpr.contains("=="),           // pas déjà une comparaison normalisée
           !cleanedExpr.contains("<>"),
           let eqIndex = topLevelSingleEqualsIndex(cleanedExpr) {   // <= ICI le helper
            let lhs = String(cleanedExpr[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let rhs = String(cleanedExpr[cleanedExpr.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            let lhsValue = evaluateExpression(lhs)
            let rhsValue = evaluateExpression(rhs)
            let res = (lhsValue == rhsValue) ? "-1" : "0"
            elog("[eval] Comparaison chaîne simple: '\(lhsValue)' = '\(rhsValue)' -> \(res)")
            return res
        }


        // 4) Appels purs LEFT$/RIGHT$/MID$/LEN/CHR$/STR$
        if let result = handleLeftRightMidLen(cleanedExpr) {
            elog("[eval] LEFT/RIGHT/MID$/LEN -> '\(result)'")
            return result
        }
        

        // 5) Parenthèses équilibrées
        var balance = 0
        for ch in cleanedExpr {
            if ch == "(" { balance += 1 }
            if ch == ")" { balance -= 1 }
            if balance < 0 { elog("[eval] Parenthèse fermante en trop"); return "Syntax error" }
        }
        if balance != 0 { elog("[eval] Parenthèses non équilibrées"); return "Syntax error" }
        
        //compteur global de depth sur les expansions, coupe au-delà d’un seuil (ex. 64) en renvoyant Overflow ou Syntax error.
        guard fnExpandDepth < 64 else { return "Overflow" }
        fnExpandDepth += 1
        defer { fnExpandDepth -= 1 }
        
        // 5.5) Expansion des fonctions utilisateur FN... AVANT tableaux/variables
        if let expanded = expandUserFnOnce(cleanedExpr) {
            let t = expanded.trimmingCharacters(in: .whitespacesAndNewlines)   // ← normalisation
            if t == "Syntax error"
                || t == "__UNDIMENSIONED__"
                || t == "Subscript out of range"
                || t == "Incorrect number of arguments" {
                return t                                                      // ← renvoie la version trim
            }
            // sinon, on réévalue l’expression expandée (gère FN imbriqués/multiples)
            return evaluateExpression(expanded)
        }


        
        // Remplacer TIME (hors guillemets) par sa valeur courante en ticks
        cleanedExpr = cleanedExpr.replacingOccurrences(
            of: #"(?<!\w)TIME(?!\w)"#,
            with: formatNumber(Double(readTIME())),
            options: .regularExpression
        )
        elog("[eval] cleanedExpr = '\(cleanedExpr)'")

        // 6) Substitutions tableaux
        cleanedExpr = substituteNumericArrays(in: cleanedExpr)
        cleanedExpr = substituteStringArrays(in: cleanedExpr)
        if cleanedExpr.contains("Syntax error") || cleanedExpr.contains("Subscript out of range") {
            elog("[eval] Propagation erreur: '\(cleanedExpr)'")
            return cleanedExpr
        }

        // 7) Substitution variables
        for (name, value) in varText.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: name) + "(?!\\w)"
            cleanedExpr = cleanedExpr.replacingOccurrences(of: pattern, with: "\"\(value)\"", options: .regularExpression)
        }
        for (name, value) in variables {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
            cleanedExpr = cleanedExpr.replacingOccurrences(of: pattern, with: "\(value)", options: .regularExpression)
        }

        // 7.4) Fonctions chaîne → "..."
        let subS = substituteStringFunctions(in: cleanedExpr)
        if subS == "Syntax error" || subS == "Illegal function call" {
            return subS
        }
        cleanedExpr = subS

        // 7.5) Fonctions numériques (VAL/LEN/ASC/INSTR) → littéraux
        let sub = substituteNumericFunctions(in: cleanedExpr)
        if sub == "Syntax error" || sub == "Subscript out of range" || sub == "__UNDIMENSIONED__" {
            elog("[eval] Erreur pendant substitution fonctions numériques: '\(sub)'")
            return sub
        }
        cleanedExpr = sub
        
        // 7.6) Fonctions numériques MSX anywhere (ABS/SGN/…/RND)
        let sub2 = substituteMsxNumericFunctions(in: cleanedExpr)
        if sub2 == "Syntax error" || sub2 == "Illegal function call" || sub2 == "Overflow" {
            return sub2
        }
        cleanedExpr = sub2

       
        // 8) Normalisation opérateurs (= → == ; <> → !=) en respectant les guillemets
        cleanedExpr = cleanedExpr.replacingOccurrences(of: "<>", with: "!=")
        cleanedExpr = normalizeEqualsOutsideQuotes(cleanedExpr)
     

        elog("[eval] Après substitution/normalisation : '\(cleanedExpr)'")

        // 9) Fins/débuts invalides
        let invalidEnd = ["+", "-", "*", "/", "=", ">", "<", "!", "==", "!=", ">=", "<="]
        if invalidEnd.contains(where: { cleanedExpr.hasSuffix($0) }) { return "Syntax error" }
        let invalidStart = ["=", ">", "<", "!"]
        if invalidStart.contains(where: { cleanedExpr.hasPrefix($0) }) { return "Syntax error" }

        // 10) Paires de guillemets
        let totalQuotes = cleanedExpr.filter { $0 == "\"" }.count
        if totalQuotes % 2 != 0 { return "Syntax error" }

        // 10.1) Retrait parenthèses englobantes
        let stripped = stripOuterParentheses(cleanedExpr)
        if stripped != cleanedExpr { cleanedExpr = stripped }

        // 10.5) Concaténation de chaînes top-level "a"+"b"
        let stringConcatPattern = #"^"([^"]*)"(\s*\+\s*"[^"]*")*$"#
        if cleanedExpr.range(of: stringConcatPattern, options: .regularExpression) != nil {
            let parts = cleanedExpr.split(separator: "+", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            var result = ""
            for p in parts {
                if p.hasPrefix("\""), p.hasSuffix("\""), p.count >= 2 {
                    result += String(p.dropFirst().dropLast())
                } else if !p.isEmpty {
                    return "Syntax error"
                }
            }
            return result
        }
        // 10.55) MSX: priorité * /  >  MOD(%)  >  + -
        do {
            let uTop = uppercaseOutsideQuotes(cleanedExpr)
            if uTop.contains("MOD") || uTop.contains("%") {
                // 1) On découpe d'abord en termes additifs top-level: + / -
                let terms = splitAdditiveTopLevel(cleanedExpr)
                if !terms.isEmpty {
                    var total: Double = 0.0

                    // Helper: réduit * et / dans une sous-expression (pas MOD ici)
                    func reduceMulDiv(_ segment: String) -> (ok: Bool, val: Double, err: String?) {
                        let toks = tokenizeMultiplicativeLevel(segment)
                        if toks.isEmpty {
                            // Segment vide → 0
                            return (true, 0.0, nil)
                        }
                        // Premier facteur
                        func toDouble(_ s: String) -> (ok: Bool, val: Double, err: String?) {
                            let vStr = evaluateExpression(s)
                            let fats = ["Syntax error","__UNDIMENSIONED__","Subscript out of range",
                                        "Division by zero","Overflow","Type mismatch"]
                            if fats.contains(vStr) { return (false, 0.0, vStr) }
                            let norm = vStr.replacingOccurrences(of: ",", with: ".")
                            guard let d = Double(norm) else { return (false, 0.0, "Type mismatch") }
                            return (true, d, nil)
                        }
                        let first = toDouble(toks[0])
                        if !first.ok { return first }
                        var acc = first.val
                        var i = 1
                        while i + 1 < toks.count {
                            let op = toks[i]
                            let rhsE = toDouble(toks[i+1])
                            if !rhsE.ok { return rhsE }
                            let rhs = rhsE.val
                            if op == "*" { acc *= rhs }
                            else if op == "/" {
                                if rhs == 0 { return (false, 0.0, "Division by zero") }
                                acc /= rhs
                            } else {
                                return (false, 0.0, "Syntax error")
                            }
                            i += 2
                        }
                        return (true, acc, nil)
                    }

                    // 2) Pour chaque terme additif: on réduit d'abord * / dans chaque "morceau" séparé par MOD,
                    //    puis on applique MOD gauche→droite (troncature du quotient vers 0).
                    for (sgn, term) in terms {
                        let modToks = splitModLevel(term)
                        if modToks.count == 0 {
                            continue
                        }
                        // format attendu: factor [MOD factor]...
                        // on réduit chaque factor (mul/div)
                        var redVals: [Double] = []
                        var j = 0
                        while j < modToks.count {
                            let piece = modToks[j]
                            if piece == "MOD" { j += 1; continue }
                            let r = reduceMulDiv(piece)
                            if !r.ok { return r.err! }
                            redVals.append(r.val)
                            j += 1
                        }
                        // Appliquer MOD si présent
                        var termVal = redVals.first ?? 0.0
                        // parcours des opérateurs: positions 1,3,5... de modToks
                        j = 1
                        var k = 1 // index dans redVals
                        while j < modToks.count && k < redVals.count {
                            // modToks[j] devrait être "MOD"
                            let rhs = redVals[k]
                            if rhs == 0 { return "Division by zero" }
                            let q = termVal / rhs
                            let qTrunc = (q < 0) ? ceil(q) : floor(q) // tronqué vers 0
                            termVal = termVal - qTrunc * rhs
                            j += 2
                            k += 1
                        }

                        // 3) Accumuler dans la somme globale selon le signe du terme
                        total += (sgn == "-") ? -termVal : termVal
                    }

                    return formatNumber(total)
                }
            }
        }
        // 10.55) Exponentiation ^ (associativité GAUCHE, plus prioritaire que * / MOD)
        if let parts = splitTopLevelByCaret(cleanedExpr), parts.count > 1 {
            let MSX_MAX: Double = 1.7014118e38
            func toDouble(_ s: String) -> (ok: Bool, val: Double, err: String?) {
                let vs = evaluateExpression(s)
                let fatals: Set<String> = ["Syntax error","__UNDIMENSIONED__","Subscript out of range",
                                           "Division by zero","Overflow","Type mismatch","Undimensioned array"]
                if fatals.contains(vs) { return (false, 0.0, vs) }
                let norm = vs.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
                guard let d = Double(norm) else { return (false, 0.0, "Type mismatch") }
                return (true, d, nil)
            }
          
            // Base (partie la plus à gauche) : retirer le signe, à appliquer après
            var baseExpr = parts[0].trimmingCharacters(in: .whitespaces)
            var signFactor: Double = 1.0
            if baseExpr.hasPrefix("+") { baseExpr.removeFirst() }
            else if baseExpr.hasPrefix("-") { baseExpr.removeFirst(); signFactor = -1.0 }

            let b0 = toDouble(baseExpr)
            if !b0.ok { return b0.err! }
            var acc = b0.val

            // Associativité GAUCHE : ((a^b)^c)^d...
            if parts.count >= 2 {
                for i in 1..<parts.count {
                    let e = toDouble(parts[i].trimmingCharacters(in: .whitespaces))
                    if !e.ok { return e.err! }

                    let powVal = pow(acc, e.val)

                    // Contrôles intermédiaires (mapping MSX)
                    if powVal.isNaN { return "Illegal function call" }     // ex: base<0 ^ exposant non entier
                    if !powVal.isFinite || abs(powVal) > MSX_MAX { return "Overflow" }

                    acc = powVal
                }
            }

            // Appliquer le signe unaire initial à la toute fin
            acc *= signFactor

            // Contrôles finaux (à conserver)
            if acc.isNaN { return "Illegal function call" }
            if !acc.isFinite || abs(acc) > MSX_MAX { return "Overflow" }

            return formatNumber(acc)
        }




        // 10.6) Logique bitwise 16-bit (ordre: NOT > AND > OR/XOR/EQV/IMP)
        if let parts = splitTopLevel(cleanedExpr, keyword: "IMP"), parts.count > 1 {
            return foldMSX16(parts) { x, y in (~x) | y }
        }
        if let parts = splitTopLevel(cleanedExpr, keyword: "EQV"), parts.count > 1 {
            return foldMSX16(parts) { x, y in ~(x ^ y) }
        }
        if let parts = splitTopLevel(cleanedExpr, keyword: "XOR"), parts.count > 1 {
            return foldMSX16(parts) { x, y in x ^ y }
        }
        if let parts = splitTopLevel(cleanedExpr, keyword: "OR"), parts.count > 1 {
            return foldMSX16(parts) { x, y in x | y }
        }
        if let parts = splitTopLevel(cleanedExpr, keyword: "AND"), parts.count > 1 {
            return foldMSX16(parts) { x, y in x & y }
        }
        if cleanedExpr.range(of: #"^NOT\b"#, options: [.regularExpression]) != nil {
            let afterNot = cleanedExpr.replacingOccurrences(of: #"^NOT\b"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard let v = toMSX16(evaluateExpression(afterNot)) else { return "Syntax error" }
            let res = ~v
            return formatNumber(Double(res))
        }

        // 10.7) Comparaisons top-level (numériques ou chaînes)
        // Raccourci : deux littéraux "..." OP "..."
        let stringComparePattern = #"^"([^"]*)" *(==|!=|=|<>|>=|<=|>|<) *"([^"]*)"$"#
        if let match = try? NSRegularExpression(pattern: stringComparePattern)
            .firstMatch(in: cleanedExpr, range: NSRange(cleanedExpr.startIndex..., in: cleanedExpr)),
           let lhsRange = Range(match.range(at: 1), in: cleanedExpr),
           let opRange  = Range(match.range(at: 2), in: cleanedExpr),
           let rhsRange = Range(match.range(at: 3), in: cleanedExpr) {

            let lhs = String(cleanedExpr[lhsRange])
            let rawOp = String(cleanedExpr[opRange])
            let rhs = String(cleanedExpr[rhsRange])

            let op = (rawOp == "<>") ? "!=" : (rawOp == "=" ? "==" : rawOp)

            let result: Bool
            switch op {
            case "==": result = (lhs == rhs)
            case "!=": result = (lhs != rhs)
            case  ">": result = (lhs >  rhs)
            case  "<": result = (lhs <  rhs)
            case ">=": result = (lhs >= rhs)
            case "<=": result = (lhs <= rhs)
            default:   return "Syntax error"
            }
            return result ? "-1" : "0"
        }


        if let (lhsCmp, rawOp, rhsCmp) = parseTopLevelComparison(cleanedExpr) {
            let op = (rawOp == "<>") ? "!=" : (rawOp == "=" ? "==" : rawOp)

            // Heuristique chaîne
            let looksString: (String) -> Bool = { side in
                if side.contains("\"") { return true }
                if side.range(of: #"^[A-Z][A-Z0-9]*\$$"#, options: .regularExpression) != nil { return true }
                if side.range(of: #"^[A-Z][A-Z0-9]*\$\(.+\)$"#, options: .regularExpression) != nil { return true }
                return false
            }
            if looksString(lhsCmp) || looksString(rhsCmp) {
                let lsv = evaluateExpression(lhsCmp)
                let rsv = evaluateExpression(rhsCmp)
                switch op {
                case "==": return (lsv == rsv) ? "-1" : "0"
                case "!=": return (lsv != rsv) ? "-1" : "0"
                case  ">": return (lsv >  rsv) ? "-1" : "0"
                case  "<": return (lsv <  rsv) ? "-1" : "0"
                case ">=": return (lsv >= rsv) ? "-1" : "0"
                case "<=": return (lsv <= rsv) ? "-1" : "0"
                default:   return "Syntax error"
                }
            }

            // Comparaison numérique
            let Ls = evaluateExpression(lhsCmp)
            let Rs = evaluateExpression(rhsCmp)
            guard let L = Double(Ls.replacingOccurrences(of: ",", with: ".")),
                  let R = Double(Rs.replacingOccurrences(of: ",", with: ".")) else { return "Type mismatch" }
            let ok: Bool
            switch op {
            case "==": ok = (L == R)
            case "!=": ok = (L != R)
            case ">=": ok = (L >= R)
            case "<=": ok = (L <= R)
            case ">":  ok = (L >  R)
            case "<":  ok = (L <  R)
            default:   return "Syntax error"
            }
            return ok ? "-1" : "0"
        }
        
        //
        if cleanedExpr.range(of: #"^[A-Z][A-Z0-9]*$"#, options: .regularExpression) != nil {
            let U = cleanedExpr.uppercased()
            if isReservedKeyword(U) { return "Syntax error" } // ⟵ au lieu de retourner 0
            let v = variables[U] ?? 0
            return formatNumber(v)
        }


        // 14) Identifiants nus
        if cleanedExpr.range(of: #"^[A-Z][A-Z0-9]*\$$"#, options: .regularExpression) != nil {
            return varText[cleanedExpr.uppercased()] ?? ""
        }
        if cleanedExpr.range(of: #"^[A-Z][A-Z0-9]*$"#, options: .regularExpression) != nil {
            let v = variables[cleanedExpr.uppercased()] ?? 0
            return formatNumber(v)
        }
        // Remplacer les littéraux &H.. / &B.. hors guillemets
        cleanedExpr = convertRadixLiteralsOutsideQuotes(cleanedExpr)

        // 15) Évaluation arithmétique finale — via NSExpression protégée
        var promoted = promoteIntegerLiteralsToDouble(cleanedExpr)

        // Supprimer tous les '+' unaires (début, après (, +, -, *, /, ,, ^)
        promoted = stripUnaryPluses(promoted)


        // ❶ Whitelist de base (autorise E/e pour la notation scientifique)
        if promoted.range(of: #"^[0-9Ee\.\+\-\*/\(\) \t]+$"#, options: .regularExpression) == nil {
            elog("[eval] invalid chars for arithmetic: '\(promoted)'")
            return "Type mismatch"
        }
        // ❷ Interdits simples
        if promoted.contains("..") {
            elog("[eval] invalid token '..' in: '\(promoted)'")
            return "Syntax error"
        }
        
        // ❸ Validation de la notation scientifique (si présente)
        let sciPattern = #"(?i)(?<![A-Z0-9_])(?:\d+(?:\.\d*)?|\.\d+)E\s*[+\-]?\s*\d+"#
        if promoted.contains("E") || promoted.contains("e") {
            let reduced = promoted.replacingOccurrences(of: sciPattern, with: "0", options: .regularExpression)
            if reduced.range(of: #"^[0-9Ee\.\+\-\*/\(\) \t]+$"#, options: .regularExpression) == nil {
                elog("[eval] malformed scientific notation in: '\(promoted)'")
                return "Syntax error"
            }
        }



        let expression = NSExpression(format: promoted)
        if let num = expression.expressionValue(with: nil, context: nil) as? NSNumber {
            let v = num.doubleValue

            // — Détections d’erreurs à la MSX —
            if v.isNaN || v.isInfinite {
                // Heuristique : si l’expression contient une division, on impute à /0
                return promoted.contains("/") ? "Division by zero" : "Overflow"
            }

            // Limite flottant MSX (~SINGLE)
            let MSX_MAX: Double = 1.7014118e38
            if abs(v) > MSX_MAX {
                return "Overflow"
            }

            // OK : format MSX habituel
            return formatNumber(v)
        } else {
            // À ce stade, la whitelist arithmétique est passée ; l’échec → incohérence de types
            return "Type mismatch"
        }

        //return "Syntax error"
    }

    private func stripUnaryPluses(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0

        func isOp(_ c: Character?) -> Bool {
            guard let c = c else { return true } // début de chaîne => unaire
            return c == "+" || c == "-" || c == "*" || c == "/" || c == "(" || c == "," || c == "^"
        }

        while i < chars.count {
            let c = chars[i]
            if c == "+" {
                // cherche le précédent non-espace
                var j = i - 1
                var prev: Character? = nil
                while j >= 0 {
                    if !chars[j].isWhitespace { prev = chars[j]; break }
                    j -= 1
                }
                if isOp(prev) {
                    // '+' unaire -> on l’ignore
                    i += 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }


    private func substituteNumericFunctions(in expr: String) -> String {
        var s = expr
        func splitArgsTopLevel(_ inside: String) -> [String] {
            var out: [String] = []
            var cur = ""
            var inStr = false
            var paren = 0
            for ch in inside {
                if ch == "\"" { inStr.toggle(); cur.append(ch); continue }
                if !inStr {
                    if ch == "(" { paren += 1; cur.append(ch); continue }
                    if ch == ")" { paren = max(0, paren - 1); cur.append(ch); continue }
                    if paren == 0 && ch == "," {
                        out.append(cur.trimmingCharacters(in: .whitespaces))
                        cur.removeAll(keepingCapacity: true)
                        continue
                    }
                }
                cur.append(ch)
            }
            let tail = cur.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty || !inside.isEmpty { out.append(tail) }
            return out
        }
        func replaceFirst(name: String, compute: ([String]) -> String?) -> Bool {
            let chars = Array(s)
            var inStr = false
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c == "\"" { inStr.toggle(); i += 1; continue }
                if !inStr {
                    if i + name.count < chars.count {
                        let slice = String(chars[i..<(i + name.count)]).uppercased()
                        if slice == name, i + name.count < chars.count, chars[i + name.count] == "(" {
                            var j = i + name.count + 1
                            var paren = 1
                            var inStr2 = false
                            while j < chars.count {
                                let cj = chars[j]
                                if cj == "\"" { inStr2.toggle(); j += 1; continue }
                                if !inStr2 {
                                    if cj == "(" { paren += 1 }
                                    else if cj == ")" { paren -= 1; if paren == 0 { break } }
                                }
                                j += 1
                            }
                            if j >= chars.count { return false }
                            let inside = String(chars[(i + name.count + 1)..<j])
                            let args = splitArgsTopLevel(inside)
                            guard let rep = compute(args) else { s = "Syntax error"; return true }
                            let prefix = String(chars[0..<i])
                            let suffix = String(chars[(j + 1)...])
                            s = prefix + rep + suffix
                            return true
                        }
                    }
                }
                i += 1
            }
            return false
        }

        while true {
            var did = false
            did = replaceFirst(name: "VAL", compute: { args in
                guard args.count == 1 else { return nil }
                var str = evaluateExpression(args[0]).trimmingCharacters(in: .whitespaces)

                // Signe optionnel en tête
                var sign: Double = 1
                if let first = str.first, first == "+" || first == "-" {
                    if first == "-" { sign = -1 }
                    str.removeFirst()
                    str = str.trimmingCharacters(in: .whitespaces)
                }

                // Support MSX-like: &Hxxx, &Bxxx et &Oxxx  au début de la chaîne
                // &H...
                if str.hasPrefix("&H") || str.hasPrefix("&h") {
                    let digitsSub = String(str.dropFirst(2)).prefix(while: { "0123456789ABCDEFabcdef".contains($0) })
                    guard !digitsSub.isEmpty else { return formatNumber(0) }
                    let v = UInt64(String(digitsSub), radix: 16) ?? 0
                    let s16 = Int16(bitPattern: UInt16(truncatingIfNeeded: v))
                    return formatNumber(sign * Double(s16))
                }

                // &B...
                if str.hasPrefix("&B") || str.hasPrefix("&b") {
                    let digitsSub = String(str.dropFirst(2)).prefix(while: { "01".contains($0) })
                    guard !digitsSub.isEmpty else { return formatNumber(0) }
                    let v = UInt64(String(digitsSub), radix: 2) ?? 0
                    let s16 = Int16(bitPattern: UInt16(truncatingIfNeeded: v))
                    return formatNumber(sign * Double(s16))
                }

                // &O...  (si tu as ajouté l’octal)
                if str.hasPrefix("&O") || str.hasPrefix("&o") {
                    let digitsSub = String(str.dropFirst(2)).prefix(while: { "01234567".contains($0) })
                    guard !digitsSub.isEmpty else { return formatNumber(0) }
                    let v = UInt64(String(digitsSub), radix: 8) ?? 0
                    let s16 = Int16(bitPattern: UInt16(truncatingIfNeeded: v))
                    return formatNumber(sign * Double(s16))
                }



                // Sinon, VAL classique (décimal, préfixe numérique maximal)
                str = str.replacingOccurrences(of: ",", with: ".")
                var i = str.startIndex
                if i < str.endIndex, (str[i] == "+" || str[i] == "-") { i = str.index(after: i) }
                var j = i
                var sawDigit = false
                var sawDot = false
                while j < str.endIndex {
                    let ch = str[j]
                    if ch.isNumber { sawDigit = true; j = str.index(after: j); continue }
                    if ch == ".", !sawDot { sawDot = true; j = str.index(after: j); continue }
                    break
                }
                if !sawDigit { return formatNumber(0) }
                let prefix = String(str[str.startIndex..<j])
                let num = Double(prefix) ?? 0.0
                return formatNumber(num)
            }) || did

            did = replaceFirst(name: "LEN", compute: { args in
                guard args.count == 1 else { return nil }
                let s = evaluateExpression(args[0])
                return formatNumber(Double(s.count))
            }) || did

            did = replaceFirst(name: "ASC", compute: { args in
                guard args.count == 1 else { return nil }
                let s = evaluateExpression(args[0])
                if s.isEmpty { return formatNumber(0) }
                let code = Int(s.unicodeScalars.first!.value) % 256
                return formatNumber(Double(code))
            }) || did

            did = replaceFirst(name: "INSTR", compute: { args in
                guard args.count == 2 || args.count == 3 else { return nil }
                let start: Int
                let hay: String
                let needle: String
                if args.count == 2 {
                    start = 1
                    hay = evaluateExpression(args[0])
                    needle = evaluateExpression(args[1])
                } else {
                    guard let st = Int(evaluateExpression(args[0])) else { return nil }
                    start = max(1, st)
                    hay = evaluateExpression(args[1])
                    needle = evaluateExpression(args[2])
                }
                if needle.isEmpty { return formatNumber(1) }
                if start > hay.count { return formatNumber(0) }
                let idx = hay.index(hay.startIndex, offsetBy: start - 1)
                if let r = hay[idx...].range(of: needle) {
                    let pos = hay.distance(from: hay.startIndex, to: r.lowerBound) + 1
                    return formatNumber(Double(pos))
                }
                return formatNumber(0)
            }) || did

            if !did { break }
        }
        return s
    }

    private func substituteStringFunctions(in expr: String) -> String {
        var s = expr
        func splitArgsTopLevel(_ inside: String) -> [String] {
            var out: [String] = [], cur = ""
            var inStr = false, paren = 0
            for ch in inside {
                if ch == "\"" { inStr.toggle(); cur.append(ch); continue }
                if !inStr {
                    if ch == "(" { paren += 1; cur.append(ch); continue }
                    if ch == ")" { paren = max(0, paren - 1); cur.append(ch); continue }
                    if paren == 0 && ch == "," {
                        out.append(cur.trimmingCharacters(in: .whitespaces))
                        cur.removeAll(keepingCapacity: true)
                        continue
                    }
                }
                cur.append(ch)
            }
            let tail = cur.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty || !inside.isEmpty { out.append(tail) }
            return out
        }
        
        func replaceFirst(name: String, compute: ([String]) -> String?) -> Bool {
            let chars = Array(s)
            var inStr = false, i = 0
            while i < chars.count {
                let c = chars[i]
                if c == "\"" { inStr.toggle(); i += 1; continue }
                if !inStr, i + name.count < chars.count {
                    if String(chars[i..<(i+name.count)]).uppercased() == name,
                       i + name.count < chars.count, chars[i+name.count] == "(" {
                        var j = i + name.count + 1, paren = 1, inStr2 = false
                        while j < chars.count {
                            let cj = chars[j]
                            if cj == "\"" { inStr2.toggle(); j += 1; continue }
                            if !inStr2 {
                                if cj == "(" { paren += 1 }
                                else if cj == ")" { paren -= 1; if paren == 0 { break } }
                            }
                            j += 1
                        }
                        if j >= chars.count { return false }
                        let inside = String(chars[(i+name.count+1)..<j])
                        let args = splitArgsTopLevel(inside)
                        guard let rep = compute(args) else { s = "Syntax error"; return true }
                        s = String(chars[0..<i]) + rep + String(chars[(j+1)...])
                        return true
                    }
                }
                i += 1
            }
            return false
        }
        while true {
            var did = false
            did = replaceFirst(name: "CHR$", compute: { args in
                guard args.count == 1, let n = Double(evaluateExpression(args[0])) else { return nil }
                var code = Int(n); code = (code % 256 + 256) % 256
                guard let sc = UnicodeScalar(code) else { return nil }
                return "\"\(String(Character(sc)))\""
            }) || did
            did = replaceFirst(name: "LEFT$", compute: { args in
                guard args.count == 2, let n = Int(evaluateExpression(args[1])), n >= 0 else { return nil }
                let src = evaluateExpression(args[0]); return "\"\(String(src.prefix(n)))\""
            }) || did
            did = replaceFirst(name: "RIGHT$", compute: { args in
                guard args.count == 2, let n = Int(evaluateExpression(args[1])), n >= 0 else { return nil }
                let src = evaluateExpression(args[0]); return "\"\(String(src.suffix(n)))\""
            }) || did
            did = replaceFirst(name: "MID$", compute: { args in
                guard args.count == 3,
                      let st = Int(evaluateExpression(args[1])),
                      let ln = Int(evaluateExpression(args[2])),
                      st >= 1, ln >= 0 else { return nil }
                let src = evaluateExpression(args[0])
                if st > src.count { return "\"\"" }
                let a = src.index(src.startIndex, offsetBy: st - 1)
                let b = src.index(a, offsetBy: min(ln, src.distance(from: a, to: src.endIndex)))
                return "\"\(String(src[a..<b]))\""
            }) || did
            did = replaceFirst(name: "STR$", compute: { args in
                guard args.count == 1, let x = Double(evaluateExpression(args[0])) else { return nil }
                return "\"\(formatNumberForPrint(x))\""
            }) || did
            did = replaceFirst(name: "HEX$", compute: { args in
                guard args.count == 1,
                      let x = Double(evaluateExpression(args[0])) else { return nil }
                let v16 = Int16(truncatingIfNeeded: Int(x))
                let u16 = UInt16(bitPattern: v16)
                let raw = String(u16, radix: 16, uppercase: true)
                // Retirer uniquement les zéros de tête
                let out: String = {
                    var s = raw
                    while s.first == "0" && s.count > 1 { s.removeFirst() }
                    return s
                }()
                return "\"\(out)\""
            }) || did

            did = replaceFirst(name: "BIN$", compute: { args in
                guard args.count == 1,
                      let x = Double(evaluateExpression(args[0])) else { return nil }
                let v16 = Int16(truncatingIfNeeded: Int(x))
                let u16 = UInt16(bitPattern: v16)
                let raw = String(u16, radix: 2)
                // Retirer uniquement les zéros de tête
                let out: String = {
                    var s = raw
                    while s.first == "0" && s.count > 1 { s.removeFirst() }
                    return s
                }()
                return "\"\(out)\""
            }) || did
            did = replaceFirst(name: "OCT$", compute: { args in
                guard args.count == 1,
                      let x = Double(evaluateExpression(args[0])) else { return nil }
                let v16 = Int16(truncatingIfNeeded: Int(x))
                let u16 = UInt16(bitPattern: v16)
                let raw = String(u16, radix: 8) // base 8
                // Retirer uniquement les zéros de tête
                let out: String = {
                    var s = raw
                    while s.first == "0" && s.count > 1 { s.removeFirst() }
                    return s
                }()
                return "\"\(out)\""
            }) || did
            // STRING$(n, c) : c peut être un nombre (code ASCII) ou une chaîne (on prend le 1er char)
            did = replaceFirst(name: "STRING$", compute: { args in
                guard args.count == 2,
                      let n = Int(evaluateExpression(args[0])),
                      n >= 0 else { return nil }

                let second = evaluateExpression(args[1])

                // numérique -> code ASCII (0..255, wrap comme CHR$)
                if let d = Double(second.replacingOccurrences(of: ",", with: ".")) {
                    var code = Int(d)
                    code = (code % 256 + 256) % 256
                    guard let sc = UnicodeScalar(code) else { return "Illegal function call" }
                    let ch = Character(sc)
                    let rep = String(repeating: ch, count: n)
                    return "\"\(rep)\""
                } else {
                    // chaîne -> premier caractère (tolère vide)
                    if second.isEmpty { return "Illegal function call" }
                    let rep = String(repeating: second.first!, count: n)
                    return "\"\(rep)\""
                }

            }) || did

            // SPACE$(n)
            did = replaceFirst(name: "SPACE$", compute: { args in
                guard args.count == 1,
                      let n = Int(evaluateExpression(args[0])),
                      n >= 0 else { return nil }
                return "\"\(String(repeating: " ", count: n))\""
            }) || did

            if !did { break }
        }
        return s
    }

    private func handleLeftRightMidLen(_ expr: String) -> String? {
        func isPureCall(_ from: String) -> Bool {
            guard let open = from.firstIndex(of: "("),
                  let close = from.lastIndex(of: ")"),
                  open < close else { return false }
            let after = from[from.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return after.isEmpty
        }
        let upper = expr.uppercased()
        func extractArgsTopLevel(_ from: String, expectedMin: Int, expectedMax: Int? = nil) -> [String]? {
            guard let open = from.firstIndex(of: "("),
                  let close = from.lastIndex(of: ")"),
                  open < close else { return nil }
            let inside = String(from[from.index(after: open)..<close])
            var args: [String] = [], cur = ""
            var inStr = false, paren = 0
            for ch in inside {
                if ch == "\"" { inStr.toggle(); cur.append(ch); continue }
                if !inStr {
                    if ch == "(" { paren += 1; cur.append(ch); continue }
                    if ch == ")" { paren = max(0, paren - 1); cur.append(ch); continue }
                    if paren == 0 && ch == "," {
                        args.append(cur.trimmingCharacters(in: .whitespaces))
                        cur.removeAll(keepingCapacity: true)
                        continue
                    }
                }
                cur.append(ch)
            }
            let tail = cur.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty || !inside.isEmpty { args.append(tail) }
            if args.count < expectedMin { return nil }
            if let mx = expectedMax, args.count > mx { return nil }
            return args
        }

        if upper.hasPrefix("LEFT$(") {
            guard isPureCall(expr),
                  let args = extractArgsTopLevel(expr, expectedMin: 2, expectedMax: 2),
                  let n = Int(evaluateExpression(args[1])), n >= 0 else { return nil }
            let s = evaluateExpression(args[0])
            return String(s.prefix(n))
        }
        if upper.hasPrefix("RIGHT$(") {
            guard isPureCall(expr),
                  let args = extractArgsTopLevel(expr, expectedMin: 2, expectedMax: 2),
                  let n = Int(evaluateExpression(args[1])), n >= 0 else { return nil }
            let s = evaluateExpression(args[0])
            return String(s.suffix(n))
        }
        if upper.hasPrefix("MID$(") {
            guard isPureCall(expr),
                  let args = extractArgsTopLevel(expr, expectedMin: 3, expectedMax: 3),
                  let st = Int(evaluateExpression(args[1])),
                  let ln = Int(evaluateExpression(args[2])),
                  st >= 1, ln >= 0 else { return nil }
            let s = evaluateExpression(args[0])
            if st > s.count { return "" }
            let a = s.index(s.startIndex, offsetBy: st - 1)
            let b = s.index(a, offsetBy: min(ln, s.distance(from: a, to: s.endIndex)))
            return String(s[a..<b])
        }
        if upper.hasPrefix("LEN(") {
            guard isPureCall(expr),
                  let args = extractArgsTopLevel(expr, expectedMin: 1, expectedMax: 1)
            else { return nil }
            let s = evaluateExpression(args[0])
            return formatNumber(Double(s.count))
        }
        if upper.hasPrefix("CHR$(") {
            guard isPureCall(expr),
                  let args = extractArgsTopLevel(expr, expectedMin: 1, expectedMax: 1),
                  let d = Double(evaluateExpression(args[0])) else { return nil }
            var code = Int(d); code = (code % 256 + 256) % 256
            guard let sc = UnicodeScalar(code) else { return nil }
            return String(Character(sc))
        }
        if upper.hasPrefix("STR$(") {
            guard isPureCall(expr),
                  let args = extractArgsTopLevel(expr, expectedMin: 1, expectedMax: 1),
                  let x = Double(evaluateExpression(args[0])) else { return nil }
            return formatNumber(x)
        }
        return nil
    }
    
    private func handleDefFn(_ trimmed: String) -> String {
        // DEF FNX(A,B,C,D)=...
        let after = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard after.uppercased().hasPrefix("FN") else { return "Syntax error" }
        let defPart = after.dropFirst(2).trimmingCharacters(in: .whitespaces)

        guard let eq = defPart.firstIndex(of: "=") else { return "Syntax error" }
        let left  = defPart[..<eq].trimmingCharacters(in: .whitespaces)
        let right = String(defPart[defPart.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

        guard let open = left.firstIndex(of: "("),
              let close = left.lastIndex(of: ")"),
              open < close else { return "Syntax error" }

        let fnName = String(left[..<open]).trimmingCharacters(in: .whitespaces).uppercased()
        guard fnName.range(of: #"^[A-Z][A-Z0-9]*$"#, options: .regularExpression) != nil else { return "Syntax error" }

        let inside = String(left[left.index(after: open)..<close])
        let rawParams = splitCsvTopLevelRespectingParens(inside)
        let params = rawParams.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }

        // Limite MSX confirmée : 1..8
        guard (1...8).contains(params.count) else { return "Incorrect number of arguments" }

        // Noms valides + pas de doublons
        var seen = Set<String>()
        for p in params {
            guard p.range(of: #"^[A-Z][A-Z0-9]*$"#, options: .regularExpression) != nil else {
                return "Syntax error"
            }
            if !seen.insert(p).inserted {
                return "Duplicate parameter name"
            }
        }

        userFunctions[fnName] = (params: params, body: right)
        elog("[DEF FN] Défini FN\(fnName)(\(params.joined(separator: ","))) = \(right)")
        return ""
    }


    private func handleDefFnString(_ trimmed: String) -> String {
        // DEF FNX$(A,B)=expression
        let after = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard after.uppercased().hasPrefix("FN") else { return "Syntax error" }
        let defPart = after.dropFirst(2).trimmingCharacters(in: .whitespaces)

        guard let eq = defPart.firstIndex(of: "=") else { return "Syntax error" }
        let left  = defPart[..<eq].trimmingCharacters(in: .whitespaces)
        let right = String(defPart[defPart.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

        guard let open = left.firstIndex(of: "("),
              let close = left.lastIndex(of: ")"),
              open < close else { return "Syntax error" }

        let fnName = String(left[..<open]).trimmingCharacters(in: .whitespaces).uppercased()
        guard fnName.hasSuffix("$") else { return "Syntax error" }

        let inside = String(left[left.index(after: open)..<close])
        let rawParams = splitCsvTopLevelRespectingParens(inside)
        let params = rawParams.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }

        guard (1...8).contains(params.count) else { return "Incorrect number of arguments" }

        // Même validation que pour la version numérique
        var seen = Set<String>()
        for p in params {
            //guard p.range(of: #"^[A-Z][A-Z0-9]*$"#, options: .regularExpression) != nil else {
            guard p.range(of: #"^[A-Z][A-Z0-9]*\$?$"#, options: .regularExpression) != nil else {
                return "Syntax error"
            }
            if !seen.insert(p).inserted {
                return "Duplicate parameter name"
            }
        }

        userStringFunctions[fnName] = (params: params, body: right)
        elog("[DEF FN$] Défini FN\(fnName)(\(params.joined(separator: ","))) = \(right)")
        return ""
    }

    private func substituteNumericArrays(in expr: String) -> String {
        var result = expr
        let pattern = #"(?<![A-Z0-9\$])([A-Z][A-Z0-9]*)\(([^()]*(?:\([^()]*\)[^()]*)*)\)"#
        let regex = try! NSRegularExpression(pattern: pattern)

        // Noms réservés à ignorer (fonctions num MSX + opérateurs logiques)
        var reservedNames: Set<String> = [
            "LEN","VAL","ASC","INSTR",
            "ABS","SGN","INT","FIX","SQR","RND",
            "SIN","COS","TAN","EXP","LOG","ATN",
            "NOT","AND","OR","XOR","EQV","IMP"
        ]
        // + fonctions utilisateur DEF FN...
        reservedNames.formUnion(userFunctions.keys.map { $0.uppercased() })

        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for m in matches.reversed() {
            guard let nameR = Range(m.range(at: 1), in: result),
                  let insideR = Range(m.range(at: 2), in: result) else { continue }
            let name = String(result[nameR]).uppercased()

            // ⛔️ Ne pas traiter comme tableau si nom réservé (fonction/opérateur)
            if reservedNames.contains(name) { continue }

            let inside = String(result[insideR])

            guard let idxs = parseIndicesList(inside) else { return "Syntax error" }
            //guard let dims = arrayDims[name], let arr = arrays[name] else { return "0" }
            // substituteNumericArrays : au lieu de `return "0"`
            guard let dims = arrayDims[name], let arr = arrays[name] else { return "__UNDIMENSIONED__" }

            guard let off = linearIndex(from: idxs, dims: dims), off < arr.count else { return "Subscript out of range" }

            let value = formatNumber(arr[off])
            let fullR = Range(m.range(at: 0), in: result)!
            result.replaceSubrange(fullR, with: value)
        }
        return result
    }

    private func substituteStringArrays(in expr: String) -> String {
        var result = expr
        let pattern = #"(?<![A-Z0-9\$])([A-Z][A-Z0-9]*\$)\(([^()]*(?:\([^()]*\)[^()]*)*)\)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        // Avant: let fnNames$: Set<String> = ["LEFT$","RIGHT$","MID$","CHR$","STR$","HEX$","BIN$","OCT$"]
        // Corrigé :
        let builtins: Set<String> = ["LEFT$","RIGHT$","MID$","CHR$","STR$","HEX$","BIN$","OCT$","SPACE$","STRING$"]
        let userFnNames: Set<String> = Set(userStringFunctions.keys.map { $0.uppercased() })
        let fnNames$ = builtins.union(userFnNames)


        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for m in matches.reversed() {
            guard let nameR = Range(m.range(at: 1), in: result),
                  let insideR = Range(m.range(at: 2), in: result) else { continue }
            let name = String(result[nameR]).uppercased()
            if fnNames$.contains(name) { continue }
            let inside = String(result[insideR])

            guard let idxs = parseIndicesList(inside) else { return "Syntax error" }
            //guard let dims = stringArrayDims[name], let arr = stringArrays[name] else { return "__UNDIMENSIONED__" }
            //guard let dims = stringArrayDims[name], let arr = stringArrays[name] else { return "\"\"" }
            // substituteStringArrays : au lieu de `return "\"\""`
            guard let dims = stringArrayDims[name], let arr = stringArrays[name] else { return "__UNDIMENSIONED__" }
            guard let off = linearIndex(from: idxs, dims: dims), off < arr.count else { return "Subscript out of range" }

            let value = arr[off]
            let fullR = Range(m.range(at: 0), in: result)!
            result.replaceSubrange(fullR, with: "\"\(value)\"")
        }
        return result
    }

   

    private func parseTopLevelComparison(_ s: String) -> (lhs: String, op: String, rhs: String)? {
        elog("[eval] parseTopLevelComparison (mono) sur: '\(s)'")
        let chars = Array(s)
        var inStr = false
        var paren = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { inStr.toggle(); i += 1; continue }
            if !inStr {
                if c == "(" { paren += 1; i += 1; continue }
                if c == ")" { paren = max(0, paren - 1); i += 1; continue }
            }
            guard !inStr && paren == 0 else { i += 1; continue }
            if i + 1 < chars.count {
                let pair = String([chars[i], chars[i+1]])
                switch pair {
                case "==", "!=", ">=", "<=", "<>":
                    let lhs = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                    let rhs = String(chars[(i+2)...]).trimmingCharacters(in: .whitespaces)
                    elog("[eval] op2 trouvé '\(pair)' lhs='\(lhs)' rhs='\(rhs)'")
                    return (lhs, pair, rhs)
                default: break
                }
            }
            if c == ">" || c == "<" || c == "=" {
                let lhs = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                let rhs = String(chars[(i+1)...]).trimmingCharacters(in: .whitespaces)
                let op = String(c)
                elog("[eval] op1 trouvé '\(op)' lhs='\(lhs)' rhs='\(rhs)'")
                return (lhs, op, rhs)
            }
            i += 1
        }
        elog("[eval] aucun opérateur top-level trouvé")
        return nil
    }

    private func clearAllUserState(_ reason: String) {
        let R = reason.uppercased()
        elog("[CLEAR] \(R) — effacement de l'état utilisateur")
        elog("[CLEAR] Avant: num=\(variables.count), arrNum=\(arrays.count), str=\(varText.count), arrStr=\(stringArrays.count), gosub=\(gosubStack.count), for=\(forStack.count)")

        // Autoriser un re-DIM une seule fois seulement pour CLEAR utilisateur
        let allowRedimOnce = (R == "IMMÉDIAT" || R == "IMMEDIAT" || R == "RUN")
        if allowRedimOnce {
            // capture des noms AVANT l'effacement des tableaux
            let numNames = Set(arrayDims.keys)
            let strNames = Set(stringArrayDims.keys)
            redimAllowedAfterClear = numNames.union(strNames)
        } else {
            redimAllowedAfterClear.removeAll()
        }

        // Scalars & runtime state
        variables.removeAll()
        varText.removeAll()
        gosubStack.removeAll()
        forStack.removeAll()
        awaitingInput = false
        inputVariable = nil
        pendingPrompt = nil
        resumeIndex = nil
        gotoTarget = nil
        deferredEnd = false
        inputCtx = nil
        resumeStatementIndex = nil
        forcedStatementIndex = nil

        // TIME like MSX
        timeSetMoment = Date()
        timeSetOffset = 0

        // CLEAR efface toujours les DIM et DEF FN
        arrays.removeAll()
        stringArrays.removeAll()
        arrayDims.removeAll()
        stringArrayDims.removeAll()
        userFunctions.removeAll()
        userStringFunctions.removeAll()

        // DATA seulement sur RUN start / LOAD / NEW
        switch R {
        case "RUN START", "LOAD", "NEW":
            preloadedDataFromProgram = false
            dataPool.removeAll()
            dataPointer = 0
            elog("[DATA] Reset pool et pointeur (raison \(R))")
        default:
            break
        }

        elog("[CLEAR] Après : num=\(variables.count), arrNum=\(arrays.count), str=\(varText.count), arrStr=\(stringArrays.count), gosub=\(gosubStack.count), for=\(forStack.count)")
    }

    private func splitDataValues(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        var i = s.startIndex

        while i < s.endIndex {
            let ch = s[i]
            if ch == "\"" {
                inQuotes.toggle()
                cur.append(ch)        // on conserve les guillemets
            } else if ch == "," && !inQuotes {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(ch)
            }
            i = s.index(after: i)
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        // Supprimer les vides causés par "DATA" final avec virgule éventuelle
        return out.filter { !$0.isEmpty }
    }
    
    private func rebuildDataPoolFromProgram() {
        dataPool.removeAll()
        dataPointer = 0

        let keys = program.lines.keys.sorted()
        for k in keys {
            guard let line = program.lines[k] else { continue }
            // Découpe par sous-instructions séparées par ':'
            for stmt in line.split(separator: ":", omittingEmptySubsequences: true) {
                let raw = String(stmt).trimmingCharacters(in: .whitespaces)
                // On cherche une instruction qui commence par DATA (insensible à la casse, espaces tolérés)
                if raw.uppercased().hasPrefix("DATA") {
                    // extrait tout ce qui suit DATA
                    let after = raw.dropFirst(4).trimmingCharacters(in: .whitespaces)
                    let values = splitDataValues(String(after))
                    if !values.isEmpty {
                        dataPool.append(contentsOf: values)
                    }
                }
            }
        }
        preloadedDataFromProgram = true  // ← utile si tu veux t’en servir ailleurs
        elog("[DATA] Rebuild: \(dataPool.count) valeurs")
    }


    private func uppercaseOutsideQuotes(_ s: String) -> String {
        var res = ""
        var inStr = false
        for ch in s {
            if ch == "\"" { inStr.toggle(); res.append(ch) }
            else { res.append(inStr ? ch : Character(String(ch).uppercased())) }
        }
        return res
    }

    private func decodeBasicStringLiteral(_ s: String) -> String? {
        guard s.hasPrefix("\""), s.hasSuffix("\"") else { return nil }
        var out = ""
        var i = s.index(after: s.startIndex)
        let end = s.index(before: s.endIndex)
        while i < end {
            let ch = s[i]
            if ch == "\"" {
                let j = s.index(after: i)
                guard j < end, s[j] == "\"" else { return nil }
                out.append("\"")
                i = s.index(after: j)
            } else {
                out.append(ch)
                i = s.index(after: i)
            }
        }
        return out
    }
    // Promeut les entiers nus vers des flottants (2 -> 2.0) hors guillemets.
    // Gère signe unaire (+/-), décimaux et notation scientifique (1E3, -2e-4).
    private func promoteIntegerLiteralsToDouble(_ s: String) -> String {
        let chars = Array(s)
        var i = 0
        var inStr = false
        var out = ""

        func isBoundary(_ c: Character?) -> Bool {
            guard let c = c else { return true } // début/fin = OK
            return " +-*/%<>=!&|^(),:\n\t\r".contains(c)
        }

        while i < chars.count {
            let c = chars[i]

            if c == "\"" {
                inStr.toggle()
                out.append(c)
                i += 1
                continue
            }

            if !inStr {
                var j = i

                // signe unaire autorisé si borne à gauche
                if (chars[j] == "+" || chars[j] == "-"),
                   isBoundary(i == 0 ? nil : chars[i-1]) {
                    j += 1
                }

                // digits
                var k = j
                var sawDigit = false
                while k < chars.count, chars[k].isNumber {
                    sawDigit = true
                    k += 1
                }

                if sawDigit {
                    // décimal -> consommer tout le décimal et laisser tel quel
                    if k < chars.count, chars[k] == "." {
                        k += 1
                        while k < chars.count, chars[k].isNumber { k += 1 }
                        // éventuelle notation scientifique après le décimal
                        if k < chars.count, chars[k] == "E" || chars[k] == "e" {
                            var e = k + 1
                            // espaces après E
                            while e < chars.count, chars[e].isWhitespace { e += 1 }
                            // signe optionnel (+/-) avec espaces tolérés après
                            var signChar: Character? = nil
                            if e < chars.count, chars[e] == "+" || chars[e] == "-" {
                                signChar = chars[e]
                                e += 1
                                while e < chars.count, chars[e].isWhitespace { e += 1 }
                            }
                            // chiffres de l’exposant
                            let digitsStart = e
                            while e < chars.count, chars[e].isNumber { e += 1 }

                            if e > digitsStart {
                                // réécrire SANS espaces : mantisse + "E" + [signe] + digits
                                let mantissa = String(chars[i..<k])
                                let digits   = String(chars[digitsStart..<e])
                                out += mantissa
                                out.append("E")
                                if let s = signChar { out.append(s) }
                                out += digits
                                i = e
                                continue
                            }
                        }
                        // pas de notation scientifique valide => on sort la mantisse telle quelle
                        out += String(chars[i..<k])
                        i = k
                        continue

                    }

                    // notation scientifique sur entier (ex: 2E3) — tolère espaces : 2E +3
                    if k < chars.count, chars[k] == "E" || chars[k] == "e" {
                        var e = k + 1
                        while e < chars.count, chars[e].isWhitespace { e += 1 }
                        var signChar: Character? = nil
                        if e < chars.count, chars[e] == "+" || chars[e] == "-" {
                            signChar = chars[e]
                            e += 1
                            while e < chars.count, chars[e].isWhitespace { e += 1 }
                        }
                        let digitsStart = e
                        while e < chars.count, chars[e].isNumber { e += 1 }

                        if e > digitsStart {
                            let mantissa = String(chars[i..<k])
                            let digits   = String(chars[digitsStart..<e])
                            out += mantissa
                            out.append("E")
                            if let s = signChar { out.append(s) }
                            out += digits
                            i = e
                            continue
                        }
                    }


                    // entier nu : promouvoir  -> .0
                    let prev = i == 0 ? nil : chars[i-1]
                    let next = k < chars.count ? chars[k] : nil
                    if isBoundary(prev) && isBoundary(next) {
                        out += String(chars[i..<k]) + ".0"
                        i = k
                        continue
                    } else {
                        // pas une borne (ex: A1) -> laisser tel quel
                        out += String(chars[i..<k])
                        i = k
                        continue
                    }
                }
            }

            out.append(c)
            i += 1
        }

        return out
    }
    
    private func prevNonSpace(in chars: [Character], before idx: Int) -> Character? {
        var j = idx - 1
        while j >= 0 {
            if !chars[j].isWhitespace { return chars[j] }
            j -= 1
        }
        return nil
    }

    private func splitAdditiveTopLevel(_ s: String) -> [(sign: Character, term: String)] {
        let chars = Array(s)
        var parts: [(Character, String)] = []
        var cur = ""
        var inStr = false
        var paren = 0
        var sign: Character = "+"

        func prevNonSpaceIndex(before idx: Int) -> Int? {
            var j = idx - 1
            while j >= 0 { if !chars[j].isWhitespace { return j }; j -= 1 }
            return nil
        }
        func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "$" }

        for i in 0..<chars.count {
            let c = chars[i]
            if c == "\"" { inStr.toggle(); cur.append(c); continue }
            if !inStr {
                if c == "(" { paren += 1; cur.append(c); continue }
                if c == ")" { paren = max(0, paren - 1); cur.append(c); continue }

                if paren == 0 && (c == "+" || c == "-") {
                    var unary = false
                    if let pIdx = prevNonSpaceIndex(before: i) {
                        let p = chars[pIdx]
                        if "+-*/%(<>=!,".contains(p) { unary = true }
                        else if pIdx >= 2 {
                            let m0 = chars[pIdx-2], m1 = chars[pIdx-1], m2 = chars[pIdx]
                            let trip = String([m0,m1,m2]).uppercased()
                            if trip == "MOD" {
                                let beforeIsId = (pIdx-3 >= 0) ? isIdentChar(chars[pIdx-3]) : false
                                let afterIsId  = (i < chars.count) ? isIdentChar(chars[i])   : false
                                if !beforeIsId && !afterIsId { unary = true }
                            }
                        }
                    } else { unary = true }

                    if unary { cur.append(c); continue }

                    let t = cur.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { parts.append((sign, t)) }
                    sign = c
                    cur = ""
                    continue
                }
            }
            cur.append(c)
        }
        let tail = cur.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append((sign, tail)) }
        return parts
    }

    // * et / uniquement (pas MOD)
    private func tokenizeMultiplicativeLevel(_ s: String) -> [String] {
        let chars = Array(s)
        var tokens: [String] = []
        var cur = ""
        var inStr = false
        var paren = 0
        var i = 0

        func flushCur() {
            let t = cur.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { tokens.append(t) }
            cur.removeAll(keepingCapacity: true)
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\"" { inStr.toggle(); cur.append(c); i += 1; continue }
            if !inStr {
                if c == "(" { paren += 1; cur.append(c); i += 1; continue }
                if c == ")" { paren = max(0, paren - 1); cur.append(c); i += 1; continue }
                if paren == 0 && (c == "*" || c == "/") {
                    flushCur()
                    tokens.append(String(c))
                    i += 1
                    continue
                }
            }
            cur.append(c)
            i += 1
        }
        flushCur()
        return tokens
    }

    // MOD / % au niveau top du "terme" (donc après * et /)
    private func splitModLevel(_ s: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var inStr = false
        var paren = 0
        let chars = Array(s)
        var i = 0

        func flush() {
            let t = cur.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { tokens.append(t) }
            cur.removeAll(keepingCapacity: true)
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\"" { inStr.toggle(); cur.append(c); i += 1; continue }
            if !inStr {
                if c == "(" { paren += 1; cur.append(c); i += 1; continue }
                if c == ")" { paren = max(0, paren - 1); cur.append(c); i += 1; continue }
                if paren == 0 {
                    if i + 3 <= chars.count && String(chars[i..<(i+3)]).uppercased() == "MOD" {
                        flush(); tokens.append("MOD"); i += 3; continue
                    }
                    if c == "%" {
                        flush(); tokens.append("MOD"); i += 1; continue
                    }
                }
            }
            cur.append(c); i += 1
        }
        flush()
        return tokens
    }


    
    private func factorToDoubleEval(_ s: String) -> (ok: Bool, value: Double, err: String?) {
        let vStr = evaluateExpression(s)

        // Propagate fatal errors verbatim
        let fatals: Set<String> = ["Syntax error","__UNDIMENSIONED__","Subscript out of range",
                                   "Division by zero","Overflow","Type mismatch"]
        if fatals.contains(vStr) { return (false, 0.0, vStr) }

        let norm = vStr.replacingOccurrences(of: ",", with: ".")
        guard let d = Double(norm) else { return (false, 0.0, "Type mismatch") }
        return (true, d, nil)
    }

    
    // LCG simple, stable entre runs si on re-seed
    private func lcgNext() -> Double {
        // Paramètres classiques de LCG
        let a: UInt64 = 1103515245
        let c: UInt64 = 12345
        let m: UInt64 = 1 << 31
        rndSeed = (a &* rndSeed &+ c) % m
        // Normalisation sur [0,1)
        let val = Double(rndSeed) / Double(m)
        rndLast = val
        return val
    }

    // RND selon MSX BASIC :
    // RND(0)  -> dernier nombre généré (si aucun, en génère un)
    // RND(1)  -> génère un nouveau pseudo-aléatoire
    // RND(x<0)-> réinitialise la graine (seed = -x), puis génère un nouveau
    private func msxRND(_ x: Double) -> Double {
        if x == 0 {
            // Si rien n’a encore été généré, on en produit un
            if rndLast == 0.5 && rndSeed == 1 {
                _ = lcgNext()
            }
            return rndLast
        } else if x < 0 {
            // Re-seed déterministe
            let s = UInt64(abs(x)).nonzeroBitCount == 0 ? 1 : UInt64(abs(x))
            rndSeed = s
            return lcgNext()
        } else {
            return lcgNext()
        }
    }

    // MARK: - Utilitaires parsing simples
    private func isCall(_ s: String, _ name: String) -> Bool {
        let u = s.trimmingCharacters(in: .whitespaces).uppercased()
        return u.hasPrefix(name + "(") && u.hasSuffix(")")
    }
    // Sépare au niveau top les segments autour de ^ en ignorant guillemets et parenthèses.
    // Pas de vérif "avant/après identifiants" (contrairement à splitTopLevel).
    private func splitTopLevelByCaret(_ s: String) -> [String]? {
        var parts: [String] = []
        var cur = ""
        var inStr = false
        var paren = 0
        for ch in s {
            if ch == "\"" { inStr.toggle(); cur.append(ch); continue }
            if !inStr {
                if ch == "(" { paren += 1; cur.append(ch); continue }
                if ch == ")" { paren = max(0, paren - 1); cur.append(ch); continue }
                if paren == 0 && ch == "^" {
                    parts.append(cur.trimmingCharacters(in: .whitespaces))
                    cur.removeAll(keepingCapacity: true)
                    continue
                }
            }
            cur.append(ch)
        }
        let tail = cur.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty || !s.isEmpty { parts.append(tail) }
        return parts.count > 1 ? parts : nil
    }

    // Sépare les arguments de niveau top (respect crochets/parenthèses imbriquées)
    private func splitTopLevelArgs(_ inside: String) -> [String] {
        var args: [String] = []
        var depth = 0
        var current = ""
        for ch in inside {
            if ch == "(" { depth += 1; current.append(ch); continue }
            if ch == ")" { depth -= 1; current.append(ch); continue }
            if ch == "," && depth == 0 {
                args.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    // Convertit String numérique (résultat d'evaluateExpression) en Double
    private func toDoubleOrNil(_ s: String) -> Double? {
        // On évite les espaces parasites
        let t = s.trimmingCharacters(in: .whitespaces)
        return Double(t)
    }

    // MARK: - Evaluation des fonctions numériques MSX
    // Retourne Double si s est une fonction numérique reconnue, sinon nil (on laisse le flux normal)
    private func tryEvalMsxNumericFunction(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let up = trimmed.uppercased()

        func inner(_ name: String) -> String? {
            guard isCall(trimmed, name) else { return nil }
            let start = trimmed.index(trimmed.firstIndex(of: "(")!, offsetBy: 1)
            let end = trimmed.index(before: trimmed.endIndex) // ')'
            return String(trimmed[start..<end])
        }

        // Helper pour 1 arg
        func oneArg(_ name: String, _ op: (Double) -> Double?) -> Double? {
            guard let ins = inner(name) else { return nil }
            let aStr = ins.trimmingCharacters(in: .whitespaces)
            elog("[num] \(name)(...) détecté, arg brut='\(aStr)'")
            let aEval = evaluateExpression(aStr)
            elog("[num] \(name) arg évalué='\(aEval)'")
            guard let a = toDoubleOrNil(aEval) else { elog("[num] \(name) arg NON numérique"); return nil }
            return op(a)
        }

        // ABS
        if up.hasPrefix("ABS(") {
            return oneArg("ABS") { a in abs(a) }
        }
        // SGN
        if up.hasPrefix("SGN(") {
            return oneArg("SGN") { a in a > 0 ? 1 : (a < 0 ? -1 : 0) }
        }
        // INT : plancher (vers -infini)
        if up.hasPrefix("INT(") {
            return oneArg("INT") { a in floor(a) }
        }
        // FIX : troncature vers 0
        if up.hasPrefix("FIX(") {
            return oneArg("FIX") { a in a < 0 ? ceil(a) : floor(a) }
        }
        // SQR : x >= 0 sinon "Illegal function call" MSX
        if up.hasPrefix("SQR(") {
            return oneArg("SQR") { a in
                if a < 0 {
                    elog("[num] SQR: Illegal function call (a<0)")
                    // On peut propager une erreur via ta mécanique, ici on renvoie NaN pour signaler
                    return Double.nan
                }
                return sqrt(a)
            }
        }
        // RND
        if up.hasPrefix("RND(") {
            return oneArg("RND") { a in msxRND(a) }
        }
        // SIN/COS/TAN  (radians, MSX)
        if up.hasPrefix("SIN(") {
            return oneArg("SIN") { a in sin(a) }
        }
        if up.hasPrefix("COS(") {
            return oneArg("COS") { a in cos(a) }
        }
        if up.hasPrefix("TAN(") {
            return oneArg("TAN") { a in tan(a) }
        }
        // EXP/LOG (LOG = ln)
        if up.hasPrefix("EXP(") {
            return oneArg("EXP") { a in exp(a) }
        }
        if up.hasPrefix("LOG(") {
            return oneArg("LOG") { a in
                if a <= 0 {
                    elog("[num] LOG: Illegal function call (a<=0)")
                    return Double.nan
                }
                return log(a)
            }
        }
        // ATN
        if up.hasPrefix("ATN(") {
            return oneArg("ATN") { a in atan(a) }
        }

        return nil
    }
    private func convertRadixLiteralsOutsideQuotes(_ s: String) -> String {
        let chars = Array(s)
        var i = 0
        var inStr = false
        var out = ""

        func isBoundary(_ c: Character?) -> Bool {
            guard let c = c else { return true }
            return " +-*/%<>=!&|^(),:\n\t\r".contains(c)
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                inStr.toggle()
                out.append(c)
                i += 1
                continue
            }

            if !inStr && c == "&" && i + 1 < chars.count {
                let next = chars[i+1]
                if "HhBbOo".contains(next) {                    // <-- H, B, O
                    let radix = ("Hh".contains(next) ? 16 : ("Bb".contains(next) ? 2 : 8))
                    var j = i + 2
                    let validSet: Set<Character> = (radix == 16) ? Set("0123456789ABCDEFabcdef")
                                                 : (radix == 2)  ? Set("01")
                                                                 : Set("01234567")
                    var hasDigit = false
                    while j < chars.count, validSet.contains(chars[j]) {
                        hasDigit = true
                        j += 1
                    }
                    if hasDigit {
                        let prev = i == 0 ? nil : chars[i-1]
                        let nxt  = j < chars.count ? chars[j] : nil
                        if isBoundary(prev) && isBoundary(nxt) {
                            let digits = String(chars[(i+2)..<j])
                            if let v = UInt64(digits, radix: radix) {
                                // ➜ MSX : réduire sur 16 bits et interpréter en signé
                                let s16 = Int16(bitPattern: UInt16(truncatingIfNeeded: v))
                                out += formatNumber(Double(s16))
                                i = j
                                continue
                            }
                        }
                    }
                }
            }

            out.append(c)
            i += 1
        }
        return out
    }

    // Sépare une liste CSV en ignorant les virgules entre parenthèses et dans les guillemets
    private func splitCsvTopLevelRespectingParens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inStr = false
        var paren = 0
        for ch in s {
            if ch == "\"" { inStr.toggle(); cur.append(ch); continue }
            if !inStr {
                if ch == "(" { paren += 1; cur.append(ch); continue }
                if ch == ")" { paren = max(0, paren - 1); cur.append(ch); continue }
                if paren == 0 && ch == "," {
                    let t = cur.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { out.append(t) }
                    cur.removeAll(keepingCapacity: true)
                    continue
                }
            }
            cur.append(ch)
        }
        let tail = cur.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
    
    private func topLevelSingleEqualsIndex(_ s: String) -> String.Index? {
        let chars = Array(s)
        var inStr = false
        var paren = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { inStr.toggle(); i += 1; continue }
            if !inStr {
                if c == "(" { paren += 1; i += 1; continue }
                if c == ")" { paren = max(0, paren - 1); i += 1; continue }
                if paren == 0 && c == "=" {
                    let prev: Character? = (i > 0) ? chars[i-1] : nil
                    let next: Character? = (i+1 < chars.count) ? chars[i+1] : nil
                    // exclut ==, <=, >=, !=, <>
                    if prev != "=" && prev != "<" && prev != ">" && prev != "!"
                       && next != "=" {
                        return s.index(s.startIndex, offsetBy: i)
                    }
                }
            }
            i += 1
        }
        return nil
    }
    
    // Remplace les '=' solitaires par '==' en ignorant tout ce qui est entre guillemets.
    // Ne touche pas à '==', '<=', '>=', '!=', '<>'.
    private func normalizeEqualsOutsideQuotes(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var inStr = false
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                inStr.toggle()
                out.append(c)
                i += 1
                continue
            }

            if !inStr && c == "=" {
                let prev = (i > 0) ? chars[i - 1] : nil
                let next = (i + 1 < chars.count) ? chars[i + 1] : nil
                // exclure ==, <=, >=, !=, <>
                if prev != "=" && prev != "<" && prev != ">" && prev != "!"
                   && next != "=" {
                    out += "=="
                    i += 1
                    continue
                }
            }

            out.append(c)
            i += 1
        }
        return out
    }
    // Coupe tout ce qui suit un ' (apostrophe) ou un REM top-level, hors guillemets.
    private func stripInlineComment(_ s: String) -> String {
        let chars = Array(s)
        var inStr = false
        var i = 0
        func isIdent(_ c: Character?) -> Bool {
            guard let c = c else { return false }
            return c.isLetter || c.isNumber || c == "$"
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { inStr.toggle(); i += 1; continue }
            if !inStr {
                if c == "'" {
                    return String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                }
                if i + 3 <= chars.count {
                    let slice = String(chars[i..<(i+3)]).uppercased()
                    if slice == "REM" {
                        // s'assurer que c'est un mot isolé
                        let before = (i > 0) ? chars[i-1] : nil
                        let after  = (i+3 < chars.count) ? chars[i+3] : nil
                        if !isIdent(before) && !isIdent(after) {
                            return String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
            }
            i += 1
        }
        return s
    }
    
  
    // MARK: - Export (utilise les stores : variables / varText / arrays / stringArrays / ...)

    // MARK: - Export

    func exportAllVariables() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Tableaux numériques
        let dumpsN: [ArrayDump<Double>] = arrays.compactMap { (name, flat) in
            guard let dims = arrayDims[name] else { return nil }
            return ArrayDump(name: name, dims: dims, flat: flat)
        }

        // Tableaux chaîne
        let dumpsS: [ArrayDump<String>] = stringArrays.compactMap { (name, flat) in
            guard let dims = stringArrayDims[name] else { return nil }
            return ArrayDump(name: name, dims: dims, flat: flat)
        }

        // DEF FN
        var defsN: [String: DefFnDump] = [:]
        for (name, fn) in userFunctions {
            defsN[name] = DefFnDump(params: fn.params, body: fn.body)
        }
        var defsS: [String: DefFnDump] = [:]
        for (name, fn) in userStringFunctions {
            defsS[name] = DefFnDump(params: fn.params, body: fn.body)
        }

        let state = SavedState(
            version: 2,
            scalarsN: variables,
            scalarsS: varText,
            arraysN: dumpsN,
            arraysS: dumpsS,
            defFnsN: defsN.isEmpty ? nil : defsN,
            defFnsS: defsS.isEmpty ? nil : defsS,
            dataPool: dataPool.isEmpty ? nil : dataPool,
            dataPointer: dataPool.isEmpty ? nil : dataPointer
        )

        return (try? enc.encode(state)) ?? Data()
    }


    // MARK: - Import

    @discardableResult
    func importAllVariables(from data: Data, clearBefore: Bool, restoreData: Bool = true) -> Bool {
        let dec = JSONDecoder()
        guard let state = try? dec.decode(SavedState.self, from: data) else { return false }

        if clearBefore {
            // ⚠️ ne PAS effacer le programme, seulement l’environnement d’exécution
            variables.removeAll()
            varText.removeAll()

            arrays.removeAll()
            stringArrays.removeAll()
            arrayDims.removeAll()
            stringArrayDims.removeAll()

            userFunctions.removeAll()
            userStringFunctions.removeAll()
            // dataPool/dataPointer gérés plus bas selon restoreData
        }

        // Scalaires
        for (k, v) in state.scalarsN { variables[k] = v }
        for (k, v) in state.scalarsS { varText[k] = v }

        // Tableaux num
        for dump in state.arraysN {
            arrays[dump.name] = dump.flat
            arrayDims[dump.name] = dump.dims
        }

        // Tableaux chaîne
        for dump in state.arraysS {
            stringArrays[dump.name] = dump.flat
            stringArrayDims[dump.name] = dump.dims
        }

        // DEF FN (numériques)
        if let defsN = state.defFnsN {
            for (name, d) in defsN {
                userFunctions[name] = (params: d.params, body: d.body)
            }
        }
        // DEF FN (chaîne)
        if let defsS = state.defFnsS {
            for (name, d) in defsS {
                userStringFunctions[name] = (params: d.params, body: d.body)
            }
        }

        // DATA (figée si demandé, et seulement si présente dans le snapshot)
        if restoreData {
            if let pool = state.dataPool {
                dataPool = pool
            }
            if let ptr = state.dataPointer {
                dataPointer = min(max(0, ptr), dataPool.count)
            }
        }

        return true
    }

    // Dossier cible (Downloads ou Documents suivant ton app)
    private var filesBaseURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    private func saveStateFileURL(name: String) -> URL {
        filesBaseURL.appendingPathComponent(name).appendingPathExtension("json")
    }

    private func handleSaveF(_ line: String) -> String {
        // SAVEF "Nom"
        guard let (name, _) = parseNameAndFlag(line, keyword: "SAVEF") else { return "Syntax error" }
        let url = saveStateFileURL(name: name)
        let data = exportAllVariables()
        do {
            try data.write(to: url, options: .atomic)
            elog("[SAVEF] ok -> \(url.path)")
            return ""
        } catch {
            elog("[SAVEF] error: \(error.localizedDescription)")
            return "I/O error"
        }
    }

    private func handleLoadF(_ line: String) -> String {
        // LOADF "Nom"[,CLEAR]
        guard let (name, clear) = parseNameAndFlag(line, keyword: "LOADF") else { return "Syntax error" }
        let url = saveStateFileURL(name: name)
        do {
            let data = try Data(contentsOf: url)
            let ok = importAllVariables(from: data, clearBefore: clear)
            elog("[LOADF] \(ok ? "ok" : "decode failed") <- \(url.path)  clear=\(clear)")
            return ok ? "" : "I/O error"
        } catch {
            elog("[LOADF] error: \(error.localizedDescription)")
            return "I/O error"
        }
    }

    // Utilitaire : parse 'SAVEF "Nom"' et 'LOADF "Nom",CLEAR'
    private func parseNameAndFlag(_ line: String, keyword: String) -> (String, Bool)? {
        // On laisse simple: mot-clé, un espace, "Nom" option virgule CLEAR
        // ex: LOADF "ADRESSE",CLEAR
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix(keyword + " ") else { return nil }

        // extrait la 1ère chaîne entre guillemets
        guard let q1 = trimmed.firstIndex(of: "\""),
              let q2 = trimmed[trimmed.index(after: q1)...].firstIndex(of: "\"") else { return nil }
        let name = String(trimmed[trimmed.index(after: q1)..<q2])

        let rest = trimmed[q2...].uppercased()
        let clear = rest.contains(",CLEAR")
        return (name, clear)
    }

}
