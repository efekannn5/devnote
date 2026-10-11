#!/bin/zsh
# Mac uygulamasını Developer ID ile imzalar, Apple'a onaylatır (notarize) ve DMG yapar.
#   ./Tools/dmg.sh   → build/DevNote-<sürüm>.dmg
set -e
cd "$(dirname "$0")/.."
BUILD=$(date +%Y%m%d%H%M)
OUT=/tmp/devnote-archive-dmg
rm -rf $OUT
# App Store Connect API anahtarı (Xcode hesabına gerek kalmaz): ~/.appstoreconnect/devnote.env
#   ASC_KEY_ID=XXXXXXXXXX  ASC_ISSUER_ID=xxxxxxxx-xxxx-...  (anahtar: ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8)
AUTH=()
if [[ -f ~/.appstoreconnect/devnote.env ]]; then
  source ~/.appstoreconnect/devnote.env
  AUTH=(-authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
        -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID)
fi
xcodegen generate >/dev/null
xcodebuild archive -project DevNote.xcodeproj -scheme DevNote-macOS -configuration Release \
  -destination 'generic/platform=macOS' -archivePath $OUT/DevNote.xcarchive \
  -derivedDataPath /tmp/devnote-build-release-dmg -allowProvisioningUpdates $AUTH CURRENT_PROJECT_VERSION=$BUILD -quiet
# Onaya gönder (Xcode'daki Apple hesabıyla)
xcodebuild -exportArchive -archivePath $OUT/DevNote.xcarchive \
  -exportOptionsPlist Tools/ExportOptions-DeveloperID.plist -exportPath $OUT/upload -allowProvisioningUpdates $AUTH
# Onay gelince damgalı uygulamayı al
until xcodebuild -exportNotarizedApp -archivePath $OUT/DevNote.xcarchive -exportPath $OUT/app $AUTH 2>/dev/null; do
  echo "Apple onayı bekleniyor…"; sleep 30
done
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $OUT/app/DevNote.app/Contents/Info.plist)
mkdir -p build $OUT/dmg
cp -R $OUT/app/DevNote.app $OUT/dmg/
ln -s /Applications $OUT/dmg/Applications
DMG=build/DevNote-$VERSION.dmg
rm -f $DMG
hdiutil create -volname DevNote -srcfolder $OUT/dmg -format UDZO -ov $DMG >/dev/null
codesign --sign "Developer ID Application: Efekan Nefesoglu (896PY6QKL9)" --timestamp $DMG
spctl -a -vv -t install $DMG 2>&1 | head -2 || true
echo "$DMG hazır (derleme $BUILD)"
