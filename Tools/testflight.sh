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
xcodegen generate >/dev/null
xcodebuild archive -project DevNote.xcodeproj -scheme $SCHEME -configuration Release \
  -destination "$DEST" -archivePath $OUT/DevNote.xcarchive \
  -derivedDataPath /tmp/devnote-build-release-$SCHEME -allowProvisioningUpdates CURRENT_PROJECT_VERSION=$BUILD -quiet
xcodebuild -exportArchive -archivePath $OUT/DevNote.xcarchive \
  -exportOptionsPlist Tools/ExportOptions-TestFlight.plist -exportPath $OUT/export -allowProvisioningUpdates \
  | grep -E "Upload succeeded|error" || true
echo "$SCHEME derlemesi $BUILD yüklendi; App Store Connect işledikten sonra TestFlight'ta görünür."
