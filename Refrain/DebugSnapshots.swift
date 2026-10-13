#if DEBUG
import ScreenCaptureKit
import SwiftUI

/// A tiny photo studio for the README. `REFRAIN_SNAPSHOTS=<dir>` shows each window and the menu
/// in light and dark mode, captures them with ScreenCaptureKit (real chrome and shadows on a
/// transparent background), and quits. Needs the Screen Recording permission.
enum DebugSnapshots {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["REFRAIN_SNAPSHOTS"] else { return }
        let dir = URL(filePath: path, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            NSApp.windows.filter { $0.styleMask.contains(.titled) }.forEach { $0.close() }  // e.g. Welcome
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                await window("welcome", dir, "welcome-\(suffix)")
                for tab in ["general", "models"] {
                    UserDefaults.standard.set(tab, forKey: "settingsTab")
                    await window("settings", dir, "settings-\(tab)-\(suffix)")
                }
                await menu(dir, "menu-\(suffix)")
            }
            NSApp.terminate(nil)
        }
    }

    private static func window(_ id: String, _ dir: URL, _ name: String) async {
        NotificationCenter.default.post(name: .openRefrainWindow, object: id)
        try? await Task.sleep(for: .seconds(3))  // past the window's opening animation
        let key = id == "settings" ? "Settings" : id  // SwiftUI names windows after their scene ID
        guard let window = NSApp.windows.first(where: { $0.isVisible && ($0.identifier?.rawValue.contains(key) ?? false) }) else {
            return log.error("no window: \(id, privacy: .public)")
        }
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(0.5))
        await capture({ $0.windowID == CGWindowID(window.windowNumber) }, dir, name)
        window.close()
        try? await Task.sleep(for: .seconds(0.5))
    }

    /// The real menu, mid-transcription. `performClick` runs the menu's own event loop on the main
    /// thread until it closes, so the shot is taken off it and the menu closed with an Escape
    /// posted to this process.
    private static func menu(_ dir: URL, _ name: String) async {
        AppModel.shared.debugShow(.transcribing(done: 750, of: 3723))
        guard let button = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(statusButton(in:)) }).first else {
            return log.error("no status item")
        }
        let pid = getpid(), menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let shot = Task.detached {
            try? await Task.sleep(for: .seconds(1))
            await capture({ $0.owningApplication?.processID == pid && $0.windowLayer == menuLevel }, dir, name)
            for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(pid) }
        }
        button.performClick(nil)
        await shot.value
        AppModel.shared.debugShow(.ready)
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        view as? NSStatusBarButton ?? view.subviews.lazy.compactMap(statusButton(in:)).first
    }

    nonisolated private static func capture(_ matching: (SCWindow) -> Bool, _ dir: URL, _ name: String) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return log.error("capture failed: \(name, privacy: .public), no shareable content")
        }
        guard let window = content.windows.first(where: matching) else {
            let ours = content.windows.filter { $0.owningApplication?.processID == getpid() }
                .map { "layer \($0.windowLayer) \($0.frame)" }
            return log.error("capture failed: \(name, privacy: .public), windows: \(ours, privacy: .public)")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        // The system shadow would be squeezed into the window's own size, unevenly for a short
        // window; the window alone is pixel-exact, and the shadow is drawn around it below.
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        config.backgroundColor = .clear
        config.pixelFormat = kCVPixelFormatType_32BGRA
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              let shadowed = withShadow(image) else {
            return log.error("capture failed: \(name, privacy: .public)")
        }
        try? NSBitmapImageRep(cgImage: shadowed).representation(using: .png, properties: [:])?
            .write(to: dir.appending(path: "\(name).png"))
    }

    /// A soft drop shadow on a transparent margin, the same for every shot.
    nonisolated private static func withShadow(_ image: CGImage) -> CGImage? {
        let margin = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width + 2 * margin, height: image.height + 2 * margin,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 44, color: CGColor(gray: 0, alpha: 0.32))
        context.draw(image, in: CGRect(x: margin, y: margin, width: image.width, height: image.height))
        return context.makeImage()
    }
}
#endif
