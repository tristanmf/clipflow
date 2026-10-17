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
  restent en place. ⚠️ ClipFlow dépose ses fichiers dans le dossier surveillé
  (`~/Movies/Sous-titrage`) : sans précaution, chaque téléchargement ou extrait y réveillait la
  Folder Action, qui le sous-titrait sans qu'on l'ait demandé. Le script ignore donc les noms
  produits par ClipFlow (`clipflow_*`, `*_extrait`, `*_qt`, `*_compressed`, en plus de `_ST`/`_FR`).
  Il rapatrie aussi les fichiers iCloud « évincés » avant ffmpeg (`brctl download`, 3 min max),
  sans quoi ffmpeg échoue en « Resource deadlock avoided ».
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
  `~/Movies/Sous-titrage/Vidéos téléchargées`. Sur l'onglet **Sous-titrer**, le sous-titrage
  s'enchaîne aussitôt ; sur Extraire et Compresser, la vidéo est seulement chargée (il reste un
  passage ou un niveau à choisir).
  **Noms parlants** : au lieu de `clipflow_5D9FAE04.mp4`, le fichier s'appelle
  `AAAA-MM-JJ Plateforme @compte — Titre court.mp4`. yt-dlp écrit les infos du post dans un JSON
  à part (`--print-to-file` + `--no-simulate --progress`, sans effet sur le téléchargement) ;
  date de publication, `@pseudo` sur les réseaux à pseudo, nom de chaîne ailleurs. Le titre court
  est rédigé par Claude à partir du texte du post **et de 3 vignettes de la vidéo** (15/50/85 %,
  640 px) — indispensable quand le post se résume à « waouh ». Pour cet appel seulement, le
  dossier des vignettes est le dossier de travail de `claude` et seul `Read` est autorisé : rien
  d'autre n'est lisible. Jamais bloquant (repli sur le titre d'origine), jamais d'écrasement.
  Si yt-dlp n'a pas fourni ses infos, repli sur le lien lui-même (réseau d'après l'hôte, compte
  d'après l'adresse sur X/TikTok/Threads) + vignettes. Chaque étape du titrage est notée dans
  `~/Library/Logs/ClipFlow.log` (diagnostic : `tail -20 ~/Library/Logs/ClipFlow.log` ; s'il
  n'existe pas, le code qui tourne est ancien — vérifier `git branch --show-current`).
  Le sous-dossier évite qu'un fichier renommé réveille la Folder Action du dossier parent.
  **Extraits** : `<vidéo> · 03m12 <sujet du passage>_extrait….mp4` — deux extraits de la même
  vidéo ne s'écrasent plus.
  **Livraison** : une fois finis, extraits et vidéos téléchargées sont déplacés dans
  **`~/Downloads`** (fabriqués dans `~/Movies`, puis déplacés en un seul geste, jamais
  d'écrasement ; en cas d'échec ils restent dans `~/Movies` et l'écran de fin le dit). Le `.srt`
  d'un extrait reste dans `~/Movies/Sous-titrage`.
  Tout ce qui dépend du lieu ou du site est **automatique** (rien à cocher) :
  - **Cookies** : premier essai en anonyme ; si le site refuse (X exige une session connectée
    **même sur un tweet public** → « No video could be found »), l'app réessaie seule avec
    `--cookies-from-browser chrome`. 1er usage : macOS demande l'accès au Trousseau de Chrome.
  - **Tunnel** : voir la section réseau ci-dessous.
  Téléchargement plafonné à **1080p** (la 4K n'apporte rien à un clip et ralentit tout derrière),
  résilient aux coupures (`--socket-timeout 30`, `--retries 5`, `--extractor-retries 3`).
  **Lisible par QuickTime** : sans consigne, yt-dlp prenait souvent de l'**AV1 + Opus** (YouTube),
  rangé tel quel dans un `.mp4` → « il manque un codec ». L'app demande donc du H.264 + AAC
  (`-S vcodec:h264,res,acodec:m4a`), puis `rendreCompatibleQuickTime` vérifie les codecs et
  convertit si besoin — ce qui est lisible est recopié, seul le reste est réencodé. La gravure ne
  recopie le son que s'il est AAC/MP3/ALAC.
  yt-dlp casse quand les sites changent → `bash maj-outils.sh`.
- **Échec rapide** : avant toute transcription (des minutes), l'app vérifie en quelques secondes
  que `claude` répond (`verifierClaude`) ; session expirée → message clair (« ouvre le Terminal,
  `claude`, `/login` ») au lieu d'un échec à la toute fin. Garde-fou iCloud (`assurerFichierLocal`) :
  fichier évincé → `brctl download` et attente jusqu'à 3 min avant de commencer.
- **Extraire un autre passage** : après une extraction, transcription et sommaire sont conservés →
  bouton sur l'écran de résultat, sans retranscrire (effacés dès qu'une autre vidéo est chargée).
  La coupe intermédiaire d'un extrait à sous-titrer est faite en `ultrafast`/CRF 16 (quasi sans
  perte), la gravure fixant la qualité finale : un seul encodage lent au lieu de deux.
- **Bouton dossier** (à côté des onglets, toujours visible) : ouvre `~/Movies/Sous-titrage`, ou
  `~/Movies/Compression` sur l'onglet Compresser.

## Piège réseau : un lien X qui échoue selon le lieu
Sur certaines lignes (constaté sur une connexion rurale), le téléchargement d'une vidéo X échoue
avec « Connection to api.x.com timed out », alors que **Safari affiche X normalement**. Ce n'est
ni l'app, ni yt-dlp, ni les cookies :
- **Cause** : l'opérateur ne route pas les plages IP de X (`162.159.128.0/19`, `172.66.0.0/16`).
  Le DNS résout correctement, mais TCP/443 part dans le vide ; le traceroute meurt après le
  3ᵉ saut. D'autres plages Cloudflare (`104.16.0.0/13`) répondent normalement. X n'a pas d'IPv6.
- **Pourquoi Safari marche** : le **Relais privé iCloud** ne couvre que Safari et contourne le
  trajet cassé. Chrome, `curl` et yt-dlp sortent en direct → échec. Le Relais privé ne peut PAS
  être étendu aux autres applis (Apple le réserve à Safari).
- **Diagnostic express** : `nc -vz -G 5 172.66.0.227 443` (X, doit répondre) vs
  `nc -vz -G 5 104.16.123.96 443` (Cloudflare témoin). X en TIMEOUT + témoin OK = ce cas.
- **Remèdes** : partage de connexion mobile, ou un tunnel couvrant toutes les applis
  (`brew install --cask cloudflare-warp`). **Dans l'app, c'est automatique** : avant un
  téléchargement, elle teste `nc -z -G 4 <hôte> 443` ; si le serveur ne répond pas et que WARP est
  installé, elle fait `warp-cli connect` avant et `disconnect` après (y compris en cas d'échec ou
  d'annulation) — le trafic ne passe par Cloudflare que le temps du transfert, et seulement quand
  c'est nécessaire. Si le tunnel était déjà actif, l'app n'y touche pas. Sans WARP : message qui
  propose le partage de connexion mobile ou l'installation.

## Comment ce projet a été construit
Tout le code (scripts shell + app SwiftUI) a été écrit par **Claude** (via Claude Code), à partir
de descriptions en langage naturel, puis affiné par itérations (tests → retours → corrections).
C'est l'intérêt de ce dépôt : montrer qu'on peut se fabriquer un outil local sur mesure sans être
développeur, en décrivant ce qu'on veut. Voir le `README.md` pour le pas-à-pas.
