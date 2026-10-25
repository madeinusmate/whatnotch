import AppKit

enum NotchScreen {
    static let openSize = CGSize(width: 680, height: 220)
    static let fallbackPill = CGSize(width: 180, height: 32)

    static func host() -> NSScreen {
        let screens = NSScreen.screens
        if let builtInNotch = screens.first(where: { isBuiltIn($0) && hasNotch($0) }) {
            return builtInNotch
        }
        if let builtIn = screens.first(where: { isBuiltIn($0) }) {
            return builtIn
        }
        return NSScreen.main ?? screens[0]
    }

    static func collapsedFrame(on screen: NSScreen) -> CGRect {
        if let notch = hardwareNotch(on: screen) {
            return notch
        }
        let size = fallbackPill
        return CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The camera housing. Nil when this display has no notch the system will report.
    static func hardwareNotch(on screen: NSScreen) -> CGRect? {
        guard let notch = notchRect(on: screen), notch.width >= 40, notch.height >= 20 else {
            return nil
        }
        return notch
    }

    static func openFrame(on screen: NSScreen, collapsed: CGRect, height: CGFloat) -> CGRect {
        var frame = CGRect(
            x: collapsed.midX - openSize.width / 2,
            y: collapsed.maxY - height,
            width: openSize.width,
            height: height
        )
        let bounds = screen.frame.insetBy(dx: 8, dy: 8)
        if frame.minX < bounds.minX { frame.origin.x = bounds.minX }
        if frame.maxX > bounds.maxX { frame.origin.x = bounds.maxX - frame.width }
        if frame.height > bounds.height {
            frame.size.height = bounds.height
            frame.origin.y = bounds.minY
        } else if frame.minY < bounds.minY {
            frame.origin.y = bounds.minY
        }
        return frame
    }

    static func hitFrame(window: CGRect, collapsed: CGRect) -> CGRect {
        guard window.height < collapsed.height + 24 else { return window }
        return window.insetBy(dx: 0, dy: -8).offsetBy(dx: 0, dy: -4)
    }

    private static func hasNotch(_ screen: NSScreen) -> Bool {
        hardwareNotch(on: screen) != nil
    }

    private static func notchRect(on screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return nil
        }
        let width = right.minX - left.maxX
        guard width > 1 else { return nil }
        let height = max(left.height, right.height, screen.safeAreaInsets.top)
        guard height > 1 else { return nil }
        return CGRect(x: left.maxX, y: screen.frame.maxY - height, width: width, height: height)
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}
