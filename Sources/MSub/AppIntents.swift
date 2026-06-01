import AppIntents
import Foundation

struct OpenMediaInMSubIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Media in MSub"
    static let description = IntentDescription("Opens a video or audio file in MSub for subtitle transcription.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Media File")
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let sourceURL = file.fileURL else {
            return .result()
        }

        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        if DockMenuState.shared.isReady {
            NotificationCenter.default.post(name: .msubOpenRecentFileRequested, object: sourceURL)
        } else {
            DockMenuState.shared.enqueueOpenURL(sourceURL)
        }
        return .result()
    }
}

struct StartTranscriptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Transcription"
    static let description = IntentDescription("Starts transcription of the files currently loaded in MSub.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .msubTranscribeRequested, object: nil)
        return .result()
    }
}

struct StopTranscriptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Transcription"
    static let description = IntentDescription("Stops the transcription that's currently running in MSub.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .msubStopRequested, object: nil)
        return .result()
    }
}

struct MSubShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMediaInMSubIntent(),
            phrases: [
                "Open file in \(.applicationName)",
                "Transcribe with \(.applicationName)"
            ],
            shortTitle: "Open Media",
            systemImageName: "waveform.badge.mic"
        )
        AppShortcut(
            intent: StartTranscriptionIntent(),
            phrases: [
                "Start transcription in \(.applicationName)",
                "Transcribe in \(.applicationName)"
            ],
            shortTitle: "Start Transcription",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: StopTranscriptionIntent(),
            phrases: [
                "Stop transcription in \(.applicationName)"
            ],
            shortTitle: "Stop Transcription",
            systemImageName: "stop.circle"
        )
    }
}
