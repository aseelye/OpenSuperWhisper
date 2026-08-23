# Codex handoff: current architecture

## Runtime contract

`DictationSessionController` is the single owner of a dictation operation.
Main-window recording, shortcuts, file drops, and imported-file calls reserve
a `SessionOperationToken` and source synchronously on `MainActor`. One context
owns the capture/provider handles, audio URLs, phase/progress, paste intent,
terminal outcome, persistence receipt, and any compensation. Published
snapshots reject updates from stale tokens and expose the cancelling state
until teardown and compensation finish.

Capture is an async, operation-scoped handle. Admission closes before
`stopAndDrain()` or `cancelAndDrain()` drains the writer; callbacks are
ordered, delivered off the audio tap/writer queue, and never occur after the
handle returns. The bounded live channel holds five seconds of audio. Overflow
closes capture, preserves the complete WAV in Recovery, and reports a typed
terminal error.

Providers expose native operation handles. Apple Speech is the live provider:
the Speech analyzer/session streams updates and is teardown-safe on success,
failure, cancellation, and abandoned streams. OpenAI is the file-after-capture
provider: its handle owns export, chunk subdivision, multipart upload, retry
backoff, cancellation, and temporary-file cleanup. The controller selects the
provider through the explicit recording strategy; no runtime caller depends on
the removed synchronous engine/session bridge or a fake live OpenAI path.

The local diagnostic sink records bounded operation identifiers, source,
backend, phase, capture generation, chunk index, and cleanup/compensation
outcomes. It never records transcript text, prompts, keys, request bodies, or
audio.

## History and recovery

`RecordingStore` is injectable and nonfatal. Its status is loading, available,
stale-with-error, or unavailable. Durable insertion returns a commit receipt;
publication failure therefore cannot make a committed row ambiguous.

Saving remains a row-plus-file operation. If history is unavailable after a
successful transcription, the controller copies the transcript to the
clipboard, preserves owned audio in the app's `Application Support/<bundle>/Recovery`
directory, and presents a nonfatal history warning. Cancellation after insert
compensates through the receipt and remains cancelling until that work settles;
failed compensation produces a repair-required warning.

Rows with missing audio retain transcript metadata and offer “Locate Audio…”
or “Remove Entry”. Startup reconciliation only scans app-owned recording,
temporary-capture, and quarantine names. Orphan/incomplete files are moved to
Recovery and surfaced; unknown files are left untouched. Deletion quarantines
audio before the database transaction and restores it if that transaction
fails. The history UI offers recovery-folder access, confirmed removal, and
history retry.

## Preferences and upgrade compatibility

The stable Codable/persisted preference boundary remains intact. Upgrades still
accept the legacy `local` backend value, migrate `whisperLanguage` to the
provider-neutral locale, preserve useful prompt/timestamp settings, and remove
only the enumerated whisper/model keys and exact legacy model directory.
These are user-data migrations, not transitional runtime protocols or
adapters. Keep them through the pre-1.0 line. Removing a migration key or
decoder requires a versioned 1.0 gate: publish the oldest-supported upgrade
matrix, validate an install/upgrade sample, and make that removal an explicit
release decision.

## Validation lanes

The shared `OpenSuperWhisper` scheme runs the 118-test unit target and skips
the template/UI target. The `OpenSuperWhisperUI` shared scheme is a separate,
serialized lane. Ordinary CI runs on the official `macos-26` arm64 image with
Xcode 26.6, asserts macOS/SDK/architecture, resolves from the workspace lock,
builds without launching the app, runs the 100 unit tests, checks shell syntax,
and runs the disposable release harness. CI never depends on a user database,
shared defaults, or real network calls.

The UI lane is workflow-dispatch-only. It validates the shared scheme and uses
ad-hoc signing. Its four tests use the UI launch mode and an isolated HOME, so
they bypass the app's microphone/accessibility gate and do not record or
install Speech assets; the runner may still need macOS
Automation/Accessibility permission for XCUITest itself. This host previously
timed out while enabling automation mode; do not run UI automation as part of
ordinary local verification. Use manual macOS acceptance for real
microphone/device changes, asset downloads, VoiceOver, history repair, and
signed/notarized artifacts.

## Known limitations and handoff notes

Apple Speech requires the selected macOS language asset and remains local.
OpenAI requires a Keychain API key, uploads completed files to `gpt-transcribe`,
and reports network/rate-limit/size errors without automatic cloud fallback.
Extensionless-media and regional-Chinese behavior remain deferred until an
endpoint contract demonstrates a failure. Generated logs and derived data
belong under ignored `build/`; keep Xcode operations serial while diagnosing
and confirm no app/test processes remain before the next invocation.
