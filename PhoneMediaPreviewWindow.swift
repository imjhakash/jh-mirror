import AppKit
import QuartzCore

private final class PhonePreviewCanvas: NSView {
    private let picture=NSImageView()
    private var currentImage: NSImage?
    var onStep: ((Int) -> Void)?
    var onClose: (() -> Void)?
    private var scrollTotal: CGFloat=0
    private var lastStep=Date.distantPast
    override init(frame: NSRect) {
        super.init(frame:frame);wantsLayer=true;layer?.backgroundColor=NSColor(calibratedWhite:0.055,alpha:1).cgColor;layer?.masksToBounds=true
        picture.imageScaling = .scaleProportionallyUpOrDown;picture.wantsLayer=true;addSubview(picture)
        setAccessibilityLabel("Photo preview. Use left and right arrow keys or swipe to browse.")
    }
    required init?(coder:NSCoder){fatalError()}
    override var acceptsFirstResponder:Bool {true}
    override func layout(){super.layout();picture.frame=bounds.insetBy(dx:24,dy:20)}
    func display(_ image:NSImage?,direction:Int=0) {
        let old=currentImage;currentImage=image
        picture.layer?.removeAllAnimations();picture.image=image;picture.frame=bounds.insetBy(dx:24,dy:20)
        guard direction != 0, old != nil, image != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {return}
        let slide=CABasicAnimation(keyPath:"transform.translation.x");slide.fromValue=direction>0 ? 34 : -34;slide.toValue=0;slide.duration=0.16;slide.timingFunction=CAMediaTimingFunction(name:.easeOut)
        let fade=CABasicAnimation(keyPath:"opacity");fade.fromValue=0.3;fade.toValue=1;fade.duration=0.16
        picture.layer?.add(slide,forKey:"slide");picture.layer?.add(fade,forKey:"fade")
    }
    override func keyDown(with event:NSEvent) {
        switch event.keyCode {case 123:onStep?(-1);case 124:onStep?(1);case 53,49:onClose?();default:super.keyDown(with:event)}
    }
    override func swipe(with event:NSEvent) { if event.deltaX != 0 {onStep?(event.deltaX>0 ? -1:1)} }
    override func scrollWheel(with event:NSEvent) {
        guard event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY) else {super.scrollWheel(with:event);return}
        if event.phase == .began {scrollTotal=0}
        scrollTotal += event.scrollingDeltaX
        if abs(scrollTotal)>60, -lastStep.timeIntervalSinceNow>0.28, event.momentumPhase.isEmpty {
            onStep?(scrollTotal>0 ? -1:1);scrollTotal=0;lastStep=Date()
        }
        if event.phase == .ended || event.phase == .cancelled {scrollTotal=0}
    }
}

final class PhoneMediaPreviewWindow: NSWindowController,NSWindowDelegate {
    var onFailure: ((Error) -> Void)?
    private let loader:PhonePreviewLoader
    private let connection:PhoneFileConnection
    private let files:[PhoneFile]
    private let thumbnail:(PhoneFile)->NSImage?
    private let onOriginal:(PhoneFile)->Void
    private let canvas=PhonePreviewCanvas(frame:.zero)
    private let previous=NSButton(image:NSImage(systemSymbolName:"chevron.left",accessibilityDescription:"Previous photo")!,target:nil,action:nil)
    private let next=NSButton(image:NSImage(systemSymbolName:"chevron.right",accessibilityDescription:"Next photo")!,target:nil,action:nil)
    private let original=NSButton(title:"Open Original",target:nil,action:nil)
    private let name=NSTextField(labelWithString:"")
    private let counter=NSTextField(labelWithString:"")
    private let status=NSTextField(labelWithString:"")
    private let spinner=NSProgressIndicator()
    private(set) var index:Int
    private var originalBusy=false
    init(files:[PhoneFile],index:Int,connection:PhoneFileConnection,loader:PhonePreviewLoader,
         thumbnail:@escaping (PhoneFile)->NSImage?,onOriginal:@escaping (PhoneFile)->Void) {
        self.files=files;self.index=index;self.connection=connection;self.loader=loader;self.thumbnail=thumbnail;self.onOriginal=onOriginal
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:740),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true;window.appearance=NSAppearance(named:.darkAqua);window.backgroundColor=NSColor(calibratedWhite:0.055,alpha:1);window.contentMinSize=NSSize(width:520,height:400);window.isReleasedWhenClosed=false
        super.init(window:window);window.delegate=self
        let content=NSView(frame:NSRect(x:0,y:0,width:960,height:740));window.contentView=content
        canvas.frame=NSRect(x:0,y:58,width:960,height:642);canvas.autoresizingMask=[.width,.height];content.addSubview(canvas)
        canvas.onStep={ [weak self] in self?.step($0) };canvas.onClose={ [weak self] in self?.close() }
        for (button,x,action) in [(previous,20.0,#selector(goPrevious)),(next,62.0,#selector(goNext))] {
            button.frame=NSRect(x:x,y:14,width:34,height:30);button.bezelStyle = .rounded;button.target=self;button.action=action;content.addSubview(button)
        }
        name.frame=NSRect(x:118,y:27,width:620,height:20);name.autoresizingMask=[.width];name.textColor = .white;name.font = .systemFont(ofSize:12,weight:.medium);name.lineBreakMode = .byTruncatingMiddle;content.addSubview(name)
        status.frame=NSRect(x:118,y:9,width:620,height:17);status.autoresizingMask=[.width];status.textColor=NSColor.white.withAlphaComponent(0.6);status.font = .systemFont(ofSize:10);status.lineBreakMode = .byTruncatingTail;content.addSubview(status)
        counter.frame=NSRect(x:140,y:707,width:680,height:20);counter.autoresizingMask=[.width,.minYMargin];counter.alignment = .center;counter.textColor = .secondaryLabelColor;counter.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium);content.addSubview(counter)
        original.frame=NSRect(x:782,y:16,width:158,height:30);original.autoresizingMask=[.minXMargin];original.bezelStyle = .rounded;original.target=self;original.action=#selector(openOriginal);original.toolTip="Download the verified original for full quality or video playback";content.addSubview(original)
        spinner.frame=NSRect(x:750,y:22,width:16,height:16);spinner.autoresizingMask=[.minXMargin];spinner.style = .spinning;spinner.controlSize = .small;spinner.isDisplayedWhenStopped=false;content.addSubview(spinner)
        window.center()
    }
    required init?(coder:NSCoder){fatalError()}
    func open(){if let window {PhoneWindowFlow.present(window);window.makeFirstResponder(canvas)};showCurrent(direction:0)}
    func reopen(files: [PhoneFile], index: Int, connection: PhoneFileConnection) -> Bool {
        guard self.files == files, self.connection == connection, let window else { return false }
        let wasOpen = window.isVisible || window.isMiniaturized, previousIndex = self.index
        self.index = index
        PhoneWindowFlow.present(window)
        if !wasOpen || previousIndex != index { showCurrent(direction: index - previousIndex) }
        else { window.makeFirstResponder(canvas) }
        return true
    }
    func step(_ direction:Int) {
        let candidate=index+direction
        guard files.indices.contains(candidate) else {return}
        index=candidate;showCurrent(direction:direction)
    }
    @objc private func goPrevious(){step(-1)}
    @objc private func goNext(){step(1)}
    @objc private func openOriginal(){guard !originalBusy else{return};onOriginal(files[index])}
    func setOriginalBusy(_ busy:Bool){originalBusy=busy;original.isEnabled = !busy;original.title=busy ? "Preparing…":files[index].kind == "video" ? "Play Video":"Open Original"}
    private func showCurrent(direction:Int) {
        let selected=index,file=files[index]
        window?.title=file.displayName;name.stringValue=file.displayName;counter.stringValue="\((index+1).formatted()) / \(files.count.formatted())"
        previous.isEnabled=index>0;next.isEnabled=index+1<files.count;setOriginalBusy(originalBusy)
        let ready=loader.cached(file,connection:connection)
        canvas.display(ready ?? thumbnail(file),direction:direction)
        status.stringValue=ready == nil ? "Loading preview…":"← → or swipe to browse"
        if ready == nil {spinner.startAnimation(nil)}
        loader.focus(files,index:index,connection:connection) { [weak self] result in
            guard let self,self.index == selected,self.window?.isVisible == true else{return}
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let frame):if ready == nil {self.canvas.display(frame.image)};self.status.stringValue=file.kind == "video" ? "Video preview · Play Video for playback":"← → or swipe to browse"
            case .failure(let error):self.status.stringValue=error.localizedDescription;self.onFailure?(error)
            }
        }
        window?.makeFirstResponder(canvas)
    }
    func windowWillClose(_ notification:Notification){loader.cancel();spinner.stopAnimation(nil)}
}
