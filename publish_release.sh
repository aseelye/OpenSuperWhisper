#!/bin/bash
# Publish a previously verified release artifact. Building and publishing are
# intentionally separate so a normal build can never mutate Git or GitHub.
set -e
set -o pipefail

APP_NAME="OpenSuperWhisper"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
PROJECT_ROOT="$SCRIPT_DIR"
MANIFEST_PATH=""
DO_PUBLISH=0
CONFIRM=0
DRY_RUN=0

die() {
    printf 'publish error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: publish_release.sh [options]

Verify a release manifest. To create the tag, push it, and create the GitHub
release, pass both --publish and --confirm.

Options:
  --project-root PATH       Repository root (default: script directory)
  --manifest PATH           Manifest (default: build/release/release-manifest.txt)
  --publish                 Arm tag/push/GitHub release publication
  --confirm                 Confirm the publication (required with --publish)
  --dry-run                 Verify only; never mutate GitHub, Git, or files
  --help                    Show this help

GitHub authentication must come from GH_TOKEN (protected environment) or the
gh CLI's existing credential store. A token is never accepted positionally or
printed.
EOF
    exit 2
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_tool() {
    command_exists "$1" || die "required tool not found: $1"
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

absolute_from_root() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PROJECT_ROOT" "$1" ;;
    esac
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
        ""|*[!0-9A-Za-z.+-]*) die "invalid release version: $1" ;;
    esac
    case "$1" in
        *.*.*) ;;
        *) die "release version must contain major, minor, and patch components: $1" ;;
    esac
}

manifest_value() {
    awk -F= -v wanted="$1" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "$MANIFEST_PATH"
}

artifact_path() {
    value="$1"
    label="$2"
    [ -n "$value" ] || die "$label is missing from manifest"
    case "$value" in
        none) printf '%s\n' "none"; return 0 ;;
        /*) candidate="$value" ;;
        *) candidate="$PROJECT_ROOT/$value" ;;
    esac
    assert_safe_child "$candidate" "$label"
    assert_not_symlink "$candidate"
    printf '%s\n' "$candidate"
}

remote_repo_parts() {
    origin_url="$1"
    ORIGIN_HOST=""
    ORIGIN_PATH=""
    case "$origin_url" in
        git@*:* )
            ORIGIN_HOST=${origin_url%%:*}
            ORIGIN_HOST=${ORIGIN_HOST#git@}
            ORIGIN_PATH=${origin_url#*:}
            ;;
        ssh://*/*|https://*/*|http://*/*)
            origin_rest=${origin_url#*://}
            origin_authority=${origin_rest%%/*}
            # Drop URL user-info before any host/repository value is logged
            # or passed to gh. scp-style git@host:path is handled separately
            # above and already removes its transport user.
            ORIGIN_HOST=${origin_authority##*@}
            ORIGIN_PATH=${origin_rest#*/}
            ;;
        *)
            die "origin URL is not a GitHub-compatible SSH/HTTP URL"
            ;;
    esac
    ORIGIN_PATH=${ORIGIN_PATH%.git}
    case "$ORIGIN_PATH" in
        */*) ;;
        *) die "origin URL does not contain owner/repository" ;;
    esac
    [ -n "$ORIGIN_HOST" ] || die "origin URL has no host"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --project-root)
            [ "$#" -ge 2 ] || usage
            PROJECT_ROOT="$2"
            shift 2
            ;;
        --manifest)
            [ "$#" -ge 2 ] || usage
            MANIFEST_PATH="$2"
            shift 2
            ;;
        --publish)
            DO_PUBLISH=1
            shift
            ;;
        --confirm|--yes)
            CONFIRM=1
            shift
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
            die "positional arguments are not accepted; use --manifest and protected environment variables"
            ;;
    esac
done

PROJECT_ROOT=$(CDPATH= cd -- "$PROJECT_ROOT" 2>/dev/null && pwd -P) || die "project root does not exist"
if [ -z "$MANIFEST_PATH" ]; then
    MANIFEST_PATH="$PROJECT_ROOT/build/release/release-manifest.txt"
else
    MANIFEST_PATH=$(absolute_from_root "$MANIFEST_PATH")
fi
assert_safe_child "$MANIFEST_PATH" "manifest"
assert_not_symlink "$MANIFEST_PATH"
[ -f "$MANIFEST_PATH" ] || die "manifest not found: $MANIFEST_PATH"

[ "$DO_PUBLISH" -eq 0 ] || [ "$DRY_RUN" -eq 1 ] || [ "$CONFIRM" -eq 1 ] || die "--publish requires explicit --confirm"

PROJECT_FILE="$PROJECT_ROOT/OpenSuperWhisper.xcodeproj/project.pbxproj"
[ -f "$PROJECT_FILE" ] || die "Xcode project settings not found: $PROJECT_FILE"
PROJECT_FILE_REL=${PROJECT_FILE#"$PROJECT_ROOT"/}

for tool in git awk sort head grep shasum codesign xcrun; do
    require_tool "$tool"
done

REPO_ROOT=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null) || die "project root is not a Git repository"
REPO_ROOT=$(CDPATH= cd -- "$REPO_ROOT" && pwd -P)
[ "$REPO_ROOT" = "$PROJECT_ROOT" ] || die "project root must be the Git repository root"
HEAD_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD 2>/dev/null) || die "repository has no commit"
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$CURRENT_BRANCH" ] || die "repository is in detached HEAD state"
[ -z "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)" ] || die "repository is dirty"

VERSION_VALUES=$(project_version "$PROJECT_FILE")
[ -n "$VERSION_VALUES" ] || die "MARKETING_VERSION is missing from project settings"
VERSION_COUNT=$(printf '%s\n' "$VERSION_VALUES" | grep -c .)
[ "$VERSION_COUNT" -eq 1 ] || die "project settings contain multiple MARKETING_VERSION values"
PROJECT_VERSION=$(printf '%s\n' "$VERSION_VALUES" | head -n 1)
validate_version "$PROJECT_VERSION"

MANIFEST_FORMAT=$(manifest_value MANIFEST_FORMAT)
[ "$MANIFEST_FORMAT" = "1" ] || die "unsupported manifest format"
VERSION=$(manifest_value VERSION)
[ "$VERSION" = "$PROJECT_VERSION" ] || die "manifest version does not match committed project version"
MARKETING_VERSION=$(manifest_value MARKETING_VERSION)
[ "$MARKETING_VERSION" = "$VERSION" ] || die "manifest MARKETING_VERSION mismatch"
SOURCE_COMMIT=$(manifest_value SOURCE_COMMIT)
[ "$SOURCE_COMMIT" = "$HEAD_COMMIT" ] || die "manifest source commit does not match current HEAD"
TAG=$(manifest_value TAG)
[ "$TAG" = "$VERSION" ] || die "manifest tag does not match version"

ORIGIN_URL=$(git -C "$PROJECT_ROOT" config --get remote.origin.url 2>/dev/null || true)
[ -n "$ORIGIN_URL" ] || die "origin remote is required"
remote_repo_parts "$ORIGIN_URL"
if [ "$ORIGIN_HOST" = "github.com" ]; then
    GH_REPO="$ORIGIN_PATH"
else
    GH_REPO="$ORIGIN_HOST/$ORIGIN_PATH"
fi

SYMREF_OUTPUT=$(git -C "$PROJECT_ROOT" ls-remote --symref origin HEAD 2>/dev/null) || die "could not query origin default branch"
DEFAULT_BRANCH=$(printf '%s\n' "$SYMREF_OUTPUT" | awk '$1 == "ref:" && $2 ~ /^refs\/heads\// { sub(/^refs\/heads\//, "", $2); print $2; exit }')
if [ -z "$DEFAULT_BRANCH" ]; then
    REMOTE_HEAD_REF=$(git -C "$PROJECT_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    case "$REMOTE_HEAD_REF" in
        origin/*) DEFAULT_BRANCH=${REMOTE_HEAD_REF#origin/} ;;
        *) DEFAULT_BRANCH="" ;;
    esac
fi
[ -n "$DEFAULT_BRANCH" ] || die "could not derive origin default branch"
[ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ] || die "current branch $CURRENT_BRANCH is not origin default branch $DEFAULT_BRANCH"

REMOTE_BRANCH_LINE=$(git -C "$PROJECT_ROOT" ls-remote origin "refs/heads/$DEFAULT_BRANCH" 2>/dev/null) || die "could not query origin/$DEFAULT_BRANCH"
REMOTE_BRANCH_SHA=$(printf '%s\n' "$REMOTE_BRANCH_LINE" | awk 'NR == 1 { print $1; exit }')
[ -n "$REMOTE_BRANCH_SHA" ] || die "could not resolve origin/$DEFAULT_BRANCH"
[ "$REMOTE_BRANCH_SHA" = "$HEAD_COMMIT" ] || die "local HEAD is not up to date with origin/$DEFAULT_BRANCH"

DMG_VALUE=$(manifest_value DMG)
DMG_SHA_VALUE=$(manifest_value DMG_SHA256)
DMG_PATH=$(artifact_path "$DMG_VALUE" "DMG")
[ "$DMG_PATH" != "none" ] || die "manifest DMG cannot be none"
[ -f "$DMG_PATH" ] || die "DMG artifact is missing: $DMG_PATH"
case "$DMG_SHA_VALUE" in
    ''|*[!0-9A-Fa-f]*) die "manifest DMG_SHA256 is invalid" ;;
esac
[ ${#DMG_SHA_VALUE} -eq 64 ] || die "manifest DMG_SHA256 is not SHA-256"
ACTUAL_DMG_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
[ "$ACTUAL_DMG_SHA" = "$DMG_SHA_VALUE" ] || die "DMG checksum does not match manifest"
codesign --verify --deep --strict "$DMG_PATH" >/dev/null 2>&1 || die "DMG signature verification failed"
xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1 || die "DMG notarization validation failed"

DSYM_VALUE=$(manifest_value DSYM)
DSYM_SHA_VALUE=$(manifest_value DSYM_SHA256)
DSYM_PATH=$(artifact_path "$DSYM_VALUE" "dSYM")
if [ "$DSYM_PATH" = "none" ]; then
    [ "$DSYM_SHA_VALUE" = "none" ] || die "manifest dSYM checksum must be none when dSYM is absent"
else
    [ -f "$DSYM_PATH" ] || die "dSYM artifact is missing: $DSYM_PATH"
    case "$DSYM_SHA_VALUE" in
        ''|*[!0-9A-Fa-f]*) die "manifest dSYM_SHA256 is invalid" ;;
    esac
    [ ${#DSYM_SHA_VALUE} -eq 64 ] || die "manifest dSYM_SHA256 is not SHA-256"
    ACTUAL_DSYM_SHA=$(shasum -a 256 "$DSYM_PATH" | awk '{print $1}')
    [ "$ACTUAL_DSYM_SHA" = "$DSYM_SHA_VALUE" ] || die "dSYM checksum does not match manifest"
fi

if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/tags/$TAG"; then
    die "local tag already exists: $TAG"
fi
REMOTE_TAG_LINE=$(git -C "$PROJECT_ROOT" ls-remote origin "refs/tags/$TAG" 2>/dev/null) || die "could not query remote tag state"
[ -z "$REMOTE_TAG_LINE" ] || die "remote tag already exists: $TAG"

if [ "$DO_PUBLISH" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    require_tool gh
    # gh consumes GH_TOKEN from the protected environment when present; its
    # output is suppressed so credentials can never enter release logs.
    gh auth status --hostname "$ORIGIN_HOST" >/dev/null 2>&1 || die "gh is not authenticated for $ORIGIN_HOST"
fi

printf 'Publish preflight OK for %s (commit %.12s, branch %s).\n' "$VERSION" "$HEAD_COMMIT" "$CURRENT_BRANCH"
printf '  repository: %s\n' "$GH_REPO"
printf '  artifact: %s\n' "$DMG_PATH"
if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$DO_PUBLISH" -eq 1 ]; then
        printf 'DRY RUN: would create tag %s, push it, and create the GitHub release; no mutation occurred.\n' "$TAG"
    else
        printf 'DRY RUN: release manifest verified; no mutation occurred.\n'
    fi
    exit 0
fi
if [ "$DO_PUBLISH" -eq 0 ]; then
    printf 'Verification only: pass --publish --confirm to publish this release.\n'
    exit 0
fi

if ! git -C "$PROJECT_ROOT" tag -a "$TAG" -m "Release $TAG" "$HEAD_COMMIT" >/dev/null 2>&1; then
    die "local tag creation failed"
fi
if ! git -C "$PROJECT_ROOT" push origin "$TAG" >/dev/null 2>&1; then
    die "tag push failed"
fi

GH_LOG=$(mktemp "${TMPDIR:-/tmp}/opensuperwhisper-gh.XXXXXX")
trap 'rm -f "$GH_LOG"' EXIT HUP INT TERM
GH_ARGS=(release create "$TAG" "$DMG_PATH")
if [ "$DSYM_PATH" != "none" ]; then
    GH_ARGS+=("$DSYM_PATH")
fi
GH_ARGS+=(--repo "$GH_REPO" --title "$APP_NAME $VERSION" --notes "OpenSuperWhisper $VERSION. See the release artifacts for installation and checksums." --verify-tag --target "$HEAD_COMMIT")
if ! gh "${GH_ARGS[@]}" >"$GH_LOG" 2>&1; then
    rm -f "$GH_LOG"
    trap - EXIT HUP INT TERM
    die "GitHub release creation failed (credentials and command output were not printed)"
fi
rm -f "$GH_LOG"
trap - EXIT HUP INT TERM
printf 'Published %s to %s.\n' "$TAG" "$GH_REPO"
