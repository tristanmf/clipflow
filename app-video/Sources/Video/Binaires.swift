import Foundation

/// Localisation des binaires externes + environnement d'exécution.
/// Reprend la logique `locate_bin()` de dossier-sous-titrage.sh :
/// on ne suppose JAMAIS le PATH (l'app lancée depuis le Finder n'hérite pas
/// du PATH du shell) — on cherche en absolu dans les emplacements Homebrew.
enum Binaires {

    static let dossiersRecherche = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// Cherche un binaire : emplacements Homebrew d'abord, puis PATH courant.
    static func localiser(_ nom: String) -> String? {
        for dossier in dossiersRecherche {
            let chemin = "\(dossier)/\(nom)"
            if FileManager.default.isExecutableFile(atPath: chemin) { return chemin }
        }
        // Repli : PATH hérité (utile si lancé depuis un terminal)
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dossier in path.split(separator: ":") {
                let chemin = "\(dossier)/\(nom)"
                if FileManager.default.isExecutableFile(atPath: chemin) { return chemin }
            }
        }
        return nil
    }

    static var ffmpeg: String? { localiser("ffmpeg") }
    static var ffprobe: String? { localiser("ffprobe") }
    static var whisper: String? { localiser("whisper-cli") }
    static var claude: String? { localiser("claude") }
    static var ytdlp: String? { localiser("yt-dlp") }

    /// Cloudflare WARP (tunnel) — utile là où l'opérateur ne route pas les plages IP de X.
    /// Installé par le cask `cloudflare-warp` ; binaire dans le PATH ou dans l'app.
    static var warp: String? {
        if let p = localiser("warp-cli") { return p }
        let dansApp = "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli"
        return FileManager.default.isExecutableFile(atPath: dansApp) ? dansApp : nil
    }

    static let modeleWhisper = NSString(string: "~/.cache/whisper/ggml-large-v3-turbo-q5_0.bin").expandingTildeInPath

    /// Fichier du jeton d'automatisation Claude (voir CLAUDE.md → Authentification).
    static let fichierJeton = NSString(string: "~/.config/sous-titrage/token").expandingTildeInPath

    /// Environnement pour les sous-processus : PATH complété + jeton Claude si présent
    /// + HOME/USER/LOGNAME garantis (nécessaires à l'accès Trousseau de `claude`).
    static func environnement() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let pathActuel = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + pathActuel
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["USER"] = env["USER"] ?? NSUserName()
        env["LOGNAME"] = env["LOGNAME"] ?? NSUserName()
        if let jeton = try? String(contentsOfFile: fichierJeton, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !jeton.isEmpty {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = jeton
        }
        return env
    }

    /// Vérifie ce qui manque pour un mode donné ; retourne des messages lisibles.
    static func verifier(besoinWhisper: Bool, besoinClaude: Bool) -> [String] {
        var manques: [String] = []
        if ffmpeg == nil { manques.append("ffmpeg introuvable — Terminal : brew install ffmpeg-full") }
        if besoinWhisper {
            if whisper == nil { manques.append("whisper-cli introuvable — Terminal : brew install whisper-cpp") }
            if !FileManager.default.fileExists(atPath: modeleWhisper) {
                manques.append("Modèle Whisper absent : \(modeleWhisper)")
            }
        }
        if besoinClaude && claude == nil {
            manques.append("CLI claude introuvable — Terminal : brew install claude-code")
        }
        return manques
    }

    /// Vérifie la présence de yt-dlp (téléchargement de liens).
    static func verifierYtDlp() -> [String] {
        ytdlp == nil ? ["yt-dlp introuvable — Terminal : brew install yt-dlp"] : []
    }
}

/// Dossiers de sortie — NON protégés par Bitdefender Safe Files (ne pas changer).
enum Dossiers {
    static let sousTitrage = NSString(string: "~/Movies/Sous-titrage").expandingTildeInPath
    static let compression = NSString(string: "~/Movies/Compression").expandingTildeInPath
    /// Vidéos récupérées depuis un lien. Sous-dossier de Sous-titrage : à portée du
    /// bouton dossier, mais séparé des résultats (et hors de portée d'une Folder Action).
    static let telechargements = NSString(string: "~/Movies/Sous-titrage/Vidéos téléchargées").expandingTildeInPath
    /// Le dossier Téléchargements du Mac : destination FINALE des extraits et des vidéos
    /// téléchargées (demande de Tristan, 17/10/2026). Tout est fabriqué dans ~/Movies,
    /// puis le fichier fini est déplacé ici en un seul geste ; en cas de refus, il reste
    /// là où il a été fabriqué.
    static let telechargementsMac = NSString(string: "~/Downloads").expandingTildeInPath

    static func preparer(_ chemin: String) throws -> String {
        try FileManager.default.createDirectory(atPath: chemin, withIntermediateDirectories: true)
        return chemin
    }
}
