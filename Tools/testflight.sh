#!/bin/zsh
# Uygulamayı arşivleyip TestFlight'a yükler. Derleme numarası: yyyyMMddHHmm.
#   ./Tools/testflight.sh        → iPhone / iPad
#   ./Tools/testflight.sh mac    → Mac
set -e
cd "$(dirname "$0")/.."
BUILD=$(date +%Y%m%d%H%M)
if [[ "$1" == "mac" ]]; then
  SCHEME=DevNote-macOS; DEST='generic/platform=macOS'; OUT=/tmp/devnote-archive-mac
else
  SCHEME=DevNote-iOS; DEST='generic/platform=iOS'; OUT=/tmp/devnote-archive
fi
# App Store Connect API anahtarı (Xcode hesabına gerek kalmaz): ~/.appstoreconnect/devnote.env
#   ASC_KEY_ID=XXXXXXXXXX  ASC_ISSUER_ID=xxxxxxxx-xxxx-...  (anahtar: ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8)
AUTH=()
if [[ -f ~/.appstoreconnect/devnote.env ]]; then
  source ~/.appstoreconnect/devnote.env
  AUTH=(-authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
        -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID)
fi
xcodegen generate >/dev/null
xcodebuild archive -project DevNote.xcodeproj -scheme $SCHEME -configuration Release \
  -destination "$DEST" -archivePath $OUT/DevNote.xcarchive \
  -derivedDataPath /tmp/devnote-build-release-$SCHEME -allowProvisioningUpdates $AUTH CURRENT_PROJECT_VERSION=$BUILD -quiet
xcodebuild -exportArchive -archivePath $OUT/DevNote.xcarchive \
  -exportOptionsPlist Tools/ExportOptions-TestFlight.plist -exportPath $OUT/export -allowProvisioningUpdates $AUTH \
  2>&1 | tee $OUT/export.log | grep -E "Upload succeeded|error" || true
if ! grep -q "EXPORT SUCCEEDED" $OUT/export.log; then
  echo "$SCHEME derlemesi $BUILD YÜKLENEMEDİ (ayrıntı: $OUT/export.log)"; exit 1
fi
echo "$SCHEME derlemesi $BUILD yüklendi; App Store Connect işledikten sonra TestFlight'ta görünür."
