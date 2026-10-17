import Foundation

struct ResultatProcessus {
    let code: Int32
    let sortie: String
    let erreurs: String
}

enum ErreurTraitement: LocalizedError {
    case annule
    case echec(String)

    var errorDescription: String? {
        switch self {
        case .annule: return "Traitement annulé."
        case .echec(let message): return message
        }
    }
}

/// Exécute un binaire externe en asynchrone, avec lecture ligne à ligne de
/// stdout/stderr (pour la progression ffmpeg/whisper) et annulation possible.
final class Executeur: @unchecked Sendable {

    private let verrou = NSLock()
    private var processusCourant: Process?
    private var _annule = false

    var annule: Bool {
        verrou.lock(); defer { verrou.unlock() }
        return _annule
    }

    func annuler() {
        verrou.lock()
        _annule = true
        let p = processusCourant
        verrou.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    /// Enregistre le processus courant et renvoie s'il a déjà été annulé.
    /// Section critique synchrone : NSLock ne peut pas être verrouillé depuis un
    /// contexte async (erreur en mode Swift 6), d'où ce helper hors de `lancer`.
    private func enregistrer(_ processus: Process) -> Bool {
        verrou.lock(); defer { verrou.unlock() }
        processusCourant = processus
        return _annule
    }

    @discardableResult
    func lancer(
        _ chemin: String,
        _ arguments: [String],
        surLigneSortie: (@Sendable (String) -> Void)? = nil,
        surLigneErreur: (@Sendable (String) -> Void)? = nil,
        dossierCourant: URL? = nil
    ) async throws -> ResultatProcessus {
        if annule { throw ErreurTraitement.annule }

        let processus = Process()
        processus.executableURL = URL(fileURLWithPath: chemin)
        processus.arguments = arguments
        processus.environment = Binaires.environnement()
        processus.standardInput = FileHandle.nullDevice
        if let dossierCourant { processus.currentDirectoryURL = dossierCourant }

        let tuyauSortie = Pipe()
        let tuyauErreur = Pipe()
        processus.standardOutput = tuyauSortie
        processus.standardError = tuyauErreur

        // stdout de claude/ffprobe (pas de callback) : on garde tout (petit).
        // Sinon (whisper/ffmpeg qui streament) : on ne garde qu'une queue bornée,
        // les appelants n'utilisant que les dernières lignes d'erreur / une regex.
        let tamponSortie = TamponLignes(rappel: surLigneSortie,
                                        limiteOctets: surLigneSortie == nil ? nil : 256 * 1024)
        let tamponErreur = TamponLignes(rappel: surLigneErreur, limiteOctets: 256 * 1024)

        tuyauSortie.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil    // EOF : sinon rappel en boucle (100 % CPU)
            } else {
                tamponSortie.ajouter(data)
            }
        }
        tuyauErreur.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
            } else {
                tamponErreur.ajouter(data)
            }
        }

        let dejaAnnule = enregistrer(processus)

        return try await withCheckedThrowingContinuation { continuation in
            processus.terminationHandler = { [weak self] p in
                tuyauSortie.fileHandleForReading.readabilityHandler = nil
                tuyauErreur.fileHandleForReading.readabilityHandler = nil
                // Vider ce qui reste dans les tuyaux
                if let data = try? tuyauSortie.fileHandleForReading.readToEnd() { tamponSortie.ajouter(data) }
                if let data = try? tuyauErreur.fileHandleForReading.readToEnd() { tamponErreur.ajouter(data) }
                tamponSortie.terminer()
                tamponErreur.terminer()

                self?.verrou.lock()
                let etaitAnnule = self?._annule ?? false
                self?.processusCourant = nil
                self?.verrou.unlock()

                if etaitAnnule {
                    continuation.resume(throwing: ErreurTraitement.annule)
                } else {
                    continuation.resume(returning: ResultatProcessus(
                        code: p.terminationStatus,
                        sortie: tamponSortie.texte,
                        erreurs: tamponErreur.texte
                    ))
                }
            }
            do {
                try processus.run()
                // Course : annuler() a pu être appelé entre le check d'entrée et
                // l'enregistrement de processusCourant. On re-teste après run().
                if dejaAnnule || annule { processus.terminate() }
            } catch {
                continuation.resume(throwing: ErreurTraitement.echec("Impossible de lancer \(chemin) : \(error.localizedDescription)"))
            }
        }
    }
}

/// Accumule des octets, découpe en lignes (\n ou \r — ffmpeg utilise \r pour
/// ses lignes de progression) et rappelle le callback pour chaque ligne.
/// `limiteOctets` borne la copie complète conservée (`tout`) : nil = illimité.
private final class TamponLignes: @unchecked Sendable {
    private let verrou = NSLock()
    private var donnees = Data()
    private var tout = Data()
    private let rappel: (@Sendable (String) -> Void)?
    private let limiteOctets: Int?

    init(rappel: (@Sendable (String) -> Void)?, limiteOctets: Int? = nil) {
        self.rappel = rappel
        self.limiteOctets = limiteOctets
    }

    var texte: String {
        verrou.lock(); defer { verrou.unlock() }
        return String(data: tout, encoding: .utf8) ?? ""
    }

    func ajouter(_ data: Data) {
        guard !data.isEmpty else { return }
        verrou.lock()
        tout.append(data)
        if let limite = limiteOctets, tout.count > limite {
            tout.removeSubrange(tout.startIndex..<(tout.index(tout.endIndex, offsetBy: -limite)))
        }
        donnees.append(data)
        var lignes: [String] = []
        while let idx = donnees.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let ligne = donnees.subdata(in: donnees.startIndex..<idx)
            donnees.removeSubrange(donnees.startIndex...idx)
            if let s = String(data: ligne, encoding: .utf8), !s.isEmpty {
                lignes.append(s)
            }
        }
        verrou.unlock()
        if let rappel { lignes.forEach(rappel) }
    }

    func terminer() {
        verrou.lock()
        let reste = donnees
        donnees = Data()
        verrou.unlock()
        if let rappel, let s = String(data: reste, encoding: .utf8), !s.isEmpty {
            rappel(s)
        }
    }
}
