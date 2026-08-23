import Foundation

enum TranscriptionBackend: String, CaseIterable, Identifiable {
    /// Apple's on-device SpeechAnalyzer/SpeechTranscriber pipeline.
    case appleSpeech
    case openAI

    /// `local` was the value persisted by releases that used whisper.cpp.
    /// Keep accepting it at the boundary so an upgrade never silently falls
    /// back to a cloud provider. New writes always use `appleSpeech`.
    /// Removal gate: retain through pre-1.0 releases; remove only with the
    /// versioned 1.0 upgrade matrix and an explicit release decision.
    init?(rawValue: String) {
        switch rawValue {
        case "local":
            self = .appleSpeech
        case "appleSpeech":
            self = .appleSpeech
        case "openAI":
            self = .openAI
        default:
            return nil
        }
    }
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .appleSpeech:
            return "Apple Speech"
        case .openAI:
            return "OpenAI"
        }
    }
    
    var helpText: String {
        switch self {
        case .appleSpeech:
            return "Private, on-device transcription powered by macOS Speech."
        case .openAI:
            return "Uploads completed recordings to OpenAI. Requires an API key."
        }
    }
}
