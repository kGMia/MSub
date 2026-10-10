import AVFoundation
import CoreMedia
import Foundation
import Speech

enum AppleSpeechError: LocalizedError {
    case unsupportedLocale
    case modelUnavailable
    case audioFileUnreadable

    var errorDescription: String? {
        let raw = UserDefaults.standard.string(forKey: "huz.uiLanguage") ?? AppLanguage.systemDefault.rawValue
        let language = AppLanguage(rawValue: raw) ?? .systemDefault
        switch self {
        case .unsupportedLocale:
            return Copy.text("error.apple.unsupportedLocale", language: language)
        case .modelUnavailable:
            return Copy.text("error.apple.modelUnavailable", language: language)
        case .audioFileUnreadable:
            return Copy.text("error.apple.audioFileUnreadable", language: language)
        }
    }
}

enum AppleSpeechService {
    /// Transcribes an audio/video file with Apple's on-device SpeechAnalyzer.
    /// - Parameters:
    ///   - url: Local audio file URL (already in a format AVAudioFile can read).
    ///   - locale: Recognition locale; accepts equivalent supported locales only.
    ///   - timeOffset: Added to each cue's start/end (used when the source was clipped).
    ///   - onProgress: Reports progress in `[0, 1]`. Best-effort.
    static func transcribe(
        url: URL,
        locale: Locale,
        timeOffset: Double = 0,
        fastResults: Bool = false,
        etiquetteFilter: Bool = false,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [SubtitleCue] {
        try Task.checkCancellation()
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechError.unsupportedLocale
        }

        var transcriptionOptions: Set<SpeechTranscriber.TranscriptionOption> = []
        if etiquetteFilter { transcriptionOptions.insert(.etiquetteReplacements) }
        var reportingOptions: Set<SpeechTranscriber.ReportingOption> = []
        if fastResults { reportingOptions.insert(.fastResults) }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: transcriptionOptions,
            reportingOptions: reportingOptions,
            attributeOptions: [.audioTimeRange]
        )

        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installationRequest.downloadAndInstall()
        }
        try Task.checkCancellation()

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw AppleSpeechError.audioFileUnreadable
        }

        let totalSeconds: Double = {
            let format = audioFile.processingFormat
            let frames = Double(audioFile.length)
            guard format.sampleRate > 0 else { return 0 }
            return frames / format.sampleRate
        }()

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = ResultCollector()
        let resultsTask = Task {
            for try await result in transcriber.results {
                try Task.checkCancellation()
                await collector.append(
                    result: result,
                    timeOffset: timeOffset,
                    totalSeconds: totalSeconds,
                    onProgress: onProgress
                )
            }
        }

        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
                if let lastSampleTime {
                    try await analyzer.finalizeAndFinish(through: lastSampleTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                try await resultsTask.value
                try Task.checkCancellation()
            } onCancel: {
                resultsTask.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            _ = await resultsTask.result
            throw error
        }
        onProgress(1)
        return await collector.cues()
    }

    private actor ResultCollector {
        private var working: [SubtitleCue] = []

        func append(
            result: SpeechTranscriber.Result,
            timeOffset: Double,
            totalSeconds: Double,
            onProgress: @Sendable (Double) -> Void
        ) {
            let attributed = result.text
            let plain = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { return }

            let range = result.range
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(range.end)
            guard start.isFinite, end.isFinite, end > start else { return }

            let cue = SubtitleCue(
                index: working.count + 1,
                start: max(0, start + timeOffset),
                end: max(start + 0.05, end + timeOffset),
                text: plain,
                confidence: nil,
                speaker: nil
            )
            working.append(cue)

            if totalSeconds > 0 {
                onProgress(min(0.99, end / totalSeconds))
            }
        }

        func cues() -> [SubtitleCue] { working }
    }
}
