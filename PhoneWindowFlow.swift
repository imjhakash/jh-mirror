import AppKit

/// Reopening the app resumes the user's work; background panels never become destinations.
final class PhoneWindowFlow {
    private weak var recentWindow: NSWindow?
    private var mirrorPreferred = false
    private var mirrorActive = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { [weak self] notification in
                if let window = notification.object as? NSWindow { self?.focused(window) }
            }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func focused(_ window: NSWindow) {
        guard Self.isContentWindow(window) else { return }
        recentWindow = window
        mirrorPreferred = false
    }

    func mirrorFocusChanged(_ active: Bool) {
        if active && !mirrorActive { mirrorPreferred = true }
        mirrorActive = active
    }

    func windowToResume(in windows: [NSWindow], mirrorAvailable: Bool) -> NSWindow? {
        if mirrorPreferred && mirrorAvailable { return nil }
        if let recentWindow, Self.isAvailable(recentWindow) { return recentWindow }
        return windows.first { Self.isContentWindow($0) && $0.isVisible && !$0.isMiniaturized }
            ?? windows.first { Self.isContentWindow($0) && $0.isMiniaturized }
    }

    private static func isContentWindow(_ window: NSWindow) -> Bool {
        // AppKit reports canBecomeMain=false while a normal window is minimized.
        !(window is NSPanel) && (window.canBecomeMain || window.isMiniaturized) && window.sheetParent == nil
    }
    private static func isAvailable(_ window: NSWindow) -> Bool {
        isContentWindow(window) && (window.isVisible || window.isMiniaturized)
    }

    static func present(_ window: NSWindow) {
        // App activation may otherwise raise its previous main window above the requested one.
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if let sheet = window.attachedSheet { sheet.makeKeyAndOrderFront(nil) }
    }
}
