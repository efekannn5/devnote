#!/bin/bash
# Windows kod imzası (Tauri her .exe için çağırır: sign.sh <dosya>).
# Sertifika yoksa hiçbir şey yapmaz; varsa Authenticode + zaman damgası ekler (osslsigncode, Mac'te: brew install osslsigncode).
#   DEVNOTE_SIGN_PFX=/yol/sertifika.pfx DEVNOTE_SIGN_PASS=... npm run build:win
set -euo pipefail
file="$1"
if [[ -z "${DEVNOTE_SIGN_PFX:-}" ]]; then
  echo "imza: sertifika verilmedi, atlandı ($file)"
  exit 0
fi
tmp="$file.signed"
osslsigncode sign \
  -pkcs12 "$DEVNOTE_SIGN_PFX" ${DEVNOTE_SIGN_PASS:+-pass "$DEVNOTE_SIGN_PASS"} \
  -n "DevNote" -i "https://github.com/efekan/devnote" \
  -h sha256 -ts "${DEVNOTE_SIGN_TS:-http://timestamp.digicert.com}" \
  -in "$file" -out "$tmp"
mv "$tmp" "$file"
osslsigncode verify -in "$file" >/dev/null && echo "imza: tamam ($file)"
