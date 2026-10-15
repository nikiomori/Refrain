import SwiftUI

/// One screen: what Refrain is, where it listens, and the one download it may need.
/// The button is the consent: nothing is fetched without it.
struct WelcomeView: View {
    let model: AppModel
    /// Closes the window.
    let done: () -> Void
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text("Refrain is your Mac's hearing")
                .font(.largeTitle.bold())
            Text("Apps send it audio through the OpenAI API they already know, and get the words back. It runs on this Mac's Neural Engine: every word stays here.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                HStack {
                    Text(model.address).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Copy", action: model.copyAddress)
                }
                .padding(4)
            } label: {
                Text("Point Reprise, VoiceInk or your scripts here. Any model name, no key.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("English, German, French, Spanish, Japanese, Chinese and two dozen more use Apple's models, which macOS already has or downloads by itself. For Russian, Ukrainian, Polish, Czech and other European languages, Parakeet is far more accurate.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fraction = model.downloading {
                    ProgressView(value: fraction)
                } else if model.parakeetDownloaded {
                    Label("Parakeet is downloaded", systemImage: "checkmark.circle.fill")
                } else {
                    Button("Download Parakeet (630 MB)", action: model.downloadParakeet)
                }
                if let error = model.downloadError {
                    Text(error).foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 520)
        // Closed with Done or the close button alike: shown once, not at every launch.
        .onDisappear { onboarded = true }
    }
}
