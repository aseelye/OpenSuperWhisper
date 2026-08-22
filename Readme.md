# OpenSuperWhisper

OpenSuperWhisper is a macOS dictation app built around Apple’s on-device Speech framework. It transcribes locally after the selected language asset is installed, with an optional OpenAI `gpt-transcribe` backend for completed recordings.

<p align="center">
<img src="docs/image.png" width="400" /> <img src="docs/image_indicator.png" width="400" />
</p>

Free alternative to paid services like:
* https://tryvoiceink.com
* https://goodsnooze.gumroad.com/l/macwhisper
* and etc..

## Installation

```shell
brew update # Optional
brew install opensuperwhisper
```

Or from [github releases page](https://github.com/Starmel/OpenSuperWhisper/releases).

## Features

- 🎙️ Local audio recording and progressive transcription with Apple Speech
- ⌨️ Global keyboard shortcuts for quick recording
- 🌍 Apple-supported language and locale selection
- ☁️ Optional post-recording uploads through OpenAI `gpt-transcribe`
- 💾 Local storage of recordings with transcriptions
- 🔒 Local-first privacy: Apple transcription works offline after its language asset is installed

## Requirements

- macOS 26 or later
- Apple Silicon (ARM64) Mac

## Support

If you encounter any issues or have questions, please:
1. Check the existing issues in the repository
2. Create a new issue with detailed information about your problem
3. Include system information and logs when reporting bugs

# Building locally

To build locally, you'll need:

    git clone git@github.com:Starmel/OpenSuperWhisper.git
    cd OpenSuperWhisper
    ./run.sh build

The script invokes `xcodebuild` directly. Install Xcode 26, select it with `xcode-select`, and grant microphone and accessibility permissions when launching the app. Only Xcode and the existing Swift packages are required; there are no model downloads.

In case of problems, consult `.github/workflows/build.yml` which is our CI workflow
where the app gets built automatically on GitHub's CI.

## Contributing

Contributions are welcome! Please feel free to submit pull requests or create issues for bugs and feature requests.

### Contribution TODO list

- [x] Progressive transcription with Apple Speech ([#22](https://github.com/Starmel/OpenSuperWhisper/issues/22))
- [ ] Custom dictionary ([#20](https://github.com/Starmel/OpenSuperWhisper/issues/35))
- [ ] Intel macOS compatibility ([#16](https://github.com/Starmel/OpenSuperWhisper/issues/16))
- [ ] Agent mode ([#14](https://github.com/Starmel/OpenSuperWhisper/issues/14))
- [x] Background app ([#9](https://github.com/Starmel/OpenSuperWhisper/issues/9))
- [x] Support long-press single key audio recording ([#19](https://github.com/Starmel/OpenSuperWhisper/issues/19))

## License

OpenSuperWhisper is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Transcription backends

Apple Speech is the default backend and runs on-device once its language asset is installed. The app does not download or bundle model files. If you choose OpenAI in Settings, add an API key; recordings are uploaded only after you stop recording and are sent to the `gpt-transcribe` model.
