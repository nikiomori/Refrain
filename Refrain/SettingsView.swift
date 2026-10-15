import RefrainKit
import ServiceManagement
import Speech
import SwiftUI

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var port = 0

    var body: some View {
        Form {
            Toggle("Open at Login", isOn: $openAtLogin)
                // Not a switch: on macOS 27 each one shown holds ~265 MB of graphics memory for a second.
                .toggleStyle(.checkbox)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    } catch {
                        log.error("Login item: \(error.localizedDescription, privacy: .public)")
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Section {
                Picker("Menu Bar Icon", selection: $model.menuBarIcon) {
                    Text("Always").tag(AppModel.MenuBarIcon.always)
                    Text("While Transcribing").tag(AppModel.MenuBarIcon.working)
                    Text("Never").tag(AppModel.MenuBarIcon.never)
                }
            } footer: {
                Text("Open Refrain again from Finder or Spotlight to see these settings.")
                    .foregroundStyle(.secondary)
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
struct ModelSettings: View {
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

/// Other services' models, which apps reach through Refrain beside this Mac's own.
struct ServiceSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            ForEach($model.providers) { $provider in
                Section {
                    TextField("Name", text: $provider.name, prompt: Text(verbatim: "groq"))
                    TextField("Address", text: $provider.url, prompt: Text(verbatim: "https://api.groq.com/openai/v1"))
                    KeyField(account: provider.id.uuidString)
                    TextField("Models", text: $provider.models, prompt: Text(verbatim: "whisper-large-v3-turbo"))
                    Button("Remove", role: .destructive) { model.removeProvider(provider) }
                } footer: {
                    let names = provider.remotes.map(\.id)
                    Group {
                        if names.isEmpty {
                            Text("Give it a name, an address and a model.")
                        } else {
                            Text("In apps, set the model to \(names.formatted(.list(type: .or))).")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }

            Section {
                Menu("Add Service") {
                    ForEach(AppModel.Provider.presets, id: \.title) { preset in
                        Button(preset.title) { model.addProvider(preset.provider) }
                    }
                }
                .fixedSize()
            } footer: {
                Text("Apps reach these models through Refrain, with the key kept here, in the Keychain. Their audio goes to the service; auto and any other model name stay on this Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// In the Keychain as it's typed: a paste is one change.
private struct KeyField: View {
    let account: String
    @State private var key = ""

    var body: some View {
        SecureField("Key", text: $key)
            .onAppear { key = Keychain.read(account: account) ?? "" }
            .onChange(of: key) { _, key in
                if key != Keychain.read(account: account) ?? "" { Keychain.write(key, account: account) }
            }
    }
}
