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

        DockMenuState.shared.submitAutomationCommands([.open(sourceURL)])
        return .result()
    }
}

struct StartTranscriptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Transcription"
    static let description = IntentDescription("Starts transcription of the files currently loaded in MSub.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DockMenuState.shared.submitAutomationCommands([.transcribe])
        return .result()
    }
}

struct StopTranscriptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Transcription"
    static let description = IntentDescription("Stops the transcription that's currently running in MSub.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        DockMenuState.shared.submitAutomationCommands([.stop])
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
