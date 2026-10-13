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

/// Always in the menu bar, so it also opens windows for AppKit (a second launch from Finder).
private struct MenuBarIcon: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let working = if case .transcribing = model.status { true } else { false }
        Image(nsImage: .refrainGlyph(working: working))
            .onReceive(NotificationCenter.default.publisher(for: .openRefrainWindow)) { note in
                let id = note.object as? String ?? "settings"
                id == "settings" ? openSettings() : openWindow(id: id)
                NSApp.activate()
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppModel.shared
        #if DEBUG
        DebugSnapshots.runIfRequested()
        #endif
    }

    /// Opened again from Finder or Spotlight: the menu bar item may be out of reach (behind
    /// the notch, or hidden), so show Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: .openRefrainWindow, object: "settings")
        return true
    }
}

extension Notification.Name {
    /// Object: a window ID, "settings" or "welcome".
    static let openRefrainWindow = Notification.Name("openRefrainWindow")
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
    /// The breath mark  ’  from sheet music, where the singer takes a breath — and, to everyone
    /// else, a quotation mark: speech. A template the system tints; filled with the accent while working.
    static func refrainGlyph(working: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 16), flipped: true) { _ in
            // The app icon's mark (Resources/AppIcon.icon/Assets/mark.svg), in its 1024 grid:
            // 250 × 463 from (382, 281), scaled to 13.5 points tall and centered.
            let scale = 13.5 / 463
            let transform = NSAffineTransform()
            transform.translateX(by: (12 - 250 * scale) / 2 - 382 * scale, yBy: (16 - 463 * scale) / 2 - 281 * scale)
            transform.scale(by: scale)
            transform.concat()
            (working ? NSColor.refrain : .black).setFill()
            NSBezierPath(ovalIn: NSRect(x: 412, y: 281, width: 220, height: 220)).fill()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 632, y: 391))
            tail.curve(to: NSPoint(x: 402, y: 739), controlPoint1: NSPoint(x: 632, y: 551), controlPoint2: NSPoint(x: 552, y: 671))
            tail.curve(to: NSPoint(x: 393, y: 723), controlPoint1: NSPoint(x: 390, y: 744), controlPoint2: NSPoint(x: 382, y: 731))
            tail.curve(to: NSPoint(x: 514, y: 499), controlPoint1: NSPoint(x: 472, y: 671), controlPoint2: NSPoint(x: 507, y: 611))
            tail.line(to: NSPoint(x: 522, y: 391))
            tail.fill()
            return true
        }
        image.isTemplate = !working
        image.accessibilityDescription = working ? String(localized: "Refrain — transcribing") : "Refrain"
        return image
    }
}
