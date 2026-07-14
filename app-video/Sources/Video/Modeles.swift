import Foundation

/// Les trois actions de l'app.
enum ModeApp: String, CaseIterable, Identifiable {
    case sousTitrer = "Sous-titrer"
    case extraire = "Extraire"
    case compresser = "Compresser"
    var id: String { rawValue }
}

/// Niveau de compression (CRF) — mêmes valeurs que compresser-video.sh.
enum NiveauCompression: Int, CaseIterable, Identifiable {
    case maximal = 18
    case equilibre = 23
    case leger = 26
    var id: Int { rawValue }
    var libelle: String {
        switch self {
        case .maximal: return "Qualité maximale (plus lourd)"
        case .equilibre: return "Équilibré (recommandé)"
        case .leger: return "Très léger"
        }
    }
}

/// Un bloc du sommaire thématique retourné par Claude.
struct BlocSommaire: Identifiable, Hashable {
    let id = UUID()
    let debut: Double     // secondes
    let fin: Double
    let description: String

    var plageAffichee: String {
        "\(formatMMSS(debut))–\(formatMMSS(fin))"
    }

    private func formatMMSS(_ s: Double) -> String {
        let total = Int(s)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Analyse une ligne "MM:SS-MM:SS | Description" (ou HH:MM:SS).
    static func depuisLigne(_ ligne: String) -> BlocSommaire? {
        let parties = ligne.components(separatedBy: "|")
        guard parties.count >= 2 else { return nil }
        let plage = parties[0].trimmingCharacters(in: .whitespaces)
        let description = parties.dropFirst().joined(separator: "|").trimmingCharacters(in: .whitespaces)
        let bornes = plage.components(separatedBy: "-")
        guard bornes.count == 2,
              let debut = secondesDepuisTimecodeCourt(bornes[0]),
              let fin = secondesDepuisTimecodeCourt(bornes[1]),
              fin > debut, !description.isEmpty
        else { return nil }
        return BlocSommaire(debut: debut, fin: fin, description: description)
    }

    /// "MM:SS" ou "HH:MM:SS" → secondes
    static func secondesDepuisTimecodeCourt(_ tc: String) -> Double? {
        let parties = tc.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        let nombres = parties.compactMap { Double($0) }
        guard nombres.count == parties.count else { return nil }
        switch nombres.count {
        case 2: return nombres[0] * 60 + nombres[1]
        case 3: return nombres[0] * 3600 + nombres[1] * 60 + nombres[2]
        default: return nil
        }
    }
}

/// Résultat final d'un traitement, pour l'écran de fin.
struct ResultatTraitement {
    let url: URL
    let sousTitresURL: URL?   // .srt FR déposé à côté, le cas échéant
    let message: String
}
