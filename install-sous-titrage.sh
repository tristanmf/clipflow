#!/bin/bash
# install-sous-titrage.sh — installe le système de sous-titrage automatique (Mac Apple Silicon).
# Prompté par Tristan Mendès France — https://tristan.pro
#
# UTILISATION sur un nouveau Mac (l'installeur copie le script depuis CE dépôt) :
#   1) git clone https://github.com/tristanmf/clipflow.git
#   2) Terminal :  bash clipflow/install-sous-titrage.sh
#   3) suivre les instructions affichées à la fin (connexion Claude + éventuel jeton)

echo "=== Installation du système de sous-titrage automatique ==="
if [ "$(uname -m)" != "arm64" ]; then echo "⚠️  Prévu pour Mac Apple Silicon (M1/M2/M3)."; fi
BREW=/opt/homebrew/bin/brew

# 1) Homebrew
if [ ! -x "$BREW" ]; then
  echo ">>> Homebrew absent — installation (entre ton mot de passe Mac si demandé)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$("$BREW" shellenv)"
grep -q "brew shellenv" "$HOME/.zprofile" 2>/dev/null || printf '\n# Homebrew\neval "$(/opt/homebrew/bin/brew shellenv)"\n' >> "$HOME/.zprofile"

# 2) Paquets (ffmpeg-full apporte libass = sous-titres ; whisper-cpp = transcription ;
#    claude-code = traduction ; yt-dlp = téléchargement de liens dans l'app ClipFlow)
echo ">>> Installation de ffmpeg-full, whisper-cpp, claude-code, yt-dlp (quelques minutes)…"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
"$BREW" install ffmpeg-full whisper-cpp claude-code yt-dlp
# yt-dlp casse régulièrement quand les sites changent : on le garde à jour à chaque install/réparation.
"$BREW" upgrade yt-dlp >/dev/null 2>&1 || true
"$BREW" unlink ffmpeg >/dev/null 2>&1
"$BREW" link --force --overwrite ffmpeg-full >/dev/null 2>&1

# 3) Modèle Whisper (~547 Mo, une fois)
MODEL="$HOME/.cache/whisper/ggml-large-v3-turbo-q5_0.bin"
if [ ! -f "$MODEL" ]; then
  echo ">>> Téléchargement du modèle Whisper…"
  mkdir -p "$HOME/.cache/whisper"
  curl -L --fail --progress-bar -o "$MODEL" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
fi

# 4) Script principal — SOURCE UNIQUE : on copie le fichier standalone de ce dépôt
#    (plus de script embarqué en double -> aucune divergence possible).
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$SRC_DIR/dossier-sous-titrage.sh" ]; then
  echo "⚠️  '$SRC_DIR/dossier-sous-titrage.sh' introuvable."
  echo "    Lance l'installeur DEPUIS le dossier cloné du dépôt (git clone …), pas isolé."
  exit 1
fi
mkdir -p "$HOME/Scripts"
cp "$SRC_DIR/dossier-sous-titrage.sh" "$HOME/Scripts/dossier-sous-titrage.sh"
chmod +x "$HOME/Scripts/dossier-sous-titrage.sh"

# Dossier du jeton d'automatisation Claude (rempli plus tard si besoin, voir fin)
mkdir -p "$HOME/.config/sous-titrage"

# 5) Dossier surveillé + sortie
mkdir -p "$HOME/Movies/Sous-titrage"

# 6) Déclencheur natif attaché à ~/Movies/Sous-titrage
FAS="$HOME/Library/Scripts/Folder Action Scripts"
mkdir -p "$FAS"
cat > /tmp/st_fa_install.applescript <<'FAEOF'
on adding folder items to thisFolder after receiving theItems
	repeat with anItem in theItems
		do shell script "nohup " & (POSIX path of (path to home folder)) & "Scripts/dossier-sous-titrage.sh " & quoted form of (POSIX path of anItem) & " >/dev/null 2>&1 &"
	end repeat
end adding folder items to
FAEOF
osacompile -o "$FAS/Sous-titrage-auto.scpt" /tmp/st_fa_install.applescript
rm -f /tmp/st_fa_install.applescript
echo ">>> Attache du déclencheur (macOS peut demander d'autoriser le contrôle de 'System Events' -> Autoriser)…"
osascript <<'ATTACHEOF'
tell application "System Events"
    set folder actions enabled to true
    set tgt to (POSIX path of (path to home folder)) & "Movies/Sous-titrage"
    if not (exists folder action "Sous-titrage Movies") then
        make new folder action at end of folder actions with properties {name:"Sous-titrage Movies", path:tgt}
    end if
    tell folder action "Sous-titrage Movies"
        if not (exists script "Sous-titrage-auto.scpt") then
            make new script at end of scripts with properties {name:"Sous-titrage-auto.scpt"}
        end if
    end tell
end tell
ATTACHEOF

# 7) Alias du dossier sur le Bureau (accès rapide)
osascript <<'ALIASEOF' 2>/dev/null
set p to (POSIX path of (path to home folder)) & "Movies/Sous-titrage"
tell application "Finder"
    try
        make alias file to ((POSIX file p) as alias) at desktop
    end try
end tell
ALIASEOF

echo ""
echo "============================================================"
echo " ✅ Installation terminée."
echo ""
echo " DERNIÈRE ÉTAPE (1 seule fois) — connecter Claude :"
echo "    1) tape :  claude"
echo "    2) connecte-toi à ton compte Claude (dans le navigateur)"
echo "    3) tape :  /exit"
echo ""
echo " Ensuite : glisse une vidéo (maintiens Option pour COPIER)"
echo " dans l'alias 'Sous-titrage' du Bureau."
echo " Résultats dans : ~/Movies/Sous-titrage"
echo ""
echo " ⚠️  SI la traduction auto échoue (notif « Traduction Claude"
echo "     invalide » ou erreur 401) — arrive quand le CLI ne peut"
echo "     pas s'authentifier en mode automatique (ex. si l'app"
echo "     Claude Desktop tourne sur cette machine) :"
echo "        claude setup-token        # copier le jeton affiché"
echo "        printf '%s' 'LE_JETON' > ~/.config/sous-titrage/token"
echo "        chmod 600 ~/.config/sous-titrage/token"
echo "     Le script lit ce fichier automatiquement (jeton ~1 an)."
echo "============================================================"
