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
    /// Exécuteur auxiliaire (tunnel WARP, test de connexion, rapatriement iCloud) :
    /// séparé pour que la coupure du tunnel fonctionne encore APRÈS une annulation
    /// (l'exécuteur principal est alors marqué annulé et refuserait de lancer quoi
    /// que ce soit).
    private let executeurAuxiliaire = Executeur()

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

    /// Fichier iCloud évincé (« Optimiser le stockage du Mac ») : le nom est dans le
    /// Finder mais les données ne sont plus sur le disque, et ffmpeg échoue avec
    /// « Resource deadlock avoided ». On force le rapatriement avant de commencer
    /// (même garde-fou que les scripts shell — voir CLAUDE.md → Piège iCloud).
    func assurerFichierLocal(_ url: URL) async throws {
        func lisible() -> Bool {
            guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? fh.close() }
            do { _ = try fh.read(upToCount: 1); return true } catch { return false }
        }
        if lisible() { return }
        etape("Rapatriement du fichier depuis iCloud…", nil)
        _ = try? await executeurAuxiliaire.lancer("/usr/bin/brctl", ["download", url.path])
        for _ in 0..<180 {                           // jusqu'à 3 min, comme le script
            if executeur.annule { throw ErreurTraitement.annule }
            if lisible() { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw ErreurTraitement.echec("« \(url.lastPathComponent) » est sur iCloud mais pas sur ce Mac, et le rapatriement n'a pas abouti. Ouvre-le une fois dans le Finder (double-clic), attends la fin du téléchargement, puis relance.")
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
    /// `imagesDans` : dossier d'images à montrer à Claude. Il devient le dossier de
    /// travail de l'appel et seul l'outil de lecture est autorisé : Claude peut ouvrir
    /// ces images, et rien hors de ce dossier (toute autre lecture demanderait une
    /// permission, refusée d'office en mode automatique).
    func appelerClaude(_ prompt: String, imagesDans: URL? = nil) async throws -> String {
        let claude = try binaire("claude", Binaires.claude)
        let r = try await executeur.lancer(claude, [
            "-p", prompt, "--model", Moteur.modeleClaude,
            "--allowedTools", imagesDans == nil ? "" : "Read"
        ], dossierCourant: imagesDans)
        guard r.code == 0 else {
            // claude écrit parfois l'erreur sur stdout, pas stderr → on prend les deux
            let err = r.erreurs.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = r.sortie.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = err.isEmpty ? out : err
            let d = detail.lowercased()
            if d.contains("not logged in") || d.contains("/login") || d.contains("401")
                || d.contains("authentication") || d.contains("oauth") {
                throw ErreurTraitement.echec(Moteur.messageReconnexion)
            }
            let suffixe = detail.isEmpty ? "" : "\n\n\(detail.suffix(400))"
            throw ErreurTraitement.echec("Appel Claude échoué.\(suffixe)")
        }
        return r.sortie
    }

    /// Message unique, en clair, quand Claude n'est plus connecté sur ce Mac.
    static let messageReconnexion = """
        Claude n'est plus connecté sur ce Mac (la session a expiré).

        Pour réparer : ouvre le Terminal, tape « claude », puis « /login »,
        connecte-toi dans le navigateur qui s'ouvre, puis tape « /exit ».
        Relance ensuite le traitement.
        """

    /// Vérifie en quelques secondes que Claude répond, AVANT de lancer une
    /// transcription de plusieurs minutes qui échouerait sinon… à la toute fin,
    /// au moment de la traduction. Échec rapide plutôt que temps perdu.
    func verifierClaude() async throws {
        etape("Vérification de la connexion à Claude…", nil)
        _ = try await appelerClaude("Réponds uniquement : OK")
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
            // Comme le script : d'abord -c:a copy, repli aac 192k si échec — mais on ne
            // recopie QUE ce que QuickTime sait lire : une source Opus recopiée telle
            // quelle donnerait un .mp4 « codec manquant ».
            let audioLisible = Moteur.audioCompatibleQuickTime.contains(await codec(video, "a") ?? "?")
            let essais: [[String]] = audioLisible
                ? [["-c:a", "copy"], ["-c:a", "aac", "-b:a", "192k"]]
                : [["-c:a", "aac", "-b:a", "192k"]]
            for audio in essais {
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
        try await assurerFichierLocal(video)
        if let srtFourni { try await assurerFichierLocal(srtFourni) }
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
        // Claude est presque toujours nécessaire (vidéos en anglais) : on s'assure
        // qu'il répond AVANT les minutes de transcription, pas après.
        try await verifierClaude()
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
        try await assurerFichierLocal(video)
        let dureeTotale = await duree(video)
        try await verifierClaude()                   // échec rapide si la session a expiré
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
    /// `libelle` = sujet du passage (description du sommaire ou demande en langage
    /// naturel) : il entre dans le nom du fichier, avec le moment de début.
    // ─────────────────────────────────────────────────────────────
    // Livraison dans le dossier Téléchargements
    // ─────────────────────────────────────────────────────────────

    /// Déplace un fichier FINI vers ~/Downloads, sans jamais écraser (« (2) »…).
    /// nil si le déplacement est refusé (Bitdefender Safe Files, droits) : le fichier
    /// reste alors intact là où il a été fabriqué.
    func deplacerVersTelechargements(_ fichier: URL) -> URL? {
        let dossier = URL(fileURLWithPath: Dossiers.telechargementsMac)
        let base = fichier.deletingPathExtension().lastPathComponent
        let ext = fichier.pathExtension
        var cible = dossier.appendingPathComponent(fichier.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: cible.path) {
            cible = dossier.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: fichier, to: cible)
            return cible
        } catch {
            return nil
        }
    }

    /// Extraction complète, puis livraison de la vidéo dans Téléchargements. Le .srt
    /// éventuel reste dans ~/Movies/Sous-titrage : c'est le fichier de travail qu'on
    /// corrige, il n'a rien à faire au milieu des téléchargements.
    func extraire(video: URL, debut: Double, fin: Double, srtComplet: [BlocSRT], langue: String?, sousTitrer: Bool, libelle: String? = nil) async throws -> ResultatTraitement {
        let r = try await extraireSurPlace(video: video, debut: debut, fin: fin, srtComplet: srtComplet,
                                           langue: langue, sousTitrer: sousTitrer, libelle: libelle)
        guard let livre = deplacerVersTelechargements(r.url) else {
            return ResultatTraitement(url: r.url, sousTitresURL: r.sousTitresURL,
                                      message: r.message + "\nImpossible de le ranger dans Téléchargements : il est resté dans Vidéos › Sous-titrage.")
        }
        return ResultatTraitement(url: livre, sousTitresURL: r.sousTitresURL,
                                  message: r.message + "\nRangé dans Téléchargements.")
    }

    private func extraireSurPlace(video: URL, debut: Double, fin: Double, srtComplet: [BlocSRT], langue: String?, sousTitrer: Bool, libelle: String?) async throws -> ResultatTraitement {
        let ffmpeg = try binaire("ffmpeg", Binaires.ffmpeg)
        let sortieDossier = try Dossiers.preparer(Dossiers.sousTitrage)
        // « <vidéo> · 03m12 Le passage sur Staline_extrait_FR.mp4 » : on retrouve le passage,
        // et deux extraits de la même vidéo ne s'écrasent plus.
        let moment = String(format: "%02dm%02d", Int(debut) / 60, Int(debut) % 60)
        let sujet = libelle.map { Moteur.nettoyerNom($0, max: 50) } ?? ""
        let nom = video.deletingPathExtension().lastPathComponent
            + " · " + (sujet.isEmpty ? moment : "\(moment) \(sujet)")
        let dureeExtrait = fin - debut

        // Si l'extrait sera ensuite sous-titré, cette coupe n'est qu'un intermédiaire
        // (la gravure réencode derrière) : on la fait très vite et quasi sans perte,
        // pour ne pas payer deux encodages lents ni cumuler deux pertes de qualité.
        let (preset, crf) = sousTitrer ? ("ultrafast", "16") : ("fast", "20")

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
            "-c:v", "libx264", "-preset", preset, "-crf", crf,
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

    // ── Tunnel Cloudflare WARP (automatique, le temps du téléchargement) ──

    /// Le tunnel est-il actif ? (« Disconnected » contient « connected » → on
    /// teste l'absence de « disconnected » d'abord.)
    private func tunnelActif(_ warp: String) async -> Bool {
        guard let r = try? await executeurAuxiliaire.lancer(warp, ["status"]) else { return false }
        let t = (r.sortie + r.erreurs).lowercased()
        if t.contains("disconnected") || t.contains("connecting") { return false }
        return t.contains("connected")
    }

    /// Lance une sous-commande warp-cli (avec repli si `--accept-tos` est inconnu
    /// de la version installée).
    private func warpCommande(_ warp: String, _ sousCommande: String) async {
        let r = try? await executeurAuxiliaire.lancer(warp, ["--accept-tos", sousCommande])
        if r?.code != 0 { _ = try? await executeurAuxiliaire.lancer(warp, [sousCommande]) }
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
            if executeur.annule { throw ErreurTraitement.annule }
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

    /// Le serveur du lien répond-il en direct ? (TCP 443, 4 s maxi — /usr/bin/nc
    /// existe sur tout macOS.) C'est le diagnostic express de CLAUDE.md, automatisé.
    private func hoteJoignable(_ hote: String) async -> Bool {
        guard let r = try? await executeurAuxiliaire.lancer("/usr/bin/nc", ["-z", "-G", "4", hote, "443"]) else { return false }
        return r.code == 0
    }

    /// Télécharge la vidéo d'un lien via yt-dlp, dans ~/Movies/Sous-titrage, en mp4
    /// (remux sans réencodage quand possible). Retourne le fichier local, prêt à
    /// enchaîner sur l'une des trois actions.
    ///
    /// Tout ce qui dépend du lieu ou du site est AUTOMATIQUE — rien à cocher :
    /// - si le serveur est injoignable en direct (opérateur qui ne route pas X…) et
    ///   que Cloudflare WARP est installé, le tunnel est ouvert le temps du transfert
    ///   puis refermé (y compris en cas d'échec ou d'annulation) ;
    /// - si le site refuse la vidéo en anonyme (X exige d'être connecté, même pour
    ///   un tweet public), on réessaie avec la session Chrome de Tristan.
    func telecharger(lien: String) async throws -> URL {
        var tunnelParNous = false
        if let hote = URL(string: lien)?.host {
            etape("Vérification de la connexion…", nil)
            if !(await hoteJoignable(hote)) {
                guard Binaires.warp != nil else {
                    throw ErreurTraitement.echec("Impossible de joindre \(hote) depuis ce réseau.\n\nDeux solutions : passer par le partage de connexion de l'iPhone, ou installer le tunnel Cloudflare (Terminal : brew install --cask cloudflare-warp) — l'app l'activera ensuite toute seule quand c'est nécessaire.")
                }
                tunnelParNous = try await activerTunnel()
            }
        }
        do {
            let fichier = try await telechargerAvecRepliCookies(lien: lien)
            if tunnelParNous { await couperTunnel() }
            let identifiant = fichier.deletingPathExtension().lastPathComponent
            // Conversion éventuelle APRÈS la coupure du tunnel : elle n'a pas besoin du réseau.
            let lisible = try await rendreCompatibleQuickTime(fichier)
            // Puis un nom parlant à la place de « clipflow_XXXX » (jamais bloquant).
            let titre = await titrer(lisible, identifiant: identifiant, lien: lien)
            // Puis rangé dans Téléchargements (s'il est refusé, il reste dans « Vidéos téléchargées »).
            return deplacerVersTelechargements(titre) ?? titre
        } catch {
            // Coupure garantie aussi en cas d'échec OU d'annulation.
            if tunnelParNous { await couperTunnel() }
            throw error
        }
    }

    /// Premier essai en anonyme ; si le site réclame une session, second essai
    /// avec les cookies de Chrome (macOS demande alors l'accès au Trousseau, une fois).
    private func telechargerAvecRepliCookies(lien: String) async throws -> URL {
        do {
            return try await telechargerBrut(lien: lien, cookiesNavigateur: nil)
        } catch ErreurTraitement.echec(let message) where Moteur.exigeUneSession(message) {
            etape("Le site demande d'être connecté : nouvel essai avec ta session Chrome…", nil)
            return try await telechargerBrut(lien: lien, cookiesNavigateur: "chrome")
        }
    }

    /// L'échec ressemble-t-il à une vidéo servie seulement aux comptes connectés ?
    private static func exigeUneSession(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("no video could be found") || m.contains("login") || m.contains("log in")
            || m.contains("sign in") || m.contains("nsfw") || m.contains("age-restricted")
            || m.contains("cookies")
    }

    // ─────────────────────────────────────────────────────────────
    // Nom parlant pour les vidéos téléchargées
    // « 2026-10-15 X @compte — Titre court.mp4 » au lieu de « clipflow_5D9FAE04.mp4 »
    // ─────────────────────────────────────────────────────────────

    /// Champs demandés à yt-dlp, écrits en une ligne JSON.
    static let gabaritMeta = "%(.{extractor_key,uploader,uploader_id,channel,title,fulltitle,description,upload_date,timestamp})j"

    static func fichierMeta(_ identifiant: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(identifiant).meta.json")
    }

    struct MetaVideo {
        var plateforme: String?
        var compte: String?
        var date: String?          // AAAA-MM-JJ, date de PUBLICATION
        var titre: String?
        var description: String?
    }

    /// Nom lisible de la plateforme à partir de l'extracteur yt-dlp.
    static func nomPlateforme(_ cle: String) -> String? {
        let table: [(String, String)] = [
            ("twitter", "X"), ("youtube", "YouTube"), ("instagram", "Instagram"),
            ("facebook", "Facebook"), ("tiktok", "TikTok"), ("threads", "Threads"),
            ("bluesky", "Bluesky"), ("telegram", "Telegram"), ("reddit", "Reddit"),
            ("vimeo", "Vimeo"), ("dailymotion", "Dailymotion"), ("rumble", "Rumble"),
            ("twitch", "Twitch"), ("linkedin", "LinkedIn"), ("truthsocial", "Truth Social")
        ]
        let c = cle.lowercased()
        if let t = table.first(where: { c.hasPrefix($0.0) }) { return t.1 }
        if c.isEmpty || c == "generic" { return nil }
        return c.prefix(1).uppercased() + c.dropFirst()
    }

    private func lireMeta(_ identifiant: String) -> MetaVideo? {
        let url = Moteur.fichierMeta(identifiant)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let texte = try? String(contentsOf: url, encoding: .utf8),
              let ligne = texte.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let data = String(ligne).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        func s(_ k: String) -> String? {
            guard let v = obj[k] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var m = MetaVideo()
        m.plateforme = Moteur.nomPlateforme(s("extractor_key") ?? "")
        // Réseaux à pseudo (@compte) : on garde le pseudo ; ailleurs, le nom de la chaîne.
        let pseudo = (s("uploader_id") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let reseauxAPseudo: Set<String> = ["X", "Instagram", "TikTok", "Threads", "Bluesky", "Truth Social"]
        if reseauxAPseudo.contains(m.plateforme ?? ""), !pseudo.isEmpty, !pseudo.allSatisfy(\.isNumber) {
            m.compte = "@" + pseudo
        } else {
            m.compte = s("channel") ?? s("uploader")
        }
        if let d = s("upload_date"), d.count == 8, d.allSatisfy(\.isNumber) {
            m.date = "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))"
        } else if let ts = obj["timestamp"] as? Double {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            m.date = f.string(from: Date(timeIntervalSince1970: ts))
        }
        m.titre = s("title") ?? s("fulltitle")
        m.description = s("description")
        return m
    }

    /// Rend un texte utilisable comme nom de fichier : pas de / : \ |, pas de retour à
    /// la ligne ni d'emoji, espaces resserrés, longueur bornée.
    static func nettoyerNom(_ texte: String, max: Int = 90) -> String {
        var r = ""
        for u in texte.unicodeScalars {
            if u.properties.isEmojiPresentation || (u.properties.isEmoji && u.value >= 0x2000)
                || u.value == 0xFE0F || u.value == 0x200D { continue }
            switch u {
            case "/", ":", "\\", "|": r += " - "
            case "\"", "<", ">", "?", "*", "«", "»", "“", "”": continue
            default:
                if CharacterSet.controlCharacters.contains(u) || CharacterSet.newlines.contains(u) { r += " " }
                else { r.unicodeScalars.append(u) }
            }
        }
        r = r.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        r = r.trimmingCharacters(in: CharacterSet(charactersIn: " .-–—"))
        if r.count > max {
            r = String(r.prefix(max)).trimmingCharacters(in: CharacterSet(charactersIn: " .-–—")) + "…"
        }
        return r
    }

    /// Trois vignettes de la vidéo (début, milieu, fin), 640 px de large, ~25 Ko chacune.
    /// Elles donnent le contexte quand le texte du post se résume à « waouh » : bandeau
    /// d'information, nom à l'écran, logo de média, lieu. Dossier vide si ffmpeg échoue.
    private func capturesPourTitre(_ fichier: URL) async -> URL? {
        guard let ffmpeg = Binaires.ffmpeg else { return nil }
        let dossier = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipflow_captures_\(UUID().uuidString.prefix(8))")
        guard (try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)) != nil
        else { return nil }
        let d = await duree(fichier)
        let instants: [Double] = d > 0 ? [0.15, 0.5, 0.85].map { $0 * d } : [1]
        var n = 0
        for (i, t) in instants.enumerated() {
            let image = dossier.appendingPathComponent("capture\(i + 1).jpg")
            let r = try? await executeur.lancer(ffmpeg, [
                "-v", "error", "-y", "-ss", String(format: "%.2f", t), "-i", fichier.path,
                "-frames:v", "1", "-vf", "scale=640:-2", "-q:v", "4", image.path])
            if r?.code == 0, FileManager.default.fileExists(atPath: image.path) { n += 1 }
        }
        if n == 0 { try? FileManager.default.removeItem(at: dossier); return nil }
        return dossier
    }

    /// Titre court en français, rédigé par Claude à partir du texte du post et de
    /// vignettes de la vidéo. nil si Claude ne répond pas ou répond à côté : on retombe
    /// alors sur le titre brut.
    private func titreCourt(_ m: MetaVideo, captures: URL?) async -> String? {
        let source = [m.titre, m.description].compactMap { $0 }.joined(separator: "\n\n")
        let images = captures.flatMap {
            try? FileManager.default.contentsOfDirectory(atPath: $0.path)
        }?.filter { $0.hasSuffix(".jpg") }.sorted() ?? []
        guard !source.isEmpty || !images.isEmpty else { return nil }
        let partieImages = images.isEmpty ? "" : """
             Regarde aussi les images extraites de la vidéo (début, milieu, fin), dans le dossier courant : \(images.joined(separator: ", ")). Elles donnent souvent le contexte que le texte n'a pas : personnes, bandeau d'information, texte à l'écran, logo de média, lieu.
            """
        let prompt = """
        Voici le titre et le texte d'accompagnement d'une vidéo publiée sur \(m.plateforme ?? "un site web")\(m.compte.map { " par \($0)" } ?? "").\(partieImages) Propose un titre de fichier en français, court (4 à 8 mots), factuel et précis, qui permette de retrouver la vidéo plus tard : qui dit ou montre quoi. Pas de guillemets, pas d'emoji, pas de point final, ni date ni nom de plateforme. Réponds uniquement par le titre.

        \(source.isEmpty ? "(aucun texte)" : String(source.prefix(2000)))
        """
        let reponse: String
        do {
            reponse = try await appelerClaude(prompt, imagesDans: images.isEmpty ? nil : captures)
        } catch {
            Moteur.journal("titrage : appel à Claude échoué — \(String(error.localizedDescription.prefix(300)))")
            return nil
        }
        let ligne = reponse.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        let titre = Moteur.nettoyerNom(ligne, max: 80)
        return (titre.count >= 3 && titre.count <= 81) ? titre : nil
    }

    /// « date plateforme compte — titre », chaque morceau étant facultatif.
    static func nomParlant(_ m: MetaVideo, titre: String?) -> String? {
        var tete: [String] = []
        if let d = m.date { tete.append(d) }
        if let p = m.plateforme { tete.append(p) }
        if let c = m.compte { tete.append(Moteur.nettoyerNom(c, max: 30)) }
        let entete = tete.joined(separator: " ")
        let t = (titre ?? m.titre.map { Moteur.nettoyerNom($0, max: 60) }) ?? ""
        switch (entete.isEmpty, t.isEmpty) {
        case (true, true):  return nil
        case (false, true): return entete
        case (true, false): return t
        default:            return "\(entete) — \(t)"
        }
    }

    /// Renomme sans jamais écraser un fichier existant (ajoute « (2) », « (3) »…).
    /// En cas d'échec, garde l'ancien nom plutôt que d'interrompre quoi que ce soit.
    private func renommer(_ fichier: URL, en base: String) -> URL {
        let dossier = fichier.deletingLastPathComponent()
        let ext = fichier.pathExtension
        var cible = dossier.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: cible.path) {
            cible = dossier.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: fichier, to: cible)
            Moteur.journal("renommage OK → \(cible.lastPathComponent)")
            return cible
        } catch {
            Moteur.journal("renommage ÉCHOUÉ vers « \(cible.lastPathComponent) » : \(error.localizedDescription)")
            return fichier
        }
    }

    /// Ce que le lien dit à lui seul : le réseau, et le compte quand il figure dans
    /// l'adresse (x.com/<compte>/status/…, tiktok.com/@compte/…, threads.net/@compte/…).
    /// Sert de base quand yt-dlp n'a pas fourni ses informations, et de complément sinon.
    static func metaDepuisLien(_ lien: String) -> MetaVideo {
        var m = MetaVideo()
        guard let u = URL(string: lien), var hote = u.host?.lowercased() else { return m }
        if hote.hasPrefix("www.") { hote.removeFirst(4) }
        if hote.hasPrefix("m.") { hote.removeFirst(2) }
        let table: [(String, String)] = [
            ("x.com", "X"), ("twitter.com", "X"), ("youtube.com", "YouTube"), ("youtu.be", "YouTube"),
            ("instagram.com", "Instagram"), ("facebook.com", "Facebook"), ("fb.watch", "Facebook"),
            ("tiktok.com", "TikTok"), ("threads.net", "Threads"), ("threads.com", "Threads"),
            ("bsky.app", "Bluesky"), ("t.me", "Telegram"), ("reddit.com", "Reddit"),
            ("vimeo.com", "Vimeo"), ("dailymotion.com", "Dailymotion"), ("rumble.com", "Rumble"),
            ("truthsocial.com", "Truth Social"), ("linkedin.com", "LinkedIn")
        ]
        m.plateforme = table.first(where: { hote == $0.0 || hote.hasSuffix("." + $0.0) })?.1
        let morceaux = u.pathComponents.filter { $0 != "/" }
        if let premier = morceaux.first {
            if m.plateforme == "X", !["i", "home", "search", "hashtag"].contains(premier.lowercased()) {
                m.compte = "@" + premier
            } else if ["TikTok", "Threads"].contains(m.plateforme ?? ""), premier.hasPrefix("@") {
                m.compte = premier
            }
        }
        return m
    }

    /// Journal des titrages : ~/Library/Logs/ClipFlow.log (une ligne horodatée par étape).
    /// Il dit, quand un fichier garde son nom provisoire, laquelle des étapes a cédé.
    static func journal(_ ligne: String) {
        let url = URL(fileURLWithPath: NSString(string: "~/Library/Logs/ClipFlow.log").expandingTildeInPath)
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let donnees = "\(f.string(from: Date()))  \(ligne)\n".data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: donnees)
        } else {
            try? donnees.write(to: url)
        }
    }

    private func titrer(_ fichier: URL, identifiant: String, lien: String) async -> URL {
        let duLien = Moteur.metaDepuisLien(lien)
        var meta: MetaVideo
        if let lue = lireMeta(identifiant) {
            meta = lue
            meta.plateforme = meta.plateforme ?? duLien.plateforme
            meta.compte = meta.compte ?? duLien.compte
            Moteur.journal("titrage : infos du post trouvées (\(meta.plateforme ?? "?") \(meta.compte ?? "?"), date \(meta.date ?? "?"))")
        } else {
            meta = duLien
            Moteur.journal("titrage : infos du post ABSENTES (attendues dans \(Moteur.fichierMeta(identifiant).path)) — repli sur le lien : \(meta.plateforme ?? "?") \(meta.compte ?? "?")")
        }
        etape("Choix d'un titre (regard sur la vidéo)…", nil)
        let captures = await capturesPourTitre(fichier)
        defer { if let captures { try? FileManager.default.removeItem(at: captures) } }
        Moteur.journal("titrage : \(captures == nil ? "aucune vignette" : "vignettes extraites")")
        let court = await titreCourt(meta, captures: captures)
        Moteur.journal("titrage : titre proposé par Claude = \(court ?? "AUCUN")")
        guard let base = Moteur.nomParlant(meta, titre: court) else {
            Moteur.journal("titrage : rien pour composer un nom — nom provisoire conservé")
            return fichier
        }
        return renommer(fichier, en: base)
    }

    private func telechargerBrut(lien: String, cookiesNavigateur: String?) async throws -> URL {
        let ytdlp = try binaire("yt-dlp", Binaires.ytdlp)
        // Sous-dossier dédié : un fichier ajouté dans un SOUS-dossier ne réveille pas une
        // Folder Action posée sur ~/Movies/Sous-titrage (dépôt public), quel que soit son nom.
        let dossier = try Dossiers.preparer(Dossiers.telechargements)
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
            // Meilleure vidéo+audio, plafonnée à 1080p : au-delà (4K YouTube), le fichier
            // est bien plus lourd sans intérêt pour un clip réseaux sociaux, et chaque
            // étape suivante (gravure, compression) serait d'autant plus lente.
            "-f", "bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b",
            // Préférer H.264 + AAC : les seuls codecs que QuickTime lit à coup sûr.
            // Sans ça, YouTube sert de l'AV1/VP9 + Opus → « codec manquant ».
            "-S", "vcodec:h264,res,acodec:m4a",
            "--remux-video", "mp4",          // conteneur mp4 sans réencodage si possible
            // Résilience aux coupures passagères (X/Twitter time out souvent) :
            "--socket-timeout", "30",        // délai de connexion allongé (défaut 20 s)
            "--retries", "5",                // relances du téléchargement
            "--extractor-retries", "3",      // relances de la récupération des métadonnées (JSON)
            "--retry-sleep", "3",            // petite pause entre les tentatives
            // Informations du post (compte, date, titre, texte) dans un petit JSON à part,
            // pour donner ensuite un nom parlant au fichier. --no-simulate et --progress
            // garantissent que cette option ne coupe ni le téléchargement ni la progression.
            "--print-to-file", Moteur.gabaritMeta, Moteur.fichierMeta(identifiant).path,
            "--no-simulate", "--progress",
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
            let detail = String((err.isEmpty ? out : err).suffix(400))
            let d = detail.lowercased()
            let conseil: String
            if cookiesNavigateur != nil && Moteur.exigeUneSession(detail) {
                conseil = "Même avec ta session Chrome, le site ne donne pas cette vidéo : elle a peut-être été supprimée, ou le compte est protégé. Vérifie aussi que Chrome est bien connecté à ce site."
            } else if d.contains("timed out") || d.contains("timeout") {
                conseil = "Le site n'a pas répondu (réseau). Réessaie ; si ça persiste sur ce réseau, passe par le partage de connexion de l'iPhone."
            } else {
                conseil = "Si le site a changé, mets yt-dlp à jour : brew upgrade yt-dlp"
            }
            let suffixe = detail.isEmpty ? "" : "\n\n\(detail)"
            throw ErreurTraitement.echec("Téléchargement échoué.\n\n\(conseil)\(suffixe)")
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
    // Compatibilité QuickTime
    // ─────────────────────────────────────────────────────────────

    /// Codecs que QuickTime lit dans un .mp4 ("" = pas de flux de ce type).
    static let videoCompatibleQuickTime: Set<String> = ["h264", "hevc", ""]
    static let audioCompatibleQuickTime: Set<String> = ["aac", "mp3", "alac", ""]

    /// Codec du premier flux vidéo ("v") ou audio ("a") : "h264", "av1", "opus"…
    /// "" s'il n'y a pas de tel flux, nil si ffprobe ne peut pas répondre.
    private func codec(_ fichier: URL, _ flux: String) async -> String? {
        guard let ffprobe = Binaires.ffprobe,
              let r = try? await executeur.lancer(ffprobe, [
                "-v", "error", "-select_streams", "\(flux):0",
                "-show_entries", "stream=codec_name",
                "-of", "default=noprint_wrappers=1:nokey=1", fichier.path]),
              r.code == 0
        else { return nil }
        return r.sortie.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// QuickTime ne lit ni l'AV1/VP9 ni l'Opus (« il manque un codec »). Si un
    /// téléchargement en contient malgré la préférence H.264/AAC demandée à yt-dlp
    /// (certaines vidéos n'existent qu'en AV1), on convertit : ce qui est déjà lisible
    /// est recopié tel quel, seul le reste est réencodé.
    private func rendreCompatibleQuickTime(_ fichier: URL) async throws -> URL {
        guard let ffmpeg = Binaires.ffmpeg,
              let video = await codec(fichier, "v"),
              let audio = await codec(fichier, "a")
        else { return fichier }                        // indéterminable : on ne touche à rien
        let videoOK = Moteur.videoCompatibleQuickTime.contains(video)
        let audioOK = Moteur.audioCompatibleQuickTime.contains(audio)
        if videoOK && audioOK && fichier.pathExtension.lowercased() == "mp4" { return fichier }

        var args = ["-y", "-i", fichier.path]
        switch video {
        case "":     break
        case "h264": args += ["-c:v", "copy"]
        case "hevc": args += ["-c:v", "copy", "-tag:v", "hvc1"]   // hvc1 : exigé par QuickTime
        default:     args += ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]
        }
        if !audio.isEmpty {
            args += audioOK ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
        }
        let tmp = fichier.deletingLastPathComponent()
            .appendingPathComponent(fichier.deletingPathExtension().lastPathComponent + "_qt.mp4")
        args += ["-movflags", "+faststart", tmp.path]

        let dureeTotale = await duree(fichier)
        let libelle = videoOK ? "Conversion du son pour QuickTime…" : "Conversion pour QuickTime…"
        etape(libelle, 0)
        let rapporter = progression
        let r: ResultatProcessus
        do {
            r = try await executeur.lancer(ffmpeg, args, surLigneErreur: { ligne in
                if let f = Moteur.fractionFFmpeg(ligne, dureeTotale: dureeTotale) { rapporter(libelle, f) }
            })
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        guard r.code == 0, FileManager.default.fileExists(atPath: tmp.path) else {
            try? FileManager.default.removeItem(at: tmp)
            return fichier                              // l'original reste exploitable par ClipFlow
        }
        let final = fichier.deletingPathExtension().appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: fichier)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: tmp, to: final)
        return final
    }

    // ─────────────────────────────────────────────────────────────
    // Action 3 — Compresser (reprend compresser-video.sh)
    // ─────────────────────────────────────────────────────────────

    func compresser(video: URL, crf: Int) async throws -> ResultatTraitement {
        let ffmpeg = try binaire("ffmpeg", Binaires.ffmpeg)
        let sortieDossier = try Dossiers.preparer(Dossiers.compression)
        let nom = video.deletingPathExtension().lastPathComponent
        let sortie = URL(fileURLWithPath: sortieDossier).appendingPathComponent("\(nom)_compressed.mp4")
        try await assurerFichierLocal(video)
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
