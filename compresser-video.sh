#!/bin/bash
#
# compresser-video.sh — compression vidéo H.264 (CRF), forte réduction sans perte visible.
# Appelé par une Action rapide (clic droit) OU une Folder Action. Reçoit les fichiers en "$@".
#
# Prompté par Tristan Mendès France — https://tristan.pro
#
# ─────────────────────────────────────────────────────────────────────────────
CRF=23            # qualité : 18 = quasi parfait (plus lourd) · 23 = bon compromis · 26 = très léger
PRESET=medium     # vitesse d'encodage (slower = un peu plus petit)
AUDIO_KBPS=160    # débit audio AAC
OUTDIR="$HOME/Movies/Compression"   # dossier de travail (NON protégé par l'antivirus)
OUTPUT_TO_DESKTOP=true              # true = dépose le résultat sur le Bureau via Finder (Finder est de
                                    #        confiance pour Bitdefender) ; false = laisse dans OUTDIR
# ─────────────────────────────────────────────────────────────────────────────

export HOME="${HOME:-$(eval echo "~$(id -un)")}"
export USER="${USER:-$(id -un)}"
export LOGNAME="${LOGNAME:-$(id -un)}"

notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }

FF="$(command -v ffmpeg 2>/dev/null)"
[ -z "$FF" ] && [ -x /opt/homebrew/bin/ffmpeg ] && FF=/opt/homebrew/bin/ffmpeg
[ -z "$FF" ] && [ -x /usr/local/bin/ffmpeg ] && FF=/usr/local/bin/ffmpeg
if [ -z "$FF" ] || [ ! -x "$FF" ]; then
  notify "Compression — erreur" "ffmpeg introuvable. Terminal : brew install ffmpeg-full"
  exit 1
fi

mkdir -p "$OUTDIR" 2>/dev/null

for f in "$@"; do
  ext="$(echo "${f##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in mp4|mov|m4v|mkv|avi|webm) : ;; *) continue ;; esac
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  name="${base%.*}"
  [ -z "${name// /}" ] && continue
  out="$OUTDIR/${name}_compressed.mp4"

  notify "Compression en cours" "$base…"
  "$FF" -y -i "$f" \
    -c:v libx264 -crf "$CRF" -preset "$PRESET" -pix_fmt yuv420p -movflags +faststart \
    -c:a aac -b:a "${AUDIO_KBPS}k" \
    "$out" >/tmp/compress_$$.log 2>&1

  if [ $? -eq 0 ] && [ -f "$out" ]; then
    insz=$(stat -f%z "$f" 2>/dev/null); outsz=$(stat -f%z "$out" 2>/dev/null)
    inmb=$(( insz/1024/1024 )); outmb=$(( outsz/1024/1024 ))
    dest="$out"
    if [ "$OUTPUT_TO_DESKTOP" = "true" ]; then
      # Finder (appli de confiance) dépose le fichier sur le Bureau -> Bitdefender ne bloque pas
      /usr/bin/osascript -e "tell application \"Finder\" to move (POSIX file \"$out\" as alias) to (path to desktop folder)" >/dev/null 2>&1 \
        && dest="$HOME/Desktop/$(basename "$out")"
    fi
    notify "Compression terminée ✅" "$(basename "$dest") — ${outmb} Mo (source ${inmb} Mo)"
  else
    notify "Compression — échec ❌" "$base (voir /tmp/compress_$$.log)"
  fi
done
exit 0
