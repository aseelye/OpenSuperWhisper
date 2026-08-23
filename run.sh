#!/bin/zsh

MODE="${1:-run}"
case "$MODE" in
    build|test|run)
        ;;
    --help|-h)
        cat <<'EOF'
Usage: ./run.sh [build|test|run]

  build  Build the Debug app without launching it. Locally signs it when an
         Apple Development identity is available.
  test   Build and run the OpenSuperWhisperTests unit target.
  run    Build and launch the Debug app (the default for local use).

Release artifact creation and publication are separate operations; see
make_release.sh and publish_release.sh.
EOF
        exit 0
        ;;
    *)
        echo "Unknown command: $MODE" >&2
        echo "Usage: ./run.sh [build|test|run]" >&2
        exit 2
        ;;
esac

set -o pipefail

sign_debug_app_if_possible() {
    local app_bundle="$PWD/build/Build/Products/Debug/OpenSuperWhisper.app"
    local signing_identity="${OPEN_SUPER_WHISPER_SIGN_IDENTITY:-}"

    if [[ -z "$signing_identity" ]] && command -v security &> /dev/null; then
        signing_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ { print $2; exit }')"
    fi

    if [[ -z "$signing_identity" ]]; then
        echo "Warning: no Apple Development identity found; Debug app remains unsigned."
        return 0
    fi

    echo "Signing Debug app for stable macOS privacy permissions..."
    codesign --force --deep --sign "$signing_identity" \
        --entitlements "$PWD/OpenSuperWhisper/OpenSuperWhisper.entitlements" \
        --identifier net.mdo.OpenSuperWhisper "$app_bundle"
    codesign --verify --deep --strict "$app_bundle"
}

# Build or test the app. Generated state stays below build/, which is ignored
# by Git. The explicit cloned package path keeps CI and cache-free verification
# on the workspace Package.resolved rather than a machine-global checkout.
if [[ "$MODE" == "test" ]]; then
    echo "Testing OpenSuperWhisper unit target..."
else
    echo "Building OpenSuperWhisper..."
fi
mkdir -p build/ModuleCache build/SwiftPackageCache build/logs
export MODULE_CACHE_DIR="$PWD/build/ModuleCache"
export SWIFTCUSTOMMODULECACHE="$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_PACKAGE_CACHE="$PWD/build/SwiftPackageCache"
export SWIFTPM_CUSTOM_CACHE_PATH="$SWIFTPM_PACKAGE_CACHE"
export SWIFT_PACKAGE_CACHE_PATH="$SWIFTPM_PACKAGE_CACHE"
mkdir -p "$HOME/.cache/clang/ModuleCache" "$HOME/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading" 2>/dev/null || true

XCODE_LOG="$PWD/build/logs/xcodebuild.log"
XCODE_JOBS="${XCODE_JOBS:-8}"
CMD=(xcodebuild -project OpenSuperWhisper.xcodeproj -scheme OpenSuperWhisper -configuration Debug -jobs "$XCODE_JOBS" -derivedDataPath build -clonedSourcePackagesDirPath "$SWIFTPM_PACKAGE_CACHE/SourcePackages" -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO MACOSX_DEPLOYMENT_TARGET=26.0)
if [[ "$MODE" == "test" ]]; then
    CMD+=(-only-testing:OpenSuperWhisperTests -parallel-testing-enabled "${XCODE_PARALLEL_TESTING:-YES}" -maximum-parallel-testing-workers "${XCODE_TEST_WORKERS:-4}" test)
else
    CMD+=(build)
fi

if [[ "${USE_XCPRETTY:-0}" == "1" ]] && command -v xcpretty &> /dev/null; then
    "${CMD[@]}" 2>&1 | tee "$XCODE_LOG" | xcpretty --simple --color
    BUILD_STATUS=${pipestatus[1]}
else
    "${CMD[@]}" 2>&1 | tee "$XCODE_LOG"
    BUILD_STATUS=${pipestatus[1]}
fi

if [[ $BUILD_STATUS -eq 0 ]]; then
    if [[ "$MODE" == "test" ]]; then
        echo "Tests successful!"
        exit 0
    fi
    sign_debug_app_if_possible || exit $?
    echo "Building successful!"
    if [[ "$MODE" == "build" ]]; then
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
