#!/usr/bin/env bash
#
# capture-screenshots.sh — capture automatique des screenshots App Store (iOS).
#
# Lit scripts/appstore/screenshots.config.json, boote un simulateur, build Debug,
# installe l'app, puis pour chaque écran : lance l'app avec son launch-arg DEBUG,
# capture l'écran et vérifie les dimensions attendues (6.9" = 1320x2868 par défaut).
#
# Prérequis dans l'app (sous #if DEBUG) : des arguments de lancement -screenshot<Écran>
# qui routent directement vers l'écran voulu. Voir la convention dans /appstore-prep.
#
# Usage : bash scripts/appstore/capture-screenshots.sh [chemin/config.json]
#
set -euo pipefail

CONFIG="${1:-scripts/appstore/screenshots.config.json}"
[ -f "$CONFIG" ] || { echo "❌ Config introuvable : $CONFIG"; exit 1; }

# --- Lecture de la config (python3 est présent par défaut sur macOS) ---
read_cfg() { /usr/bin/python3 - "$CONFIG" "$1" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
key = sys.argv[2]
val = cfg
for part in key.split('.'):
    val = val[part]
print(val)
PY
}

SCHEME="$(read_cfg scheme)"
BUNDLE_ID="$(read_cfg bundleId)"
SIM_NAME="$(read_cfg simulator)"
PROJECT="$(read_cfg project)"        # ex. HIIT974.xcodeproj
OUT_DIR="$(read_cfg outputDir)"      # ex. screenshots
EXP_W="$(read_cfg expectedWidth)"
EXP_H="$(read_cfg expectedHeight)"
SB_TIME="$(read_cfg statusBarTime)"  # ex. 9:41

mkdir -p "$OUT_DIR"
DD="$(pwd)/build/screenshots-dd"

echo "▶︎ Simulateur : $SIM_NAME"
# Plusieurs simulateurs portent le même nom sur des runtimes iOS différents ; on choisit
# celui du runtime iOS le plus récent (sinon xcodebuild rejette si runtime < deployment target).
SIM_UDID="$(/usr/bin/python3 - "$SIM_NAME" <<'PY'
import json, subprocess, sys
name = sys.argv[1]
d = json.loads(subprocess.check_output(["xcrun","simctl","list","devices","available","--json"]))
def ver(rt):
    try: return tuple(int(x) for x in rt.split("iOS-")[-1].split("-"))
    except Exception: return (0,)
best = None
for rt, devs in d["devices"].items():
    if "iOS" not in rt: continue
    for dev in devs:
        if dev["name"] == name and dev.get("isAvailable"):
            if best is None or ver(rt) > best[0]:
                best = (ver(rt), dev["udid"])
print(best[1] if best else "")
PY
)"
[ -n "$SIM_UDID" ] || { echo "❌ Simulateur '$SIM_NAME' introuvable (aucun runtime iOS disponible)."; exit 1; }
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
open -a Simulator || true

echo "▶︎ Build Debug ($SCHEME)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "id=$SIM_UDID" -derivedDataPath "$DD" build >/dev/null
APP="$(ls -d "$DD"/Build/Products/Debug-iphonesimulator/*.app | head -1)"
[ -d "$APP" ] || { echo "❌ .app introuvable après build."; exit 1; }

echo "▶︎ Install + status bar propre…"
xcrun simctl install "$SIM_UDID" "$APP"
xcrun simctl status_bar "$SIM_UDID" override \
  --time "${SB_TIME:-9:41}" --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4 2>/dev/null || true

# --- Boucle sur les écrans (arg + file séparés par TAB) ---
/usr/bin/python3 - "$CONFIG" <<'PY' | while IFS=$'\t' read -r ARG FILE; do
import json, sys
cfg = json.load(open(sys.argv[1]))
for s in cfg["screens"]:
    print(f"{s['arg']}\t{s['file']}")
PY
  echo "  • $FILE  ($ARG)"
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" "$ARG" >/dev/null
  sleep 3
  # Rafale : un écran animé (transition numérique du chrono) est flou une image sur
  # trois. On tire plusieurs vues et on garde la plus nette.
  BURST_DIR="$(mktemp -d)"
  for N in 1 2 3 4 5 6; do
    xcrun simctl io "$SIM_UDID" screenshot "$BURST_DIR/$N.png" >/dev/null 2>&1
    sleep 0.35
  done
  # Garde la plus nette, puis aplatit : simctl écrit du RGBA, ASC refuse le canal alpha.
  /usr/bin/python3 -c 'import sys, glob
from PIL import Image, ImageFilter, ImageStat
burst, out = sys.argv[1], sys.argv[2]
best = None
for path in sorted(glob.glob(burst + "/*.png")):
    im = Image.open(path)
    w, h = im.size
    # Bande centrale : la zone qui porte le texte animé.
    zone = im.convert("L").crop((w // 4, int(h * 0.36), w * 3 // 4, int(h * 0.46)))
    score = ImageStat.Stat(zone.filter(ImageFilter.FIND_EDGES)).stddev[0]
    if best is None or score > best[0]:
        best = (score, path)
im = Image.open(best[1])
if "A" in im.getbands():
    im = im.convert("RGB")
im.save(out, "PNG", optimize=True)' "$BURST_DIR" "$OUT_DIR/$FILE" 2>/dev/null \
    || xcrun simctl io "$SIM_UDID" screenshot "$OUT_DIR/$FILE" >/dev/null 2>&1
  rm -rf "$BURST_DIR"
  W="$(sips -g pixelWidth  "$OUT_DIR/$FILE" 2>/dev/null | awk '/pixelWidth/{print $2}')"
  H="$(sips -g pixelHeight "$OUT_DIR/$FILE" 2>/dev/null | awk '/pixelHeight/{print $2}')"
  if [ "$W" = "$EXP_W" ] && [ "$H" = "$EXP_H" ]; then
    echo "    ✅ ${W}x${H}"
  else
    echo "    ⚠️  ${W}x${H} (attendu ${EXP_W}x${EXP_H}) — vérifier le simulateur"
  fi
done

echo "✅ Screenshots dans $OUT_DIR/"
