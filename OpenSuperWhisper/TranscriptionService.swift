import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Float = 0.0
    
    private var context: MyWhisperContext?
    private var totalDuration: Float = 0.0
    private var transcriptionTask: Task<String, Error>? = nil
    private var isCancelled = false
    private var abortFlag: UnsafeMutablePointer<Bool>? = nil
    private let openAIClient = OpenAITranscriptionClient()
    private let apiKeyStore = OpenAIAPIKeyStore.shared
    private let openAIChunkMaxDuration: TimeInterval = 6 * 60
    private let openAIChunkMinDuration: TimeInterval = 30
    private let openAIChunkSizeMarginBytes = 512 * 1024
    private let openAIFileSizeLimitBytes = 25 * 1024 * 1024
    
    init() {
        loadModel()
    }
    
    func cancelTranscription() {
        isCancelled = true
        
        // Set the abort flag to true to signal the whisper processing to stop
        if let abortFlag = abortFlag {
            abortFlag.pointee = true
        }
        
        transcriptionTask?.cancel()
        transcriptionTask = nil
        
        // Reset state
        isTranscribing = false
        currentSegment = ""
        progress = 0.0
        isCancelled = false
    }
    
    deinit {
        // Free the abort flag if it exists
        abortFlag?.deallocate()
    }
    
    private func loadModel() {
        print("Loading model")
        if let modelPath = AppPreferences.shared.selectedModelPath {
            isLoading = true

            Task.detached(priority: .userInitiated) { [weak self] in
                let params = WhisperContextParams()
                let newContext = MyWhisperContext.initFromFile(path: modelPath, params: params)
                
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.context = newContext
                    self.isLoading = false
                    print("Model loaded")
                }
            }
        }
    }
    
    func reloadModel(with path: String) {
        print("Reloading model")
        isLoading = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let params = WhisperContextParams()
            let newContext = MyWhisperContext.initFromFile(path: path, params: params)
            
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.context = newContext
                self.isLoading = false
                print("Model reloaded")
            }
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        await MainActor.run {
            self.progress = 0.0
            self.isTranscribing = true
            self.transcribedText = ""
            self.currentSegment = ""
            self.isCancelled = false

            if let abortFlag = self.abortFlag {
                abortFlag.deallocate()
                self.abortFlag = nil
            }
        }

        defer {
            Task { @MainActor in
                self.isTranscribing = false
                self.currentSegment = ""
                if !self.isCancelled {
                    self.progress = 1.0
                }
                self.transcriptionTask = nil
                if let abortFlag = self.abortFlag {
                    abortFlag.deallocate()
                    self.abortFlag = nil
                }
            }
        }

        switch settings.transcriptionBackend {
        case .local:
            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration)
            let durationInSeconds = Float(CMTimeGetSeconds(duration))
            await MainActor.run {
                self.totalDuration = durationInSeconds
            }
            return try await transcribeWithLocal(url: url, settings: settings)
        case .openAI:
            await MainActor.run {
                self.totalDuration = 0.0
            }
            return try await transcribeWithOpenAI(url: url, settings: settings)
        }
    }

    private func transcribeWithLocal(url: URL, settings: Settings) async throws -> String {
        let abortPointer = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        abortPointer.initialize(to: false)

        guard let contextForTask = context else {
            abortPointer.deallocate()
            throw TranscriptionError.contextInitializationFailed
        }

        await MainActor.run {
            self.abortFlag = abortPointer
        }

        let abortFlagForTask = abortPointer

        let task = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            let context = contextForTask

            guard let samples = try await self.convertAudioToPCM(fileURL: url) else {
                throw TranscriptionError.audioConversionFailed
            }

            try Task.checkCancellation()

            let nThreads = 4

            guard context.pcmToMel(samples: samples, nSamples: samples.count, nThreads: nThreads) else {
                throw TranscriptionError.processingFailed
            }

            try Task.checkCancellation()

            guard context.encode(offset: 0, nThreads: nThreads) else {
                throw TranscriptionError.processingFailed
            }

            try Task.checkCancellation()

            var params = WhisperFullParams()

            params.strategy = settings.useBeamSearch ? .beamSearch : .greedy
            params.nThreads = Int32(nThreads)
            params.noTimestamps = !settings.showTimestamps
            params.suppressBlank = settings.suppressBlankAudio
            params.translate = settings.translateToEnglish
            params.language = settings.selectedLanguage != "auto" ? settings.selectedLanguage : nil
            params.detectLanguage = false

            params.temperature = Float(settings.temperature)
            params.noSpeechThold = Float(settings.noSpeechThreshold)
            params.initialPrompt = settings.initialPrompt.isEmpty ? nil : settings.initialPrompt

            typealias GGMLAbortCallback = @convention(c) (UnsafeMutableRawPointer?) -> Bool

            let abortCallback: GGMLAbortCallback = { userData in
                guard let userData = userData else { return false }
                let flag = userData.assumingMemoryBound(to: Bool.self)
                return flag.pointee
            }

            if settings.useBeamSearch {
                params.beamSearchBeamSize = Int32(settings.beamSize)
            }

            params.printRealtime = true
            params.print_realtime = true

            let segmentCallback: @convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Void = { ctx, state, n_new, user_data in
                guard let ctx = ctx,
                      let userData = user_data,
                      let service = Unmanaged<TranscriptionService>.fromOpaque(userData).takeUnretainedValue() as TranscriptionService?
                else { return }

                let segmentInfo = service.processNewSegment(context: ctx, state: state, nNew: Int(n_new))

                Task { @MainActor in
                    if service.isCancelled { return }

                    if !segmentInfo.text.isEmpty {
                        service.currentSegment = segmentInfo.text
                        service.transcribedText += segmentInfo.text + "\n"
                    }

                    if service.totalDuration > 0 && segmentInfo.timestamp > 0 {
                        let newProgress = min(segmentInfo.timestamp / service.totalDuration, 1.0)
                        service.progress = newProgress
                    }
                }
            }

            params.newSegmentCallback = segmentCallback
            params.newSegmentCallbackUserData = Unmanaged.passUnretained(self).toOpaque()

            var cParams = params.toC()
            cParams.abort_callback = abortCallback

            cParams.abort_callback_user_data = UnsafeMutableRawPointer(abortFlagForTask)

            try Task.checkCancellation()

            guard context.full(samples: samples, params: &cParams) else {
                throw TranscriptionError.processingFailed
            }

            try Task.checkCancellation()

            var text = ""
            let nSegments = context.fullNSegments

            for i in 0..<nSegments {
                if i % 5 == 0 {
                    try Task.checkCancellation()
                }

                guard let segmentText = context.fullGetSegmentText(iSegment: i) else { continue }

                if settings.showTimestamps {
                    let t0 = context.fullGetSegmentT0(iSegment: i)
                    let t1 = context.fullGetSegmentT1(iSegment: i)
                    text += String(format: "[%.1f->%.1f] ", Float(t0) / 100.0, Float(t1) / 100.0)
                }
                text += segmentText + "\n"
            }

            let cleanedText = text
                .replacingOccurrences(of: "[MUSIC]", with: "")
                .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var processedText = cleanedText
            if ["zh", "ja", "ko"].contains(settings.selectedLanguage) && settings.useAsianAutocorrect && !cleanedText.isEmpty {
                processedText = AutocorrectWrapper.format(cleanedText)
            }

            let finalText = processedText.isEmpty ? "No speech detected in the audio" : processedText

            await MainActor.run {
                if !self.isCancelled {
                    self.transcribedText = finalText
                    self.progress = 1.0
                }
            }

            return finalText
        }

        await MainActor.run {
            self.transcriptionTask = task
        }

        do {
            return try await task.value
        } catch is CancellationError {
            await MainActor.run {
                self.isCancelled = true
                self.abortFlag?.pointee = true
            }
            throw TranscriptionError.processingFailed
        }
    }

    private func transcribeWithOpenAI(url: URL, settings: Settings) async throws -> String {
        let apiKey: String
        do {
            apiKey = (try apiKeyStore.loadKey() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw TranscriptionError.openAIError("Unable to read API key from Keychain: \(error.localizedDescription)")
        }

        guard !apiKey.isEmpty else {
            throw TranscriptionError.missingAPIKey
        }

        let task = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()

            let asset = AVAsset(url: url)
            let durationValue = try await asset.load(.duration)
            let totalSeconds = CMTimeGetSeconds(durationValue)
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

            await MainActor.run {
                self.currentSegment = "Contacting OpenAI..."
                self.progress = 0.1
            }

            do {
                let rawTranscript: String
                if fileSize > openAIFileSizeLimitBytes || totalSeconds > openAIChunkMaxDuration {
                    rawTranscript = try await self.transcribeWithOpenAIChunks(asset: asset, totalSeconds: totalSeconds, settings: settings, apiKey: apiKey)
                } else {
                    rawTranscript = try await self.transcribeOpenAIFileWithRetries(fileURL: url, settings: settings, apiKey: apiKey)
                }

                try Task.checkCancellation()

                let cleaned = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                var processedText = cleaned
                if ["zh", "ja", "ko"].contains(settings.selectedLanguage) && settings.useAsianAutocorrect && !cleaned.isEmpty {
                    processedText = AutocorrectWrapper.format(cleaned)
                }
                let finalText = processedText.isEmpty ? "No speech detected in the audio" : processedText

                await MainActor.run {
                    if !self.isCancelled {
                        self.transcribedText = finalText
                        self.currentSegment = finalText
                        self.progress = 1.0
                    }
                }

                return finalText
            } catch let error as OpenAITranscriptionClientError {
                throw TranscriptionError.openAIError(error.localizedDescription)
            }
        }

        await MainActor.run {
            self.transcriptionTask = task
        }

        do {
            return try await task.value
        } catch is CancellationError {
            await MainActor.run {
                self.isCancelled = true
            }
            throw TranscriptionError.processingFailed
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.openAIError(error.localizedDescription)
        }
    }


    private func transcribeWithOpenAIChunks(asset: AVAsset, totalSeconds: Double, settings: Settings, apiKey: String) async throws -> String {
        try Task.checkCancellation()

        let targetLimitBytes = max(openAIFileSizeLimitBytes - openAIChunkSizeMarginBytes, openAIChunkSizeMarginBytes)
        let estimatedBitrate: Double
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            if let track = tracks.first {
                let rate = try await track.load(.estimatedDataRate)
                let numericRate = Double(rate)
                estimatedBitrate = numericRate.isFinite && numericRate > 0 ? numericRate : 64000
            } else {
                estimatedBitrate = 64000
            }
        } catch {
            estimatedBitrate = 64000
        }
        let maxSecondsBySize = estimatedBitrate > 0 ? Double(targetLimitBytes * 8) / estimatedBitrate : openAIChunkMaxDuration

        var chunkDuration = min(openAIChunkMaxDuration, maxSecondsBySize)
        if !chunkDuration.isFinite || chunkDuration <= 0 {
            chunkDuration = openAIChunkMaxDuration
        }
        chunkDuration = max(openAIChunkMinDuration, chunkDuration)
        chunkDuration = min(chunkDuration, totalSeconds)

        let totalChunks = max(1, Int(ceil(totalSeconds / chunkDuration)))
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("osw-openai-chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        var transcripts: [String] = []
        var start: Double = 0
        let progressBase: Float = 0.1
        let progressRange: Float = 0.9

        for chunkIndex in 0..<totalChunks {
            try Task.checkCancellation()
            let remaining = totalSeconds - start
            let duration = min(chunkDuration, remaining)
            let chunkURL = tempDirectory.appendingPathComponent("chunk-\(UUID().uuidString).m4a")

            let exportedURL = try await exportAudioChunk(asset: asset, start: start, duration: duration, outputURL: chunkURL, fileLimit: targetLimitBytes)
            defer { try? FileManager.default.removeItem(at: exportedURL) }

            let resourceValues = try exportedURL.resourceValues(forKeys: Set([.fileSizeKey]))
            let chunkFileSize = resourceValues.fileSize ?? 0
            if chunkFileSize > openAIFileSizeLimitBytes {
                throw TranscriptionError.fileTooLarge(limitMB: openAIFileSizeLimitBytes / (1024 * 1024))
            }

            await MainActor.run {
                self.currentSegment = "Transcribing chunk \(chunkIndex + 1) of \(totalChunks)..."
                self.progress = progressBase + (Float(chunkIndex) / Float(totalChunks)) * progressRange
            }

            do {
                let chunkTranscript = try await transcribeOpenAIFileWithRetries(fileURL: exportedURL, settings: settings, apiKey: apiKey)
                transcripts.append(chunkTranscript)
            } catch is CancellationError {
                throw TranscriptionError.processingFailed
            } catch let error as OpenAITranscriptionClientError {
                throw TranscriptionError.openAIError(error.localizedDescription)
            }

            await MainActor.run {
                self.progress = progressBase + (Float(chunkIndex + 1) / Float(totalChunks)) * progressRange
            }
            start += duration
        }

        return transcripts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeOpenAIFileWithRetries(fileURL: URL, settings: Settings, apiKey: String) async throws -> String {
        try await performOpenAIRequestWithRetries(settings: settings) {
            try await self.openAIClient.transcribeAudio(at: fileURL, settings: settings, apiKey: apiKey)
        }
    }

    private func performOpenAIRequestWithRetries<T>(settings: Settings, operation: @escaping () async throws -> T) async throws -> T {
        let maxRetries = max(0, settings.openAIRetryCount)
        var attempt = 0

        while true {
            try Task.checkCancellation()

            do {
                return try await operation()
            } catch {
                guard attempt < maxRetries, shouldRetryOpenAI(error: error) else {
                    throw error
                }

                attempt += 1

                if AppPreferences.shared.debugMode {
                    print("OpenAI transcription retry #\(attempt) due to: \(error.localizedDescription)")
                }

                let delaySeconds = min(pow(2.0, Double(attempt)), 8.0)
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
    }

    private func shouldRetryOpenAI(error: Error) -> Bool {
        if let clientError = error as? OpenAITranscriptionClientError {
            switch clientError {
            case .invalidURL, .decodingFailed:
                return false
            case let .httpError(status, _):
                return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
            case let .network(urlError):
                return shouldRetry(urlError: urlError)
            }
        }

        if let urlError = error as? URLError {
            return shouldRetry(urlError: urlError)
        }

        return false
    }

    private func shouldRetry(urlError: URLError) -> Bool {
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .secureConnectionFailed,
             .cannotLoadFromNetwork,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private func exportAudioChunk(asset: AVAsset, start: Double, duration: Double, outputURL: URL, fileLimit: Int) async throws -> URL {
        guard duration > 0 else {
            throw TranscriptionError.audioConversionFailed
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioConversionFailed
        }

        let assetDuration = try await asset.load(.duration)
        let timescale: CMTimeScale = assetDuration.timescale != 0 ? assetDuration.timescale : 600
        let startTime = CMTime(seconds: start, preferredTimescale: timescale)
        let durationTime = CMTime(seconds: duration, preferredTimescale: timescale)

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.timeRange = CMTimeRange(start: startTime, duration: durationTime)
        exportSession.fileLengthLimit = Int64(fileLimit)

        let exportSessionBox = UncheckedSendableBox(exportSession)
        return try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                let exportSession = exportSessionBox.value
                switch exportSession.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                case .failed:
                    continuation.resume(throwing: exportSession.error ?? TranscriptionError.audioConversionFailed)
                case .cancelled:
                    continuation.resume(throwing: TranscriptionError.processingFailed)
                default:
                    continuation.resume(throwing: TranscriptionError.audioConversionFailed)
                }
            }
        }
    }

    private final class UncheckedSendableBox<T>: @unchecked Sendable {
        let value: T

        init(_ value: T) {
            self.value = value
        }
    }

    // Make this method nonisolated to be callable from any context
    nonisolated func processNewSegment(context: OpaquePointer, state: OpaquePointer?, nNew: Int) -> (text: String, timestamp: Float) {
        let nSegments = Int(whisper_full_n_segments(context))
        let startIdx = max(0, nSegments - nNew)
        
        var newText = ""
        var latestTimestamp: Float = 0
        
        for i in startIdx..<nSegments {
            guard let cString = whisper_full_get_segment_text(context, Int32(i)) else { continue }
            let segmentText = String(cString: cString)
            newText += segmentText + " "
            
            let t1 = Float(whisper_full_get_segment_t1(context, Int32(i))) / 100.0
            latestTimestamp = max(latestTimestamp, t1)
        }
        
        let cleanedText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleanedText, latestTimestamp)
    }
    
    // Make this method nonisolated to be callable from any context
    nonisolated func createContext() -> MyWhisperContext? {
        guard let modelPath = AppPreferences.shared.selectedModelPath else {
            return nil
        }
        
        let params = WhisperContextParams()
        return MyWhisperContext.initFromFile(path: modelPath, params: params)
    }
    
    nonisolated func convertAudioToPCM(fileURL: URL) async throws -> [Float]? {
        return try await Task.detached(priority: .userInitiated) {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16000,
                                       channels: 1,
                                       interleaved: false)!
            
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let converter = AVAudioConverter(from: audioFile.processingFormat, to: format)!
            
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: audioFile.processingFormat)
            
            let lengthInFrames = UInt32(audioFile.length)
            let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(lengthInFrames))
            
            guard let buffer = buffer else { return nil }
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                do {
                    let tempBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(inNumPackets))
                    guard let tempBuffer = tempBuffer else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    try audioFile.read(into: tempBuffer)
                    outStatus.pointee = .haveData
                    return tempBuffer
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }
            
            converter.convert(to: buffer,
                              error: &error,
                              withInputFrom: inputBlock)
            
            if let error = error {
                print("Conversion error: \(error)")
                return nil
            }
            
            guard let channelData = buffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0],
                                             count: Int(buffer.frameLength)))
        }.value
    }
}

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
    case missingAPIKey
    case openAIError(String)
    case fileTooLarge(limitMB: Int)
}

struct OpenAITranscriptionResponse: Decodable {
    let text: String
}

struct OpenAIAPIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
        let type: String?
    }

    let error: APIError
}

enum OpenAITranscriptionClientError: LocalizedError {
    case invalidURL
    case httpError(status: Int, message: String?)
    case decodingFailed
    case network(URLError)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "OpenAI endpoint URL is invalid."
        case let .httpError(status, message):
            if let message = message, !message.isEmpty {
                return "OpenAI API error (status \(status)): \(message)"
            } else {
                return "OpenAI API request failed with status \(status)."
            }
        case .decodingFailed:
            return "Unable to decode OpenAI response."
        case let .network(error):
            return "Network error contacting OpenAI: \(error.localizedDescription)"
        }
    }
}

final class OpenAITranscriptionClient {
    private let session: URLSession
    private let endpoint = "https://api.openai.com/v1/audio/transcriptions"
    private let model = "whisper-1"

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 300
            configuration.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: configuration)
        }
    }

    func transcribeAudio(at fileURL: URL, settings: Settings, apiKey: String) async throws -> String {
        guard let requestURL = URL(string: endpoint) else {
            throw OpenAITranscriptionClientError.invalidURL
        }

        let boundary = UUID().uuidString

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = try buildMultipartBody(
            fileURL: fileURL,
            boundary: boundary,
            settings: settings
        )
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw OpenAITranscriptionClientError.network(urlError)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscriptionClientError.decodingFailed
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message: String?
            if let errorResponse = try? JSONDecoder().decode(OpenAIAPIErrorResponse.self, from: data) {
                message = errorResponse.error.message
            } else {
                message = String(data: data, encoding: .utf8)
            }
            throw OpenAITranscriptionClientError.httpError(status: httpResponse.statusCode, message: message)
        }

        if let textResponse = try? JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data) {
            return textResponse.text
        }

        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }

        throw OpenAITranscriptionClientError.decodingFailed
    }

    private func buildMultipartBody(fileURL: URL, boundary: String, settings: Settings) throws -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            guard let fieldData = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8) else { return }
            body.append(fieldData)
        }

        func appendFileField(name: String, fileURL: URL) throws {
            let fileData = try Data(contentsOf: fileURL)
            let filename = fileURL.lastPathComponent
            let mimeType = mimeTypeForFile(url: fileURL)

            guard let headerData = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8) else { return }
            body.append(headerData)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }

        appendField(name: "model", value: model)

        if settings.translateToEnglish {
            appendField(name: "translate", value: "true")
        }

        if !settings.initialPrompt.isEmpty {
            appendField(name: "prompt", value: settings.initialPrompt)
        }

        appendField(name: "temperature", value: String(settings.temperature))

        if settings.selectedLanguage != "auto" {
            appendField(name: "language", value: settings.selectedLanguage)
        }

        appendField(name: "response_format", value: "json")

        try appendFileField(name: "file", fileURL: fileURL)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }

    private func mimeTypeForFile(url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension),
           let mime = utType.preferredMIMEType {
            return mime
        }
        return "audio/wav"
    }
}
