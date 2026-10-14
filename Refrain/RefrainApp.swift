import SwiftUI

@main
struct RefrainApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage("onboarded") private var onboarded = false

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: .shared)
        } label: {
            MenuBarIcon(model: .shared)
        }

        Window("Welcome to Refrain", id: "welcome") {
            WelcomeView(model: .shared)
                .onAppear { NSApp.activate() }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(onboarded ? .suppressed : .presented)

        Settings {
            SettingsView(model: .shared)
                .onAppear { NSApp.activate() }
        }
    }
}

private struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(model.statusText)
        Text(model.address)
        Button("Copy Address", action: model.copyAddress)
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Refrain") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Always in the menu bar, so it also opens Settings for AppKit (a second launch from Finder).
private struct MenuBarIcon: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let working = if case .transcribing = model.status { true } else { false }
        Image(nsImage: .refrainGlyph(working: working))
            .onReceive(NotificationCenter.default.publisher(for: .openRefrainSettings)) { _ in
                openSettings()
                NSApp.activate()
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppModel.shared
    }

    /// Opened again from Finder or Spotlight: the menu bar item may be out of reach (behind
    /// the notch, or hidden), so show Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: .openRefrainSettings, object: nil)
        return true
    }
}

extension Notification.Name {
    static let openRefrainSettings = Notification.Name("openRefrainSettings")
}

extension NSColor {
    /// Refrain's one accent. Not red: in Reprise red means "recording".
    static let refrain = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.33, green: 0.78, blue: 0.69, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.56, blue: 0.48, alpha: 1)
    }
}

extension NSImage {
    /// A sound wave: a voice's bars, uneven as speech is. A template the system tints; filled with
    /// the accent while working. The app icon's mark (Resources/AppIcon.icon/Assets/mark.svg) is
    /// these bars at 40×.
    static func refrainGlyph(working: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 16), flipped: true) { _ in
            (working ? NSColor.refrain : .black).setFill()
            for (i, height) in [4, 8.5, 12, 7, 3.5].enumerated() {
                let bar = NSRect(x: 1 + Double(i) * 2.6, y: 8 - height / 2, width: 1.6, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        image.isTemplate = !working
        image.accessibilityDescription = working ? String(localized: "Refrain — transcribing") : "Refrain"
        return image
    }
}
