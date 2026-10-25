import AppKit

enum CallCamera { static var available = false }
enum CallDevices { static func loopback() -> Int? { nil } }
enum PhoneCalls {
    static var launches = 0
    static func openOBS() async throws -> Bool { launches += 1; return true }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
Task { @MainActor in
    var state = CallSetupState(cameraReady: false, obsInstalled: false, microphoneReady: false, audioDriverInstalled: false)
    var links: [URL] = []; var captures = 0; var pairing = 0; var guides = 0
    let flow = PhoneWindowFlow()
    let content = NSWindow(contentRect: NSRect(x:0,y:0,width:320,height:240),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    content.isReleasedWhenClosed=false;PhoneWindowFlow.present(content)
    let panel = CallSetupWindow(probe: { state }, openURL: { links.append($0) })
    panel.onOpenCamera = { captures += 1 }; panel.onPairPhone = { pairing += 1 }; panel.onQuickStart = { guides += 1 }
    panel.showWindow(nil); try? await Task.sleep(nanoseconds: 250_000_000)
    require(panel.window is NSPanel && flow.windowToResume(in:[content,panel.window!],mirrorAvailable:false) === content,"setup is a utility panel and never replaces the user's Dock destination")
    let views = children(panel.window!.contentView!)
    let labels = views.compactMap { $0 as? NSTextField }, buttons = views.compactMap { $0 as? NSButton }
    @MainActor func click(_ title: String) { buttons.first { $0.title == title }!.performClick(nil) }
    require(labels.filter { $0.stringValue == "○ Not installed" }.count == 2, "missing optional drivers never block the included core")
    require(captures == 0 && links.isEmpty && PhoneCalls.launches == 0, "opening setup is passive")
    click("Get OBS Studio"); require(links.last == SetupLinks.obsDownload, "missing camera opens the official download")
    click("Download BlackHole 2ch ↗"); require(links.last == SetupLinks.blackHoleDownload, "mic uses official vendor download")
    let help = buttons.filter { $0.title == "Setup help ↗" }; help[0].performClick(nil); help[1].performClick(nil)
    require(links.suffix(2) == [SetupLinks.obsHelp, SetupLinks.blackHoleHelp], "help buttons open their corresponding official guides")
    click("Pair Phone…"); click("Quick Start"); require(pairing == 1 && guides == 1, "core setup actions work without call add-ons")
    state.obsInstalled = true; state.audioDriverInstalled = true; click("Refresh Status")
    require(labels.contains { $0.stringValue == "● Enable extension" } && labels.contains { $0.stringValue == "● Restart needed" }, "installed and available are distinct states")
    click("Open OBS for Setup"); try? await Task.sleep(nanoseconds: 100_000_000)
    require(PhoneCalls.launches == 1 && captures == 0, "only an explicit setup action opens OBS without phone capture")
    state.cameraReady = true; state.microphoneReady = true
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
    require(labels.filter { $0.stringValue == "● Ready" }.count == 2, "returning from installation refreshes availability")
    require(labels.contains { $0.stringValue.contains("Keep OBS installed and closed") }, "ready state gives direct-camera instructions")
    for label in labels {
        let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 2000)).height
        require(needed <= label.bounds.height + 1, "setup text fits its frame: \(label.stringValue)")
    }
    if let bitmap = panel.window!.contentView!.bitmapImageRepForCachingDisplay(in: panel.window!.contentView!.bounds) {
        panel.window!.contentView!.cacheDisplay(in: panel.window!.contentView!.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/jh-setup-ready.png"))
    }
    click("Open Phone Camera"); require(captures == 1 && PhoneCalls.launches == 1, "ready camera invokes the preview only after a click")
    print("PASS: missing, installed and ready add-ons; official links; manual capture; refreshed status and unclipped setup text")
    exit(0)
}
app.run()
