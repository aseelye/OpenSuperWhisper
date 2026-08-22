# Codex Handoff – Current Architecture

## TL;DR

- `DictationSessionController` owns capture, progressive updates, cancellation,
  finalization, and persistence for both transcription providers.
- Apple Speech is the default on-device provider and streams progressive
  results while recording after its macOS language asset is available.
- OpenAI uses completed-file uploads to `gpt-transcribe`, with chunking for
  large recordings and retry/backoff for transient failures.
- The repository builds through the normal Xcode/SwiftPM workflow; there are
  no native transcription submodules, bundled model files, or model-build
  steps.

## Current State

- `OpenSuperWhisper/TranscriptionCore.swift` defines provider-neutral
  transcripts, updates, engine protocols, and shared errors.
- `OpenSuperWhisper/DictationSessionController.swift` coordinates recording,
  live sessions, completed-file transcription, cancellation, and final-only
  history writes.
- `OpenSuperWhisper/AudioCaptureService.swift` owns AVAudioEngine capture and
  temporary WAV recording files.
- `OpenSuperWhisper/AppleSpeechTranscriptionEngine.swift` uses
  `SpeechAnalyzer`/`SpeechTranscriber` for progressive on-device results.
- `OpenSuperWhisper/OpenAITranscriptionEngine.swift` uploads completed files,
  keeps uploads below the 25 MB API limit, stitches chunks, and applies the
  configured retry policy.
- `OpenSuperWhisper/FileDropHandler.swift` routes dropped audio through the
  same controller and surfaces provider errors to the UI.
- `AppPreferences` migrates old provider-neutral settings and removes only
  the known legacy model/preferences keys during upgrade.

## Validation and follow-up

- Exercise Apple Speech with an installed language asset and verify
  progressive updates, cancellation, and final history persistence.
- Exercise OpenAI with a Keychain API key using both a small file and a file
  large enough to trigger chunking; verify cleanup after success and failure.
- GitHub Actions uses the same ordinary Xcode build invoked by `run.sh`.

Keep generated logs out of source control; update this handoff when the
current architecture or validation status changes.
