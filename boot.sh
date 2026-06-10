#!/bin/bash
# ==============================================================================
# boot.sh — tiny bootstrap entry point for a FRESH minimal install:
#
#   curl -fsSL https://raw.githubusercontent.com/Stars-Hiker/postInstall/main/boot.sh | bash
#
# Pass flags through to the main script:   ... | bash -s -- --desktop --yes
#
# Why this exists: git is NOT in Arch's `base` package group, so on a truly
# minimal install the README's `git clone` step fails. This installs git first,
# clones the repo, then hands off to ArchHyprPostInstall.sh with stdin
# reattached to the terminal so the wizard and the confirmation prompt still
# work even though the script itself arrived through a pipe.
# ==============================================================================
set -euo pipefail

REPO_URL="https://github.com/Stars-Hiker/postInstall"
DEST="$HOME/postInstall"

[[ "$EUID" -eq 0 ]] && { echo "Do not run as root — use a regular user with sudo." >&2; exit 1; }

command -v git >/dev/null 2>&1 \
    || sudo pacman -Sy --needed --noconfirm git

if [[ -d "$DEST/.git" ]]; then
    git -C "$DEST" pull --ff-only \
        || echo "WARN: could not update $DEST — continuing with the existing checkout." >&2
else
    git clone "$REPO_URL" "$DEST"
fi

cd "$DEST"
# `[[ -r /dev/tty ]]` only checks permission — actually try opening it, which
# fails (ENXIO) when there is no controlling terminal at all.
if { : < /dev/tty; } 2>/dev/null; then
    exec ./ArchHyprPostInstall.sh "$@" < /dev/tty
else
    # No terminal available (fully unattended) — flags/defaults apply.
    exec ./ArchHyprPostInstall.sh "$@"
fi
