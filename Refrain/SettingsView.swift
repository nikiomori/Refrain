import RefrainKit
import ServiceManagement
import Speech
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    /// Opens where it was left, as System Settings does.
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings(model: model) }
            Tab("Models", systemImage: "waveform", value: "models") { ModelSettings(model: model) }
        }
        .frame(width: 520)
        .frame(maxHeight: 720)  // a scroll view past that, never taller than the screen
        .fixedSize(horizontal: false, vertical: true)  // each tab as tall as its content, like Apple's settings
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var port = 0

    var body: some View {
        Form {
            Toggle("Open at Login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    } catch {
                        log.error("Login item: \(error.localizedDescription, privacy: .public)")
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Section {
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .onSubmit(commit)
                LabeledContent("Address") {
                    HStack {
                        Text(model.address).textSelection(.enabled)
                        Button("Copy", action: model.copyAddress)
                    }
                    .fixedSize()
                    // Otherwise VoiceOver names the button after the row: "Address, button".
                    .accessibilityElement(children: .contain)
                }
                LabeledContent("Status", value: model.statusText)
            } footer: {
                Text("Apps that speak the OpenAI API transcribe here: set this address as the server, any model name, no key. Only this Mac can connect, never a web page.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { port = model.port }
        .onDisappear(perform: commit)  // typed, but the window closed before Return
    }

    /// A port below 1024 needs root; a typo goes back to the port in use rather than stopping the server.
    private func commit() {
        guard (1024...65535).contains(port) else {
            port = model.port
            return
        }
        model.setPort(port)
    }
}

/// Each engine, what it costs on disk and which languages it serves.
private struct ModelSettings: View {
    let model: AppModel
    @State private var appleCodes: Set<String> = []

    var body: some View {
        Form {
            Section {
                LabeledContent("Apple Speech", value: String(localized: "System"))
                Text(names(appleCodes))
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Apple's newer model. Its languages download once, for every app on this Mac.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Parakeet") { ParakeetState(model: model) }
                // Parakeet's languages that Apple's newer model lacks: the ones it's chosen for.
                Text(names(Parakeet.languages.subtracting(appleCodes)))
                    .foregroundStyle(.secondary)
                if let error = model.downloadError {
                    Text(error).foregroundStyle(.red)
                }
            } footer: {
                Text("Runs on the Neural Engine. Far more accurate than Apple's older model in these languages; Russian makes less than half the mistakes. Pretype shares the same copy.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Speakers") { SpeakersState(model: model) }
                if let error = model.speakersError {
                    Text(error).foregroundStyle(.red)
                }
            } footer: {
                Text("Tells voices apart for apps that ask who said what, like Reprise with several people on a call. 22 MB, on the Neural Engine.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Apple Dictation", value: String(localized: "System"))
            } footer: {
                Text("Every other language macOS can dictate.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            // "mul" is a multilingual model, not a language to list.
            appleCodes = Set(await SpeechTranscriber.supportedLocales.compactMap { $0.language.languageCode?.identifier }).subtracting(["mul"])
        }
    }

    private func names(_ codes: Set<String>) -> String {
        codes.compactMap { Locale.current.localizedString(forLanguageCode: $0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .formatted(.list(type: .and))
    }
}

private struct SpeakersState: View {
    let model: AppModel

    var body: some View {
        HStack {
            if model.downloadingSpeakers {
                ProgressView().controlSize(.small)
            } else if model.speakersDownloaded {
                Text("Downloaded")
                Button("Delete", role: .destructive, action: model.deleteSpeakers)
                    .disabled(model.queued > 0)
            } else {
                Text("Not downloaded")
                Button("Download", action: model.downloadSpeakers)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}

private struct ParakeetState: View {
    let model: AppModel

    var body: some View {
        HStack {
            if let fraction = model.downloading {
                ProgressView(value: fraction).frame(width: 120)
                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
            } else if model.parakeetDownloaded {
                Text("Downloaded — \(Parakeet.size.formatted(.byteCount(style: .file)))")
                Button("Delete", role: .destructive, action: model.deleteParakeet)
                    .disabled(model.queued > 0)
            } else {
                Text("Not downloaded")
                Button("Download", action: model.downloadParakeet)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}
