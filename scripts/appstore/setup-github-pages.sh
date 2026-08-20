#!/usr/bin/env bash
#
# setup-github-pages.sh — héberge une page (privacy/support) via GitHub Pages.
# Active Pages depuis la branche par défaut, attend le build, vérifie le HTTP 200.
#
# ⚠️ Si le repo est privé, GitHub Pages public nécessite de le passer en PUBLIC.
#    Ce script NE rend PAS le repo public tout seul : passe --make-public
#    explicitement (consentement requis, action quasi irréversible).
#
# Usage :
#   bash setup-github-pages.sh <owner/repo> <fichier.html> [branch] [--make-public]
# Exemple :
#   bash setup-github-pages.sh j0hanj0han/HIIT974 privacy.html main
#
set -euo pipefail

REPO="${1:?Usage: setup-github-pages.sh <owner/repo> <file.html> [branch] [--make-public]}"
FILE="${2:?fichier HTML requis}"
BRANCH="${3:-main}"
MAKE_PUBLIC=0
[ "${4:-}" = "--make-public" ] && MAKE_PUBLIC=1

VIS="$(gh repo view "$REPO" --json visibility -q .visibility)"
echo "▶︎ Repo $REPO : visibilité $VIS"

if [ "$VIS" != "PUBLIC" ]; then
  if [ "$MAKE_PUBLIC" -eq 1 ]; then
    echo "▶︎ Passage du repo en PUBLIC (consenti)…"
    gh repo edit "$REPO" --visibility public --accept-visibility-change-consequences
  else
    echo "❌ Repo privé. GitHub Pages public nécessite --make-public (expose le code source),"
    echo "   ou un plan GitHub Pro, ou un repo public dédié. Abandon."
    exit 2
  fi
fi

echo "▶︎ Activation de Pages ($BRANCH / root)…"
gh api -X POST "repos/$REPO/pages" --input - >/dev/null 2>&1 <<JSON || \
gh api -X PUT  "repos/$REPO/pages" --input - >/dev/null 2>&1
{"source":{"branch":"$BRANCH","path":"/"}}
JSON

echo -n "▶︎ Build Pages "
for _ in $(seq 1 12); do
  ST="$(gh api "repos/$REPO/pages" -q .status 2>/dev/null || echo '')"
  echo -n "."
  [ "$ST" = "built" ] && break
  sleep 10
done
echo

BASE="$(gh api "repos/$REPO/pages" -q .html_url)"
URL="${BASE%/}/$FILE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$URL")"
if [ "$CODE" = "200" ]; then
  echo "✅ En ligne : $URL"
else
  echo "⚠️  $URL → HTTP $CODE (le build Pages peut prendre 1-2 min de plus)"
fi
