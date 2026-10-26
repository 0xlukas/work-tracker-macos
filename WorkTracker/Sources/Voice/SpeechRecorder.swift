import AVFoundation
import Foundation
import Observation
import Speech

/// Live, on-device transcription of the microphone with SpeechAnalyzer.
@MainActor
@Observable
final class SpeechRecorder {
    enum RecorderError: LocalizedError {
        case microphoneDenied
        case languageUnsupported

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return tr("Work Tracker needs microphone access. Allow it in System Settings ▸ Privacy & Security ▸ Microphone.")
            case .languageUnsupported:
                return tr("Speech recognition doesn’t support this language on this Mac.")
            }
        }
    }

    /// Everything heard so far: finalized text plus the current, still changing guess.
    var transcript: String { (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Set while speech assets are downloaded (first use of a language).
    private(set) var isInstallingAssets = false

    private var finalized = ""
    private var volatile = ""
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var input: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var results: Task<Void, Never>?

    /// Start listening. `vocabulary` (project names) helps recognize unusual words.
    func start(locale: Locale, vocabulary: [String]) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.microphoneDenied }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw RecorderError.languageUnsupported
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            isInstallingAssets = true
            defer { isInstallingAssets = false }
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        try await analyzer.setContext(context)

        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let engine = AVAudioEngine()
        try Self.installTap(on: engine, converter: converter, continuation: continuation)
        engine.prepare()
        try engine.start()

        finalized = ""
        volatile = ""
        self.engine = engine
        self.analyzer = analyzer
        self.input = continuation
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self?.finalized += text
                        self?.volatile = ""
                    } else {
                        self?.volatile = text
                    }
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Stop listening and return the final transcript.
    func stop() async -> String {
        stopAudio()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        analyzer = nil
        results = nil
        return transcript
    }

    func cancel() {
        stopAudio()
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        self.analyzer = nil
    }

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        input?.finish()
        input = nil
    }

    /// Nonisolated so the tap block isn't main-actor isolated: it runs on the audio thread.
    /// The converter resamples the microphone's format into the one the analyzer wants.
    private nonisolated static func installTap(on engine: AVAudioEngine, converter: AnalyzerInputConverter,
                                               continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        // Only ever used from the tap, which the engine calls serially.
        nonisolated(unsafe) let converter = converter
        let node = engine.inputNode
        try node.installAudioTap(onBus: 0, bufferSize: 4096, format: node.outputFormat(forBus: 0)) { buffer, time in
            let copy = AVAudioPCMBuffer(copying: buffer)
            for input in (try? converter.convert(copy, at: time)) ?? [] {
                continuation.yield(input)
            }
        }
    }
}
