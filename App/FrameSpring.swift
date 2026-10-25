import CoreGraphics
import Foundation

/// Critically damped spring. Hover carries no flick, so damping ratio is 1
/// and response is 0.35s. Each axis keeps its own velocity, and a new target
/// continues from the current value.
final class FrameSpring {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0
    var opacity: CGFloat = 0

    private var vx: CGFloat = 0
    private var vy: CGFloat = 0
    private var vw: CGFloat = 0
    private var vh: CGFloat = 0
    private var vOpacity: CGFloat = 0

    private(set) var target = CGRect.zero
    private var targetOpacity: CGFloat = 0
    private var fadeStarted: CFTimeInterval = 0
    private var fadeFrom: CGFloat = 0
    private var fading = false

    let response: CGFloat = 0.35
    let dampingRatio: CGFloat = 1

    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    func seed(_ rect: CGRect) {
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
        target = rect
        vx = 0
        vy = 0
        vw = 0
        vh = 0
        opacity = 0
        targetOpacity = 0
        vOpacity = 0
        fading = false
    }

    func retarget(_ rect: CGRect, reduceMotion: Bool, now: CFTimeInterval) {
        target = rect
        guard reduceMotion else { return }
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
        vx = 0
        vy = 0
        vw = 0
        vh = 0
        _ = now
    }

    func setOpacityTarget(_ value: CGFloat, reduceMotion: Bool, now: CFTimeInterval) {
        guard abs(targetOpacity - value) > 0.001 else { return }
        targetOpacity = value
        if reduceMotion {
            fadeFrom = opacity
            fadeStarted = now
            fading = true
            vOpacity = 0
        }
    }

    func step(dt rawDt: CGFloat, reduceMotion: Bool, now: CFTimeInterval) {
        let dt = min(1.0 / 30.0, max(0.001, rawDt))
        if !reduceMotion {
            let omega = 2 * CGFloat.pi / response
            let stiffness = omega * omega
            let damping = 2 * dampingRatio * sqrt(stiffness)
            integrate(&x, &vx, target.minX, stiffness, damping, dt)
            integrate(&y, &vy, target.minY, stiffness, damping, dt)
            integrate(&width, &vw, target.width, stiffness, damping, dt)
            integrate(&height, &vh, target.height, stiffness, damping, dt)
            integrate(&opacity, &vOpacity, targetOpacity, stiffness, damping, dt)
        } else if fading {
            let elapsed = CGFloat(now - fadeStarted)
            let t = min(1, max(0, elapsed / 0.2))
            opacity = fadeFrom + (targetOpacity - fadeFrom) * t
            if t >= 1 {
                fading = false
                opacity = targetOpacity
            }
        }
        opacity = min(1, max(0, opacity))
        width = max(1, width)
        height = max(1, height)
    }

    var isSettled: Bool {
        let geometry = near(x, target.minX, vx)
            && near(y, target.minY, vy)
            && near(width, target.width, vw)
            && near(height, target.height, vh)
        let faded = abs(opacity - targetOpacity) < 0.01 && abs(vOpacity) < 0.05 && !fading
        return geometry && faded
    }

    func progress(collapsedHeight: CGFloat, openHeight: CGFloat) -> CGFloat {
        let span = openHeight - collapsedHeight
        guard span > 1 else { return 1 }
        return min(1, max(0, (height - collapsedHeight) / span))
    }

    private func near(_ value: CGFloat, _ goal: CGFloat, _ velocity: CGFloat) -> Bool {
        abs(value - goal) < 0.4 && abs(velocity) < 8
    }

    private func integrate(
        _ value: inout CGFloat,
        _ velocity: inout CGFloat,
        _ goal: CGFloat,
        _ stiffness: CGFloat,
        _ damping: CGFloat,
        _ dt: CGFloat
    ) {
        let acceleration = stiffness * (goal - value) - damping * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }
}
