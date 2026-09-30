#!/bin/bash
#
# dossier-sous-titrage.sh — version "intelligente"
# Incrustation automatique de sous-titres (burn-in / open captions) pour les réseaux sociaux.
# Conçu pour une ACTION DE DOSSIER (Folder Action) attachée à ~/Desktop/Sous-titrage.
#
# Prompté par Tristan Mendès France — https://tristan.pro
#
# DEUX MODES (la vidéo est toujours le déclencheur ; un .srt seul ne lance rien) :
#   • Vidéo + .srt de même nom déposés  -> on grave TON .srt (ta traduction MacWhisper).
#   • Vidéo SEULE déposée               -> transcription locale (whisper.cpp)
#                                          + traduction en français par Claude (Opus 4.8)
#                                          + gravure.
# Les fichiers d'entrée ne sont JAMAIS supprimés.
#
# ─────────────────────────────────────────────────────────────────────────────
# STYLE DES SOUS-TITRES — modifiable ici
# ─────────────────────────────────────────────────────────────────────────────
FONT="Helvetica"        # police (doit être installée sur le système)
SIZE=30                 # taille (relative à la hauteur de l'image, indépendante de la résolution)
OUTLINE=6               # épaisseur du halo en mode "contour doux" (5-7 = halo qui épouse le texte)
MARGINV=20              # marge basse (plus petit = plus bas)
MARGINLR=20             # marges gauche/droite (plus petit = texte plus large / proche des bords)
PRIMARY="&H00FFFFFF"      # couleur du texte (ASS = &HAABBGGRR) -> blanc
OUTLINECOLOR="&H20202020" # couleur du halo translucide (AA=transparence : 00=opaque, FF=invisible)

# Fond derrière le texte :
#   BOX=false -> "contour doux" : halo sombre translucide qui épouse le texte (bords arrondis naturels) — CHOISI
#   BOX=true  -> bande rectangulaire pleine (coins droits)
BOX=false
BOX_COLOR="&H66202020"    # couleur de la bande si BOX=true (ASS &HAABBGGRR, AA=transparence)
BOX_PAD=6                 # marge interne de la bande si BOX=true

# Note libass : FontSize/MarginV sont relatifs à un canevas interne, donc déjà
# indépendants de la résolution (480p, 720p, 1080p, vertical 9:16). Ne pas mettre à l'échelle.

# ─────────────────────────────────────────────────────────────────────────────
# PIPELINE AUTO (vidéo seule) — modifiable ici
# ─────────────────────────────────────────────────────────────────────────────
WHISPER_MODEL="$HOME/.cache/whisper/ggml-large-v3-turbo-q5_0.bin"
WHISPER_LANG="auto"            # langue source ("auto" = détection ; "en" force l'anglais)
WHISPER_MAXLEN=58              # longueur max (en caractères ANGLAIS ; le FR s'allonge ~+30%). 0 = off
CLAUDE_MODEL="claude-opus-4-8" # modèle de traduction (ex. claude-sonnet-4-6 = plus rapide)

# SORTIE : dossier NON protégé par l'antivirus (Bitdefender Safe Files protège Bureau/
#   Documents/Images/Téléchargements). On y écrit les résultats -> aucune alerte, et le
#   Bureau garde sa protection anti-ransomware. Le dépôt des vidéos, lui, reste sur le Bureau
#   (un glisser-déposer n'est jamais bloqué ; seule l'écriture par un programme l'est).
#   Vide ("") = sous-dossier "Sortie" du dossier surveillé.
OUTDIR="$HOME/Movies/Sous-titrage"
OUTSUB="Sortie"

SUF_MANUAL="_ST"   # suffixe sortie quand tu fournis le .srt
SUF_AUTO="_FR"     # suffixe sortie quand Claude traduit
# (Ces suffixes servent aussi de garde-fou anti-boucle : le script ignore ses propres sorties.)
# ─────────────────────────────────────────────────────────────────────────────

# Robustesse Folder Action : garantir HOME/USER/LOGNAME (nécessaires à l'accès Trousseau de claude)
export HOME="${HOME:-$(eval echo "~$(id -un)")}"
export USER="${USER:-$(id -un)}"
export LOGNAME="${LOGNAME:-$(id -un)}"

# Jeton d'automatisation Claude (généré par `claude setup-token`, valable ~1 an).
# Indispensable en headless : le simple login d'abonnement est refusé (401) pour `claude -p`.
# Régénérer avec `claude setup-token` puis remettre le jeton dans ce fichier quand il expire.
CLAUDE_TOKEN_FILE="$HOME/.config/sous-titrage/token"
[ -f "$CLAUDE_TOKEN_FILE" ] && export CLAUDE_CODE_OAUTH_TOKEN="$(cat "$CLAUDE_TOKEN_FILE")"

# Notification macOS
notify() {
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1
}

# Localisation absolue des binaires (les Folder Actions n'héritent pas du PATH)
locate_bin() {
  local b; b="$(command -v "$1" 2>/dev/null)"
  [ -z "$b" ] && [ -x "/opt/homebrew/bin/$1" ] && b="/opt/homebrew/bin/$1"
  [ -z "$b" ] && [ -x "/usr/local/bin/$1" ] && b="/usr/local/bin/$1"
  echo "$b"
}
FFMPEG="$(locate_bin ffmpeg)"
WHISPER="$(locate_bin whisper-cli)"
CLAUDE="$(locate_bin claude)"

if [ -z "$FFMPEG" ] || [ ! -x "$FFMPEG" ]; then
  notify "Sous-titrage — erreur" "ffmpeg introuvable. Terminal : brew install ffmpeg-full"
  exit 1
fi

for f in "$@"; do
  # Déclencheur = vidéo uniquement (insensible à la casse)
  ext="$(echo "${f##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in mp4|mov|m4v) : ;; *) continue ;; esac
  [ -f "$f" ] || continue

  dir="$(dirname "$f")"
  base="$(basename "$f")"
  name="${base%.*}"

  # Garde-fou : ignorer noms vides/anormaux et nos propres sorties (anti-boucle)
  [ -z "${name// /}" ] && continue
  case "$name" in *"$SUF_MANUAL"|*"$SUF_AUTO") continue ;; esac
  # ClipFlow dépose aussi ses fichiers dans ce dossier (téléchargements clipflow_…,
  # extraits bruts …_extrait, conversions temporaires …_qt) : ils ne doivent jamais
  # déclencher de sous-titrage automatique.
  case "$name" in clipflow_*|*_extrait|*_qt|*_compressed) continue ;; esac

  # ── iCloud : un fichier « évincé » (Bureau/Documents synchronisés + « Optimiser le
  #    stockage du Mac ») garde son nom et sa taille affichés, mais ses données ne sont
  #    plus sur le disque. ffmpeg ne sait pas déclencher le rapatriement et sort en
  #    erreur « Resource deadlock avoided ». On force le téléchargement puis on attend
  #    que le fichier soit réellement lisible (3 min max). Voir CLAUDE.md.
  if ! head -c 1 "$f" >/dev/null 2>&1; then
    notify "Téléchargement iCloud…" "$base n'est pas sur le disque, rapatriement en cours"
    [ -x /usr/bin/brctl ] && /usr/bin/brctl download "$f" >/dev/null 2>&1
    n=0
    while ! head -c 1 "$f" >/dev/null 2>&1 && [ "$n" -lt 180 ]; do
      sleep 1; n=$((n+1))
    done
    if ! head -c 1 "$f" >/dev/null 2>&1; then
      notify "Sous-titrage — échec ❌" "$base est resté sur iCloud. Ouvre-le une fois dans le Finder (attends la fin de la jauge), puis relance."
      continue
    fi
  fi

  # Dossier de sortie : sous-dossier non surveillé (évite tout re-déclenchement)
  if [ -n "$OUTDIR" ]; then out_dir="$OUTDIR"; else out_dir="$dir/$OUTSUB"; fi
  mkdir -p "$out_dir" 2>/dev/null

  user_srt="$dir/$name.srt"

  if [ -f "$user_srt" ]; then
    # ───────── MODE MANUEL : on grave le .srt fourni ─────────
    suffix="$SUF_MANUAL"
    srt_src="$user_srt"
    notify "Sous-titrage en cours" "$base — gravure de ton .srt…"
  else
    # ───────── MODE AUTO : transcription + traduction ─────────
    suffix="$SUF_AUTO"
    if [ -z "$WHISPER" ] || [ ! -x "$WHISPER" ]; then
      notify "Sous-titrage — erreur" "whisper-cli introuvable. Terminal : brew install whisper-cpp"
      continue
    fi
    if [ ! -f "$WHISPER_MODEL" ]; then
      notify "Sous-titrage — erreur" "Modèle Whisper absent : $WHISPER_MODEL"
      continue
    fi
    if [ -z "$CLAUDE" ] || [ ! -x "$CLAUDE" ]; then
      notify "Sous-titrage — erreur" "CLI claude introuvable. Terminal : brew install claude-code"
      continue
    fi

    tag="$$_${RANDOM}"
    wav="/tmp/st_${tag}.wav"
    whbase="/tmp/st_wh_${tag}"

    notify "Sous-titrage 1/3" "$base — transcription locale (Whisper)…"
    "$FFMPEG" -y -i "$f" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$wav" >/tmp/st_ff_${tag}.log 2>&1
    if [ ! -f "$wav" ]; then
      notify "Sous-titrage — échec" "Extraction audio impossible : $base"
      rm -f "$wav"; continue
    fi

    wml=()
    [ "${WHISPER_MAXLEN:-0}" -gt 0 ] 2>/dev/null && wml=(-ml "$WHISPER_MAXLEN" -sow)
    "$WHISPER" -m "$WHISPER_MODEL" -f "$wav" -l "$WHISPER_LANG" -osrt -of "$whbase" -np "${wml[@]}" >/tmp/st_wh_${tag}.log 2>&1
    en_srt="${whbase}.srt"
    rm -f "$wav"
    if [ ! -s "$en_srt" ]; then
      notify "Sous-titrage — échec" "Transcription vide : $base (voir /tmp/st_wh_${tag}.log)"
      continue
    fi

    notify "Sous-titrage 2/3" "$base — traduction en français (Claude)…"
    prompt="Tu es un traducteur professionnel de sous-titres. Voici un fichier SRT. Traduis le TEXTE en français naturel et idiomatique, adapté à des sous-titres courts.
Règles STRICTES :
- Garde EXACTEMENT les lignes de timecode (celles contenant -->) inchangées.
- Renumérote les blocs séquentiellement à partir de 1.
- Si le texte d'un bloc est vide ou ne contient que de la ponctuation, SUPPRIME ce bloc entièrement (timecode compris).
- Ne renvoie QUE le SRT final : aucun commentaire, aucun bloc de code markdown, aucune phrase d'introduction.

Fichier SRT :
$(cat "$en_srt")"

    fr_raw="$("$CLAUDE" -p "$prompt" --model "$CLAUDE_MODEL" --allowedTools "" < /dev/null 2>/tmp/st_cl_${tag}.log)"
    rm -f "$en_srt"
    # Nettoyage : retire d'éventuelles barrières markdown ``` et lignes vides en tête
    fr_srt="$out_dir/${name}${SUF_AUTO}.srt"
    printf '%s\n' "$fr_raw" | grep -v '^```' | sed '/./,$!d' > "$fr_srt"
    if ! grep -q -- '-->' "$fr_srt" 2>/dev/null; then
      notify "Sous-titrage — échec" "Traduction Claude invalide : $base (voir /tmp/st_cl_${tag}.log)"
      rm -f "$fr_srt"; continue
    fi
    srt_src="$fr_srt"
    # NB : le .srt FR éditable est dans OUTDIR (à côté du résultat). Pour corriger : édite-le,
    # copie-le en "<nom>.srt" dans le dossier surveillé du Bureau, puis re-glisse la vidéo (mode manuel).
    notify "Sous-titrage 3/3" "$base — gravure des sous-titres FR…"
  fi

  # ───────── GRAVURE (commune aux deux modes) ─────────
  # Le filtre subtitles gère mal espaces / ':' / apostrophes : on copie vers un /tmp propre.
  tmp_srt="/tmp/st_burn_$$_${RANDOM}.srt"
  cp "$srt_src" "$tmp_srt" 2>/dev/null
  if [ ! -f "$tmp_srt" ]; then
    notify "Sous-titrage — erreur" "Préparation du .srt impossible : $base"
    continue
  fi

  if [ "$BOX" = "true" ]; then
    force_style="FontName=${FONT},FontSize=${SIZE},PrimaryColour=${PRIMARY},OutlineColour=${BOX_COLOR},BackColour=${BOX_COLOR},BorderStyle=4,Outline=${BOX_PAD},Shadow=0,MarginV=${MARGINV},MarginL=${MARGINLR},MarginR=${MARGINLR}"
  else
    force_style="FontName=${FONT},FontSize=${SIZE},PrimaryColour=${PRIMARY},OutlineColour=${OUTLINECOLOR},BorderStyle=1,Outline=${OUTLINE},Shadow=0,MarginV=${MARGINV},MarginL=${MARGINLR},MarginR=${MARGINLR}"
  fi
  out="$out_dir/${name}${suffix}.mp4"

  "$FFMPEG" -y -i "$f" \
    -vf "subtitles=${tmp_srt}:force_style='${force_style}'" \
    -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart \
    -c:a copy \
    "$out" >/tmp/st_burn_$$.log 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then
    "$FFMPEG" -y -i "$f" \
      -vf "subtitles=${tmp_srt}:force_style='${force_style}'" \
      -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart \
      -c:a aac -b:a 192k \
      "$out" >/tmp/st_burn_$$.log 2>&1
    rc=$?
  fi
  rm -f "$tmp_srt"

  if [ $rc -eq 0 ] && [ -f "$out" ]; then
    # En mode manuel, dépose aussi une copie du .srt utilisé à côté de la sortie
    [ "$suffix" = "$SUF_MANUAL" ] && cp "$user_srt" "$out_dir/${name}${SUF_MANUAL}.srt" 2>/dev/null
    notify "Sous-titrage terminé ✅" "${name}${suffix}.mp4 prêt."
  else
    notify "Sous-titrage — échec ❌" "ffmpeg a échoué sur $base."
  fi
done

exit 0
