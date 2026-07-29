# ClipFlow — sous-titrer, traduire, découper et compresser ses vidéos, en local sur Mac

![macOS 14+](https://img.shields.io/badge/macOS-14+-111111?logo=apple&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-Swift-F05138?logo=swift&logoColor=white)
![Transcription locale](https://img.shields.io/badge/transcription-100%25%20locale-2EA043)
![Whisper + ffmpeg](https://img.shields.io/badge/Whisper%20%C2%B7%20ffmpeg%20%C2%B7%20yt--dlp-informational)
![Construit avec Claude](https://img.shields.io/badge/construit%20avec-Claude-8A5CF6)
![Licence MIT](https://img.shields.io/badge/licence-MIT-0A7BBB)

> Une app macOS + des scripts pour **transcrire, traduire en français, incruster des sous-titres,
> extraire un passage et compresser** des vidéos courtes — **entièrement en local** sur ton Mac.
> Rien ne part dans un cloud tiers : la transcription tourne sur ta machine.

Créé par **[Tristan Mendès France](https://tristan.pro)** pour sa veille (désinformation, cultures
numériques), et publié en open source. **Point important : je ne suis pas développeur.** Je n'ai
pas écrit ce code à la main — je l'ai **décrit à une IA** ([Claude Code](https://claude.com/claude-code)),
qui l'a écrit, corrigé et complété au fil de mes retours. Ce dépôt est autant un outil qu'une
**démonstration** : on peut se fabriquer l'outil dont on a besoin en le racontant.

---

## Ce que ça fait

- **Sous-titrer & traduire** — transcription locale (Whisper `large-v3-turbo`) → traduction FR par
  Claude → sous-titres **gravés dans l'image**. Sortie `…_FR.mp4` (ou `…_ST.mp4` si tu fournis ton
  propre `.srt`).
- **Extraire un passage** — cherche le moment voulu **en langage naturel** (« le passage où il
  parle de X ») ou via un **sommaire thématique** généré par l'IA ; **aperçu du texte avant la
  coupe** ; coupe nette au timecode exact ; sous-titrage en option.
- **Compresser** — H.264 CRF, 3 niveaux, forte réduction sans perte visible.
- **Coller un lien** — colle une URL (YouTube, X, etc.), `yt-dlp` télécharge, tu enchaînes.

Deux formes : une **app fenêtrée (ClipFlow)** et des **scripts** (dont un mode « déposer une vidéo
dans un dossier → sous-titrage automatique »).

---

## Prérequis

- Un **Mac Apple Silicon** (M1/M2/M3…), macOS 14+.
- [Homebrew](https://brew.sh) (l'installeur le pose si absent).
- Pour compiler l'app : les outils Xcode en ligne de commande → `xcode-select --install`.
- Un compte **Claude** (la traduction utilise le CLI `claude`). Chacun utilise **le sien** — aucun
  identifiant n'est fourni ni stocké dans ce dépôt.

## Installation (les scripts + le pipeline auto)

```bash
git clone https://github.com/tristanmf/clipflow.git
bash clipflow/install-sous-titrage.sh
```

L'installeur pose `ffmpeg-full`, `whisper-cpp`, `claude-code`, `yt-dlp`, le modèle Whisper, écrit
le script, crée le dossier surveillé et le déclencheur. Ensuite, une fois : `claude` → se connecter
→ `/exit`. (Si la traduction auto échoue avec une erreur 401, voir la section *Authentification*
dans [`CLAUDE.md`](CLAUDE.md) : un jeton d'automatisation règle ça.)

## Installer l'app ClipFlow

```bash
cd clipflow
bash app-video/construire-app.sh
```

→ installe `~/Applications/ClipFlow.app` (signature ad hoc locale, aucun compte développeur Apple
requis ; au premier lancement : clic droit → Ouvrir). Icône optionnelle : dépose une image
`app-video/AppIcon.png` (1024×1024), le build la convertit.

## Garder les outils à jour

```bash
bash maj-outils.sh
```

Met à jour ffmpeg/whisper/claude/yt-dlp et affiche les versions. Utile surtout si un
téléchargement de lien échoue (yt-dlp casse quand les sites changent).

---

## Sécurité & vie privée

- **Rien de confidentiel dans ce dépôt** : aucun identifiant, aucune clé API, aucun jeton. Le CLI
  `claude` lit un éventuel jeton d'automatisation dans un fichier **local** (`~/.config/sous-titrage/token`,
  `chmod 600`) qui n'est jamais versionné.
- **La transcription est locale** (Whisper sur ta machine). Seule la **traduction** passe par
  Claude, comme n'importe quel appel à ton assistant.
- Les sorties vont dans `~/Movies/Sous-titrage` et `~/Movies/Compression` (dossiers non protégés
  par les antivirus « safe files » et par les autorisations « dossiers protégés » de macOS).

## Comment c'est fait (l'idée à retenir)

Tout le code — scripts shell **et** app SwiftUI — a été produit par Claude à partir de descriptions
en langage naturel, puis affiné par allers-retours (« teste ça » → « le bouton devrait plutôt… »
→ correction). Aucune ligne écrite à la main par un humain « développeur ». Si tu veux comprendre
la logique et les pièges rencontrés, [`CLAUDE.md`](CLAUDE.md) est la mémoire complète du projet.

## Structure du dépôt

- `install-sous-titrage.sh` — installeur tout-en-un.
- `dossier-sous-titrage.sh` — le moteur de sous-titrage (appelé par la Folder Action). Réglages de style en tête.
- `compresser-video.sh` — compression H.264 CRF.
- `maj-outils.sh` — met à jour les outils et affiche les versions.
- `app-video/` — l'app macOS ClipFlow (SwiftUI). Voir [`app-video/README.md`](app-video/README.md).
- `skill-cloud-soustitrage/` — variante **cloud** du sous-titrage, sous forme de *skill* pour
  Claude : elle tourne dans l'environnement d'exécution de Claude, donc **sans Mac** (utilisable
  depuis un téléphone). Modèle Whisper plus léger → qualité inférieure au local, mais dépanne
  en déplacement. Le pipeline local reste l'outil de référence.
- `CLAUDE.md` — la mémoire du projet (architecture, pièges, réglages).

## Licence

[MIT](LICENSE) — fais-en ce que tu veux. Aucune garantie ; teste sur tes propres fichiers.
