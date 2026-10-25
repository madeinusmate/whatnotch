import AppKit
import QuartzCore

final class NotchChromeView: NSView {
    let webView: NSView
    private let wideHalo = CALayer()
    private let tightHalo = CALayer()
    private let depthShadow = CALayer()
    private let pill = NSView()
    private let mark = CALayer()

    var contentAlpha: CGFloat = 0 {
        didSet { webView.alphaValue = contentAlpha }
    }

    var showsMark = false {
        didSet { mark.isHidden = !showsMark }
    }

    /// Transparent margin around the black notch. The top stays flush with the screen.
    var padSide: CGFloat = 0 {
        didSet {
            guard padSide != oldValue else { return }
            needsLayout = true
        }
    }

    var padBottom: CGFloat = 0 {
        didSet {
            guard padBottom != oldValue else { return }
            needsLayout = true
        }
    }

    var halo: CGFloat = 0 {
        didSet {
            let amount = min(1, max(0, halo))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wideHalo.shadowOpacity = Float(amount * 0.1)
            tightHalo.shadowOpacity = Float(amount * 0.9)
            wideHalo.isHidden = amount < 0.01
            tightHalo.isHidden = amount < 0.01
            CATransaction.commit()
        }
    }

    /// Strength of the drop shadow under a fully open shelf. Zero while closed or hovering.
    var depth: CGFloat = 0 {
        didSet {
            let amount = min(1, max(0, depth))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            depthShadow.shadowOpacity = Float(amount * 0.55)
            depthShadow.isHidden = amount < 0.01
            CATransaction.commit()
        }
    }

    init(frame frameRect: NSRect, webView: NSView) {
        self.webView = webView
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        styleHalo(wideHalo, radius: 16)
        styleHalo(tightHalo, radius: 6)
        styleDepth(depthShadow)
        wideHalo.isHidden = true
        tightHalo.isHidden = true
        depthShadow.isHidden = true
        layer?.addSublayer(wideHalo)
        layer?.addSublayer(tightHalo)
        layer?.addSublayer(depthShadow)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.cgColor
        pill.layer?.masksToBounds = true
        pill.layer?.cornerCurve = .continuous
        pill.layer?.maskedCorners = Self.bottomCorners
        mark.backgroundColor = NSColor.white.cgColor
        mark.cornerRadius = 3
        mark.isHidden = true
        pill.layer?.addSublayer(mark)
        addSubview(pill)
        webView.autoresizingMask = [.width, .height]
        pill.addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        layer?.masksToBounds = false
        let side = max(0, padSide)
        let bottom = max(0, padBottom)
        let body = CGRect(
            x: side,
            y: bottom,
            width: max(1, bounds.width - side * 2),
            height: max(1, bounds.height - bottom)
        )
        let radius = cornerRadius(height: body.height)
        pill.frame = body
        webView.frame = pill.bounds
        pill.layer?.cornerRadius = radius
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for halo in [wideHalo, tightHalo, depthShadow] {
            halo.frame = body
            halo.cornerRadius = radius
            halo.contentsScale = scale
        }
        CATransaction.commit()
        mark.frame = CGRect(x: body.width - 16, y: (body.height - 6) / 2, width: 6, height: 6)
        mark.cornerRadius = 3
    }

    /// Closed notch and its hover swell stay a shallow rounded rectangle.
    /// Taller shelf frames keep the larger open corner.
    private func cornerRadius(height: CGFloat) -> CGFloat {
        let notchRadius = min(10, height / 2)
        let shelfRadius = min(28, height / 2)
        let hold: CGFloat = 64
        let settle: CGFloat = 140
        if height <= hold { return notchRadius }
        if height >= settle { return shelfRadius }
        let t = (height - hold) / (settle - hold)
        return notchRadius + (shelfRadius - notchRadius) * t
    }

    private func styleHalo(_ layer: CALayer, radius: CGFloat) {
        layer.backgroundColor = NSColor.black.cgColor
        layer.shadowColor = NSColor.white.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = radius
        layer.shadowOpacity = 0
        layer.cornerCurve = .continuous
        layer.masksToBounds = false
        layer.maskedCorners = Self.bottomCorners
    }

    private func styleDepth(_ layer: CALayer) {
        layer.backgroundColor = NSColor.black.cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: -16)
        layer.shadowRadius = 26
        layer.shadowOpacity = 0
        layer.cornerCurve = .continuous
        layer.masksToBounds = false
        layer.maskedCorners = Self.bottomCorners
    }

    /// The notch hangs from the screen edge, so only the lower corners are rounded.
    private static let bottomCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
}

final class NotchPanel: NSPanel {
    let chrome: NotchChromeView
    let spring = FrameSpring()
    var hoverChanged: ((Bool) -> Void)?
    var escaped: (() -> Void)?
    var onProgress: ((CGFloat, Bool) -> Void)?
    /// The composer, a settings field, or a widget text field is focused.
    /// Command shortcuts are forwarded to the web view; this monitor otherwise
    /// sees them before they can become edit actions.
    var textFieldFocused = false

    private var displayLink: CADisplayLink?
    private var collapsedFrame = CGRect.zero
    private var openFrame = CGRect.zero
    private var openHeight: CGFloat = 148
    /// Requested width of the closed pill while a compact widget is showing.
    /// Nil keeps the hardware notch.
    private var compactWidth: CGFloat?
    private let maxCompactWidth: CGFloat = 320
    private var expanded = false
    private var lastInside = false
    private var openCommitted = false
    private var previewing = false
    private var leaveWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?
    private var tracking: NSTrackingArea?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    // Once the pointer is inside, it can drift this far past the panel before
    // a leave starts, and it has to stay out for `leaveDelay` before the shelf closes.
    // A closed notch swells slightly on hover and only opens after `openDelay`.
    private let leavePadding = CGSize(width: 48, height: 72)
    private let leaveDelay: TimeInterval = 0.6
    private let openDelay: TimeInterval = 0.5
    private let hoverScale: CGFloat = 1.1
    private let haloRoom: CGFloat = 36
    private let shadowSide: CGFloat = 40
    private let shadowDrop: CGFloat = 64

    init(webView: NSView) {
        let chrome = NotchChromeView(frame: .zero, webView: webView)
        self.chrome = chrome
        let screen = NotchScreen.host()
        let collapsed = NotchScreen.collapsedFrame(on: screen)
        super.init(
            contentRect: collapsed,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        contentView = chrome
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        spring.seed(collapsed)
        collapsedFrame = collapsed
        openFrame = NotchScreen.openFrame(on: screen, collapsed: collapsed, height: openHeight)
        setFrame(collapsed, display: false)
        installTracking()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, !isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            makeKey()
        }
        super.sendEvent(event)
    }

    var notchHeight: CGFloat { max(collapsedFrame.height, 32) }

    var openProgress: CGFloat {
        spring.progress(collapsedHeight: collapsedFrame.height, openHeight: openFrame.height)
    }

    func setCompactWidth(_ width: CGFloat?) {
        guard width != compactWidth else { return }
        compactWidth = width
        guard !expanded else {
            ensureLink()
            return
        }
        let target = previewing ? hoverFrame() : restFrame
        spring.retarget(target, reduceMotion: reduceMotion, now: CACurrentMediaTime())
        ensureLink()
    }

    func reveal() {
        leaveWork?.cancel()
        leaveWork = nil
        lastInside = true
        commitOpen()
    }

    /// A compact control was clicked. Leave the pill closed until the pointer exits.
    func holdClosed() {
        guard !expanded, !openCommitted else { return }
        openWork?.cancel()
        openWork = nil
    }

    func present() {
        orderFrontRegardless()
        ensureLink()
    }

    func setExpanded(_ expanded: Bool, height: CGFloat? = nil) {
        if expanded, !self.expanded, lastInside, !openCommitted {
            openWork?.cancel()
            openWork = nil
            openCommitted = true
        }
        if expanded != self.expanded {
            previewing = false
        }
        if let height { openHeight = height }
        self.expanded = expanded
        refreshAnchors()
        let now = CACurrentMediaTime()
        spring.retarget(expanded ? openFrame : restFrame, reduceMotion: reduceMotion, now: now)
        ensureLink()
    }

    func focusForTyping() {
        NSApp.activate(ignoringOtherApps: true)
        makeKey()
    }

    func pointerInside() -> Bool {
        stickyFrame(around: spring.frame).contains(NSEvent.mouseLocation)
    }

    func releaseTyping() {
        resignKey()
        NSApp.deactivate()
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func refreshAnchors() {
        let screen = NotchScreen.host()
        collapsedFrame = NotchScreen.collapsedFrame(on: screen)
        openFrame = NotchScreen.openFrame(on: screen, collapsed: collapsedFrame, height: openHeight)
    }

    private func installTracking() {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        chrome.addTrackingArea(area)
        tracking = area
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.evaluateHover()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.escaped?()
                    return nil
                }
                // Command shortcuts are delivered here before the Edit menu sees
                // them. Perform the edit once, then swallow the event.
                if self.performEditShortcut(event) {
                    return nil
                }
            }
            self.evaluateHover()
            return event
        }
    }

    /// Copy, paste, cut, select all, undo, and redo while a text field is focused.
    /// The event is consumed so the Edit menu does not perform it a second time.
    private func performEditShortcut(_ event: NSEvent) -> Bool {
        guard isKeyWindow, textFieldFocused else { return false }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard flags.contains(.command) else { return false }
        let extra = flags.subtracting(.command)
        guard extra.isSubset(of: .shift),
              let key = event.charactersIgnoringModifiers?.lowercased(),
              key.count == 1 else { return false }
        let selector: Selector
        switch key {
        case "a" where extra.isEmpty:
            selector = #selector(NSText.selectAll(_:))
        case "c" where extra.isEmpty:
            selector = #selector(NSText.copy(_:))
        case "x" where extra.isEmpty:
            selector = #selector(NSText.cut(_:))
        case "v" where extra.isEmpty:
            selector = #selector(NSText.paste(_:))
        case "z" where extra.isEmpty:
            selector = Selector(("undo:"))
        case "z" where extra == .shift:
            selector = Selector(("redo:"))
        default:
            return false
        }
        guard chrome.webView.responds(to: selector) else { return false }
        chrome.webView.perform(selector, with: nil)
        return true
    }

    override func mouseEntered(with event: NSEvent) {
        evaluateHover()
    }

    override func mouseExited(with event: NSEvent) {
        evaluateHover()
    }

    private func evaluateHover() {
        updateClickThrough()
        let mouse = NSEvent.mouseLocation
        let hit = NotchScreen.hitFrame(window: spring.frame, collapsed: collapsedFrame)
        let zone: CGRect
        if openCommitted && lastInside {
            zone = stickyFrame(around: hit)
        } else if previewing {
            zone = hit.union(spring.frame)
        } else {
            zone = hit
        }
        let inside = zone.contains(mouse)
        if inside {
            leaveWork?.cancel()
            leaveWork = nil
            guard !lastInside else { return }
            lastInside = true
            beginOpen()
            return
        }
        guard lastInside, leaveWork == nil else { return }
        if !openCommitted {
            lastInside = false
            cancelOpen()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.leaveWork = nil
            let mouse = NSEvent.mouseLocation
            let hit = NotchScreen.hitFrame(window: self.spring.frame, collapsed: self.collapsedFrame)
            guard !self.stickyFrame(around: hit).contains(mouse) else { return }
            self.lastInside = false
            self.openCommitted = false
            self.hoverChanged?(false)
        }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + leaveDelay, execute: work)
    }

    private func beginOpen() {
        if expanded || spring.height > collapsedFrame.height + 24 {
            commitOpen()
            return
        }
        if !reduceMotion {
            previewing = true
            spring.retarget(hoverFrame(), reduceMotion: false, now: CACurrentMediaTime())
            ensureLink()
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lastInside, !self.openCommitted else { return }
            self.commitOpen()
        }
        openWork?.cancel()
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay, execute: work)
    }

    private func commitOpen() {
        openWork?.cancel()
        openWork = nil
        openCommitted = true
        previewing = false
        hoverChanged?(true)
    }

    private func cancelOpen() {
        openWork?.cancel()
        openWork = nil
        previewing = false
        spring.retarget(restFrame, reduceMotion: reduceMotion, now: CACurrentMediaTime())
        ensureLink()
    }

    /// Drop shadow once the shelf has opened. Closed and hovering stay flat on the menu bar.
    private func depthStrength(open: CGFloat) -> CGFloat {
        let start: CGFloat = 0.82
        let t = min(1, max(0, (open - start) / (1 - start)))
        return t * t * (3 - 2 * t)
    }

    /// Light around the swollen notch, gone once the shelf is actually opening.
    private func haloStrength(height: CGFloat, open: CGFloat) -> CGFloat {
        let grown = collapsedFrame.height * (hoverScale - 1)
        guard grown > 0.5 else { return 0 }
        let swell = min(1, max(0, (height - collapsedFrame.height) / grown))
        let shelf = min(1, max(0, (open - 0.05) / 0.2))
        return swell * (1 - shelf)
    }

    private func padded(_ visual: CGRect, side: CGFloat, bottom: CGFloat) -> CGRect {
        guard side > 0.1 || bottom > 0.1 else { return visual }
        return CGRect(
            x: visual.minX - side,
            y: visual.minY - bottom,
            width: visual.width + side * 2,
            height: visual.height + bottom
        )
    }

    /// The shadow margin is clear, so clicks there fall through to whatever is underneath.
    private func updateClickThrough() {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let padded = chrome.padSide > 0.5 || chrome.padBottom > 0.5
        let gutter = padded && !spring.frame.contains(NSEvent.mouseLocation)
        if ignoresMouseEvents != gutter {
            ignoresMouseEvents = gutter
        }
    }

    private var restFrame: CGRect {
        guard let requested = compactWidth else { return collapsedFrame }
        let collapsed = collapsedFrame
        let width = min(maxCompactWidth, max(collapsed.width, requested))
        var frame = CGRect(
            x: collapsed.midX - width / 2,
            y: collapsed.maxY - collapsed.height,
            width: width,
            height: collapsed.height
        )
        let bounds = NotchScreen.host().frame.insetBy(dx: 8, dy: 0)
        if frame.minX < bounds.minX { frame.origin.x = bounds.minX }
        if frame.maxX > bounds.maxX { frame.origin.x = bounds.maxX - frame.width }
        return frame
    }

    private func hoverFrame() -> CGRect {
        let base = restFrame
        let width = base.width * hoverScale
        let height = base.height * hoverScale
        return CGRect(
            x: base.midX - width / 2,
            y: base.maxY - height,
            width: width,
            height: height
        )
    }

    private func stickyFrame(around hit: CGRect) -> CGRect {
        hit.insetBy(dx: -leavePadding.width, dy: -leavePadding.height)
            .offsetBy(dx: 0, dy: -leavePadding.height / 4)
    }

    @objc private func screenChanged() {
        refreshAnchors()
        let target = expanded ? openFrame : (previewing ? hoverFrame() : restFrame)
        spring.retarget(target, reduceMotion: reduceMotion, now: CACurrentMediaTime())
        ensureLink()
    }

    private func ensureLink() {
        guard displayLink == nil else { return }
        let link = chrome.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let dt = CGFloat(link.targetTimestamp - link.timestamp)
        let now = CACurrentMediaTime()
        let progress = spring.progress(
            collapsedHeight: collapsedFrame.height,
            openHeight: openFrame.height
        )
        let showContent = compactWidth != nil || progress > 0.42
        spring.setOpacityTarget(showContent ? 1 : 0, reduceMotion: reduceMotion, now: now)
        let halo = haloStrength(height: spring.height, open: progress)
        spring.step(dt: dt, reduceMotion: reduceMotion, now: now)
        let shown = spring.progress(
            collapsedHeight: collapsedFrame.height,
            openHeight: openFrame.height
        )
        let depth = depthStrength(open: shown)
        let side = max(haloRoom * halo, shadowSide * depth)
        let bottom = max(haloRoom * halo, shadowDrop * depth)
        chrome.halo = halo
        chrome.depth = depth
        chrome.padSide = side
        chrome.padBottom = bottom
        setFrame(padded(spring.frame, side: side, bottom: bottom), display: true)
        chrome.contentAlpha = spring.opacity
        onProgress?(shown, spring.isSettled)
        chrome.layoutSubtreeIfNeeded()
        updateClickThrough()
        if spring.isSettled {
            link.invalidate()
            displayLink = nil
        }
    }

    func stop() {
        leaveWork?.cancel()
        leaveWork = nil
        openWork?.cancel()
        openWork = nil
        previewing = false
        ignoresMouseEvents = false
        displayLink?.invalidate()
        displayLink = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }
}
