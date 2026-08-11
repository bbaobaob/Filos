#!/bin/bash
# yes this is vibecoded, i don't care.

set -e

cd "$(dirname "$0")"

APPLICATION_NAME=Filos
PACKAGE_ID="com.jailbreakdotparty.filos"
MAINTAINER="jbdotparty"
SECTION="Utilities"
ARCHITECTURE="iphoneos-arm64"     # rootless arch tag
MINIOS="15.0"

echo "[*] $APPLICATION_NAME Build Script (rootless .deb)"

rm -rf build
if ls *.deb 1> /dev/null 2>&1; then
    rm -rf *.deb
fi

WORKING_LOCATION="$(pwd)"

if [ ! -d "build" ]; then
    mkdir build
fi

cd build

echo "[*] Building..."
if [[ $* == *--debug* ]]; then
xcodebuild -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
    -scheme "$APPLICATION_NAME" \
    -configuration Debug \
    -derivedDataPath "$WORKING_LOCATION/build/DerivedDataApp" \
    -destination 'generic/platform=iOS' \
    clean build \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

DD_APP_PATH="$WORKING_LOCATION/build/DerivedDataApp/Build/Products/Debug-iphoneos/$APPLICATION_NAME.app"
TARGET_APP="$WORKING_LOCATION/build/$APPLICATION_NAME.app"
cp -r "$DD_APP_PATH" "$TARGET_APP"
else
xcodebuild -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
    -scheme "$APPLICATION_NAME" \
    -configuration Release \
    -derivedDataPath "$WORKING_LOCATION/build/DerivedDataApp" \
    -destination 'generic/platform=iOS' \
    clean build \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

DD_APP_PATH="$WORKING_LOCATION/build/DerivedDataApp/Build/Products/Release-iphoneos/$APPLICATION_NAME.app"
TARGET_APP="$WORKING_LOCATION/build/$APPLICATION_NAME.app"
cp -r "$DD_APP_PATH" "$TARGET_APP"
fi

echo "[*] Stripping signature..."
codesign --remove "$TARGET_APP"
if [ -e "$TARGET_APP/_CodeSignature" ]; then
    rm -rf "$TARGET_APP/_CodeSignature"
fi
if [ -e "$TARGET_APP/embedded.mobileprovision" ]; then
    rm -rf "$TARGET_APP/embedded.mobileprovision"
fi

echo "[*] Reading version from Info.plist..."
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$TARGET_APP/Info.plist")"
echo "    -> $VERSION"

echo "[*] Fake-signing binary with unsandboxed entitlements..."
cat > "$WORKING_LOCATION/build/entitlements.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key>
    <true/>
    <key>com.apple.private.security.no-sandbox</key>
    <true/>
    <key>com.apple.private.skip-library-validation</key>
    <true/>
</dict>
</plist>
EOF

if ! command -v ldid >/dev/null 2>&1; then
    echo "[!] ldid not found in PATH. Install it (e.g. 'brew install ldid') and re-run." >&2
    exit 1
fi

ldid -S"$WORKING_LOCATION/build/entitlements.plist" "$TARGET_APP/$APPLICATION_NAME"

echo "[*] Assembling rootless package layout..."
PKGROOT="$WORKING_LOCATION/build/pkgroot"
rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/DEBIAN"
mkdir -p "$PKGROOT/var/jb/Applications"

cp -r "$TARGET_APP" "$PKGROOT/var/jb/Applications/$APPLICATION_NAME.app"

cat > "$PKGROOT/DEBIAN/control" << EOF
Package: $PACKAGE_ID
Name: $APPLICATION_NAME
Version: $VERSION
Architecture: $ARCHITECTURE
Description: A file browser for iOS.
Maintainer: $MAINTAINER
Author: $MAINTAINER
Section: $SECTION
Depends: firmware (>= $MINIOS)
EOF

cat > "$PKGROOT/DEBIAN/postinst" << 'EOF'
#!/bin/bash
if command -v uicache >/dev/null 2>&1; then
    uicache -p /var/jb/Applications/Filos.app
fi
exit 0
EOF
chmod 0755 "$PKGROOT/DEBIAN/postinst"

echo "[*] Packaging..."
if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "[!] dpkg-deb not found in PATH. Install it (e.g. 'brew install dpkg') and re-run." >&2
    exit 1
fi

DEB_NAME="${PACKAGE_ID}_${VERSION}_${ARCHITECTURE}.deb"
dpkg-deb -Zzstd --root-owner-group -b "$PKGROOT" "$WORKING_LOCATION/build/$DEB_NAME"

echo "[*] All done, cleaning up..."
cd ..
if [[ $* == *--debug* ]]; then
mv "$WORKING_LOCATION/build/$DEB_NAME" "./${APPLICATION_NAME}.debug.deb"
else
mv "$WORKING_LOCATION/build/$DEB_NAME" .
fi
rm -rf "$WORKING_LOCATION/build/"

echo "[*] Built: $DEB_NAME"
