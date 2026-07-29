---
name: soustitrage-video
description: >
  Sous-titre automatiquement une vidéo déposée par Tristan : transcription, traduction en français si la langue source n'est pas le français, puis gravure des sous-titres (burn-in / open captions) au style exact de son setup. Utilise ce skill dès que Tristan dépose une vidéo (.mp4, .mov, .m4v) et dit "sous-titre", "sous-titre-moi ça", "traduis et sous-titre", "sous-titrage", "mets les sous-titres", "en français", ou toute formulation indiquant qu'il veut la vidéo sous-titrée. Fonctionne aussi si Tristan demande d'abord un résumé ou un extrait de la vidéo, puis le sous-titrage. Ce skill s'exécute entièrement dans l'environnement d'exécution (bash) — aucun outil local requis, utilisable depuis mobile, web ou desktop.
---

# Sous-titrage vidéo — portage cloud du setup de Tristan

Reproduit le pipeline de `dossier-sous-titrage.sh` (dépôt `tristanmf/clipflow`), exécuté dans l'environnement Claude plutôt que sur le Mac.

**Validé en conditions réelles le 12 juillet 2026** (vidéo Fuentes/Bilzerian, 84 s, anglais → français).

---

## RÈGLE CRITIQUE : NE PAS UTILISER faster-whisper

`faster-whisper` est **défectueux dans cet environnement**. Testé et prouvé : sur un audio de contrôle synthétique parfaitement propre, il ne restitue que des fragments tronqués et hallucine (caractères vietnamiens/thaï/cyrilliques parasites, segments fantômes hors durée). Le problème persiste quel que soit le modèle, avec ou sans VAD, audio brut ou normalisé.

**Utiliser `openai-whisper`** (implémentation de référence). Transcription parfaite du premier coup.

---

## Setup (à refaire à chaque nouvelle conversation)

L'environnement est jetable. Installation en 2 étapes — **respecter l'ordre**, sinon saturation disque :

```bash
# 1. PyTorch CPU-only (la version par défaut tire CUDA et sature les ~10 Go dispo)
pip install torch --index-url https://download.pytorch.org/whl/cpu --break-system-packages -q

# 2. openai-whisper sans redépendances
pip install openai-whisper --break-system-packages -q --no-deps
pip install tiktoken numba more-itertools --break-system-packages -q
```

Si `No space left on device` : `rm -rf /root/.cache/huggingface` puis `pip cache purge`.

### Modèle : `small` obligatoire

RAM limitée à ~4 Go. `medium` en float32 **se fait tuer** (OOM). `small` suffit largement : transcription complète et propre, zéro hallucination sur du contenu parlé normal.

```python
import whisper
m = whisper.load_model('small')
r = m.transcribe(audio_path, fp16=False, verbose=False)
# r['language'] = langue détectée
# r['segments'] = liste de {start, end, text}
```

Compter ~40 s de traitement pour 84 s de vidéo.

---

## Style des sous-titres — NE PAS MODIFIER

Repris à l'identique du script de Tristan. Une seule adaptation : `Helvetica` → `Liberation Sans` (clone métrique ; Helvetica absente sous Linux, mêmes largeurs de glyphes donc taille et marges restent valides).

```
FontName=Liberation Sans,FontSize=30,PrimaryColour=&H00FFFFFF,OutlineColour=&H20202020,BorderStyle=1,Outline=6,Shadow=0,MarginV=20,MarginL=20,MarginR=20
```

- Halo sombre translucide qui épouse le texte (BorderStyle=1, Outline=6) — **pas** de bande rectangulaire
- Texte blanc, pas d'ombre portée
- **Note libass** : FontSize et MarginV sont relatifs à un canevas interne, donc déjà indépendants de la résolution (480p, 720p, 1080p, vertical 9:16). Ne jamais mettre à l'échelle.

---

## Workflow

### 1. Extraction audio

```bash
ffmpeg -y -i "$VIDEO" -vn -ar 16000 -ac 1 -c:a pcm_s16le /tmp/audio.wav
```

Ne pas normaliser ni filtrer : testé, ça n'améliore rien et peut dégrader.

### 2. Transcription

`openai-whisper`, modèle `small`, `fp16=False`. Détection de langue automatique.

### 3. Traduction en français (si langue ≠ fr)

**C'est Claude qui traduit**, directement, pas un outil externe. Règles (reprises du script original) :

- Garder EXACTEMENT les timecodes inchangés
- Renuméroter les blocs séquentiellement à partir de 1
- Supprimer entièrement les blocs vides ou ne contenant que de la ponctuation
- Français naturel et idiomatique, adapté à des sous-titres courts
- Couper les lignes trop longues en deux (le français s'allonge d'environ 30 % par rapport à l'anglais)

### 4. Gravure

Copier le .srt vers un chemin propre dans `/tmp` (le filtre `subtitles` de ffmpeg gère mal espaces, `:` et apostrophes).

```bash
ffmpeg -y -i "$VIDEO" \
  -vf "subtitles=/tmp/burn.srt:force_style='<FORCE_STYLE>'" \
  -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart \
  -c:a copy "/mnt/user-data/outputs/<nom>_FR.mp4"
```

Si `-c:a copy` échoue → refaire avec `-c:a aac -b:a 192k` (fallback du script original).

### 5. Livraison

`present_files` sur le MP4. **La vidéo sous-titrée uniquement** — pas de .srt sauf demande explicite.

Nommage : `<nom>_FR.mp4` si traduit, `<nom>_ST.mp4` si déjà en français.

Message final court, sans post-ambule.

---

## Comportement par défaut (validé par Tristan)

- **Traduction** : si la langue détectée n'est pas le français → traduire. Si déjà en français → sous-titrer tel quel.
- **Sortie** : vidéo sous-titrée uniquement.
- **Pas de question préalable** : exécuter directement.
- **Fichiers** : Tristan envoie les vidéos **non compressées**. Ne pas lui demander de compresser (la compression n'améliore pas la transcription et dégrade la sortie, qui est réencodée de toute façon).

---

## Contrôle qualité

Avant de livrer, extraire une frame sur un passage avec du texte :
```bash
ffmpeg -y -i sortie.mp4 -ss 00:00:XX -vframes 1 /tmp/check.png
```
Vérifier : halo présent, pas de bande, texte lisible, marges correctes, pas de débordement.

---

## Cas particuliers

- **Vidéo déjà en français** → pas de traduction, suffixe `_ST`.
- **Tristan fournit son propre .srt** → le graver directement, sauter transcription et traduction.
- **Tristan demande un résumé ou un extrait d'abord** → transcrire, résumer/découper (`-ss` / `-to`), puis sous-titrer.
- **Vidéo longue (> 10 min)** → prévenir du temps de traitement ; proposer de ne traiter qu'un extrait.

---

## Limites connues — à signaler si pertinent

- **Audio difficile** (chant, cris, voix superposées, forte saturation) : `small` décroche. Le setup local de Tristan (`large-v3-turbo-q5_0` sur Apple Silicon) est nettement supérieur dans ces cas — l'orienter vers son pipeline local plutôt que de s'acharner.
- Police = Liberation Sans, pas Helvetica (métriquement identique, visuellement très proche).
- Transcription CPU : plus lente que le setup local.
- Pour du volume ou du traitement répété, le pipeline local (ce dépôt) reste l'outil de référence.

---

*Prompté par Tristan Mendès France — https://tristan.pro*
