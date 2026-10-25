import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let flow = PhoneWindowFlow()
func require(_ condition: @autoclosure () -> Bool, _ text: String) {
    guard condition() else { fatalError(text) }
}
func makeWindow(_ title: String) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 260),
        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = title; window.isReleasedWhenClosed = false
    return window
}
let dashboard = makeWindow("Generated dashboard")
let gallery = makeWindow("Generated gallery")
let preview = makeWindow("Generated preview")
let tools = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
func pause() async { try? await Task.sleep(nanoseconds: 150_000_000) }

Task { @MainActor in
    require(flow.windowToResume(in: [dashboard], mirrorAvailable: false) == nil, "A never-opened dashboard must stay hidden")
    PhoneWindowFlow.present(gallery); await pause()
    require(gallery.isKeyWindow && !dashboard.isVisible, "A gallery action presents only the gallery")
    require(flow.windowToResume(in: [dashboard, gallery], mirrorAvailable: true) === gallery, "Dock resumes the actual gallery focus")
    PhoneWindowFlow.present(preview); await pause()
    require(flow.windowToResume(in: [gallery, preview], mirrorAvailable: true) === preview, "Preview wins over the underlying gallery")
    tools.orderFrontRegardless(); flow.focused(tools)
    require(flow.windowToResume(in: [tools, gallery, preview], mirrorAvailable: true) === preview, "A tools panel cannot replace the current work")
    flow.mirrorFocusChanged(true)
    require(flow.windowToResume(in: [gallery, preview], mirrorAvailable: true) == nil, "An explicitly focused mirror wins over stale Mac windows")
    PhoneWindowFlow.present(gallery); await pause()
    require(flow.windowToResume(in: [preview, gallery], mirrorAvailable: true) === gallery, "A later gallery focus wins over the mirror")
    flow.mirrorFocusChanged(true)
    require(flow.windowToResume(in: [preview, gallery], mirrorAvailable: true) === gallery, "Repeated geometry reports cannot steal gallery focus")
    preview.orderOut(nil); tools.orderOut(nil)
    gallery.miniaturize(nil); await pause()
    require(flow.windowToResume(in: [preview, gallery], mirrorAvailable: true) === gallery, "Minimized work remains a resume destination")
    PhoneWindowFlow.present(gallery); await pause()
    require(!gallery.isMiniaturized && gallery.isKeyWindow, "Resume restores and focuses a minimized window")
    gallery.close(); preview.close(); tools.orderOut(nil); await pause()
    require(flow.windowToResume(in: [gallery, preview, dashboard, tools], mirrorAvailable: false) == nil, "Closed work and hidden dashboard are never resurrected")
    PhoneWindowFlow.present(dashboard); await pause()
    require(flow.windowToResume(in: [dashboard], mirrorAvailable: false) === dashboard, "An explicitly opened dashboard remains usable")
    dashboard.close()
    print("PASS: gallery/preview focus, mirror focus transitions, minimized resume, hidden dashboard and tools exclusion")
    exit(0)
}
app.run()
