# Building OpenSuperWhisper

OpenSuperWhisper targets macOS 26 and builds with Xcode 26 using the ordinary
Swift Package Manager and Xcode project workflows. The repository contains no
native transcription library, bundled model, or model-build step.

## Requirements

- macOS 26 or later
- Xcode 26 selected with `xcode-select`
- Apple Silicon Mac

## Local build

From the repository root, run:

```shell
./run.sh build
```

The script invokes `xcodebuild` directly and writes generated logs beneath
`build/`, which are ignored by Git. You can also open
`OpenSuperWhisper.xcodeproj` in Xcode and build the `OpenSuperWhisper` scheme.

Apple Speech performs local transcription after its selected language asset is
available. The optional OpenAI backend uploads completed recordings to the
`gpt-transcribe` model and requires an API key in Settings. No model download
is needed for either the build or the default local provider.

## CI and release builds

GitHub Actions uses the same `./run.sh build` path. Release creation is
separate from publishing: `make_release.sh` reads and verifies the committed
project version, builds/notarizes it, and writes a manifest under
`build/release/`. It does not edit project settings or mutate Git. Use
`publish_release.sh --publish --confirm` only after the manifest has been
reviewed and the checkout is clean and up to date with the origin default
branch. See [release_build.md](release_build.md) for prerequisites, signing
inputs, artifact names, and dry-run commands.
