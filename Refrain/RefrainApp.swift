import AppKit
import SwiftUI

/// AppKit's own lifecycle: SwiftUI's held ~6 MB at rest for a menu bar item. The windows'
/// contents are SwiftUI, built when one opens and let go when it closes.
@main
enum RefrainApp {
    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate  // a weak reference
        withExtendedLifetime(delegate) { NSApplication.shared.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var item: NSStatusItem!
    private let statusLine = NSMenuItem()
    private let addressLine = NSMenuItem()
    /// The menu's lines kept current while it's open; closed, it costs nothing.
    private var following: Task<Void, Never>?
    private var settings: NSWindow?
    private var welcome: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppModel.shared

        let menu = NSMenu()
        menu.delegate = self
        menu.items = [
            statusLine, addressLine,
            NSMenuItem(String(localized: "Copy Address"), #selector(copyAddress), target: self),
            .separator(),
            NSMenuItem(String(localized: "Settings…"), #selector(showSettings), ",", target: self),
            NSMenuItem(String(localized: "Quit Refrain"), #selector(NSApplication.terminate(_:)), "q"),
        ]
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        Task {
            for await working in Observations({ AppModel.shared.status == .transcribing }) {
                item.button?.image = .refrainGlyph(working: working)
            }
        }

        if !UserDefaults.standard.bool(forKey: "onboarded") { showWelcome() }
    }

    /// Opened again from Finder or Spotlight: the menu bar item may be out of reach (behind
    /// the notch, or hidden), so show Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusLine.title = AppModel.shared.statusText
        addressLine.title = AppModel.shared.address
        following = Task { [statusLine, addressLine] in
            for await (status, address) in Observations({ (AppModel.shared.statusText, AppModel.shared.address) }) {
                statusLine.title = status
                addressLine.title = address
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        following?.cancel()
    }

    @objc private func copyAddress() {
        AppModel.shared.copyAddress()
    }

    /// General and Models as toolbar tabs, each as tall as its content, like Apple's settings.
    @objc private func showSettings() {
        if settings == nil {
            let tabs = SettingsTabs()
            tabs.tabStyle = .toolbar
            tabs.addTabViewItem(.init("general", String(localized: "General"), "gearshape", GeneralSettings(model: .shared)))
            tabs.addTabViewItem(.init("models", String(localized: "Models"), "waveform", ModelSettings(model: .shared)))
            let saved = UserDefaults.standard.string(forKey: "settingsTab")
            tabs.selectedTabViewItemIndex = tabs.tabViewItems.firstIndex { $0.identifier as? String == saved } ?? 0
            settings = window(tabs, style: [.titled, .closable])
            settings?.toolbarStyle = .preference
        }
        show(settings)
    }

    private func showWelcome() {
        welcome = window(NSHostingController(rootView: WelcomeView(model: .shared) { [weak self] in self?.welcome?.close() }),
                         style: [.titled, .closable, .fullSizeContentView])
        welcome?.title = String(localized: "Welcome to Refrain")
        welcome?.titleVisibility = .hidden
        welcome?.titlebarAppearsTransparent = true
        show(welcome)
    }

    private func window(_ content: NSViewController, style: NSWindow.StyleMask) -> NSWindow {
        let window = NSWindow(contentViewController: content)
        window.styleMask = style
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(content.view.fittingSize)  // sized to its content first, or it's centered as a point
        window.center()
        return window
    }

    private func show(_ window: NSWindow?) {
        // With the first window, not at launch: its items load their symbols, ~1 MB held at rest.
        if NSApp.mainMenu == nil { NSApp.mainMenu = Self.keyEquivalents() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Let go once AppKit is done closing it: its SwiftUI goes, saving what it saves on the way out
    /// (a port typed without Return, the welcome seen), and the next open builds it anew.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.makeFirstResponder(nil)  // ends an edit in progress, so the field holds what was typed
        DispatchQueue.main.async { [self] in
            guard !window.isVisible else { return }  // opened again meanwhile
            if settings === window { settings = nil }
            if welcome === window { welcome = nil }
        }
    }

    /// Never shown (an agent app has no menu bar), but where Return-less keys go when a window
    /// is key: editing in the port field, ⌘W, ⌘, and ⌘Q.
    private static func keyEquivalents() -> NSMenu {
        let app = NSMenu()
        app.items = [
            NSMenuItem(String(localized: "Settings…"), #selector(AppDelegate.showSettings), ","),
            NSMenuItem(String(localized: "Quit Refrain"), #selector(NSApplication.terminate(_:)), "q"),
        ]
        let edit = NSMenu()
        edit.items = [
            NSMenuItem("Undo", Selector(("undo:")), "z"),
            NSMenuItem("Redo", Selector(("redo:")), "Z"),
            NSMenuItem("Cut", #selector(NSText.cut(_:)), "x"),
            NSMenuItem("Copy", #selector(NSText.copy(_:)), "c"),
            NSMenuItem("Paste", #selector(NSText.paste(_:)), "v"),
            NSMenuItem("Select All", #selector(NSText.selectAll(_:)), "a"),
            NSMenuItem("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]
        let main = NSMenu()
        for submenu in [app, edit] {
            let holder = NSMenuItem()
            holder.submenu = submenu
            main.addItem(holder)
        }
        return main
    }
}

/// Remembers the tab last shown, as System Settings does.
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        UserDefaults.standard.set(item?.identifier as? String, forKey: "settingsTab")
    }
}

private extension NSTabViewItem {
    convenience init(_ id: String, _ label: String, _ symbol: String, _ view: some View) {
        // A scroll view past 720 points, never taller than the screen.
        let host = NSHostingController(rootView: view.frame(width: 520).frame(maxHeight: 720).fixedSize(horizontal: false, vertical: true))
        host.sizingOptions = .preferredContentSize
        host.title = label  // the window's title while its tab is shown
        self.init(viewController: host)
        identifier = id
        self.label = label
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}

private extension NSMenuItem {
    /// `target` nil sends the action up the responder chain: the key window, then the app.
    convenience init(_ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil) {
        self.init(title: title, action: action, keyEquivalent: key)
        self.target = target
    }
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
