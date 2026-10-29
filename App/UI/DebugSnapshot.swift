#if DEBUG
import AppKit

/// Debug builds only: writes a PNG of the main window for the README, e.g.
///   Krimp.app/Contents/MacOS/Krimp -KrimpSnapshot /tmp/shot.png -KrimpAutoStart YES -KrimpSnapshotDelay 6
/// (`screencapture` needs Screen Recording permission; the app can always draw its own window.)
@MainActor
enum DebugSnapshot {
    static func scheduleIfRequested(model: AppModel) {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "KrimpSnapshot") else { return }
        let delay = defaults.object(forKey: "KrimpSnapshotDelay") as? Double ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let window = NSApp.windows.first(where: \.isVisible) {
                window.setContentSize(NSSize(width: 1180, height: 700))
            }
        }
        if defaults.bool(forKey: "KrimpAutoStart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.start() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    private static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
