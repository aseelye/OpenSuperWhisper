# Building OpenSuperWhisper

OpenSuperWhisper is a macOS 26 app built with Xcode 26.6 on Apple Silicon.
There is no bundled model, native transcription submodule, or model-build
step.

## Supported toolchain

- macOS 26.x
- Xcode 26.6 (build 17F113 or the matching 26.6 image)
- macOS 26.x SDK
- arm64

The workspace lock at
`OpenSuperWhisper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
is the only SwiftPM lock. The old root `Package.resolved` is intentionally
absent. Do not create a second lock at the repository root or resolve from a
machine-global package checkout when verifying a change.

## Local build and unit tests

From the repository root:

```shell
./run.sh build                         # Debug build; never launches the app
./run.sh test                          # unit target; parallel by default
XCODE_PARALLEL_TESTING=NO XCODE_TEST_WORKERS=1 ./run.sh test
```

`run.sh` uses a repository-local derived-data and SwiftPM checkout under
`build/`. The `build` command is safe to use while iterating. `run` (or an
invocation with no command) is the explicit local-launch path; CI uses only
`build` and `test`.

For a cache-free authority check, use fresh directories and resolve before
building or testing:

```shell
rm -rf build/cache-free
mkdir -p build/cache-free/DerivedData build/cache-free/SourcePackages
xcodebuild -resolvePackageDependencies \
  -project OpenSuperWhisper.xcodeproj -scheme OpenSuperWhisper \
  -derivedDataPath build/cache-free/DerivedData \
  -clonedSourcePackagesDirPath build/cache-free/SourcePackages
xcodebuild -project OpenSuperWhisper.xcodeproj -scheme OpenSuperWhisper \
  -configuration Debug -derivedDataPath build/cache-free/DerivedData \
  -clonedSourcePackagesDirPath build/cache-free/SourcePackages \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
xcodebuild -project OpenSuperWhisper.xcodeproj -scheme OpenSuperWhisper \
  -configuration Debug -derivedDataPath build/cache-free/DerivedData \
  -clonedSourcePackagesDirPath build/cache-free/SourcePackages \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
  -only-testing:OpenSuperWhisperTests test
```

The unit target currently contains 118 tests. The default shared scheme keeps
the unit target enabled and the UI target skipped; the separate
`OpenSuperWhisperUI` scheme is serialized and opt-in.

Shell and release checks are independent of an artifact build:

```shell
zsh -n run.sh
bash -n make_release.sh notarize_app.sh publish_release.sh tests/release/test_release_safety.sh
bash tests/release/test_release_safety.sh
git diff --check
```

Keep Xcode invocations serial when collecting diagnostics. After a test or
build, verify that no OpenSuperWhisper app or test-runner process remains
before starting another Xcode invocation. The test suite does not use the
user's history database, shared user defaults, or real network services.

## Runtime architecture

`DictationSessionController` owns one operation context and issues a
`SessionOperationToken`/source before the first suspension. Capture exposes an
async operation handle (`start`, `stopAndDrain`, `cancelAndDrain`) and Apple
Speech exposes a live operation. OpenAI uses a completed-file operation with
upload, retry, cancellation, and temporary-chunk cleanup owned by that handle.
There are no runtime callers for the former synchronous engine/session bridge.

The controller publishes one phase snapshot, rejects stale token updates, and
waits for capture/provider teardown before admitting a replacement. A bounded
five-second live-audio channel closes on overflow; the complete WAV is moved
to Recovery and the operation reports an actionable failure.

History is nonfatal. A durable commit receipt separates database insertion
from publication. If history is unavailable after transcription, the text is
copied to the clipboard, audio is preserved in Recovery, and the UI shows a
warning with retry/recovery actions. Missing-audio rows retain transcript
metadata and offer “Locate Audio…” or “Remove Entry”. Startup reconciliation
quarantines app-owned orphan or incomplete capture files; unknown files are
left untouched.

## Permissions and known limitations

Manual microphone validation requires microphone permission and an installed
Apple Speech language asset. The UI scheme uses the launch argument
`--open-super-whisper-ui-test`; it is deliberately not part of ordinary pull
request CI because automation mode is host-specific. Its four tests use an
isolated HOME, bypass the app's microphone/accessibility gate, and do not
record or install Speech assets. The opt-in workflow lane uses serialized UI
tests and an ad-hoc signing posture; the runner may still need macOS
Automation/Accessibility permission for XCUITest itself.

Apple Speech is local after its asset is installed. OpenAI uploads completed
audio to `gpt-transcribe`, requires a Keychain API key, enforces the configured
upload ceiling, and does not provide automatic cloud fallback from Apple
Speech. Real microphone/device disconnects, Speech asset downloads, network
failure, and signed/notarized artifacts remain manual macOS acceptance gates.

The pre-1.0 upgrade path still accepts the legacy `local` backend value and
migrates `whisperLanguage` plus the known whisper model/prompt keys. These are
user-data compatibility migrations, not runtime engine protocols. Keep them
through the pre-1.0 line; a versioned 1.0 removal gate requires an explicit
oldest-supported upgrade matrix and release decision before deleting the
decoder/migration keys.

See [release_build.md](release_build.md) for the explicit artifact/publish
split and [codex-handoff.md](codex-handoff.md) for the current ownership and
recovery contract.
