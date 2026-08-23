#!/bin/bash
# Build a release artifact from the version already committed in project
# settings. This command never commits, tags, pushes, or calls GitHub.
set -e
set -o pipefail

APP_NAME="OpenSuperWhisper"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
PROJECT_ROOT="$SCRIPT_DIR"
OUTPUT_DIR=""
SIGNING_IDENTITY="$RELEASE_SIGNING_IDENTITY"
NOTARY_PROFILE="$RELEASE_NOTARY_PROFILE"
DEVELOPMENT_TEAM_VALUE="$RELEASE_DEVELOPMENT_TEAM"
EXPECTED_VERSION=""
DRY_RUN=0

die() {
    printf 'release error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: make_release.sh [options]

Build and notarize the committed project version, then write a verified
artifact manifest. Publishing is a separate operation (publish_release.sh).

Options:
  --project-root PATH       Repository/project root (default: script directory)
  --output-dir PATH         Artifact directory (default: build/release)
  --identity VALUE          Developer ID signing identity
  --notary-profile VALUE    xcrun notarytool keychain profile
  --team VALUE              Development team (optional; never hard-coded)
  --version VALUE           Assert this version; never modify project settings
  --dry-run                 Run preflight only; no build or filesystem mutation
  --help                    Show this help

Signing inputs can also be supplied with RELEASE_SIGNING_IDENTITY,
RELEASE_NOTARY_PROFILE, and RELEASE_DEVELOPMENT_TEAM. GitHub credentials are
not read by this command and are never accepted as positional arguments.
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

project_build_number() {
    awk '
        /CURRENT_PROJECT_VERSION[[:space:]]*=/ {
            value=$0
            sub(/^.*CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*/, "", value)
            sub(/[;[:space:]].*$/, "", value)
            if (value != "") print value
        }
    ' "$1" | sort -u | head -n 1
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
        --version)
            [ "$#" -ge 2 ] || usage
            EXPECTED_VERSION="$2"
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
assert_safe_child "$OUTPUT_DIR" "artifact directory"
assert_not_symlink "$OUTPUT_DIR"

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
if [ -n "$EXPECTED_VERSION" ] && [ "$EXPECTED_VERSION" != "$VERSION" ]; then
    die "requested version $EXPECTED_VERSION does not match committed project version $VERSION"
fi

HEAD_VERSION=$(git -C "$PROJECT_ROOT" show "HEAD:$PROJECT_FILE_REL" 2>/dev/null | project_version /dev/stdin)
[ "$HEAD_VERSION" = "$VERSION" ] || die "working project version is not the committed HEAD version"
BUILD_NUMBER=$(project_build_number "$PROJECT_FILE")
[ -n "$BUILD_NUMBER" ] || die "CURRENT_PROJECT_VERSION is missing from project settings"

if [ -n "$DEVELOPMENT_TEAM_VALUE" ]; then
    case "$DEVELOPMENT_TEAM_VALUE" in
        *[!A-Za-z0-9]*) die "development team contains unsupported characters" ;;
    esac
fi

NOTARIZE_SCRIPT="$SCRIPT_DIR/notarize_app.sh"
[ -f "$NOTARIZE_SCRIPT" ] || die "notarize_app.sh not found beside make_release.sh"

for tool in awk sort head grep git shasum codesign xcrun security bash xcodebuild zip swifty-dmg; do
    require_tool "$tool"
done
verify_identity
[ -n "$NOTARY_PROFILE" ] || die "notary profile is required (--notary-profile or RELEASE_NOTARY_PROFILE)"

DMG_PATH="$OUTPUT_DIR/$APP_NAME.dmg"
DMG_SHA_PATH="$OUTPUT_DIR/$APP_NAME.dmg.sha256"
DSYM_ZIP_PATH="$OUTPUT_DIR/$APP_NAME.app.dSYM.zip"
MANIFEST_PATH="$OUTPUT_DIR/release-manifest.txt"

printf 'Release preflight OK for %s (commit %.12s, build %s).\n' "$VERSION" "$HEAD_COMMIT" "$BUILD_NUMBER"
printf '  artifact directory: %s\n' "$OUTPUT_DIR"
if [ -n "$SIGNING_IDENTITY" ]; then
    printf '  signing identity: provided\n'
else
    printf '  signing identity: missing (dry-run only)\n'
fi
if [ -n "$NOTARY_PROFILE" ]; then
    printf '  notary profile: provided\n'
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY RUN: no build, cleanup, manifest, Git, or network mutation will occur.\n'
    exit 0
fi

NOTARIZE_ARGS=(
    --project-root "$PROJECT_ROOT"
    --output-dir "$OUTPUT_DIR"
    --identity "$SIGNING_IDENTITY"
    --notary-profile "$NOTARY_PROFILE"
)
if [ -n "$DEVELOPMENT_TEAM_VALUE" ]; then
    NOTARIZE_ARGS+=(--team "$DEVELOPMENT_TEAM_VALUE")
fi
bash "$NOTARIZE_SCRIPT" "${NOTARIZE_ARGS[@]}"

[ -f "$DMG_PATH" ] || die "DMG not found after notarization: $DMG_PATH"
[ -f "$DMG_SHA_PATH" ] || die "DMG checksum not found after notarization: $DMG_SHA_PATH"
codesign --verify --deep --strict "$DMG_PATH" >/dev/null 2>&1 || die "DMG signature verification failed"
xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1 || die "DMG notarization validation failed"

EXPECTED_SHA=$(awk '{print $1; exit}' "$DMG_SHA_PATH")
case "$EXPECTED_SHA" in
    ''|*[!0-9A-Fa-f]*) die "invalid DMG checksum file: $DMG_SHA_PATH" ;;
esac
[ ${#EXPECTED_SHA} -eq 64 ] || die "DMG checksum is not SHA-256: $DMG_SHA_PATH"
ACTUAL_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || die "DMG checksum does not match artifact"
if [ -f "$DSYM_ZIP_PATH" ]; then
    DSYM_REL=${DSYM_ZIP_PATH#"$PROJECT_ROOT"/}
    DSYM_SHA=$(shasum -a 256 "$DSYM_ZIP_PATH" | awk '{print $1}')
else
    DSYM_REL="none"
    DSYM_SHA="none"
fi

FINAL_HEAD=$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD 2>/dev/null) || die "repository HEAD disappeared"
[ "$FINAL_HEAD" = "$HEAD_COMMIT" ] || die "repository HEAD changed during build"
if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)" ]; then
    die "build changed tracked or untracked repository state"
fi
FINAL_VERSION=$(project_version "$PROJECT_FILE")
[ "$FINAL_VERSION" = "$VERSION" ] || die "project version changed during build"

DMG_REL=${DMG_PATH#"$PROJECT_ROOT"/}
DMG_SHA_REL=${DMG_SHA_PATH#"$PROJECT_ROOT"/}
REPOSITORY_URL=$(git -C "$PROJECT_ROOT" config --get remote.origin.url 2>/dev/null || true)
MANIFEST_TMP="$MANIFEST_PATH.tmp.$$"
trap 'rm -f "$MANIFEST_TMP"' EXIT HUP INT TERM
umask 077
{
    printf 'MANIFEST_FORMAT=1\n'
    printf 'APP_NAME=%s\n' "$APP_NAME"
    printf 'VERSION=%s\n' "$VERSION"
    printf 'MARKETING_VERSION=%s\n' "$VERSION"
    printf 'CURRENT_PROJECT_VERSION=%s\n' "$BUILD_NUMBER"
    printf 'SOURCE_COMMIT=%s\n' "$HEAD_COMMIT"
    printf 'TAG=%s\n' "$VERSION"
    printf 'ORIGIN_URL=%s\n' "$REPOSITORY_URL"
    printf 'DMG=%s\n' "$DMG_REL"
    printf 'DMG_SHA256=%s\n' "$ACTUAL_SHA"
    printf 'DSYM=%s\n' "$DSYM_REL"
    printf 'DSYM_SHA256=%s\n' "$DSYM_SHA"
    printf 'NOTARIZATION=stapled\n'
} >"$MANIFEST_TMP"
mv -f "$MANIFEST_TMP" "$MANIFEST_PATH"
trap - EXIT HUP INT TERM

printf 'Verified release artifacts written to %s.\n' "$MANIFEST_PATH"
