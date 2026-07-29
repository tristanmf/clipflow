import Foundation

/// Le moteur : enchaîne ffmpeg / whisper-cli / claude.
/// C'est une transposition FIDÈLE de dossier-sous-titrage.sh et
/// compresser-video.sh — mêmes commandes, mêmes réglages, mêmes sorties.
/// L'app est une interface, pas un nouveau moteur.
final class Moteur: @unchecked Sendable {

    // ── Réglages — identiques aux scripts (NE PAS MODIFIER le style) ──
    static let styleSousTitres = "FontName=Helvetica,FontSize=30,PrimaryColour=&H00FFFFFF,OutlineColour=&H20202020,BorderStyle=1,Outline=6,Shadow=0,MarginV=20,MarginL=20,MarginR=20"
    static let modeleClaude = "claude-opus-4-8"
    static let whisperMaxLen = 58
    static let suffixeManuel = "_ST"
    static let suffixeAuto = "_FR"

    let executeur = Executeur()
    /// Exécuteur dédié aux commandes du tunnel : séparé pour que la coupure du
    /// tunnel fonctionne encore APRÈS une annulation (l'exécuteur principal est
    /// alors marqué annulé et refuserait de lancer quoi que ce soit).
    private let executeurTunnel = Executeur()

    /// Rappel de progression : (libellé de l'étape, fraction 0…1 ou nil = indéterminé)
    var progression: @Sendable (String, Double?) -> Void = { _, _ in }

    private func etape(_ libelle: String, _ fraction: Double? = nil) {
        progression(libelle, fraction)
    }

    func annuler() { executeur.annuler() }

    /// Annule le moteur ET coupe le rappel de progression (un moteur périmé ne
    /// doit plus réveiller le MainActor après le changement de génération).
    func neutraliser() {
        executeur.annuler()
        progression = { _, _ in }
    }

    // ─────────────────────────────────────────────────────────────
    // Briques de base
    // ─────────────────────────────────────────────────────────────

    private func binaire(_ nom: String, _ chemin: String?) throws -> String {
        guard let chemin else { throw ErreurTraitement.echec("\(nom) introuvable.") }
        return chemin
    }

    /// Durée de la vidéo en secondes (ffprobe, avec repli sur ffmpeg).
    /// Best-effort : renvoie 0 si indéterminable (la progression passe alors en
    /// mode indéterminé). Les scripts shell n'ont jamais eu besoin de la durée —
    /// on ne doit donc PAS faire échouer un traitement parce qu'elle manque
    /// (ex. .webm/.mkv sans durée annoncée, .mp4 tronqué).
    func duree(_ video: URL) async -> Double {
        if let ffprobe = Binaires.ffprobe,
           let r = try? await executeur.lancer(ffprobe, [
                "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", video.path
           ]),
           let d = Double(r.sortie.trimmingCharacters(in: .whitespacesAndNewlines)), d > 0 {
            return d
        }
        // Repli : parser "Duration: HH:MM:SS.cc" dans la sortie d'erreur de ffmpeg
        if let ffmpeg = Binaires.ffmpeg,
           let r = try? await executeur.lancer(ffmpeg, ["-i", video.path]),
           let plage = r.erreurs.range(of: #"Duration: (\d+):(\d+):(\d+\.?\d*)"#, options: .regularExpression) {
            let morceaux = String(r.erreurs[plage]).replacingOccurrences(of: "Duration: ", with: "").split(separator: ":").map(String.init)
            if morceaux.count == 3, let h = Double(morceaux[0]), let m = Double(morceaux[1]), let s = Double(morceaux[2]) {
                return h * 3600 + m * 60 + s
            }
        }
        return 0
    }

    /// Fraction de progression à partir d'une ligne ffmpeg "… time=HH:MM:SS.cc …".
    private static func fractionFFmpeg(_ ligne: String, dureeTotale: Double) -> Double? {
        guard dureeTotale > 0,
              let plage = ligne.range(of: #"time=(\d+):(\d+):(\d+\.?\d*)"#, options: .regularExpression)
        else { return nil }
        let morceaux = String(ligne[plage]).replacingOccurrences(of: "time=", with: "").split(separator: ":").map(String.init)
        guard morceaux.count == 3, let h = Double(morceaux[0]), let m = Double(morceaux[1]), let s = Double(morceaux[2])
        else { return nil }
        return min(1.0, (h * 3600 + m * 60 + s) / dureeTotale)
    }

    /// Fraction de progression à partir d'une ligne whisper "[HH:MM:SS.mmm --> …]".
    private static func fractionWhisper(_ ligne: String, dureeTotale: Double) -> Double? {
        guard dureeTotale > 0,
              let plage = ligne.range(of: #"\[(\d+):(\d+):(\d+)\.\d+ -->"#, options: .regularExpression)
        else { return nil }
        let tc = String(ligne[plage]).dropFirst().split(separator: " ").first.map(String.init) ?? ""
        let morceaux = tc.split(separator: ":").map(String.init)
        guard morceaux.count == 3, let h = Double(morceaux[0]), let m = Double(morceaux[1]),
              let s = Double(morceaux[2].split(separator: ".").first.map(String.init) ?? "")
        else { return nil }
        return min(1.0, (h * 3600 + m * 60 + s) / dureeTotale)
    }

    /// ffmpeg → extraction audio 16 kHz mono PCM (comme le script).
    func extraireAudio(_ video: URL, dureeTotale: Double, libelle: String) async throws -> URL {
        let ffmpeg = try binaire("ffmpeg", Binaires.ffmpeg)
        let rapporter = progression
        let wav = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("st_\(UUID().uuidString).wav")
        let r = try await executeur.lancer(ffmpeg, [
            "-y", "-i", video.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path
        ], surLigneErreur: { ligne in
            if let f = Moteur.fractionFFmpeg(ligne, dureeTotale: dureeTotale) {
                rapporter(libelle, f)
            }
        })
        guard r.code == 0, FileManager.default.fileExists(atPath: wav.path) else {
            throw ErreurTraitement.echec("Extraction audio impossible.")
        }
        return wav
    }

    /// whisper-cli → SRT + langue détectée. Mêmes réglages que le script
    /// (-l auto, -ml 58 -sow, modèle large-v3-turbo-q5_0). On omet volontairement
    /// le -np du script : on a besoin des lignes imprimées pour la progression et
    /// la détection de langue (le SRT final, lui, sort à l'identique dans le fichier).
    func transcrire(_ wav: URL, dureeTotale: Double) async throws -> (srt: String, langue: String?) {
        let whisper = try binaire("whisper-cli", Binaires.whisper)
        guard FileManager.default.fileExists(atPath: Binaires.modeleWhisper) else {
            throw ErreurTraitement.echec("Modèle Whisper absent : \(Binaires.modeleWhisper)")
        }
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("st_wh_\(UUID().uuidString)")
        let detecteur = DetecteurLangue()
        let rapporter = progression

        let r = try await executeur.lancer(whisper, [
            "-m", Binaires.modeleWhisper, "-f", wav.path, "-l", "auto",
            "-osrt", "-of", base.path,
            "-ml", String(Moteur.whisperMaxLen), "-sow"
        ], surLigneSortie: { ligne in
            if let f = Moteur.fractionWhisper(ligne, dureeTotale: dureeTotale) {
                rapporter("Transcription (Whisper)…", f)
            }
        }, surLigneErreur: { ligne in
            detecteur.examiner(ligne)
        })
        detecteur.examiner(r.erreurs)

        let srtURL = URL(fileURLWithPath: base.path + ".srt")
        defer { try? FileManager.default.removeItem(at: srtURL) }
        guard r.code == 0, let contenu = try? String(contentsOf: srtURL, encoding: .utf8),
              !contenu.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ErreurTraitement.echec("Transcription vide ou échouée (whisper-cli).")
        }
        return (contenu, detecteur.langue)
    }

    /// Enchaîne extraction audio + transcription.
    func transcrireVideo(_ video: URL, dureeTotale: Double, libelleAudio: String = "Extraction de l'audio…") async throws -> (srt: String, langue: String?) {
        etape(libelleAudio, 0)
        let wav = try await extraireAudio(video, dureeTotale: dureeTotale, libelle: libelleAudio)
        defer { try? FileManager.default.removeItem(at: wav) }
        etape("Transcription (Whisper)…", 0)
        return try await transcrire(wav, dureeTotale: dureeTotale)
    }

    /// Appel générique du CLI claude en mode headless — mêmes garde-fous que
    /// le script : --allowedTools "" et stdin fermé, jeton via l'environnement.
    func appelerClaude(_ prompt: String) async throws -> String {
        let claude = try binaire("claude", Binaires.claude)
        let r = try await executeur.lancer(claude, [
            "-p", prompt, "--model", Moteur.modeleClaude, "--allowedTools", ""
        ])
        guard r.code == 0 else {
            // claude écrit parfois l'erreur sur stdout, pas stderr → on prend les deux
            let err = r.erreurs.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = r.sortie.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (err.isEmpty ? out : err).suffix(400)
            let suffixe = detail.isEmpty ? "" : "\n\n\(detail)"
            throw ErreurTraitement.echec("Appel Claude échoué (jeton expiré ? voir CLAUDE.md → Authentification).\(suffixe)")
        }
        return r.sortie
    }

    /// Traduction d'un SRT en français — prompt IDENTIQUE au script.
    func traduire(_ srt: String) async throws -> String {
        let prompt = """
        Tu es un traducteur professionnel de sous-titres. Voici un fichier SRT. Traduis le TEXTE en français naturel et idiomatique, adapté à des sous-titres courts.
        Règles STRICTES :
        - Garde EXACTEMENT les lignes de timecode (celles contenant -->) inchangées.
        - Renumérote les blocs séquentiellement à partir de 1.
        - Si le texte d'un bloc est vide ou ne contient que de la ponctuation, SUPPRIME ce bloc entièrement (timecode compris).
        - Ne renvoie QUE le SRT final : aucun commentaire, aucun bloc de code markdown, aucune phrase d'introduction.

        Fichier SRT :
        \(srt)
        """
        let brut = try await appelerClaude(prompt)
        let propre = SRT.nettoyerReponseClaude(brut)
        guard propre.contains("-->") else {
            throw ErreurTraitement.echec("Traduction Claude invalide (réponse sans timecodes).")
        }
        return propre
    }

    /// Gravure des sous-titres — style et encodage identiques au script,
    /// avec le même repli -c:a copy → aac 192k.
    /// `srtSource` est copié byte à byte (on préserve l'encodage d'un .srt fourni
    /// par Tristan : Latin-1/Windows-1252/UTF-16… libass s'en charge, pas nous).
    func graver(video: URL, srtSource: URL, sortie: URL, dureeTotale: Double) async throws {
        let ffmpeg = try binaire("ffmpeg", Binaires.ffmpeg)
        // Le filtre subtitles gère mal espaces / ':' / apostrophes → copie /tmp propre
        let tmpSRT = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("st_burn_\(UUID().uuidString).srt")
        try? FileManager.default.removeItem(at: tmpSRT)
        try FileManager.default.copyItem(at: srtSource, to: tmpSRT)
        defer { try? FileManager.default.removeItem(at: tmpSRT) }

        let filtre = "subtitles=\(tmpSRT.path):force_style='\(Moteur.styleSousTitres)'"
        let rapporter = progression
        let surErreur: @Sendable (String) -> Void = { ligne in
            if let f = Moteur.fractionFFmpeg(ligne, dureeTotale: dureeTotale) {
                rapporter("Gravure des sous-titres…", f)
            }
        }
        let base = ["-y", "-i", video.path, "-vf", filtre,
                    "-c:v", "libx264", "-preset", "medium", "-crf", "20",
                    "-pix_fmt", "yuv420p", "-movflags", "+faststart"]

        do {
            var derniere: Int32 = -1
            // Comme le script : d'abord -c:a copy, repli -c:a aac 192k si échec.
            for audio in [["-c:a", "copy"], ["-c:a", "aac", "-b:a", "192k"]] {
                let r = try await executeur.lancer(ffmpeg, base + audio + [sortie.path], surLigneErreur: surErreur)
                derniere = r.code
                if r.code == 0 { break }
            }
            guard derniere == 0, FileManager.default.fileExists(atPath: sortie.path) else {
                try? FileManager.default.removeItem(at: sortie)   // pas de fichier partiel illisible
                throw ErreurTraitement.echec("La gravure ffmpeg a échoué.")
            }
        } catch {
            try? FileManager.default.removeItem(at: sortie)       // nettoyage sur annulation/échec
            throw error
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Action 1 — Sous-titrer la vidéo entière
    // ─────────────────────────────────────────────────────────────

    /// srtFourni ≠ nil = mode manuel (gravure du .srt de Tristan → _ST) ;
    /// sinon mode auto (transcription + traduction si besoin → _FR ou _ST).
    func sousTitrer(video: URL, srtFourni: URL?) async throws -> ResultatTraitement {
        let sortieDossier = try Dossiers.preparer(Dossiers.sousTitrage)
        let nom = video.deletingPathExtension().lastPathComponent
        let dureeTotale = await duree(video)

        if let srtFourni {
            // ── Mode manuel : graver le .srt fourni (sans le relire/réencoder) ──
            let sortie = URL(fileURLWithPath: sortieDossier).appendingPathComponent("\(nom)\(Moteur.suffixeManuel).mp4")
            etape("Gravure des sous-titres…", 0)
            try await graver(video: video, srtSource: srtFourni, sortie: sortie, dureeTotale: dureeTotale)
            // Copie byte à byte du .srt utilisé à côté de la sortie (comme le script)
            let copieSRT = URL(fileURLWithPath: sortieDossier).appendingPathComponent("\(nom)\(Moteur.suffixeManuel).srt")
            try? FileManager.default.removeItem(at: copieSRT)
            try? FileManager.default.copyItem(at: srtFourni, to: copieSRT)
            return ResultatTraitement(url: sortie, sousTitresURL: copieSRT,
                                      message: "Sous-titres gravés depuis ton .srt.")
        }

        // ── Mode auto ──
        let (srtBrut, langue) = try await transcrireVideo(video, dureeTotale: dureeTotale)

        let estFrancais = (langue == "fr")
        var srtFinal = srtBrut
        var suffixe = Moteur.suffixeManuel   // vidéo déjà en français → _ST (comme le brief)
        var message = "Vidéo en français : sous-titres gravés sans traduction."
        if estFrancais {
            // Pas de passe Claude ici → on reproduit son nettoyage minimal :
            // retirer les blocs vides / uniquement ponctuation (hallucinations de silence).
            srtFinal = SRT.composer(SRT.retirerBlocsVides(SRT.analyser(srtBrut)))
        } else {
            etape("Traduction en français (Claude)…", nil)
            srtFinal = try await traduire(srtBrut)
            suffixe = Moteur.suffixeAuto
            message = "Transcription\(langue.map { " (\($0))" } ?? "") traduite en français et gravée."
        }

        // Le .srt final éditable est déposé à côté du résultat (comme le script)
        let srtURL = URL(fileURLWithPath: sortieDossier).appendingPathComponent("\(nom)\(suffixe).srt")
        try srtFinal.write(to: srtURL, atomically: true, encoding: .utf8)

        let sortie = URL(fileURLWithPath: sortieDossier).appendingPathComponent("\(nom)\(suffixe).mp4")
        etape("Gravure des sous-titres…", 0)
        try await graver(video: video, srtSource: srtURL, sortie: sortie, dureeTotale: dureeTotale)
        return ResultatTraitement(url: sortie, sousTitresURL: srtURL, message: message)
    }

    // ─────────────────────────────────────────────────────────────
    // Action 2 — Extraire un passage
    // ─────────────────────────────────────────────────────────────

    /// Phase 1 : transcription + sommaire thématique par Claude.
    func analyserPourExtraction(video: URL) async throws -> (blocs: [BlocSommaire], srt: [BlocSRT], langue: String?) {
        let dureeTotale = await duree(video)
        let (srtBrut, langue) = try await transcrireVideo(video, dureeTotale: dureeTotale)
        let blocsSRT = SRT.analyser(srtBrut)
        guard !blocsSRT.isEmpty else { throw ErreurTraitement.echec("Transcription vide.") }

        etape("Sommaire thématique (Claude)…", nil)
        // Prompt validé dans le chat Claude du 12 juillet 2026 (voir brief)
        let prompt = """
        Voici la transcription horodatée d'une vidéo. Produis un sommaire thématique : regroupe les segments par sujet (pas segment par segment), 3 à 8 blocs maximum. Format strict, une ligne par bloc, rien d'autre : `MM:SS-MM:SS | Description courte et factuelle du bloc` Ne renvoie que ces lignes, sans introduction ni commentaire.

        Transcription :
        \(srtBrut)
        """
        let reponse = try await appelerClaude(prompt)
        let blocs = reponse
            .components(separatedBy: "\n")
            .compactMap { BlocSommaire.depuisLigne($0.replacingOccurrences(of: "`", with: "")) }
        guard !blocs.isEmpty else {
            throw ErreurTraitement.echec("Sommaire Claude illisible — réessaie.")
        }
        return (blocs, blocsSRT, langue)
    }

    /// Recherche en langage naturel (« le passage où il parle de Staline »).
    func chercherPassage(srt: [BlocSRT], demande: String) async throws -> (debut: Double, fin: Double) {
        etape("Recherche du passage (Claude)…", nil)
        let prompt = """
        Voici la transcription horodatée d'une vidéo (format SRT) et une demande. Identifie le passage correspondant à la demande. Réponds UNIQUEMENT avec la plage de timecodes, au format strict `MM:SS-MM:SS` (ou `HH:MM:SS-HH:MM:SS` si la vidéo dépasse une heure), sans aucun autre texte. Si aucun passage ne correspond, réponds exactement : AUCUN

        Demande : \(demande)

        Transcription :
        \(SRT.composer(srt))
        """
        let reponse = try await appelerClaude(prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "`", with: "")
        if reponse.uppercased().contains("AUCUN") {
            throw ErreurTraitement.echec("Aucun passage trouvé pour « \(demande) ».")
        }
        let bornes = reponse.components(separatedBy: "-")
        guard bornes.count == 2,
              let debut = BlocSommaire.secondesDepuisTimecodeCourt(bornes[0]),
              let fin = BlocSommaire.secondesDepuisTimecodeCourt(bornes[1]),
              fin > debut
        else { throw ErreurTraitement.echec("Réponse de Claude illisible : \(reponse)") }
        return (debut, fin)
    }

    /// Phase 2 : coupe nette aux timecodes exacts (réencodage volontaire —
    /// -c copy couperait sur les keyframes, donc imprécis), puis sous-titrage
    /// conditionnel du passage.
    func extraire(video: URL, debut: Double, fin: Double, srtComplet: [BlocSRT], langue: String?, sousTitrer: Bool) async throws -> ResultatTraitement {
        let ffmpeg = try binaire("ffmpeg", Binaires.ffmpeg)
        let sortieDossier = try Dossiers.preparer(Dossiers.sousTitrage)
        let nom = video.deletingPathExtension().lastPathComponent
        let dureeExtrait = fin - debut

        etape("Coupe du passage…", 0)
        let rapporter = progression
        let cut = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("extrait_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: cut) }
        // Seek AVANT -i = saut direct au point de départ (rapide même en fin de
        // longue vidéo), puis -t pour la durée. Le réencodage garde la coupe
        // frame-exacte (-accurate_seek est activé par défaut en transcodage) :
        // on obtient la précision voulue SANS décoder toute la vidéo depuis zéro.
        let r = try await executeur.lancer(ffmpeg, [
            "-y",
            "-ss", String(format: "%.3f", debut),
            "-i", video.path,
            "-t", String(format: "%.3f", dureeExtrait),
            "-c:v", "libx264", "-preset", "fast", "-crf", "20",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart",
            "-c:a", "aac", "-b:a", "192k", cut.path
        ], surLigneErreur: { ligne in
            if let f = Moteur.fractionFFmpeg(ligne, dureeTotale: dureeExtrait) {
                rapporter("Coupe du passage…", f)
            }
        })
        guard r.code == 0, FileManager.default.fileExists(atPath: cut.path) else {
            throw ErreurTraitement.echec("La coupe ffmpeg a échoué.")
        }

        // Fonction utilitaire : livrer le cut brut sous <nom>_extrait.mp4.
        func livrerBrut(_ message: String) throws -> ResultatTraitement {
            let sortie = URL(fileURLWithPath: sortieDossier).appendingPathComponent("\(nom)_extrait.mp4")
            try? FileManager.default.removeItem(at: sortie)
            try FileManager.default.moveItem(at: cut, to: sortie)
            return ResultatTraitement(url: sortie, sousTitresURL: nil, message: message)
        }

        // Sous-titres non demandés → coupe brute (aucun .srt).
        if !sousTitrer {
            return try livrerBrut("Extrait coupé (sans sous-titres).")
        }

        // Rebaser les timecodes sur zéro (l'extrait commence à 00:00:00).
        let blocsExtrait = SRT.extraireEtRebaser(srtComplet, debut: debut, fin: fin)
        guard !blocsExtrait.isEmpty else {
            return try livrerBrut("Extrait livré brut (aucune parole dans ce passage).")
        }

        let srtFinal: String
        let suffixe: String
        let message: String
        if langue == "fr" {
            // Déjà en français : sous-titres FR sans traduction (nettoyage local des blocs vides).
            srtFinal = SRT.composer(SRT.retirerBlocsVides(blocsExtrait))
            suffixe = "_extrait_ST"
            message = "Extrait coupé et sous-titré (français)."
        } else {
            etape("Traduction du passage (Claude)…", nil)
            srtFinal = try await traduire(SRT.composer(blocsExtrait))
            suffixe = "_extrait_FR"
            message = "Extrait coupé, traduit et sous-titré."
        }

        let srtURL = URL(fileURLWithPath: sortieDossier).appendingPathComponent("\(nom)\(suffixe).srt")
        try srtFinal.write(to: srtURL, atomically: true, encoding: .utf8)
        let sortie = URL(fileURLWithPath: sortieDossier).appendingPathComponent("\(nom)\(suffixe).mp4")
        etape("Gravure des sous-titres…", 0)
        try await graver(video: cut, srtSource: srtURL, sortie: sortie, dureeTotale: dureeExtrait)
        return ResultatTraitement(url: sortie, sousTitresURL: srtURL, message: message)
    }

    // ─────────────────────────────────────────────────────────────
    // Entrée en amont — Télécharger un lien (yt-dlp)
    // ─────────────────────────────────────────────────────────────

    /// Fraction de progression à partir d'une ligne yt-dlp "[download]  42.3% of …".
    private static func fractionYtDlp(_ ligne: String) -> Double? {
        guard let plage = ligne.range(of: #"\[download\]\s+(\d+\.?\d*)%"#, options: .regularExpression)
        else { return nil }
        let pourcent = String(ligne[plage])
            .replacingOccurrences(of: "[download]", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let p = Double(pourcent) else { return nil }
        return min(1.0, p / 100)
    }

    /// Télécharge la vidéo d'un lien via yt-dlp, dans ~/Movies/Sous-titrage, en mp4
    /// (remux sans réencodage quand possible). Retourne le fichier local, prêt à
    /// enchaîner sur l'une des trois actions. yt-dlp casse régulièrement quand un
    /// site change ses endpoints → le message d'erreur pointe vers sa mise à jour.
    // ── Tunnel Cloudflare WARP (optionnel, le temps du téléchargement) ──

    /// Le tunnel est-il actif ? (« Disconnected » contient « connected » → on
    /// teste l'absence de « disconnected » d'abord.)
    private func tunnelActif(_ warp: String) async -> Bool {
        guard let r = try? await executeurTunnel.lancer(warp, ["status"]) else { return false }
        let t = (r.sortie + r.erreurs).lowercased()
        if t.contains("disconnected") || t.contains("connecting") { return false }
        return t.contains("connected")
    }

    /// Lance une sous-commande warp-cli (avec repli si `--accept-tos` est inconnu
    /// de la version installée).
    private func warpCommande(_ warp: String, _ sousCommande: String) async {
        let r = try? await executeurTunnel.lancer(warp, ["--accept-tos", sousCommande])
        if r?.code != 0 { _ = try? await executeurTunnel.lancer(warp, [sousCommande]) }
    }

    /// Active le tunnel. Retourne true si c'est NOUS qui l'avons activé (donc à
    /// couper après) ; false s'il était déjà actif — dans ce cas on n'y touche pas.
    private func activerTunnel() async throws -> Bool {
        guard let warp = Binaires.warp else {
            throw ErreurTraitement.echec("Cloudflare WARP n'est pas installé. Terminal : brew install --cask cloudflare-warp")
        }
        if await tunnelActif(warp) { return false }
        etape("Activation du tunnel Cloudflare…", nil)
        await warpCommande(warp, "connect")
        for _ in 0..<20 {                            // jusqu'à ~20 s
            if await tunnelActif(warp) { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw ErreurTraitement.echec("Le tunnel Cloudflare ne s'est pas activé. Ouvre l'app « Cloudflare WARP » une fois et active-la à la main (nécessaire au premier usage), puis réessaie.")
    }

    private func couperTunnel() async {
        guard let warp = Binaires.warp else { return }
        etape("Coupure du tunnel…", nil)
        await warpCommande(warp, "disconnect")
    }

    /// `cookiesNavigateur` (ex. "chrome") = passe `--cookies-from-browser` à yt-dlp,
    /// indispensable pour les vidéos X/Twitter qui exigent d'être connecté (même
    /// publiques : X ne sert plus les flux vidéo en anonyme).
    /// `tunnel` = active Cloudflare WARP le temps du téléchargement puis le recoupe
    /// (utile là où l'opérateur ne route pas les plages IP de X — voir CLAUDE.md).
    func telecharger(lien: String, cookiesNavigateur: String? = nil, tunnel: Bool = false) async throws -> URL {
        var tunnelParNous = false
        if tunnel { tunnelParNous = try await activerTunnel() }
        do {
            let fichier = try await telechargerSansTunnel(lien: lien, cookiesNavigateur: cookiesNavigateur)
            if tunnelParNous { await couperTunnel() }
            return fichier
        } catch {
            // Coupure garantie aussi en cas d'échec OU d'annulation.
            if tunnelParNous { await couperTunnel() }
            throw error
        }
    }

    private func telechargerSansTunnel(lien: String, cookiesNavigateur: String?) async throws -> URL {
        let ytdlp = try binaire("yt-dlp", Binaires.ytdlp)
        let dossier = try Dossiers.preparer(Dossiers.sousTitrage)
        let identifiant = "clipflow_\(UUID().uuidString.prefix(8))"
        let gabarit = "\(dossier)/\(identifiant).%(ext)s"

        etape("Téléchargement…", 0)
        let rapporter = progression
        let surLigne: @Sendable (String) -> Void = { ligne in
            if let f = Moteur.fractionYtDlp(ligne) { rapporter("Téléchargement…", f) }
        }

        var args = [
            "--no-playlist",
            "--newline",                     // progression ligne par ligne (pas de \r)
            "-f", "bv*+ba/b",                // meilleure vidéo+audio, repli meilleur unique
            "--remux-video", "mp4",          // conteneur mp4 sans réencodage si possible
            // Résilience aux coupures passagères (X/Twitter time out souvent) :
            "--socket-timeout", "30",        // délai de connexion allongé (défaut 20 s)
            "--retries", "5",                // relances du téléchargement
            "--extractor-retries", "3",      // relances de la récupération des métadonnées (JSON)
            "--retry-sleep", "3",            // petite pause entre les tentatives
            "-o", gabarit,
            lien
        ]
        if let nav = cookiesNavigateur {
            args.insert(contentsOf: ["--cookies-from-browser", nav], at: 0)
        }
        // yt-dlp a besoin de ffmpeg (fusion vidéo+audio, remux) : on le localise
        // explicitement plutôt que de dépendre du PATH.
        if let ff = Binaires.ffmpeg {
            args.insert(contentsOf: ["--ffmpeg-location", (ff as NSString).deletingLastPathComponent], at: 0)
        }

        let r = try await executeur.lancer(ytdlp, args, surLigneSortie: surLigne, surLigneErreur: surLigne)
        guard r.code == 0 else {
            let err = r.erreurs.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = r.sortie.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (err.isEmpty ? out : err).suffix(400)
            let suffixe = detail.isEmpty ? "" : "\n\n\(detail)"
            // Indice utile si l'échec ressemble à une vidéo X protégée et qu'on n'a pas passé de cookies.
            let indiceCookies = (cookiesNavigateur == nil && detail.lowercased().contains("no video"))
                ? "\n\nAstuce : pour une vidéo X/Twitter, coche « Utiliser mes cookies » — X exige d'être connecté, même pour un tweet public."
                : "\n\nSi le site a changé, mets yt-dlp à jour : brew upgrade yt-dlp"
            throw ErreurTraitement.echec("Téléchargement échoué.\(indiceCookies)\(suffixe)")
        }

        // Retrouver le fichier produit (mp4 attendu ; sinon même préfixe, autre conteneur).
        let attendu = URL(fileURLWithPath: "\(dossier)/\(identifiant).mp4")
        if FileManager.default.fileExists(atPath: attendu.path) { return attendu }
        if let contenu = try? FileManager.default.contentsOfDirectory(atPath: dossier),
           let nom = contenu.first(where: { $0.hasPrefix(identifiant + ".") }) {
            return URL(fileURLWithPath: "\(dossier)/\(nom)")
        }
        throw ErreurTraitement.echec("Téléchargement terminé mais fichier introuvable.")
    }

    // ─────────────────────────────────────────────────────────────
    // Action 3 — Compresser (reprend compresser-video.sh)
    // ─────────────────────────────────────────────────────────────

    func compresser(video: URL, crf: Int) async throws -> ResultatTraitement {
        let ffmpeg = try binaire("ffmpeg", Binaires.ffmpeg)
        let sortieDossier = try Dossiers.preparer(Dossiers.compression)
        let nom = video.deletingPathExtension().lastPathComponent
        let sortie = URL(fileURLWithPath: sortieDossier).appendingPathComponent("\(nom)_compressed.mp4")
        let dureeTotale = await duree(video)

        etape("Compression…", 0)
        let rapporter = progression
        let r: ResultatProcessus
        do {
            r = try await executeur.lancer(ffmpeg, [
                "-y", "-i", video.path,
                "-c:v", "libx264", "-crf", String(crf), "-preset", "medium",
                "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                "-c:a", "aac", "-b:a", "160k", sortie.path
            ], surLigneErreur: { ligne in
                if let f = Moteur.fractionFFmpeg(ligne, dureeTotale: dureeTotale) {
                    rapporter("Compression…", f)
                }
            })
        } catch {
            try? FileManager.default.removeItem(at: sortie)   // pas de fichier partiel illisible
            throw error
        }
        guard r.code == 0, FileManager.default.fileExists(atPath: sortie.path) else {
            try? FileManager.default.removeItem(at: sortie)
            throw ErreurTraitement.echec("La compression ffmpeg a échoué.")
        }

        let tailleAvant = (try? FileManager.default.attributesOfItem(atPath: video.path))?[.size] as? Int64
        let tailleApres = (try? FileManager.default.attributesOfItem(atPath: sortie.path))?[.size] as? Int64
        var message = "Compression terminée."
        if let avant = tailleAvant, let apres = tailleApres, avant > 0 {
            let moAvant = Double(avant) / 1_048_576
            let moApres = Double(apres) / 1_048_576
            message = String(format: "%.0f Mo → %.0f Mo (−%.0f %%).", moAvant, moApres, (1 - moApres / moAvant) * 100)
        }
        return ResultatTraitement(url: sortie, sousTitresURL: nil, message: message)
    }
}

/// Repère « auto-detected language: xx » dans la sortie de whisper-cli.
private final class DetecteurLangue: @unchecked Sendable {
    private let verrou = NSLock()
    private var _langue: String?

    var langue: String? {
        verrou.lock(); defer { verrou.unlock() }
        return _langue
    }

    func examiner(_ texte: String) {
        guard let plage = texte.range(of: #"auto-detected language: ([a-z]{2,3})"#, options: .regularExpression) else { return }
        let code = String(texte[plage]).components(separatedBy: ": ").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        verrou.lock()
        if _langue == nil { _langue = code }
        verrou.unlock()
    }
}
