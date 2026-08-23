# OpenAI transcription integration

## Current architecture

The backend toggle is complete. `TranscriptionBackend` keeps Apple Speech as
the private, on-device default and exposes OpenAI as an explicit choice.
`OpenAIAPIKeyStore` stores the API key in the macOS Keychain; it is never put
in preferences, logs, prompts, or command-line arguments.

OpenAI is intentionally a file-after-capture provider. The controller first
drains the operation-scoped capture handle, then creates an OpenAI file
operation. That handle owns multipart request creation, upload/progress
events, transient retry/backoff, cancellation, response validation, and
temporary chunk cleanup. It returns a provider-neutral `Transcript` and
cannot be mistaken for a live stream. Apple Speech remains the only `.live`
recording strategy.

## Upload behavior

- Completed recordings are sent to the configured `gpt-transcribe` endpoint.
- Locale hints preserve Chinese regional identifiers and use the normalized
  base language for other locales.
- Context/keyword fields are sanitized before multipart encoding.
- An export over the configured safety ceiling is subdivided in half, up to
  eight levels, without producing a piece shorter than five seconds; overlap
  is deduplicated when results are stitched.
- Transient HTTP failures use the configured bounded retry policy. Request,
  retry sleep, export, and cleanup all honor operation cancellation.
- A cleanup failure is diagnosed without discarding an otherwise valid
  transcript. An oversized source is rejected before upload when it cannot be
  safely subdivided.

## Failure and privacy contract

Missing keys, malformed/non-JSON success bodies, non-success HTTP responses,
network failures, cancellation, and size violations are typed terminal
outcomes. The controller waits for handle quiescence before allowing a new
operation. It never logs transcript text, prompts, API keys, request bodies,
or audio. If history storage fails after a successful upload, the transcript
is copied to the clipboard and owned audio is preserved in Recovery with a
nonfatal history warning.

## Verification

`OpenAITranscriptionEngineTests` and the deterministic provider-boundary suite
cover JSON/content-type validation, language and keyword normalization,
parallel client isolation, retries, cancellation, chunk subdivision/overlap,
upload progress, safety limits, cleanup diagnostics, and native operation
handles. Network fixtures use per-test identifiers and do not contact OpenAI.
Run the full 100-test unit target serially and in parallel; run the focused
provider/capture suites separately, with Thread Sanitizer where the host
supports it. The release shell harness and syntax checks are independent of
the API tests.

## Deferred contract work and limitations

The app does not automatically fall back from Apple Speech to OpenAI. Real
endpoint validation for extensionless media and regional-Chinese request
semantics is deferred until an endpoint test demonstrates a failure; no
unproven compatibility behavior should be added. OpenAI requires an API key,
network access, and a completed recording, and remains subject to provider
availability, configured retry limits, and the upload ceiling.
