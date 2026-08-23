#!/bin/bash
# Build, sign, notarize, and package the application without changing Git.
set -e
set -o pipefail

APP_NAME="OpenSuperWhisper"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
PROJECT_ROOT="$SCRIPT_DIR"
OUTPUT_DIR=""
DERIVED_DATA_DIR=""
SIGNING_IDENTITY="$RELEASE_SIGNING_IDENTITY"
NOTARY_PROFILE="$RELEASE_NOTARY_PROFILE"
DEVELOPMENT_TEAM_VALUE="$RELEASE_DEVELOPMENT_TEAM"
DRY_RUN=0

die() {
    printf 'release error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: notarize_app.sh [options]

Build and notarize the committed project version without changing Git state.

Options:
  --project-root PATH       Repository/project root (default: script directory)
  --output-dir PATH         Artifact directory (default: build/release)
  --derived-data-dir PATH   Xcode derived-data directory (default: build/release-derived-data)
  --identity VALUE          Developer ID signing identity
  --notary-profile VALUE    xcrun notarytool keychain profile
  --team VALUE              Development team (optional; never hard-coded)
  --dry-run                 Validate inputs and print the planned actions only
  --help                    Show this help

Signing inputs can also be supplied with RELEASE_SIGNING_IDENTITY,
RELEASE_NOTARY_PROFILE, and RELEASE_DEVELOPMENT_TEAM. Credentials are never
accepted as positional arguments.
EOF
    exit 2
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_tool() {
    command_exists "$1" || die "required tool not found: $1"
}

absolute_from_root() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PROJECT_ROOT" "$1" ;;
    esac
}

assert_safe_child() {
    candidate="$1"
    label="$2"
    case "$candidate" in
        "$PROJECT_ROOT"/*) ;;
        *) die "$label must be inside project root: $candidate" ;;
    esac
    [ "$candidate" != "$PROJECT_ROOT" ] || die "$label may not be the project root"
    case "$candidate" in
        *"/../"*|*/..|*/./*|*/.) die "$label contains an unsafe path: $candidate" ;;
    esac
}

assert_not_symlink() {
    [ ! -L "$1" ] || die "refusing symlink path: $1"
}

project_version() {
    awk '
        /MARKETING_VERSION[[:space:]]*=/ {
            value=$0
            sub(/^.*MARKETING_VERSION[[:space:]]*=[[:space:]]*/, "", value)
            sub(/[;[:space:]].*$/, "", value)
            if (value != "") print value
        }
    ' "$1" | sort -u
}

validate_version() {
    case "$1" in
        ""|*[!0-9A-Za-z.+-]*) die "invalid MARKETING_VERSION: $1" ;;
    esac
    case "$1" in
        *.*.*) ;;
        *) die "MARKETING_VERSION must contain major, minor, and patch components: $1" ;;
    esac
}

verify_identity() {
    [ -n "$SIGNING_IDENTITY" ] || die "signing identity is required (--identity or RELEASE_SIGNING_IDENTITY)"
    case "$SIGNING_IDENTITY" in
        *$'\n'*|*$'\r'*) die "signing identity contains a line break" ;;
    esac
    security_output=$(security find-identity -v -p codesigning 2>/dev/null) || die "unable to inspect code-signing identities"
    printf '%s\n' "$security_output" | grep -F -- "$SIGNING_IDENTITY" >/dev/null 2>&1 || die "signing identity is not available in the keychain"
}

verify_notary_profile() {
    [ -n "$NOTARY_PROFILE" ] || die "notary profile is required (--notary-profile or RELEASE_NOTARY_PROFILE)"
    case "$NOTARY_PROFILE" in
        *$'\n'*|*$'\r'*) die "notary profile contains a line break" ;;
    esac
    if [ "$DRY_RUN" -eq 0 ]; then
        xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || die "notary profile is unavailable"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --project-root)
            [ "$#" -ge 2 ] || usage
            PROJECT_ROOT="$2"
            shift 2
            ;;
        --output-dir)
            [ "$#" -ge 2 ] || usage
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --derived-data-dir)
            [ "$#" -ge 2 ] || usage
            DERIVED_DATA_DIR="$2"
            shift 2
            ;;
        --identity|--signing-identity)
            [ "$#" -ge 2 ] || usage
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --notary-profile)
            [ "$#" -ge 2 ] || usage
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --team)
            [ "$#" -ge 2 ] || usage
            DEVELOPMENT_TEAM_VALUE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            usage
            ;;
        --*)
            die "unknown option: $1"
            ;;
        *)
            die "positional arguments are not accepted; use explicit options"
            ;;
    esac
done

PROJECT_ROOT=$(CDPATH= cd -- "$PROJECT_ROOT" 2>/dev/null && pwd -P) || die "project root does not exist"
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$PROJECT_ROOT/build/release"
else
    OUTPUT_DIR=$(absolute_from_root "$OUTPUT_DIR")
fi
if [ -z "$DERIVED_DATA_DIR" ]; then
    DERIVED_DATA_DIR="$PROJECT_ROOT/build/release-derived-data"
else
    DERIVED_DATA_DIR=$(absolute_from_root "$DERIVED_DATA_DIR")
fi

assert_safe_child "$OUTPUT_DIR" "artifact directory"
assert_safe_child "$DERIVED_DATA_DIR" "derived-data directory"
assert_not_symlink "$OUTPUT_DIR"
assert_not_symlink "$DERIVED_DATA_DIR"

PROJECT_FILE="$PROJECT_ROOT/OpenSuperWhisper.xcodeproj/project.pbxproj"
[ -f "$PROJECT_FILE" ] || die "Xcode project settings not found: $PROJECT_FILE"
PROJECT_FILE_REL=${PROJECT_FILE#"$PROJECT_ROOT"/}

require_tool git
REPO_ROOT=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null) || die "project root is not a Git repository"
REPO_ROOT=$(CDPATH= cd -- "$REPO_ROOT" && pwd -P)
[ "$REPO_ROOT" = "$PROJECT_ROOT" ] || die "project root must be the Git repository root"
HEAD_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD 2>/dev/null) || die "repository has no commit"
if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)" ]; then
    die "repository is dirty; commit project changes before building"
fi

VERSION_VALUES=$(project_version "$PROJECT_FILE")
[ -n "$VERSION_VALUES" ] || die "MARKETING_VERSION is missing from project settings"
VERSION_COUNT=$(printf '%s\n' "$VERSION_VALUES" | grep -c .)
[ "$VERSION_COUNT" -eq 1 ] || die "project settings contain multiple MARKETING_VERSION values"
VERSION=$(printf '%s\n' "$VERSION_VALUES" | head -n 1)
validate_version "$VERSION"

HEAD_VERSION=$(git -C "$PROJECT_ROOT" show "HEAD:$PROJECT_FILE_REL" 2>/dev/null | project_version /dev/stdin)
[ "$HEAD_VERSION" = "$VERSION" ] || die "working project version is not the committed HEAD version"

if [ -n "$DEVELOPMENT_TEAM_VALUE" ]; then
    case "$DEVELOPMENT_TEAM_VALUE" in
        *[!A-Za-z0-9]*) die "development team contains unsupported characters" ;;
    esac
fi

for tool in awk sort head grep git xcodebuild xcrun codesign security zip shasum swifty-dmg; do
    require_tool "$tool"
done
verify_identity
verify_notary_profile

APP_PATH="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME.app"
APP_ZIP_PATH="$DERIVED_DATA_DIR/$APP_NAME.zip"
DMG_PATH="$OUTPUT_DIR/$APP_NAME.dmg"
DMG_SHA_PATH="$OUTPUT_DIR/$APP_NAME.dmg.sha256"
DSYM_PATH="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME.app.dSYM"
DSYM_ZIP_PATH="$OUTPUT_DIR/$APP_NAME.app.dSYM.zip"

printf 'Release preflight OK for %s (commit %.12s).\n' "$VERSION" "$HEAD_COMMIT"
printf '  artifact directory: %s\n' "$OUTPUT_DIR"
if [ -n "$SIGNING_IDENTITY" ]; then
    printf '  signing identity: provided\n'
else
    printf '  signing identity: missing (dry-run only)\n'
fi
if [ -n "$NOTARY_PROFILE" ]; then
    printf '  notary profile: provided\n'
else
    printf '  notary profile: missing (dry-run only)\n'
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY RUN: would build, notarize, staple, package, and verify %s.\n' "$APP_NAME"
    exit 0
fi

rm -rf "$DERIVED_DATA_DIR"
mkdir -p "$OUTPUT_DIR" "$DERIVED_DATA_DIR"
rm -f "$DMG_PATH" "$DMG_SHA_PATH" "$DSYM_ZIP_PATH" "$APP_ZIP_PATH"

BUILD_LOG="$DERIVED_DATA_DIR/xcodebuild.log"
XCODEBUILD_ARGS=(
    -scheme "$APP_NAME"
    -configuration Release
    -destination "platform=macOS,arch=arm64"
    -derivedDataPath "$DERIVED_DATA_DIR"
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
    OTHER_CODE_SIGN_FLAGS=--timestamp
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    MACOSX_DEPLOYMENT_TARGET=26.0
)
if [ -n "$DEVELOPMENT_TEAM_VALUE" ]; then
    XCODEBUILD_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM_VALUE")
fi

if ! xcodebuild "${XCODEBUILD_ARGS[@]}" build >"$BUILD_LOG" 2>&1; then
    printf 'release error: xcodebuild failed; see %s\n' "$BUILD_LOG" >&2
    exit 1
fi
[ -d "$APP_PATH" ] || die "built application not found: $APP_PATH"

codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 || die "application signature verification failed"

rm -f "$APP_ZIP_PATH"
(CD_PATH= cd -- "$(dirname "$APP_PATH")" && zip -r -y "$APP_ZIP_PATH" "$(basename "$APP_PATH")") >/dev/null
[ -f "$APP_ZIP_PATH" ] || die "application zip was not created"

xcrun notarytool submit "$APP_ZIP_PATH" --wait --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || die "application notarization failed"
xcrun stapler staple "$APP_PATH" >/dev/null 2>&1 || die "application stapling failed"
xcrun stapler validate "$APP_PATH" >/dev/null 2>&1 || die "application notarization validation failed"

swifty-dmg --skipcodesign "$APP_PATH" --output "$DMG_PATH" --verbose >/dev/null 2>&1 || die "DMG creation failed"
[ -f "$DMG_PATH" ] || die "DMG was not created: $DMG_PATH"

codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH" >/dev/null 2>&1 || die "DMG signing failed"
codesign --verify --deep --strict "$DMG_PATH" >/dev/null 2>&1 || die "DMG signature verification failed"
xcrun notarytool submit "$DMG_PATH" --wait --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || die "DMG notarization failed"
xcrun stapler staple "$DMG_PATH" >/dev/null 2>&1 || die "DMG stapling failed"
xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1 || die "DMG notarization validation failed"

# The dSYM source and zip destination are absolute. The zip is created
# directly at its final destination; there is no cd/mv self-move.
if [ -d "$DSYM_PATH" ]; then
    rm -f "$DSYM_ZIP_PATH"
    (CDPATH= cd -- "$(dirname "$DSYM_PATH")" && zip -r -y "$DSYM_ZIP_PATH" "$(basename "$DSYM_PATH")") >/dev/null
    [ -f "$DSYM_ZIP_PATH" ] || die "dSYM zip was not created: $DSYM_ZIP_PATH"
else
    rm -f "$DSYM_ZIP_PATH"
    printf 'No dSYM was emitted; continuing without a dSYM artifact.\n'
fi

shasum -a 256 "$DMG_PATH" >"$DMG_SHA_PATH"
[ -s "$DMG_SHA_PATH" ] || die "DMG checksum was not created"

printf 'Build, signing, notarization, and packaging succeeded for %s.\n' "$VERSION"
printf '  DMG: %s\n' "$DMG_PATH"
if [ -f "$DSYM_ZIP_PATH" ]; then
    printf '  dSYM: %s\n' "$DSYM_ZIP_PATH"
fi
