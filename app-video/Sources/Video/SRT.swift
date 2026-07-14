import Foundation

/// Un bloc de sous-titre SRT.
struct BlocSRT {
    var debut: Double   // secondes
    var fin: Double
    var texte: String
}

/// Lecture / écriture / rebasage de fichiers SRT.
enum SRT {

    /// "HH:MM:SS,mmm" → secondes
    static func secondes(_ timecode: String) -> Double? {
        let propre = timecode.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parties = propre.split(separator: ":").map(String.init)
        guard parties.count == 3,
              let h = Double(parties[0]), let m = Double(parties[1]), let s = Double(parties[2])
        else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// secondes → "HH:MM:SS,mmm"
    static func timecode(_ secondes: Double) -> String {
        let total = max(0, secondes)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int((total - total.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    static func analyser(_ contenu: String) -> [BlocSRT] {
        var blocs: [BlocSRT] = []
        let paquets = contenu
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for paquet in paquets {
            let lignes = paquet.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let idxTemps = lignes.firstIndex(where: { $0.contains("-->") }) else { continue }
            let morceaux = lignes[idxTemps].components(separatedBy: "-->")
            guard morceaux.count == 2,
                  let debut = secondes(morceaux[0]),
                  let fin = secondes(morceaux[1])
            else { continue }
            let texte = lignes.dropFirst(idxTemps + 1).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if texte.isEmpty { continue }
            blocs.append(BlocSRT(debut: debut, fin: fin, texte: texte))
        }
        return blocs
    }

    static func composer(_ blocs: [BlocSRT]) -> String {
        var sortie = ""
        for (i, bloc) in blocs.enumerated() {
            sortie += "\(i + 1)\n\(timecode(bloc.debut)) --> \(timecode(bloc.fin))\n\(bloc.texte)\n\n"
        }
        return sortie
    }

    /// Extrait les blocs qui chevauchent [debut, fin] et REBASE leurs timecodes
    /// sur zéro (l'extrait coupé commence à 00:00:00 — piège principal du brief :
    /// sans cette soustraction les sous-titres seraient décalés de plusieurs minutes).
    static func extraireEtRebaser(_ blocs: [BlocSRT], debut: Double, fin: Double) -> [BlocSRT] {
        let duree = fin - debut
        var resultat: [BlocSRT] = []
        for bloc in blocs where bloc.fin > debut && bloc.debut < fin {
            let nouveauDebut = max(0, bloc.debut - debut)
            let nouvelleFin = min(duree, bloc.fin - debut)
            if nouvelleFin - nouveauDebut < 0.05 { continue }
            resultat.append(BlocSRT(debut: nouveauDebut, fin: nouvelleFin, texte: bloc.texte))
        }
        return resultat
    }

    /// Retire les blocs vides ou ne contenant que de la ponctuation / des tirets
    /// musicaux (hallucinations de Whisper pendant les silences). Reproduit, pour
    /// le chemin « vidéo déjà en français », le nettoyage que fait sinon Claude.
    static func retirerBlocsVides(_ blocs: [BlocSRT]) -> [BlocSRT] {
        let ponctuation = CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines)
            .union(.symbols)
        return blocs.filter { bloc in
            let sansPonctuation = bloc.texte.unicodeScalars.filter { !ponctuation.contains($0) }
            return !sansPonctuation.isEmpty
        }
    }

    /// Nettoyage de la réponse de Claude : retire les barrières markdown ```
    /// et les lignes vides de tête (même logique que le script shell).
    static func nettoyerReponseClaude(_ brut: String) -> String {
        var lignes = brut
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("```") }
        while let premiere = lignes.first, premiere.trimmingCharacters(in: .whitespaces).isEmpty {
            lignes.removeFirst()
        }
        return lignes.joined(separator: "\n")
    }
}
