#!/usr/bin/env bash
#
# verify-release-build.sh — compile l'app en Release et valide pour le store.
# Détecte précocement les erreurs qui feraient échouer l'archivage.
#
# Usage : bash scripts/appstore/verify-release-build.sh <Project.xcodeproj> <Scheme>
#
set -euo pipefail

PROJECT="${1:?Usage: verify-release-build.sh <Project.xcodeproj> <Scheme>}"
SCHEME="${2:?Usage: verify-release-build.sh <Project.xcodeproj> <Scheme>}"

echo "▶︎ Build Release ($SCHEME)…"
OUT="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation clean build 2>&1)" || { echo "$OUT" | tail -30; exit 1; }

if echo "$OUT" | grep -q '\*\* BUILD SUCCEEDED \*\*'; then
  echo "✅ BUILD SUCCEEDED (validate-for-store inclus)"
else
  echo "$OUT" | tail -30
  echo "❌ Build Release échoué."
  exit 1
fi
