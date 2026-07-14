# ClipFlow — mémoire de projet

Système de sous-titrage / traduction / extraction / compression de vidéos courtes, en **local**
sur Mac (Apple Silicon). Un jeu de scripts + une app macOS SwiftUI, construits avec l'aide de
Claude. Ce fichier est la **mémoire du projet** : tout Claude (ou toute personne) qui le lit
comprend comment le système fonctionne et pourquoi il est fait ainsi.

> Projet initialement créé par **Tristan Mendès France** (https://tristan.pro) pour sa veille
> (désinformation, cultures numériques). Publié en open source pour que d'autres puissent
> s'en servir et l'adapter.

> ⚠️ Les outils **s'exécutent en LOCAL** sur le Mac (ffmpeg + whisper-cpp + le CLI `claude`).
> Un environnement cloud ne peut pas les faire tourner. Ce dépôt sert à **synchroniser le code**
> entre machines ; le déploiement local se fait via `install-sous-titrage.sh`.

## Vue d'ensemble
Deux façons d'utiliser le système, qui partagent le même moteur :
- **Automatique (Folder Action)** : on dépose une vidéo dans `~/Movies/Sous-titrage` → une action
  de dossier lance `~/Scripts/dossier-sous-titrage.sh`.
- **App ClipFlow** : une fenêtre unique pour les trois traitements + le téléchargement d'un lien.

Modes de sous-titrage (la vidéo .mp4/.mov/.m4v est toujours le déclencheur) :
- **Vidéo + `.srt` de même nom** → grave le `.srt` fourni → `…_ST.mp4`.
- **Vidéo seule** → extrait l'audio (ffmpeg) → transcrit en local (whisper-cli) → traduit en
  français via le CLI `claude` → grave → `…_FR.mp4` (+ `…_FR.srt`).

## Composants (Homebrew)
- **`ffmpeg-full`** (PAS la formule `ffmpeg` standard) : `ffmpeg` n'a plus `libass`, donc pas de
  filtre `subtitles`. Il faut `ffmpeg-full` + `brew link --force --overwrite ffmpeg-full`.
- **`whisper-cpp`** + modèle `~/.cache/whisper/ggml-large-v3-turbo-q5_0.bin` (~547 Mo, Metal/M-series).
- **CLI `claude`** (cask `claude-code`) : fait la traduction via `claude -p … --allowedTools ""`.
- **`yt-dlp`** : téléchargement d'un lien dans l'app (casse quand les sites changent → à garder à jour).

## Authentification Claude (login OU jeton) — IMPORTANT
Le CLI en mode headless (`claude -p`) a besoin d'identifiants valides. Deux cas :
- **Certaines machines : le login simple suffit** (`claude` → login → `/exit`).
- **D'autres : le login headless est refusé → `401 Invalid authentication`** (souvent quand l'app
  Claude Desktop tourne et fait tourner le jeton du Trousseau).
- **Solution robuste : un jeton d'automatisation** (méthode officielle pour le headless) :
  1. `claude setup-token` → autoriser → copier le jeton `sk-ant-oat01-…` (valable ~1 an).
  2. `mkdir -p ~/.config/sous-titrage && printf '%s' 'LE_JETON' > ~/.config/sous-titrage/token && chmod 600 ~/.config/sous-titrage/token`
  3. Vérifier : `CLAUDE_CODE_OAUTH_TOKEN="$(cat ~/.config/sous-titrage/token)" claude -p "dis OK"`.
- Le script lit ce fichier via une **ligne conditionnelle** → le même code marche partout
  (machine avec fichier = jeton ; sans = login normal). **Le jeton n'est JAMAIS dans le dépôt**,
  seulement dans ce fichier local (`chmod 600`).

## Réglages de style (en tête de `dossier-sous-titrage.sh`)
- `FONT="Helvetica"`, `SIZE=30`, `MARGINV=20`, `MARGINLR=20`, texte blanc.
- `BOX=false` = **contour doux** (halo translucide : `OUTLINE=6`, `OUTLINECOLOR="&H20202020"` en ASS
  `&HAABBGGRR`). `BOX=true` = bande rectangulaire. **libass ne fait pas de coins arrondis.**
- `WHISPER_MAXLEN=58` (`-ml -sow`) découpe les blocs (~2 lignes ; le FR s'allonge ~+30 % vs l'anglais).
- libass : FontSize/MarginV sont relatifs à un canevas interne → **indépendants de la résolution**
  (480p → 1080p, vertical 9:16). NE PAS mettre à l'échelle selon la hauteur.

## Pourquoi la sortie est dans `~/Movies` et pas sur le Bureau
Certains antivirus (ex. Bitdefender « Safe Files ») protègent Bureau/Documents/Images/
Téléchargements et **bloquent l'écriture par bash/ffmpeg** → alertes en boucle. On écrit donc
dans `~/Movies` (non protégé) → zéro alerte. Le **dépôt** des vidéos peut rester ailleurs (un
glisser-déposer n'est jamais bloqué ; seule l'écriture par un programme l'est). C'est aussi un
dossier non soumis aux autorisations « dossiers protégés » de macOS.

## Le déclencheur (Folder Action)
- Mécanisme : script natif `~/Library/Scripts/Folder Action Scripts/Sous-titrage-auto.scpt` qui
  fait `do shell script "nohup <chemin>/dossier-sous-titrage.sh <fichier> &"`, attaché via System Events.
- ⚠️ **Piège du chemin home** : `POSIX path of (path to home folder)` ne met pas toujours le slash
  final. Toujours utiliser le `$HOME` du shell (ou un chemin en dur) dans l'AppleScript.
- Robustesse env (dans le .sh) : réexporter `HOME`/`USER`/`LOGNAME` (sinon `claude` = « Not logged
  in »). Localiser ffmpeg/whisper-cli/claude en absolu (le PATH n'est pas hérité par une Folder Action).

## Corriger une traduction puis re-graver
Le `.srt` FR est à côté du résultat dans `~/Movies/Sous-titrage`. Éditer, copier en `<nom>.srt`
dans le dossier surveillé à côté de la vidéo, re-glisser la vidéo → mode manuel grave la version
corrigée (`…_ST.mp4`).

## Compression
Script **`compresser-video.sh`** : ré-encode en H.264 **CRF** (qualité constante → forte réduction
sans perte visible). Défaut `CRF=23` (18 = quasi parfait/lourd, 26 = très léger). Sortie dans
`~/Movies/Compression`.

## App macOS « ClipFlow » (SwiftUI) — `app-video/`
Interface unique pour les trois traitements : **Sous-titrer** (pipeline complet, avec bouton
« Utiliser mon .srt » = mode manuel), **Extraire un passage** (transcription → sommaire thématique
par Claude en liste cliquable OU recherche en langage naturel → **écran d'aperçu** montrant le
texte du passage + interrupteur « Sous-titrer l'extrait » → sur « Lancer l'extraction » : coupe
nette aux timecodes exacts, sous-titrage seulement si demandé), **Compresser** (CRF 18/23/26).
Principes :
- **Interface, pas nouveau moteur** : `Moteur.swift` transpose fidèlement les scripts shell
  (mêmes commandes ffmpeg/whisper-cli/`claude -p`, même style, mêmes sorties). Les Folder Actions
  restent en place.
- **Piège géré** : après la coupe d'un extrait, les timecodes du SRT sont **rebasés sur zéro**
  (`SRT.extraireEtRebaser`) sinon les sous-titres seraient décalés.
- Coupe d'extrait : **seek d'entrée** (`-ss` avant `-i`) + `-t` → rapide même en fin de longue
  vidéo, tout en restant frame-exact grâce au réencodage.
- Binaires localisés en absolu (pas de PATH hérité), jeton lu dans `~/.config/sous-titrage/token`,
  **pas de sandbox** (nécessaire pour exécuter Homebrew + écrire dans `~/Movies`).
- Build : `bash app-video/construire-app.sh` (Swift Package, pas de projet Xcode ; prérequis
  `xcode-select --install`) → installe `~/Applications/ClipFlow.app`, signature ad hoc.
  (Icône : déposer `app-video/AppIcon.png` — le build génère l'`.icns`. Nom interne du binaire : `Video`.)
- **Coller un lien** : un champ « ou colle un lien » télécharge via **yt-dlp** (tous sites) dans
  `~/Movies/Sous-titrage`, puis charge la vidéo dans la zone → on choisit ensuite l'action.

## Comment ce projet a été construit
Tout le code (scripts shell + app SwiftUI) a été écrit par **Claude** (via Claude Code), à partir
de descriptions en langage naturel, puis affiné par itérations (tests → retours → corrections).
C'est l'intérêt de ce dépôt : montrer qu'on peut se fabriquer un outil local sur mesure sans être
développeur, en décrivant ce qu'on veut. Voir le `README.md` pour le pas-à-pas.
