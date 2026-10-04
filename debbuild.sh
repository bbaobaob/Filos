#!/bin/bash

set -e

cd "$(dirname "$0")"

APPLICATION_NAME=Filos

echo "[*] $APPLICATION_NAME Build Script"
echo "[!] IMPORTANT: Make sure that ldid and dpkg are installed before running this script!"

rm -rf build

if ls *.ipa 1> /dev/null 2>&1; then
    rm -rf *.ipa
fi

WORKING_LOCATION="$(pwd)"

if [ ! -d "build" ]; then
    mkdir build
fi

cd build

if command -v xcodegen &> /dev/null; then
    echo "[*] Generating Xcode project (xcodegen)..."
    cd "$WORKING_LOCATION"
    xcodegen generate
    cd build
fi

echo "[*] Building..."
xcodebuild -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
    -scheme "$APPLICATION_NAME" \
    -configuration Release -sdk iphoneos \
    -derivedDataPath "$WORKING_LOCATION/build/DerivedDataApp" \
    -destination 'generic/platform=iOS' \
    clean build \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

DD_APP_PATH="$WORKING_LOCATION/build/DerivedDataApp/Build/Products/Release-iphoneos/$APPLICATION_NAME.app"
TARGET_APP="$WORKING_LOCATION/build/$APPLICATION_NAME.app"
cp -r "$DD_APP_PATH" "$TARGET_APP"

echo "[*] Stripping signature..."
codesign --remove "$TARGET_APP"
if [ -e "$TARGET_APP/_CodeSignature" ]; then
    rm -rf "$TARGET_APP/_CodeSignature"
fi
if [ -e "$TARGET_APP/embedded.mobileprovision" ]; then
    rm -rf "$TARGET_APP/embedded.mobileprovision"
fi

echo "[*] Linking entitlements..."
ldid -S"$WORKING_LOCATION/entitlements.plist" "$TARGET_APP"

TARGET_APP="$WORKING_LOCATION/build/$APPLICATION_NAME.app"

echo "[*] Getting Info.plist values..."
INFO_PLIST="$TARGET_APP/Info.plist"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")
APP_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$INFO_PLIST")
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")

# no reason for these to be here, i honestly could've just hardcoded everything but i'd rather this be reusable because then it won't be as much of a pain in the future.
: '
# prompt here
read -p "Description: " APP_DESCRIP
read -p "Maintainer: " APP_MAINT
read -p "Author: " APP_AUTH
read -p "Icon (url): " ICON_URL
read -p "Section: " APP_SECT
read -p "Depends (e.g. >= 15.0): " APP_DEPND
'

echo "[*] Building file structure..."
PKG_ROOT="$WORKING_LOCATION/package-root"
mkdir -p "$PKG_ROOT"
mkdir -p "$PKG_ROOT/DEBIAN"
cd "$PKG_ROOT/DEBIAN"
cat << EOF > control
Package: $BUNDLE_ID
Name: $APP_NAME
Version: $APP_VERSION
Architecture: iphoneos-arm64
Description: Modern and open-source file manager. Supports iOS 15+. For more information, check out our GitHub: https://github.com/jailbreakdotparty/Filos.
Maintainer: jailbreak.party
Author: jailbreak.party
Icon: https://raw.githubusercontent.com/jailbreakdotparty/Filos/main/PreviewIcon.png
Section: Utilities
Depends: firmware (>= 15.0)
Replaces: $BUNDLE_ID
Conflicts: $BUNDLE_ID
EOF
cat << EOF > postinst
#!/bin/bash
uicache -p /var/jb/Applications/$APP_NAME.app
EOF
cat << 'EOF' > postrm
#!/bin/bash
uicache
EOF
chmod 755 postinst postrm

mkdir -p "$PKG_ROOT/var/jb/Applications"
cp -r "$WORKING_LOCATION/build/$APP_NAME.app" "$PKG_ROOT/var/jb/Applications"

echo "[*] Cleaning DS Store artifacts..."
find $PKG_ROOT -name '.DS_Store' -delete

echo "[*] Packaging..."
PKG_NAME="${BUNDLE_ID}_${APP_VERSION}_iphoneos-arm64.deb"
dpkg-deb -b --root-owner-group $PKG_ROOT $PKG_NAME

echo "[*] All done, cleaning up..."
mv "$PKG_ROOT/DEBIAN/$PKG_NAME" $WORKING_LOCATION

rm -rf "$WORKING_LOCATION/build/"
rm -rf "$WORKING_LOCATION/package-root/"
