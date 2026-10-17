import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var modele = VueModele()

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Picker("", selection: $modele.mode) {
                    ForEach(ModeApp.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(modele.enCours)

                // Toujours accessible, quelle que soit l'étape : ouvre le dossier
                // de sortie du mode courant (Sous-titrage ou Compression).
                Button { modele.ouvrirDossierSortie() } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .help(modele.mode == .compresser
                      ? "Ouvrir le dossier des vidéos compressées"
                      : "Ouvrir le dossier des vidéos traitées")
            }
            .padding(.horizontal)

            contenuPrincipal
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)   // Tristan préfère le thème sombre
    }

    @ViewBuilder
    private var contenuPrincipal: some View {
        switch modele.phase {
        case .pret:
            PanneauPreparation(modele: modele)
        case .enCours:
            PanneauProgression(modele: modele)
        case .choixExtrait:
            PanneauChoixExtrait(modele: modele)
        case .confirmerExtrait:
            PanneauConfirmerExtrait(modele: modele)
        case .termine(let resultat):
            PanneauResultat(modele: modele, resultat: resultat)
        case .erreur(let message):
            PanneauErreur(modele: modele, message: message)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// Préparation : zone de dépôt + options + bouton Lancer
// ─────────────────────────────────────────────────────────────

struct PanneauPreparation: View {
    @ObservedObject var modele: VueModele

    var body: some View {
        VStack(spacing: 14) {
            ZoneDepot(modele: modele)
                .padding(.horizontal)

            if let video = modele.video {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([video])
                } label: {
                    Label("Révéler dans le Finder", systemImage: "magnifyingglass")
                }
                .buttonStyle(.link)
                .font(.callout)
            }

            champLien

            options

            Spacer(minLength: 0)

            Button(action: { modele.lancer() }) {
                Text(libelleBouton)
                    .frame(minWidth: 180)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(modele.video == nil)
            .padding(.bottom, 4)
        }
    }

    private var libelleBouton: String {
        switch modele.mode {
        case .sousTitrer: return modele.srtFourni == nil ? "Sous-titrer" : "Graver mon .srt"
        case .extraire: return "Analyser la vidéo"
        case .compresser: return "Compresser"
        }
    }

    /// Entrée alternative à la zone de dépôt : coller un lien à télécharger (yt-dlp).
    private var champLien: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("ou colle un lien (YouTube, X, Fox…)", text: $modele.lienEntree)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { modele.telecharger() }
                Button("Télécharger") { modele.telecharger() }
                    .disabled(modele.lienEntree.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(modele.mode == .sousTitrer
                 ? "Sur cet onglet, la vidéo est téléchargée puis sous-titrée directement."
                 : "La vidéo se charge ici, puis tu choisis l'action. Connexion au site et tunnel réseau : gérés automatiquement.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var options: some View {
        switch modele.mode {
        case .sousTitrer:
            VStack(spacing: 6) {
                if let srt = modele.srtFourni {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                        Text(srt.lastPathComponent)
                        Button("Retirer") { modele.srtFourni = nil }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                    Text("Ton .srt sera gravé tel quel (sortie _ST).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    BoutonChoisirFichier(titre: "Utiliser mon .srt…", types: [UTType(filenameExtension: "srt") ?? .plainText]) { url in
                        modele.srtFourni = url
                    }
                    .buttonStyle(.link)
                    Text("Sinon : transcription locale (Whisper) puis traduction en français (Claude).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .extraire:
            Text("La vidéo sera transcrite, puis Claude proposera un sommaire des passages.")
                .font(.caption).foregroundStyle(.secondary)
        case .compresser:
            VStack(spacing: 6) {
                Picker("Niveau", selection: $modele.niveauCompression) {
                    ForEach(NiveauCompression.allCases) { niveau in
                        Text(niveau.libelle).tag(niveau)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("Réencodage H.264 à qualité constante — forte réduction sans perte visible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// Zone de dépôt (drag & drop + clic pour choisir)
// ─────────────────────────────────────────────────────────────

struct ZoneDepot: View {
    @ObservedObject var modele: VueModele
    @StateObject private var survole = Etat(false)
    @StateObject private var montrePanneau = Etat(false)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(survole.valeur ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(survole.valeur ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            VStack(spacing: 10) {
                Image(systemName: modele.video == nil ? "film" : "checkmark.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(modele.video == nil ? Color.secondary : Color.accentColor)
                if let video = modele.video {
                    Text(video.lastPathComponent)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("Dépose une autre vidéo pour la remplacer")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Dépose une vidéo ici")
                        .font(.headline)
                    Text("ou clique pour choisir un fichier")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, minHeight: 170)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { montrePanneau.valeur = true }
        .onDrop(of: [.fileURL], isTargeted: $survole.valeur) { fournisseurs in
            deposer(fournisseurs)
        }
        .fileImporter(isPresented: $montrePanneau.valeur,
                      allowedContentTypes: typesAcceptes,
                      allowsMultipleSelection: false) { resultat in
            if case .success(let urls) = resultat, let url = urls.first {
                modele.accepter(url: url)
            }
        }
    }

    private var typesAcceptes: [UTType] {
        // Uniquement les formats du mode courant (+ le .srt en sous-titrage), pour
        // que le sélecteur ne propose PAS des fichiers qui seraient ensuite refusés
        // silencieusement. Le glisser-déposer reste filtré par accepter().
        var types = modele.extensionsAcceptees.compactMap { UTType(filenameExtension: $0) }
        if modele.mode == .sousTitrer, let srt = UTType(filenameExtension: "srt") { types.append(srt) }
        return types
    }

    private func deposer(_ fournisseurs: [NSItemProvider]) -> Bool {
        // Traiter TOUS les fichiers déposés (ex. vidéo + .srt de même nom ensemble),
        // pas seulement le premier. accepter() trie vidéo / .srt.
        let pertinents = fournisseurs.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !pertinents.isEmpty else { return false }
        for fournisseur in pertinents {
            fournisseur.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url {
                    Task { @MainActor in modele.accepter(url: url) }
                }
            }
        }
        return true
    }
}

/// Petit bouton ouvrant un sélecteur de fichier.
struct BoutonChoisirFichier: View {
    let titre: String
    let types: [UTType]
    let action: (URL) -> Void
    @StateObject private var montre = Etat(false)

    var body: some View {
        Button(titre) { montre.valeur = true }
            .fileImporter(isPresented: $montre.valeur, allowedContentTypes: types, allowsMultipleSelection: false) { resultat in
                if case .success(let urls) = resultat, let url = urls.first { action(url) }
            }
    }
}

// ─────────────────────────────────────────────────────────────
// Progression
// ─────────────────────────────────────────────────────────────

struct PanneauProgression: View {
    @ObservedObject var modele: VueModele

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            if let video = modele.video {
                Text(video.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(modele.etapeLibelle.isEmpty ? "Traitement…" : modele.etapeLibelle)
                .font(.title3)
            Group {
                if let fraction = modele.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .frame(maxWidth: 360)
            if modele.fraction == nil {
                Text("Cette étape peut prendre plusieurs minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Annuler") { modele.annuler() }
                .controlSize(.large)
                .padding(.bottom, 4)
        }
        .padding(.horizontal)
    }
}

// ─────────────────────────────────────────────────────────────
// Choix du passage à extraire (sommaire + langage naturel)
// ─────────────────────────────────────────────────────────────

struct PanneauChoixExtrait: View {
    @ObservedObject var modele: VueModele

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choisis le passage à extraire")
                .font(.headline)
                .padding(.horizontal)

            List(modele.blocsSommaire, selection: $modele.selection) { bloc in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(bloc.plageAffichee)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(bloc.description)
                }
                .padding(.vertical, 3)
                .tag(bloc.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 180)

            Text("Sélection multiple possible (⌘-clic) : l'extrait ira du début du premier bloc à la fin du dernier.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal)

            Divider().padding(.horizontal)

            HStack(spacing: 8) {
                TextField("Ou décris le passage : « le moment où il parle de… »", text: $modele.demandeNaturelle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { modele.extraireDemande() }
                Button("Chercher le passage") { modele.extraireDemande() }
                    .disabled(modele.demandeNaturelle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)

            HStack {
                Button("Annuler") { modele.reinitialiser() }
                Spacer()
                Button("Voir le passage") { modele.extraireSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(modele.selection.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// Confirmation du passage : aperçu du texte + options avant la coupe
// ─────────────────────────────────────────────────────────────

struct PanneauConfirmerExtrait: View {
    @ObservedObject var modele: VueModele

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Passage à extraire")
                    .font(.headline)
                Spacer()
                Text(modele.plageExtraitAffichee)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            ScrollView {
                Text(modele.texteExtrait.isEmpty
                     ? "Aucune parole détectée dans ce passage."
                     : modele.texteExtrait)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(minHeight: 160)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)

            Toggle(isOn: $modele.sousTitrerExtrait) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sous-titrer l'extrait")
                    Text(modele.sousTitrerExtrait
                         ? "Traduction en français (ou sous-titres FR si déjà en français) puis gravure."
                         : "Coupe brute, sans sous-titres ni fichier .srt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.horizontal)

            HStack {
                Button("Retour") { modele.retourChoixExtrait() }
                Spacer()
                Button("Lancer l'extraction") { modele.lancerExtraction() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// Résultat + erreur
// ─────────────────────────────────────────────────────────────

struct PanneauResultat: View {
    @ObservedObject var modele: VueModele
    let resultat: ResultatTraitement
    @StateObject private var miniature = Etat<NSImage?>(nil)

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            if let image = miniature.valeur {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 3, y: 1)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            Text(resultat.url.lastPathComponent)
                .font(.headline)
            Text(resultat.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let srt = resultat.sousTitresURL {
                Text("Sous-titres éditables : \(srt.lastPathComponent)"
                     + (srt.deletingLastPathComponent() == resultat.url.deletingLastPathComponent()
                        ? " (même dossier)" : " (dans Vidéos › Sous-titrage)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Révéler dans le Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([resultat.url])
                }
                .buttonStyle(.borderedProminent)
                if modele.peutExtraireAutrePassage {
                    // La transcription est conservée : second passage sans attente.
                    Button("Extraire un autre passage") { modele.extraireAutrePassage() }
                }
                Button("Nouveau traitement") { modele.reinitialiser() }
            }
            .controlSize(.large)
            Spacer()
        }
        .padding(.horizontal)
        .task { miniature.valeur = await Miniature.generer(pour: resultat.url) }
    }
}

struct PanneauErreur: View {
    @ObservedObject var modele: VueModele
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.orange)
            Text("Le traitement a échoué")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            Button("Recommencer") { modele.reinitialiser() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer()
        }
        .padding(.horizontal)
    }
}

/// Remplace `@State` : sur le SDK macOS 27, `@State` est une macro dont le plugin
/// (SwiftUIMacros) n'est livré qu'avec Xcode — les Command Line Tools ne savent pas
/// la compiler. `@StateObject` + cette petite boîte donne le même comportement.
final class Etat<Valeur>: ObservableObject {
    @Published var valeur: Valeur
    init(_ valeur: Valeur) { self.valeur = valeur }
}
