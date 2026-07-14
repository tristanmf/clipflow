# App macOS « ClipFlow » (SwiftUI)

Interface graphique unique pour les trois traitements vidéo du dépôt :
**Sous-titrer** · **Extraire un passage** · **Compresser**.

> L'app est une **interface, pas un nouveau moteur** : elle appelle exactement les mêmes
> commandes que `dossier-sous-titrage.sh` et `compresser-video.sh` (ffmpeg, whisper-cli,
> `claude -p`), avec le même style de sous-titres et les mêmes dossiers de sortie.
> Les Folder Actions existantes continuent de fonctionner — l'app coexiste, elle ne remplace rien.

## Installer / mettre à jour (sur chaque Mac)

```bash
cd ~/clipflow && git pull
bash app-video/construire-app.sh
```

Prérequis (une seule fois) : les outils en ligne de commande Xcode — `xcode-select --install`.
Le script compile et installe **`~/Applications/ClipFlow.app`**. Pas de compte développeur requis.
Icône : déposer une image `app-video/AppIcon.png` (idéalement 1024×1024) — le build la convertit en `.icns`.

Les binaires utilisés sont ceux déjà installés par `install-sous-titrage.sh`
(ffmpeg-full, whisper-cpp, claude-code, modèle Whisper). Si une machine est neuve,
lancer d'abord l'installeur du dépôt.

## Coller un lien (téléchargement)

Un champ « ou colle un lien » sous la zone de dépôt télécharge une vidéo via **yt-dlp**
(YouTube, X, Fox… tout ce que yt-dlp sait faire), en mp4, dans `~/Movies/Sous-titrage`.
La vidéo se charge alors dans la zone : tu choisis ensuite l'une des trois actions
(pas d'enchaînement automatique). Nécessite `yt-dlp` (`brew install yt-dlp`, ajouté à
l'installeur). Comme yt-dlp casse quand un site change ses endpoints, en cas d'échec le
message renvoie vers `brew upgrade yt-dlp`.

## Les trois actions

### Sous-titrer (vidéo entière)
Reprend le pipeline de la Folder Action : extraction audio 16 kHz → transcription locale
(whisper-cli, modèle `large-v3-turbo-q5_0`, langue auto) → si la langue n'est pas le français,
traduction par Claude (Opus 4.8) → gravure. Sortie dans `~/Movies/Sous-titrage` :
`<nom>_FR.mp4` (traduit) ou `<nom>_ST.mp4` (déjà en français), avec le `.srt` éditable à côté.
Bouton « Utiliser mon .srt » = mode manuel du script (gravure telle quelle → `_ST`).

### Extraire un passage
1. Transcription, puis **sommaire thématique** généré par Claude (3 à 8 blocs) affiché en liste.
2. Deux façons de choisir : cliquer un ou plusieurs blocs contigus (⌘-clic), **ou** décrire le
   passage en langage naturel (« le moment où il parle de… ») — Claude retrouve les timecodes.
3. **Écran d'aperçu avant toute coupe** : le texte (transcription) du passage choisi s'affiche,
   avec un interrupteur **« Sous-titrer l'extrait »**. Rien n'est coupé tant qu'on ne clique pas
   **« Lancer l'extraction »** (le langage naturel ne coupe donc plus « à l'aveugle »).
4. Coupe **nette aux timecodes exacts** (seek d'entrée + réencodage : `-c copy` couperait sur
   les keyframes). Les timecodes des sous-titres sont **rebasés sur zéro** après la coupe.
5. Selon l'interrupteur : sous-titres désactivés → coupe brute `<nom>_extrait.mp4` (aucun .srt) ;
   activés → `<nom>_extrait_FR.mp4` (traduit) ou `<nom>_extrait_ST.mp4` (déjà en français).

### Compresser
Reprend `compresser-video.sh` : H.264 CRF (18 / 23 / 26 au choix), sortie
`~/Movies/Compression/<nom>_compressed.mp4`.

## Points techniques
- **Binaires localisés en absolu** (`/opt/homebrew/bin`, `/usr/local/bin`, puis PATH) — une app
  lancée du Finder n'hérite pas du PATH du shell.
- **Jeton Claude** lu dans `~/.config/sous-titrage/token` (même mécanisme que le script ;
  voir `CLAUDE.md` → *Authentification Claude*). `claude -p … --allowedTools ""`, stdin fermé.
- **Style de sous-titres inchangé** (constante dans `Moteur.swift`) :
  `FontName=Helvetica,FontSize=30,…,BorderStyle=1,Outline=6,…` — calibré, ne pas modifier.
- **Sorties hors périmètre Bitdefender** (`~/Movies/…`) — ne pas écrire sur le Bureau/Documents.
- **Pas de sandbox** (choix assumé) : l'app doit exécuter les binaires Homebrew et écrire dans
  `~/Movies`. Signature ad hoc locale, suffisante pour un usage personnel.
- Les fichiers temporaires (wav, srt intermédiaires) sont nettoyés après traitement.

## Structure du code (`Sources/Video/`)
- `Moteur.swift` — le pipeline (transposition fidèle des scripts shell : mêmes commandes/réglages).
- `Binaires.swift` — localisation ffmpeg/whisper-cli/claude + environnement (PATH, jeton).
- `ProcessRunner.swift` — exécution asynchrone avec progression ligne à ligne et annulation.
- `SRT.swift` — analyse/écriture/rebasage des sous-titres.
- `VueModele.swift` — état de l'app et orchestration.
- `ContentView.swift`, `VideoApp.swift`, `Miniature.swift`, `Modeles.swift` — interface.
