import AppKit

let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let health = DeviceHealth(); health.usePhone("generated")
health.update(PhoneDeviceInfo(model: "Generated Galaxy A10", android: "10", sdk: 29, hasCamera: true, hasMicrophone: true, notificationAccess: true, notificationEnabled: true, touchGuard: false))
health.connectionState(true); health.adbConnected = true
let panel = DeviceHealthWindow(); var checked = false; var selected: DeviceFeature?
panel.onCheck = { checked = true }; panel.onDetails = { selected = $0 }
func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
Task { @MainActor in
    panel.render(health); panel.open(); try? await Task.sleep(nanoseconds: 300_000_000)
    panel.window!.contentView!.layoutSubtreeIfNeeded()
    let views = children(panel.window!.contentView!), labels = views.compactMap { $0 as? NSTextField }
    require(labels.filter { $0.stringValue == "● Unsupported" }.count == 4, "A10 Android 10 displays four unsupported features")
    require(labels.contains { $0.stringValue.contains("requires Android 12") }, "camera requirement is explained in the list")
    let buttons = views.compactMap { $0 as? NSButton }
    require(buttons.filter { $0.title == "Details" }.count == 9, "every feature has a details action")
    buttons.filter { $0.title == "Details" }[3].performClick(nil); require(selected == .camera, "camera details use the correct feature")
    buttons.first { $0.title == "Check again" }!.performClick(nil); require(checked, "manual check action is connected")
    let scroll = views.compactMap { $0 as? NSScrollView }.first!
    require(scroll.documentView!.frame.height >= 800 && scroll.documentView!.visibleRect.minY == 0, "checklist scrolls and starts at the first feature")
    panel.window!.setContentSize(NSSize(width: 570, height: 480)); panel.window!.contentView!.layoutSubtreeIfNeeded()
    require(scroll.documentView!.frame.width <= 540, "checklist fits the minimum window width")
    if let bitmap = panel.window!.contentView!.bitmapImageRepForCachingDisplay(in: panel.window!.contentView!.bounds) {
        panel.window!.contentView!.cacheDisplay(in: panel.window!.contentView!.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/jh-device-check.png"))
    }
    panel.close(); print("PASS: nine feature rows, old-phone signals, actionable details, refresh and responsive checklist layout"); exit(0)
}
app.run()
