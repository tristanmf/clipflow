#!/bin/bash
# maj-outils.sh — met à jour tous les outils utilisés par les scripts et par ClipFlow,
# puis affiche les versions installées. Prompté par Tristan Mendès France — https://tristan.pro
#
# À lancer quand tu veux t'assurer que tout est à jour :  bash maj-outils.sh
# (yt-dlp casse souvent quand les sites changent leurs endpoints → c'est surtout
#  lui à rafraîchir ; un échec de « coller un lien » dans ClipFlow = presque
#  toujours yt-dlp en retard.)

BREW=/opt/homebrew/bin/brew
[ -x "$BREW" ] || BREW=/usr/local/bin/brew
if [ ! -x "$BREW" ]; then
  echo "Homebrew introuvable. Lance d'abord :  bash install-sous-titrage.sh"
  exit 1
fi

echo ">>> Rafraîchissement de la liste des formules Homebrew…"
"$BREW" update

echo ">>> Mise à jour des outils (ffmpeg-full, whisper-cpp, claude-code, yt-dlp)…"
"$BREW" upgrade ffmpeg-full whisper-cpp claude-code yt-dlp

echo ""
echo "=== Versions installées ==="
for outil in ffmpeg whisper-cli claude yt-dlp; do
  chemin="$(command -v "$outil" 2>/dev/null)"
  [ -z "$chemin" ] && [ -x "/opt/homebrew/bin/$outil" ] && chemin="/opt/homebrew/bin/$outil"
  [ -z "$chemin" ] && [ -x "/usr/local/bin/$outil" ] && chemin="/usr/local/bin/$outil"
  if [ -n "$chemin" ]; then
    case "$outil" in
      ffmpeg)      v="$("$chemin" -version 2>/dev/null | head -1 | cut -d' ' -f1-3)";;
      claude)      v="$("$chemin" --version 2>/dev/null | head -1)";;
      yt-dlp)      v="$("$chemin" --version 2>/dev/null | head -1)";;
      *)           v="présent";;
    esac
    printf "  %-14s %s\n" "$outil" "${v:-présent}"
  else
    printf "  %-14s %s\n" "$outil" "ABSENT — voir install-sous-titrage.sh"
  fi
done

# Modèle Whisper : téléchargé une fois, ne se met pas à jour via brew (rarement utile).
MODEL="$HOME/.cache/whisper/ggml-large-v3-turbo-q5_0.bin"
if [ -f "$MODEL" ]; then
  printf "  %-14s présent (%s)\n" "modèle Whisper" "$(du -h "$MODEL" 2>/dev/null | cut -f1)"
else
  printf "  %-14s ABSENT — relancer install-sous-titrage.sh\n" "modèle Whisper"
fi

echo ""
echo "Terminé. Si un « coller un lien » échoue encore après ça, le site a peut-être"
echo "changé et yt-dlp n'a pas encore de correctif — réessaie plus tard."
