import SwiftUI

/// État global de l'app + orchestration des traitements.
@MainActor
final class VueModele: ObservableObject {

    enum Phase {
        case pret                          // en attente d'une vidéo / d'un lancement
        case enCours                       // traitement en route (progression affichée)
        case choixExtrait                  // sommaire affiché, en attente du choix du passage
        case confirmerExtrait              // passage choisi : aperçu du texte + options avant coupe
        case termine(ResultatTraitement)
        case erreur(String)
    }

    @Published var mode: ModeApp = .sousTitrer {
        didSet { if mode != oldValue { reinitialiser() } }
    }

    @Published var video: URL?
    @Published var srtFourni: URL?                       // mode « Utiliser mon .srt »
    @Published var lienEntree: String = ""               // « coller un lien » → yt-dlp
    @Published var niveauCompression: NiveauCompression = .equilibre

    @Published var phase: Phase = .pret
    @Published var etapeLibelle: String = ""
    @Published var fraction: Double?                     // nil = indéterminé

    // État de l'extraction
    @Published var blocsSommaire: [BlocSommaire] = []
    @Published var selection: Set<UUID> = []
    @Published var demandeNaturelle: String = ""
    private var srtComplet: [BlocSRT] = []
    private var langueDetectee: String?

    // Passage choisi, en attente de confirmation (aperçu avant coupe)
    @Published var debutExtrait: Double?
    @Published var finExtrait: Double?
    @Published var sousTitrerExtrait: Bool = false     // désactivé par défaut ; préférence conservée d'un extrait à l'autre

    /// Texte d'origine (transcription) du passage choisi, pour l'aperçu avant coupe.
    var texteExtrait: String {
        guard let d = debutExtrait, let f = finExtrait else { return "" }
        return srtComplet
            .filter { $0.fin > d && $0.debut < f }
            .map { $0.texte }
            .joined(separator: " ")
    }

    /// Plage du passage choisi, formatée « M:SS → M:SS (durée s) ».
    var plageExtraitAffichee: String {
        guard let d = debutExtrait, let f = finExtrait else { return "" }
        func mmss(_ s: Double) -> String {
            let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
        }
        return "\(mmss(d)) → \(mmss(f))  (\(Int((f - d).rounded())) s)"
    }

    private var moteur: Moteur?
    private var tache: Task<Void, Never>?
    /// Jeton de génération : incrémenté à chaque lancement / annulation / reset.
    /// Un job périmé (annulé mais dont le sous-processus se termine tard) ne doit
    /// PAS écraser l'état d'un job démarré ensuite — on compare son jeton au courant.
    private var generation = 0

    var enCours: Bool {
        if case .enCours = phase { return true }
        return false
    }

    /// Extensions vidéo acceptées (compression : mêmes formats que le script).
    var extensionsAcceptees: [String] {
        mode == .compresser ? ["mp4", "mov", "m4v", "mkv", "avi", "webm"]
                            : ["mp4", "mov", "m4v"]
    }

    func accepter(url: URL) {
        guard !enCours else { return }
        let ext = url.pathExtension.lowercased()
        if ext == "srt" {
            if mode == .sousTitrer { srtFourni = url }
            return
        }
        guard extensionsAcceptees.contains(ext) else { return }
        if url != video { effacerAnalyse() }     // autre vidéo → l'ancienne transcription ne vaut plus
        video = url
        if case .termine = phase { phase = .pret }
        if case .erreur = phase { phase = .pret }
    }

    /// Ouvre dans le Finder le dossier de sortie du mode courant (le dossier est
    /// créé s'il n'existe pas encore, pour ne jamais ouvrir dans le vide).
    func ouvrirDossierSortie() {
        let voulu = (mode == .compresser) ? Dossiers.compression : Dossiers.sousTitrage
        let chemin = (try? Dossiers.preparer(voulu)) ?? voulu
        NSWorkspace.shared.open(URL(fileURLWithPath: chemin))
    }

    func reinitialiser() {
        generation += 1                 // invalide les callbacks/fin du job en cours
        tache?.cancel()
        moteur?.neutraliser()
        moteur = nil
        phase = .pret
        etapeLibelle = ""
        fraction = nil
        effacerAnalyse()
        srtFourni = nil
        // Après un changement de mode, une vidéo valide pour l'ancien mode
        // (ex. .webm en compression) peut ne plus l'être : on la retire.
        if let v = video, !extensionsAcceptees.contains(v.pathExtension.lowercased()) {
            video = nil
        }
    }

    /// Oublie la transcription et le sommaire (autre vidéo → autre analyse).
    private func effacerAnalyse() {
        blocsSommaire = []
        selection = []
        srtComplet = []
        langueDetectee = nil
        demandeNaturelle = ""
        debutExtrait = nil
        finExtrait = nil
    }

    func annuler() {
        generation += 1                 // le job courant devient périmé
        moteur?.neutraliser()
        tache?.cancel()
        phase = .pret
        etapeLibelle = ""
        fraction = nil
    }

    private func nouveauMoteur(_ gen: Int) -> Moteur {
        let throttle = Throttle()
        let m = Moteur()
        m.progression = { [weak self] libelle, fraction in
            // Filtrer le bruit : ffmpeg émet plusieurs lignes/seconde. On ne
            // réveille le MainActor que si l'étape change ou la barre avance nettement.
            guard throttle.doitEmettre(libelle: libelle, fraction: fraction) else { return }
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.etapeLibelle = libelle
                self.fraction = fraction
            }
        }
        moteur = m
        return m
    }

    /// Lance un travail asynchrone et applique la Phase qu'il retourne, en
    /// ignorant tout résultat d'un job périmé (jeton de génération).
    /// Le travail est @MainActor : il peut lire/écrire l'état publié en toute
    /// sécurité entre deux `await` (les appels moteur libèrent l'acteur).
    private func demarrer(_ travail: @escaping @MainActor (Moteur) async throws -> Phase) {
        guard video != nil else { return }
        generation += 1
        let gen = generation
        let m = nouveauMoteur(gen)
        phase = .enCours
        etapeLibelle = "Préparation…"
        fraction = nil
        tache = Task {
            let resultat: Phase
            do {
                resultat = try await travail(m)
            } catch is CancellationError {
                resultat = .pret
            } catch let e as ErreurTraitement {
                if case .annule = e { resultat = .pret } else { resultat = .erreur(e.localizedDescription) }
            } catch {
                resultat = .erreur(error.localizedDescription)
            }
            guard self.generation == gen else { return }   // job périmé → ne rien toucher
            self.phase = resultat
            self.etapeLibelle = ""
            self.fraction = nil
        }
    }

    // ── Téléchargement d'un lien (entrée en amont) ──

    /// Télécharge la vidéo du lien collé, puis revient à l'accueil avec la vidéo
    /// chargée : Tristan choisit ensuite l'action (pas d'enchaînement automatique).
    func telecharger() {
        let lien = lienEntree.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lien.isEmpty else { return }
        guard let url = URL(string: lien), let s = url.scheme?.lowercased(), s == "http" || s == "https" else {
            phase = .erreur("Lien invalide : colle une URL commençant par http(s) (YouTube, X, Fox…).")
            return
        }
        let manques = Binaires.verifierYtDlp()
        guard manques.isEmpty else { phase = .erreur(manques.joined(separator: "\n")); return }

        generation += 1
        let gen = generation
        let m = nouveauMoteur(gen)
        phase = .enCours
        etapeLibelle = "Téléchargement…"
        fraction = nil
        tache = Task {
            let issue: Result<URL, Error>
            do { issue = .success(try await m.telecharger(lien: lien)) }
            catch { issue = .failure(error) }
            guard self.generation == gen else { return }
            switch issue {
            case .success(let fichier):
                self.effacerAnalyse()
                self.video = fichier
                self.srtFourni = nil
                self.lienEntree = ""
                self.phase = .pret
            case .failure(let e):
                if e is CancellationError { self.phase = .pret }
                else if let et = e as? ErreurTraitement, case .annule = et { self.phase = .pret }
                else { self.phase = .erreur((e as? LocalizedError)?.errorDescription ?? e.localizedDescription) }
            }
            self.etapeLibelle = ""
            self.fraction = nil
        }
    }

    // ── Lancements ──

    func lancer() {
        guard let video else { return }
        switch mode {
        case .sousTitrer:
            let manques = Binaires.verifier(besoinWhisper: srtFourni == nil, besoinClaude: srtFourni == nil)
            guard manques.isEmpty else { phase = .erreur(manques.joined(separator: "\n")); return }
            let srt = srtFourni
            demarrer { .termine(try await $0.sousTitrer(video: video, srtFourni: srt)) }
        case .extraire:
            let manques = Binaires.verifier(besoinWhisper: true, besoinClaude: true)
            guard manques.isEmpty else { phase = .erreur(manques.joined(separator: "\n")); return }
            analyser(video)
        case .compresser:
            let manques = Binaires.verifier(besoinWhisper: false, besoinClaude: false)
            guard manques.isEmpty else { phase = .erreur(manques.joined(separator: "\n")); return }
            let crf = niveauCompression.rawValue
            demarrer { .termine(try await $0.compresser(video: video, crf: crf)) }
        }
    }

    /// Extraction, phase 1 : transcription + sommaire → affichage du choix.
    private func analyser(_ video: URL) {
        demarrer { [weak self] m in
            let (blocs, srt, langue) = try await m.analyserPourExtraction(video: video)
            guard let self else { return .pret }
            self.blocsSommaire = blocs
            self.srtComplet = srt
            self.langueDetectee = langue
            self.selection = []
            return .choixExtrait
        }
    }

    /// Extraction, phase 2a : depuis la sélection dans le sommaire
    /// (blocs multiples → début du premier, fin du dernier).
    /// Ne coupe PAS : affiche l'aperçu de confirmation.
    func extraireSelection() {
        let choisis = blocsSommaire.filter { selection.contains($0.id) }
        guard let debut = choisis.map(\.debut).min(),
              let fin = choisis.map(\.fin).max() else { return }
        debutExtrait = debut
        finExtrait = fin
        phase = .confirmerExtrait
    }

    /// Extraction, phase 2b : depuis une demande en langage naturel.
    /// Claude cherche les timecodes, puis on affiche l'aperçu (on ne coupe PAS
    /// directement : Tristan voit le passage trouvé avant de lancer).
    func extraireDemande() {
        let demande = demandeNaturelle.trimmingCharacters(in: .whitespaces)
        guard !demande.isEmpty else { return }
        let srt = srtComplet

        generation += 1
        let gen = generation
        let m = nouveauMoteur(gen)
        phase = .enCours
        etapeLibelle = "Recherche du passage…"
        fraction = nil
        tache = Task {
            let issue: Result<(Double, Double), Error>
            do { issue = .success(try await m.chercherPassage(srt: srt, demande: demande)) }
            catch { issue = .failure(error) }
            guard self.generation == gen else { return }
            switch issue {
            case .success(let (debut, fin)):
                self.debutExtrait = debut
                self.finExtrait = fin
                self.phase = .confirmerExtrait
            case .failure(let e):
                if e is CancellationError { self.phase = .choixExtrait }
                else if let et = e as? ErreurTraitement, case .annule = et { self.phase = .choixExtrait }
                else { self.phase = .erreur((e as? LocalizedError)?.errorDescription ?? e.localizedDescription) }
            }
            self.etapeLibelle = ""
            self.fraction = nil
        }
    }

    /// Extraction, phase 3 : coupe réelle du passage confirmé (+ sous-titres si demandé).
    func lancerExtraction() {
        guard let video, let debut = debutExtrait, let fin = finExtrait else { return }
        let srt = srtComplet
        let langue = langueDetectee
        let sousTitrer = sousTitrerExtrait
        demarrer { .termine(try await $0.extraire(video: video, debut: debut, fin: fin,
                                                  srtComplet: srt, langue: langue, sousTitrer: sousTitrer)) }
    }

    /// Revenir de l'aperçu au choix du passage (sans couper).
    func retourChoixExtrait() {
        debutExtrait = nil
        finExtrait = nil
        phase = .choixExtrait
    }

    /// Après une extraction, la transcription et le sommaire sont encore là : on
    /// peut choisir un autre passage de la même vidéo SANS tout retranscrire.
    var peutExtraireAutrePassage: Bool {
        mode == .extraire && !blocsSommaire.isEmpty && !srtComplet.isEmpty
    }

    func extraireAutrePassage() {
        guard peutExtraireAutrePassage else { reinitialiser(); return }
        debutExtrait = nil
        finExtrait = nil
        selection = []
        demandeNaturelle = ""
        phase = .choixExtrait
    }
}

/// Limiteur de débit pour la progression : émet si l'étape change, si la barre
/// avance d'au moins 1 %, ou si la fraction devient indéterminée.
private final class Throttle: @unchecked Sendable {
    private let verrou = NSLock()
    private var dernierLibelle = ""
    private var derniereFraction: Double = -1

    func doitEmettre(libelle: String, fraction: Double?) -> Bool {
        verrou.lock(); defer { verrou.unlock() }
        guard let fraction else {
            dernierLibelle = libelle
            derniereFraction = -1
            return true
        }
        if libelle != dernierLibelle || fraction < derniereFraction || fraction - derniereFraction >= 0.01 {
            dernierLibelle = libelle
            derniereFraction = fraction
            return true
        }
        return false
    }
}
