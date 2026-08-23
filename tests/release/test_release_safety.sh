#!/bin/bash
# Disposable release-script contract tests. Every repository, remote, fake tool,
# and mutation created here lives below one private mktemp directory.
set -e
set -o pipefail

HARNESS_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
SCRIPT_ROOT=$(CDPATH= cd -- "$HARNESS_DIR/../.." && pwd -P)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/opensuperwhisper-release-tests.XXXXXX")
SYSTEM_PATH="$PATH"
REAL_GIT=$(command -v git)
REAL_SHASUM=$(command -v shasum)
export REAL_GIT REAL_SHASUM
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

TESTS_RUN=0
TEST_REPO=""
CASE_NAME=""
FAKE_NO_DSYM=0
FAKE_BUILD_FAIL=0
FAKE_EXISTING_TAG=0
FAKE_GH_FAIL=0
REMOTE_SHA=""

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf 'ok %d - %s\n' "$TESTS_RUN" "$1"
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "expected failure: $*"
    fi
}

assert_file() {
    [ -f "$1" ] || fail "missing file: $1"
}

assert_contains() {
    needle="$1"
    file="$2"
    grep -F -- "$needle" "$file" >/dev/null 2>&1 || fail "expected '$needle' in $file"
}

assert_not_contains() {
    needle="$1"
    file="$2"
    if grep -F -- "$needle" "$file" >/dev/null 2>&1; then
        fail "unexpected '$needle' in $file"
    fi
}

make_fake_tools() {
    FAKE_BIN="$TMP_ROOT/fake-bin"
    FAKE_BIN_NO_XCODE="$TMP_ROOT/fake-bin-no-xcode"
    mkdir -p "$FAKE_BIN" "$FAKE_BIN_NO_XCODE"
    for tool in awk sort head grep dirname pwd mktemp; do
        ln -s "$(command -v "$tool")" "$FAKE_BIN_NO_XCODE/$tool"
    done
    ln -s /bin/bash "$FAKE_BIN_NO_XCODE/bash"
    for tool in awk sort head grep dirname pwd mktemp; do
        ln -s "$(command -v "$tool")" "$FAKE_BIN/$tool"
    done

    cat >"$FAKE_BIN/xcodebuild" <<'EOF'
#!/bin/bash
printf 'xcodebuild %s\n' "$*" >>"$FAKE_TOOL_LOG"
if [ "$FAKE_BUILD_FAIL" = "1" ]; then
    exit 47
fi
derived=""
previous=""
for arg in "$@"; do
    if [ "$previous" = "-derivedDataPath" ]; then
        derived="$arg"
    fi
    previous="$arg"
done
[ -n "$derived" ] || exit 48
app="$derived/Build/Products/Release/OpenSuperWhisper.app"
mkdir -p "$app/Contents"
printf 'fake app\n' >"$app/Contents/Info.plist"
if [ "$FAKE_NO_DSYM" != "1" ]; then
    mkdir -p "$derived/Build/Products/Release/OpenSuperWhisper.app.dSYM"
    printf 'fake symbols\n' >"$derived/Build/Products/Release/OpenSuperWhisper.app.dSYM/Contents"
fi
exit 0
EOF
    chmod +x "$FAKE_BIN/xcodebuild"

    cat >"$FAKE_BIN/xcrun" <<'EOF'
#!/bin/bash
printf 'xcrun %s\n' "$*" >>"$FAKE_TOOL_LOG"
exit 0
EOF
    cat >"$FAKE_BIN/codesign" <<'EOF'
#!/bin/bash
printf 'codesign %s\n' "$*" >>"$FAKE_TOOL_LOG"
exit 0
EOF
    cat >"$FAKE_BIN/security" <<'EOF'
#!/bin/bash
if [ "$FAKE_MISSING_IDENTITY" = "1" ]; then
    exit 1
fi
printf '  1) FAKEHASH "Developer ID Application: Fake (TEAMID)"\n'
exit 0
EOF
    cat >"$FAKE_BIN/swifty-dmg" <<'EOF'
#!/bin/bash
printf 'swifty-dmg %s\n' "$*" >>"$FAKE_TOOL_LOG"
output=""
previous=""
for arg in "$@"; do
    if [ "$previous" = "--output" ]; then
        output="$arg"
    fi
    previous="$arg"
done
[ -n "$output" ] || exit 49
mkdir -p "$(dirname "$output")"
printf 'fake dmg\n' >"$output"
exit 0
EOF
    cat >"$FAKE_BIN/zip" <<'EOF'
#!/bin/bash
printf 'zip %s\n' "$*" >>"$FAKE_TOOL_LOG"
output=""
for arg in "$@"; do
    case "$arg" in
        -*) ;;
        *) output="$arg"; break ;;
    esac
done
[ -n "$output" ] || exit 50
mkdir -p "$(dirname "$output")"
printf 'fake zip\n' >"$output"
exit 0
EOF
    cat >"$FAKE_BIN/shasum" <<EOF
#!/bin/bash
exec "$REAL_SHASUM" "\$@"
EOF
    cat >"$FAKE_BIN/git" <<'EOF'
#!/bin/bash
repo=""
if [ "$1" = "-C" ]; then
    repo="$2"
    shift 2
fi
cmd="$1"
printf '%s %s\n' "$cmd" "$*" >>"$FAKE_GIT_LOG"
if [ "$cmd" = "ls-remote" ]; then
    if [ "$2" = "--symref" ] || [ "$3" = "--symref" ]; then
        printf 'ref: refs/heads/master\tHEAD\n%s\tHEAD\n' "$FAKE_REMOTE_SHA"
        exit 0
    fi
    for arg in "$@"; do
        case "$arg" in
            refs/heads/*)
                printf '%s\t%s\n' "$FAKE_REMOTE_SHA" "$arg"
                exit 0
                ;;
            refs/tags/*)
                if [ "$FAKE_EXISTING_TAG" = "1" ]; then
                    printf 'deadbeef\t%s\n' "$arg"
                fi
                exit 0
                ;;
        esac
    done
fi
if [ "$cmd" = "push" ]; then
    exit 0
fi
if [ -n "$repo" ]; then
    exec "$REAL_GIT" -C "$repo" "$@"
fi
exec "$REAL_GIT" "$@"
EOF
    chmod +x "$FAKE_BIN/xcrun" "$FAKE_BIN/codesign" "$FAKE_BIN/security" "$FAKE_BIN/swifty-dmg" "$FAKE_BIN/zip" "$FAKE_BIN/shasum" "$FAKE_BIN/git"
    for tool in xcrun codesign security swifty-dmg zip shasum git; do
        cp "$FAKE_BIN/$tool" "$FAKE_BIN_NO_XCODE/$tool"
    done
    ln -s "$REAL_GIT" "$FAKE_BIN_NO_XCODE/git.real" 2>/dev/null || true

    cat >"$FAKE_BIN/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
if [ "$FAKE_GH_FAIL" = "1" ]; then
    exit 51
fi
exit 0
EOF
    chmod +x "$FAKE_BIN/gh"
    cp "$FAKE_BIN/gh" "$FAKE_BIN_NO_XCODE/gh"
}

new_repo() {
    CASE_NAME="$1"
    TEST_REPO="$TMP_ROOT/repo-$CASE_NAME"
    rm -rf "$TEST_REPO"
    mkdir -p "$TEST_REPO/OpenSuperWhisper.xcodeproj"
    printf 'MARKETING_VERSION = 1.2.3;\nCURRENT_PROJECT_VERSION = 7;\n' >"$TEST_REPO/OpenSuperWhisper.xcodeproj/project.pbxproj"
    printf 'build/\nfake-*.log\n*.out\n' >"$TEST_REPO/.gitignore"
    "$REAL_GIT" -C "$TEST_REPO" init -q
    "$REAL_GIT" -C "$TEST_REPO" config user.email test@example.invalid
    "$REAL_GIT" -C "$TEST_REPO" config user.name "Release Harness"
    "$REAL_GIT" -C "$TEST_REPO" add .
    "$REAL_GIT" -C "$TEST_REPO" commit -q -m baseline
    "$REAL_GIT" -C "$TEST_REPO" branch -M master
    "$REAL_GIT" -C "$TEST_REPO" remote add origin git@github.com:example/open-super-whisper.git
    REMOTE_SHA=$("$REAL_GIT" -C "$TEST_REPO" rev-parse HEAD)
    "$REAL_GIT" -C "$TEST_REPO" update-ref refs/remotes/origin/master "$REMOTE_SHA"
    "$REAL_GIT" -C "$TEST_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
    export REMOTE_SHA
    FAKE_GIT_LOG="$TEST_REPO/fake-git.log"
    FAKE_TOOL_LOG="$TEST_REPO/fake-tool.log"
    FAKE_GH_LOG="$TEST_REPO/fake-gh.log"
    : >"$FAKE_GIT_LOG"
    : >"$FAKE_TOOL_LOG"
    : >"$FAKE_GH_LOG"
    export FAKE_GIT_LOG FAKE_TOOL_LOG FAKE_GH_LOG FAKE_REMOTE_SHA="$REMOTE_SHA"
    FAKE_NO_DSYM=0
    FAKE_BUILD_FAIL=0
    FAKE_EXISTING_TAG=0
    FAKE_GH_FAIL=0
    export FAKE_NO_DSYM FAKE_BUILD_FAIL FAKE_EXISTING_TAG FAKE_GH_FAIL
}

run_make() {
    PATH="$FAKE_BIN:$SYSTEM_PATH" \
    RELEASE_SIGNING_IDENTITY="Developer ID Application: Fake (TEAMID)" \
    RELEASE_NOTARY_PROFILE="fake-profile" \
    FAKE_GIT_LOG="$FAKE_GIT_LOG" FAKE_TOOL_LOG="$FAKE_TOOL_LOG" \
    FAKE_REMOTE_SHA="$REMOTE_SHA" FAKE_NO_DSYM="$FAKE_NO_DSYM" \
    FAKE_BUILD_FAIL="$FAKE_BUILD_FAIL" \
    bash "$SCRIPT_ROOT/make_release.sh" --project-root "$TEST_REPO" "$@"
}

run_publish() {
    PATH="$FAKE_BIN:$SYSTEM_PATH" \
    GH_TOKEN="$GH_TOKEN" \
    FAKE_GIT_LOG="$FAKE_GIT_LOG" FAKE_TOOL_LOG="$FAKE_TOOL_LOG" \
    FAKE_GH_LOG="$FAKE_GH_LOG" FAKE_REMOTE_SHA="$REMOTE_SHA" \
    FAKE_EXISTING_TAG="$FAKE_EXISTING_TAG" \
    bash "$SCRIPT_ROOT/publish_release.sh" --project-root "$TEST_REPO" "$@"
}

test_dry_run() {
    new_repo dry-run
    rm -f "$FAKE_TOOL_LOG"
    set +e
    run_make --dry-run >"$TEST_REPO/dry.out" 2>&1
    dry_status=$?
    set -e
    [ "$dry_status" -eq 0 ] || fail "dry-run unexpectedly failed"
    [ ! -d "$TEST_REPO/build" ] || fail "dry run created build directory"
    [ ! -f "$FAKE_TOOL_LOG" ] || fail "dry run invoked a mutating tool"
    pass "dry-run has no build or filesystem side effect"
}

test_dirty_tree() {
    new_repo dirty
    printf dirty >"$TEST_REPO/untracked.txt"
    expect_failure run_make --dry-run
    pass "dirty tree is rejected before build"
}

test_missing_tool() {
    new_repo missing-tool
    PATH="$FAKE_BIN_NO_XCODE:/bin" \
    RELEASE_SIGNING_IDENTITY="Developer ID Application: Fake (TEAMID)" \
    RELEASE_NOTARY_PROFILE="fake-profile" \
    FAKE_GIT_LOG="$FAKE_GIT_LOG" FAKE_TOOL_LOG="$FAKE_TOOL_LOG" \
    bash "$SCRIPT_ROOT/make_release.sh" --project-root "$TEST_REPO" --dry-run >/dev/null 2>&1 && fail "missing xcodebuild was accepted"
    pass "missing build tool is rejected during preflight"
}

test_missing_credential() {
    new_repo missing-credential
    PATH="$FAKE_BIN:$SYSTEM_PATH" RELEASE_SIGNING_IDENTITY="" RELEASE_NOTARY_PROFILE="fake-profile" \
    FAKE_GIT_LOG="$FAKE_GIT_LOG" FAKE_TOOL_LOG="$FAKE_TOOL_LOG" bash "$SCRIPT_ROOT/make_release.sh" --project-root "$TEST_REPO" --dry-run >/dev/null 2>&1 && fail "missing identity was accepted"
    pass "missing signing credential is rejected"
}

test_build_failure_and_dsym() {
    new_repo build-failure
    FAKE_BUILD_FAIL=1
    export FAKE_BUILD_FAIL
    expect_failure run_make
    if grep -E '^(commit|tag|push) ' "$FAKE_GIT_LOG" >/dev/null 2>&1; then
        fail "build failure mutated Git"
    fi
    FAKE_BUILD_FAIL=0
    export FAKE_BUILD_FAIL
    run_make
    assert_file "$TEST_REPO/build/release/OpenSuperWhisper.dmg"
    assert_file "$TEST_REPO/build/release/OpenSuperWhisper.dmg.sha256"
    assert_file "$TEST_REPO/build/release/OpenSuperWhisper.app.dSYM.zip"
    assert_contains 'DSYM=build/release/OpenSuperWhisper.app.dSYM.zip' "$TEST_REPO/build/release/release-manifest.txt"
    if grep -E '^(commit|tag|push) ' "$FAKE_GIT_LOG" >/dev/null 2>&1; then
        fail "build mutated Git"
    fi
    pass "build failure is safe and dSYM artifact uses an absolute zip destination"
}

test_no_dsym() {
    new_repo no-dsym
    FAKE_NO_DSYM=1
    export FAKE_NO_DSYM
    run_make
    assert_contains 'DSYM=none' "$TEST_REPO/build/release/release-manifest.txt"
    [ ! -f "$TEST_REPO/build/release/OpenSuperWhisper.app.dSYM.zip" ] || fail "stale dSYM artifact remained"
    pass "missing dSYM is represented safely in the manifest"
}

test_manifest_and_publish_guards() {
    new_repo publish-guards
    run_make
    run_publish --dry-run --publish
    [ ! -f "$TEST_REPO/.git/refs/tags/1.2.3" ] || fail "unconfirmed dry-run created tag"
    expect_failure run_publish --publish

    "$REAL_GIT" -C "$TEST_REPO" checkout -q -b feature
    expect_failure run_publish --dry-run
    "$REAL_GIT" -C "$TEST_REPO" checkout -q master
    "$REAL_GIT" -C "$TEST_REPO" tag -a 1.2.3 -m existing
    expect_failure run_publish --dry-run
    "$REAL_GIT" -C "$TEST_REPO" tag -d 1.2.3 >/dev/null
    FAKE_EXISTING_TAG=1
    export FAKE_EXISTING_TAG
    expect_failure run_publish --dry-run
    FAKE_EXISTING_TAG=0
    export FAKE_EXISTING_TAG
    REMOTE_SHA=0000000000000000000000000000000000000000
    export REMOTE_SHA FAKE_REMOTE_SHA="$REMOTE_SHA"
    expect_failure run_publish --dry-run
    REMOTE_SHA=$("$REAL_GIT" -C "$TEST_REPO" rev-parse HEAD)
    export REMOTE_SHA FAKE_REMOTE_SHA="$REMOTE_SHA"
    printf corrupt >>"$TEST_REPO/build/release/OpenSuperWhisper.dmg"
    expect_failure run_publish --dry-run
    pass "branch, local/remote tag, checksum, and manifest guards reject unsafe publish"
}

test_secret_and_publish() {
    new_repo publish-secret
    run_make
    GH_TOKEN="release-secret-never-print"
    export GH_TOKEN
    set +e
    run_publish --publish --confirm >"$TEST_REPO/publish.out" 2>&1
    publish_status=$?
    set -e
    if [ "$publish_status" -ne 0 ]; then
        cat "$TEST_REPO/publish.out" >&2
        fail "confirmed publish failed"
    fi
    assert_not_contains "$GH_TOKEN" "$TEST_REPO/publish.out"
    assert_contains 'release create' "$FAKE_GH_LOG"
    if ! "$REAL_GIT" -C "$TEST_REPO" show-ref --verify --quiet refs/tags/1.2.3; then
        fail "confirmed publish did not create local tag"
    fi
    pass "protected token is not printed and confirmed publish is explicit"
}

test_verify_never_publishes() {
    new_repo verify-only
    run_make
    GH_TOKEN=""
    export GH_TOKEN
    run_publish >"$TEST_REPO/verify.out" 2>&1
    if grep -E '^(commit|tag|push) ' "$FAKE_GIT_LOG" >/dev/null 2>&1; then
        fail "verification-only publish mutated Git"
    fi
    [ ! -s "$FAKE_GH_LOG" ] || fail "verification-only publish invoked gh"
    pass "build and verification paths never commit, tag, push, or create releases"
}

make_fake_tools
test_dry_run
test_dirty_tree
test_missing_tool
test_missing_credential
test_build_failure_and_dsym
test_no_dsym
test_manifest_and_publish_guards
test_secret_and_publish
test_verify_never_publishes
printf 'All %d release safety tests passed.\n' "$TESTS_RUN"
