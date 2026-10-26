import SwiftUI
import SwiftData

/// Popover for a spoken command: listens, shows the live transcript, and hands the
/// understood command to `onCommand`. Stays open with a message when it didn't work.
struct VoiceCommandPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Project> { !$0.isArchived }, sort: \Project.name) private var projects: [Project]
    @State private var recorder = SpeechRecorder()
    @State private var phase: Phase = .starting

    let onCommand: (VoiceCommand) -> Void

    enum Phase: Equatable {
        case starting
        case listening
        case understanding
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text(recorder.transcript.isEmpty ? placeholder : recorder.transcript)
                .font(.body)
                .foregroundStyle(recorder.transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .textSelection(.enabled)

            if case .failed(let message) = phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(tr("Cancel")) { close() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if case .failed = phase {
                    Button(tr("Try Again")) { Task { await listen() } }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(tr("Done")) { Task { await finish() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                        .disabled(phase != .listening)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .task { await listen() }
        .onDisappear { recorder.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            switch phase {
            case .starting:
                ProgressView().controlSize(.small)
                Text(recorder.isInstallingAssets ? tr("Downloading speech recognition…") : tr("Starting…"))
            case .listening:
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .foregroundStyle(.red)
                Text(tr("Listening…"))
            case .understanding:
                ProgressView().controlSize(.small)
                Text(tr("Understanding…"))
            case .failed:
                Image(systemName: "mic.slash")
                Text(tr("Voice Entry"))
            }
        }
        .font(.headline)
    }

    private var placeholder: String {
        tr("Say “Starting work on %@”, “Stopping work” or “Yesterday 8 to 12 on %@”.",
           projects.first?.name ?? "Alpha", projects.first?.name ?? "Alpha")
    }

    private func listen() async {
        if let reason = VoiceCommandParser.unavailableReason {
            phase = .failed(reason)
            return
        }
        guard !projects.isEmpty else {
            phase = .failed(tr("Add a project first."))
            return
        }
        phase = .starting
        do {
            try await recorder.start(locale: Localization.locale, vocabulary: projects.map(\.name))
            phase = .listening
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func finish() async {
        phase = .understanding
        let transcript = await recorder.stop()
        guard !transcript.isEmpty else {
            phase = .failed(tr("Didn’t hear anything."))
            return
        }
        do {
            let spoken = try await VoiceCommandParser(projects: projects.map(\.name)).parse(transcript)
            let command = VoiceCommand(spoken, transcript: transcript, now: Date()) { EntryActions.nextStart(on: $0, in: modelContext) }
            guard command != .notUnderstood else {
                phase = .failed(tr("Couldn’t tell what to do. Mention a project and times, or say start or stop."))
                return
            }
            onCommand(command)
            close()
        } catch {
            phase = .failed(tr("Apple Intelligence couldn’t process that. Try again."))
        }
    }

    private func close() {
        recorder.cancel()
        dismiss()
    }
}
