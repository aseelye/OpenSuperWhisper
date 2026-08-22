# OpenAI transcription integration

## Goals
- Add a user-selectable transcription backend (Apple Speech or the OpenAI transcription API).
- Support OpenAI file-upload transcription first; evaluate streaming as a follow-up.
- Keep Apple Speech as the default local, offline-capable backend.

## Milestones
1. **Backend Toggle (completed)**
   - Add an app preference for transcription backend (`appleSpeech` vs `openai`).
   - Surface the choice in Settings with clear copy and prerequisites (API key).
   - Adjust transcription flow to read the new preference.
2. **OpenAI Upload Flow (in progress)**
   - Capture recordings, upload stopped recordings via multipart/form-data to `gpt-transcribe`, and handle responses and errors.
   - Manage API key storage and validation (keychain or user defaults with warnings).
   - Update UI to show remote transcription progress.
3. **Polish**
   - Refine UX, retries, cancellation, chunking, and actionable API/network errors.

## Open Questions
- Where to store the OpenAI API key securely? (Keychain recommended.)
- How to handle rate limits and retries gracefully?
- Apple Speech remains available offline after its language asset is installed; no cloud fallback is automatic.

## Notes
- Implement a small Security.framework-backed helper (service: "OpenSuperWhisper") to manage the OpenAI API key.
- Keep code paths loosely coupled so the Apple and OpenAI providers share the same recording flow.
- Maintain feature parity in tests/UX for both backends.
