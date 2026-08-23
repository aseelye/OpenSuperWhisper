## Release build

Release creation is deliberately split into two commands:

1. make_release.sh builds and notarizes the version already committed in
   OpenSuperWhisper.xcodeproj/project.pbxproj. It never edits project files,
   commits, tags, pushes, calls GitHub, or accepts a GitHub token.
2. publish_release.sh is the separately guarded publishing entry point. It
   verifies the build manifest against the current commit and version before
   an explicit, confirmed tag/push/GitHub release operation.

### Prerequisites

Run on the supported macOS/Xcode toolchain from a clean checkout. The release
machine must have:

- Xcode 26 and an Apple Silicon macOS 26 host;
- xcodebuild, xcrun, codesign, security, zip, and shasum;
- the swifty-dmg command;
- a Developer ID Application identity visible to security find-identity;
- an xcrun notarytool keychain profile; and
- for publication only, gh authenticated for the repository or a protected
  GH_TOKEN environment variable.

Signing inputs are explicit flags or protected environment variables. No
personal team, keychain profile, repository, or token is embedded in the
scripts.

### Build and verify locally

Inspect the committed version first:

```shell
./make_release.sh --dry-run \
  --identity "Developer ID Application: Example (TEAMID)" \
  --notary-profile release-notary
```

The dry run performs read-only preflight and does not create files, invoke the
build, or mutate Git. A real artifact build uses the same explicit inputs:

```shell
./make_release.sh \
  --identity "Developer ID Application: Example (TEAMID)" \
  --notary-profile release-notary
```

Optional values can be supplied through RELEASE_SIGNING_IDENTITY,
RELEASE_NOTARY_PROFILE, and RELEASE_DEVELOPMENT_TEAM. --version is an
assertion only; it cannot bump a project version.

The canonical artifact directory is build/release/:

- OpenSuperWhisper.dmg — signed, notarized, and stapled application image;
- OpenSuperWhisper.dmg.sha256 — SHA-256 checksum;
- OpenSuperWhisper.app.dSYM.zip — symbol archive when Xcode emitted a dSYM;
- release-manifest.txt — version, source commit, artifact paths, checksums,
  and notarization status.

The manifest is required for publishing. A missing dSYM is represented as
DSYM=none; it is not a release failure.

### Publish explicitly

Publishing requires a clean checkout on the origin default branch, an exact
match with the remote default-branch commit, no existing local or remote tag,
and an artifact manifest whose version and source commit match HEAD. The
command derives the repository and default branch from origin/gh; it does
not assume a particular owner or upstream.

Verify without mutation:

```shell
./publish_release.sh --dry-run
```

Create the annotated version tag, push it, and create the GitHub release only
after an explicit confirmation:

```shell
./publish_release.sh --publish --confirm
```

Use --manifest PATH when the artifact directory is elsewhere inside the
checkout. GH_TOKEN must be inherited from a protected secret store; never put
it in a command-line argument, shell history, or diagnostic output.

If publication fails after the tag push, inspect the repository and GitHub
release manually before retrying. Re-running the build command is safe and
does not alter source or Git state.
