#!/bin/zsh
# Build the watch app from the command line.
#   ./build.sh fenix7           -> builds for that device, side as currently set in Config.mc
#   ./build.sh fenix7 left      -> sets SIDE = "left" in Config.mc, then builds
#   ./build.sh fenix847mm right -> his watch, his side
# Output: watch/bin/BedTemp-<device>-<side>.prg  (copy to the watch's GARMIN/APPS folder)
set -euo pipefail
cd "$(dirname "$0")"

DEVICE="${1:-fenix7}"
KEY="$HOME/.garmin/developer_key.der"

if [[ ! -f source/Config.mc ]]; then
  echo "source/Config.mc is missing. Copy source/Config.mc.example to source/Config.mc and fill in your relay URL and secret."
  exit 1
fi

if [[ -n "${2:-}" ]]; then
  case "$2" in
    left|right|me) sed -i '' -E "s/const SIDE = \"[a-z]+\";/const SIDE = \"$2\";/" source/Config.mc ;;
    *) echo "side must be left, right or me"; exit 1 ;;
  esac
fi
SIDE="$(sed -nE 's/.*const SIDE = "([a-z]+)";.*/\1/p' source/Config.mc)"

# Java from Homebrew (the SDK's monkeyc needs a JRE on PATH).
for j in /opt/homebrew/opt/openjdk@21/bin /opt/homebrew/opt/openjdk/bin; do
  [[ -d "$j" ]] && export PATH="$j:$PATH" && break
done

# Find monkeyc: Homebrew-linked, or the SDK the Garmin SDK Manager made current.
MONKEYC="$(command -v monkeyc || true)"
if [[ -z "$MONKEYC" ]]; then
  CFG="$HOME/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg"
  [[ -f "$CFG" ]] && MONKEYC="$(cat "$CFG")/bin/monkeyc"
fi
[[ -x "${MONKEYC:-}" ]] || { echo "monkeyc not found. brew install --cask connectiq, or install an SDK with the Connect IQ SDK Manager."; exit 1; }

# Developer key (apps must be signed, even to sideload onto your own watch).
if [[ ! -f "$KEY" ]]; then
  mkdir -p "$(dirname "$KEY")"
  openssl genrsa -out "$HOME/.garmin/developer_key.pem" 4096 2>/dev/null
  openssl pkcs8 -topk8 -inform PEM -outform DER -in "$HOME/.garmin/developer_key.pem" -out "$KEY" -nocrypt
  echo "generated developer key at $KEY (keep it; apps signed with a different key are seen as different apps)"
fi

mkdir -p bin
OUT="bin/BedTemp-$DEVICE-$SIDE.prg"
"$MONKEYC" -d "$DEVICE" -f monkey.jungle -o "$OUT" -y "$KEY" -w -l 1
echo "built $OUT  (side: $SIDE)"
