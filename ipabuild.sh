#!/bin/bash

set -e

cd "$(dirname "$0")"

APPLICATION_NAME=Filos

echo "[*] $APPLICATION_NAME Build Script"

if [[ $* == *--ts* ]]; then
    echo "[!] Make sure that ldid is installed before building!"
fi

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

if [[ $* == *--ts* ]]; then
    echo "[*] Linking entitlements..."
    ldid -S"$WORKING_LOCATION/entitlements.plist" "$TARGET_APP"
fi

echo "[*] Getting Info.plist values..."
INFO_PLIST="$TARGET_APP/Info.plist"
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")

echo "[*] Packaging..."
mkdir Payload
cp -r $APPLICATION_NAME.app Payload/$APPLICATION_NAME.app
zip -vr $APPLICATION_NAME.ipa Payload

echo "[*] All done, cleaning up..."
rm -rf Payload

cd ..
if [[ $* == *--debug* ]]; then
mv "$WORKING_LOCATION/build/$APPLICATION_NAME.ipa" ./"${APPLICATION_NAME}_${APP_VERSION}_debug".ipa
elif [[ $* == *--ts* ]]; then
mv "$WORKING_LOCATION/build/$APPLICATION_NAME.ipa" ./"${APPLICATION_NAME}_${APP_VERSION}_trollstore".ipa
else
mv "$WORKING_LOCATION/build/$APPLICATION_NAME.ipa" ./"${APPLICATION_NAME}_${APP_VERSION}_release".ipa
fi
rm -rf "$WORKING_LOCATION/build/"
