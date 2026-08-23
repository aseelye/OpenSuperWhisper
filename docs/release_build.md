# Release build and publication

Release creation and publication are intentionally separate. A normal build
or verification run never writes a Git tag, pushes, calls GitHub, or uploads
an artifact.

`make_release.sh` reads the committed project version, builds/signs/notarizes
that version, and writes a verified manifest under `build/release/`.
`publish_release.sh` is the only entry point that can create the annotated tag,
push it, or create the GitHub release, and it requires both `--publish` and
`--confirm`.

## Prerequisites

Use the supported macOS 26 arm64/Xcode 26.6 toolchain. A signing machine also
needs `xcodebuild`, `xcrun`, `codesign`, `security`, `zip`, `shasum`, and
`swifty-dmg`, plus:

- a Developer ID Application identity visible to `security find-identity`;
- an `xcrun notarytool` keychain profile; and
- for publication only, `gh` authentication or a protected `GH_TOKEN`.

Signing identity, development team, notary profile, repository, and tokens are
inputs. None are embedded in the scripts, passed positionally, or printed.

## Safe preflight and artifact creation

Inspect the committed version without creating files or invoking build tools:

```shell
./make_release.sh --dry-run \
  --identity "Developer ID Application: Example (TEAMID)" \
  --notary-profile release-notary
```

Build a release artifact with explicit credentials:

```shell
./make_release.sh \
  --identity "Developer ID Application: Example (TEAMID)" \
  --notary-profile release-notary
```

The optional `--team` and `--version` flags are assertions/configuration;
`--version` cannot bump the project. Environment equivalents are
`RELEASE_SIGNING_IDENTITY`, `RELEASE_NOTARY_PROFILE`, and
`RELEASE_DEVELOPMENT_TEAM`.

The output directory contains:

- `OpenSuperWhisper.dmg` and its SHA-256 file;
- `OpenSuperWhisper.app.dSYM.zip` when Xcode emits a dSYM (otherwise the
  manifest records `DSYM=none`); and
- `release-manifest.txt`, including version, source commit, artifact paths,
  checksums, and notarization status.

The dSYM archive is written using an absolute artifact path and is verified
independently. The script refuses a dirty checkout, a version different from
`HEAD`, missing signing/notary tools, invalid artifact paths, or an artifact
whose checksum/signature/staple does not validate. Build failures leave no
Git mutation; inspect the logged derived-data path before retrying.

## Verify and publish explicitly

Publication first verifies the manifest against the current committed version
and commit, artifact checksums, the origin repository/default branch, and the
absence of local/remote tags:

```shell
./publish_release.sh --dry-run
```

Only after reviewing the manifest and confirming the remote state:

```shell
./publish_release.sh --publish --confirm
```

The command derives repository and default branch from `origin`, requires a
clean checkout at that branch and an exact remote commit match, and reads
credentials only from `gh`'s protected store or inherited `GH_TOKEN`. Never
put a token in shell history, an argument, or a log. If publication fails
after a tag push, inspect the remote tag and GitHub release before retrying;
do not rebuild merely to recover a publication step.

## Disposable safety harness

The release contract test uses only a private temporary repository and fake
tools. It covers dry-run non-mutation, dirty trees, missing tools/credentials,
failed builds, existing tags, missing and present dSYMs, manifest/checksum
verification, and explicit publish confirmation:

```shell
bash tests/release/test_release_safety.sh
```

The test harness never stages, commits, tags, pushes, or contacts GitHub in
the real checkout.
