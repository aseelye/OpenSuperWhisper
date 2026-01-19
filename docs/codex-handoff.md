# Codex Handoff – 2025-10-04

## TL;DR
- OpenAI backend now supports chunked uploads for files that exceed the 25 MB limit; stitching logic lives in `OpenSuperWhisper/TranscriptionService.swift`.
- Timeout windows increased (req 5 min / resource 10 min) but long uploads are still timing out; chunked path needs end-to-end validation.
- User is currently testing a large MP3 via drag-and-drop; be ready to pick up debugging that flow.
- OpenAI uploads now retry transient failures (configurable 0–5 attempts; default 1) with exponential backoff.

## Current State
- `transcribeWithOpenAIChunks` (≈L381) chooses a chunk duration based on bitrate estimate and ensures each exported `.m4a` stays under ~25 MB.
- Each chunk is exported to a temp dir (`~/Library/Caches/.../osw-openai-chunks`) and sequentially uploaded with the same request code path used for small files.
- UI now surfaces `fileTooLarge` errors in `FileDropHandler.present(error:)`, so oversized drops warn the user before hitting the network.
- Progress log (`docs/openai-integration-progress.log`) is up to date through the chunking implementation.
- Retry count preference lives in Settings → Model (OpenAI section) and persists via `AppPreferences.openAIRetryCount`.

## What’s Being Tested
1. Backend: OpenAI (toggle in Settings) with a valid API key stored in the Keychain helper.
2. Scenario: drag-and-drop MP3s >25 MB (or >6 min) to trigger chunking fallback.
3. Environment: built/running in Xcode on macOS (app bundle at `~/Library/Developer/Xcode/DerivedData/.../Debug/OpenSuperWhisper.app`).
4. Observed behaviour so far: drop shows 10 % progress, eventually fails with `NSURLErrorDomain Code=-1001` (~timeout) even for a ~9 MB low-bitrate file after chunking enabled.

## Open Issues / Next Steps
1. **Verify chunked transcription** – confirm `transcribeWithOpenAIChunks` actually receives OpenAI transcripts and stitches them; add logging around chunk export size/duration and HTTP response times if needed.
2. **Investigate timeout cause** – ensure `URLSession` upload isn’t recreating large `Data` causing slow serialization; consider streaming upload or reducing `chunkDuration` (currently min 30 s, max 6 min) for slow connections. Observe whether new retry logic masks Cloudflare timeouts or if we need client-side chunk parallelism.
3. **Temp directory cleanup** – on early failures some `osw-openai-chunks` files may persist; consider removing the directory after completion/error.
4. **User feedback** – progress indicator jumps per chunk; optional: expose more granular progress or retry messaging for long uploads.
5. **CI** – GitHub Actions still fails during “Building OpenSuperWhisper…” (post-Cargo step). Collect failing logs from `logs_46818487106` (if re-downloaded) and decide whether to skip the GUI build or adjust workflow.

## Helpful References
- `OpenSuperWhisper/TranscriptionService.swift:381` – chunking logic.
- `OpenSuperWhisper/TranscriptionService.swift:607` – `OpenAITranscriptionClient` with timeout configuration.
- `OpenSuperWhisper/FileDropHandler.swift` – drag/drop orchestration + error surfacing.
- `docs/openai-integration-progress.log` – chronological change log.
- API limit reminder: Whisper file upload max 25 MB; streaming API not yet integrated.

_Please append new findings to `docs/openai-integration-progress.log` and update this handoff file when you continue._
