#!/bin/zsh

JUST_BUILD=false
if [[ "$1" == "build" ]]; then
    JUST_BUILD=true
fi

set -o pipefail

# Build the app
echo "Building OpenSuperWhisper..."
mkdir -p build/ModuleCache build/SwiftPackageCache build/logs
export MODULE_CACHE_DIR="$PWD/build/ModuleCache"
export SWIFTCUSTOMMODULECACHE="$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_PACKAGE_CACHE="$PWD/build/SwiftPackageCache"
export SWIFTPM_CUSTOM_CACHE_PATH="$SWIFTPM_PACKAGE_CACHE"
export SWIFT_PACKAGE_CACHE_PATH="$SWIFTPM_PACKAGE_CACHE"
mkdir -p "$HOME/.cache/clang/ModuleCache" "$HOME/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading" 2>/dev/null || true

XCODE_LOG="$PWD/build/logs/xcodebuild.log"
CMD=(xcodebuild -scheme OpenSuperWhisper -configuration Debug -jobs 8 -derivedDataPath build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO MACOSX_DEPLOYMENT_TARGET=26.0 build)

if command -v xcpretty &> /dev/null; then
    "${CMD[@]}" 2>&1 | tee "$XCODE_LOG" | xcpretty --simple --color
    BUILD_STATUS=${pipestatus[1]}
else
    "${CMD[@]}" 2>&1 | tee "$XCODE_LOG"
    BUILD_STATUS=${pipestatus[1]}
fi

if [[ $BUILD_STATUS -eq 0 ]]; then
    echo "Building successful!"
    if $JUST_BUILD; then
        exit 0
    fi
    echo "Starting the app..."
    APP_BUNDLE="./build/Build/Products/Debug/OpenSuperWhisper.app"
    xattr -d com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
    "$APP_BUNDLE/Contents/MacOS/OpenSuperWhisper"
else
    echo "Build failed! See $XCODE_LOG for details."
    exit $BUILD_STATUS
fi
