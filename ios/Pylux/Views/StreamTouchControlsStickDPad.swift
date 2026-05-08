// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Analog sticks + D-pad (Android AnalogStickView, DPadView).

import OSLog
import UIKit

#if DEBUG
private let pyluxDPadLog = Logger(subsystem: "com.pylux.stream", category: "DPad")
#endif

// MARK: - Vector / touch tracker (AnalogStickView + DPadView)

private struct Vec2 {
    var x: CGFloat
    var y: CGFloat
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    static func * (a: Vec2, b: CGFloat) -> Vec2 { Vec2(x: a.x * b, y: a.y * b) }
    static func / (a: Vec2, b: CGFloat) -> Vec2 { Vec2(x: a.x / b, y: a.y / b) }
    var length: CGFloat { sqrt(x * x + y * y) }
}

private final class TouchPointerTracker {
    var current: Vec2?
    private weak var activeTouch: UITouch?
    var onChange: ((Vec2?) -> Void)?

    func handleTouches(_ touches: Set<UITouch>, in view: UIView, phase: UITouch.Phase) {
        for touch in touches where touch.view === view {
            switch phase {
            case .began:
                if activeTouch == nil {
                    activeTouch = touch
                    let p = touch.location(in: view)
                    current = Vec2(x: p.x, y: p.y)
                    onChange?(current)
                }
            case .moved:
                if touch === activeTouch {
                    let p = touch.location(in: view)
                    current = Vec2(x: p.x, y: p.y)
                    onChange?(current)
                }
            case .ended, .cancelled:
                if touch === activeTouch {
                    activeTouch = nil
                    current = nil
                    onChange?(nil)
                }
            default:
                break
            }
        }
    }

    /// Clears the active pointer without a touch end (e.g. overlay hidden); matches lifting finger on Android.
    func cancelTracking() {
        guard activeTouch != nil else { return }
        activeTouch = nil
        current = nil
        onChange?(nil)
    }
}

// MARK: - Analog stick

final class PyluxAnalogStickView: UIView {
    var radius: CGFloat = 48
    var handleRadius: CGFloat = 32
    var onStick: ((CGFloat, CGFloat) -> Void)?

    private let tracker = TouchPointerTracker()
    private var centerPt: CGPoint?
    private var handleNorm = Vec2(x: 0, y: 0)
    private var stickVec = Vec2(x: 0, y: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        backgroundColor = .clear
        clipsToBounds = false
        tracker.onChange = { [weak self] pos in
            self?.updateState(pos)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateState(_ position: Vec2?) {
        guard radius > 1 else { return }
        if let p = position {
            let c = centerPt ?? CGPoint(x: p.x, y: p.y)
            centerPt = c
            let dir = Vec2(x: p.x - c.x, y: p.y - c.y)
            let len = dir.length
            if len > 1e-4 {
                let strength = min(CGFloat(1), len / radius)
                let nd = Vec2(x: dir.x / len, y: dir.y / len)
                handleNorm = Vec2(x: nd.x * strength, y: nd.y * strength)
                let axv = abs(nd.x)
                let ayv = abs(nd.y)
                let ax: CGFloat
                let ay: CGFloat
                if axv > ayv, axv > 1e-6 {
                    ax = nd.x / axv
                    ay = nd.y / axv
                } else if ayv > 1e-6 {
                    ax = nd.x / ayv
                    ay = nd.y / ayv
                } else {
                    ax = 0
                    ay = 0
                }
                stickVec = Vec2(x: ax * strength, y: ay * strength)
            } else {
                handleNorm = Vec2(x: 0, y: 0)
                stickVec = Vec2(x: 0, y: 0)
            }
        } else {
            centerPt = nil
            handleNorm = Vec2(x: 0, y: 0)
            stickVec = Vec2(x: 0, y: 0)
        }
        onStick?(stickVec.x, stickVec.y)
        setNeedsDisplay()
    }

    func resetInteraction() {
        tracker.cancelTracking()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracker.handleTouches(touches, in: self, phase: .began)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracker.handleTouches(touches, in: self, phase: .moved)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracker.handleTouches(touches, in: self, phase: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracker.handleTouches(touches, in: self, phase: .cancelled)
    }

    /// Outer ring radius; `draw(_:)` is clipped to `bounds`, so the hit rect insets `r` from left/right/bottom — a touch
    /// starting at local y≈0 would draw the base circle up to y=-r unless we reserve top space (see container layout).
    private var drawableOutset: CGFloat { radius + handleRadius }

    /// Shrinks the thumbstick activation area vs the full drawable-padding rect (still inside bounds for drawing).
    private var hitExtraTop: CGFloat { max(10, radius * 0.24) }
    private var hitExtraSide: CGFloat { max(6, radius * 0.14) }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let r = drawableOutset
        let side = hitExtraSide
        let top = hitExtraTop
        guard r > 0, bounds.width > 2 * (r + side), bounds.height > r + top + r else { return super.point(inside: point, with: event) }
        let inner = CGRect(
            x: r + side,
            y: r + top,
            width: max(0, bounds.width - 2 * (r + side)),
            height: max(0, bounds.height - (r + top) - r)
        )
        return inner.contains(point)
    }

    override func draw(_ rect: CGRect) {
        // Android `AnalogStickView.onDraw`: draws only while `center != null` (active touch).
        guard let ctx = UIGraphicsGetCurrentContext(), let c = centerPt else { return }
        let R = radius + handleRadius
        let base = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)
        ctx.setFillColor(StreamControlTheme.fillIdle.cgColor)
        ctx.fillEllipse(in: base)
        let hx = c.x + handleNorm.x * radius
        let hy = c.y + handleNorm.y * radius
        let moved = hypot(handleNorm.x, handleNorm.y) > 0.04
        ctx.setFillColor((moved ? StreamControlTheme.fillPressed : StreamControlTheme.fillIdle).cgColor)
        ctx.fillEllipse(in: CGRect(x: hx - handleRadius, y: hy - handleRadius, width: handleRadius * 2, height: handleRadius * 2))
    }
}

// MARK: - D-pad

private enum DPadDir {
    case up, down, left, right, leftUp, rightUp, leftDown, rightDown

    /// Android `DPadView.onDraw`: diagonal uses `control_dpad_left_up`, else `control_dpad_left`, then canvas rotate (CW).
    var isDiagonal: Bool {
        switch self {
        case .leftUp, .rightUp, .leftDown, .rightDown: return true
        default: return false
        }
    }

    /// CG `rotate(by:)` + = CCW. Pairings follow `DPadView.onDraw`; UP/DOWN angles swapped vs literal
    /// Android degrees so the pressed arm matches touch under our translate/scale order.
    var dpadCanvasRotation: CGFloat {
        switch self {
        case .left, .leftUp: return 0
        case .up, .rightUp: return -3 * .pi / 2 // Android 270° CW
        case .right, .rightDown: return -.pi // Android 180° CW
        case .down, .leftDown: return -.pi / 2 // Android 90° CW
        }
    }
}

final class PyluxDPadView: UIView {
    var onDirection: ((UInt32?) -> Void)?
    var hapticOnDirectionChange: (() -> Void)?

    private let tracker = TouchPointerTracker()
    private let deadzone: CGFloat = 0.3
    private var currentMask: UInt32?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        backgroundColor = .clear
        tracker.onChange = { [weak self] pos in
            self?.updateDir(pos)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func dirMask(_ d: DPadDir) -> UInt32 {
        switch d {
        case .up: return UInt32(1 << 6)
        case .down: return UInt32(1 << 7)
        case .left: return UInt32(1 << 4)
        case .right: return UInt32(1 << 5)
        case .leftUp: return UInt32(1 << 4) | UInt32(1 << 6)
        case .rightUp: return UInt32(1 << 5) | UInt32(1 << 6)
        case .leftDown: return UInt32(1 << 4) | UInt32(1 << 7)
        case .rightDown: return UInt32(1 << 5) | UInt32(1 << 7)
        }
    }

    private func direction(for pos: Vec2) -> DPadDir {
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        // Identical to Android `DPadView.directionForPosition` (full view bounds).
        let dir = Vec2(x: (pos.x / w - 0.5) * 2, y: (pos.y / h - 0.5) * 2)
        let angleSection = CGFloat.pi * 2 / 8
        let angle = atan2(dir.x, dir.y) + .pi + angleSection * 0.5
        // Cascading `<` matches Kotlin `when` exactly (including `else -> UP` for angle >= 2π).
        if angle < 1 * angleSection { return .up }
        if angle < 2 * angleSection { return .leftUp }
        if angle < 3 * angleSection { return .left }
        if angle < 4 * angleSection { return .leftDown }
        if angle < 5 * angleSection { return .down }
        if angle < 6 * angleSection { return .rightDown }
        if angle < 7 * angleSection { return .right }
        if angle < 8 * angleSection { return .rightUp }
        return .up
    }

    private func updateDir(_ pos: Vec2?) {
        let newMask: UInt32?
        if let p = pos {
            let w = max(bounds.width, 1)
            let h = max(bounds.height, 1)
            let xf = 2 * (p.x / w - 0.5)
            let yf = 2 * (p.y / h - 0.5)
            let rad = sqrt(xf * xf + yf * yf)
            if rad < deadzone, currentMask != nil {
                newMask = currentMask
            } else {
                newMask = dirMask(direction(for: p))
            }
        } else {
            newMask = nil
        }
        if newMask != currentMask {
            #if DEBUG
            if let p = pos {
                let w = max(bounds.width, 1)
                let h = max(bounds.height, 1)
                let dir = Vec2(x: (p.x / w - 0.5) * 2, y: (p.y / h - 0.5) * 2)
                let angleSection = CGFloat.pi * 2 / 8
                let angle = atan2(dir.x, dir.y) + .pi + angleSection * 0.5
                let name: String
                if let m = newMask, let d = directionFrom(mask: m) {
                    name = "\(d)"
                } else {
                    name = "nil"
                }
                pyluxDPadLog.debug("touch=(\(String(format: "%.1f", p.x)),\(String(format: "%.1f", p.y))) bounds=\(String(format: "%.0f", w))x\(String(format: "%.0f", h)) dir=(\(String(format: "%.2f", dir.x)),\(String(format: "%.2f", dir.y))) angle=\(String(format: "%.3f", angle))rad mask=\(String(describing: newMask)) dir=\(name)")
            }
            #endif
            if newMask != nil { hapticOnDirectionChange?() }
            currentMask = newMask
            onDirection?(newMask)
            setNeedsDisplay()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracker.handleTouches(touches, in: self, phase: .began)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracker.handleTouches(touches, in: self, phase: .moved)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracker.handleTouches(touches, in: self, phase: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracker.handleTouches(touches, in: self, phase: .cancelled)
    }

    /// Reverse `dirMask` for visuals (same as active `currentMask` while touching / deadzone).
    private func directionFrom(mask: UInt32?) -> DPadDir? {
        guard let m = mask, m != 0 else { return nil }
        if m == dirMask(.up) { return .up }
        if m == dirMask(.down) { return .down }
        if m == dirMask(.left) { return .left }
        if m == dirMask(.right) { return .right }
        if m == dirMask(.leftUp) { return .leftUp }
        if m == dirMask(.rightUp) { return .rightUp }
        if m == dirMask(.leftDown) { return .leftDown }
        if m == dirMask(.rightDown) { return .rightDown }
        return nil
    }

    /// Paths from `control_dpad_idle.xml` viewport 135.46667 — order: up, left, right, down arms.
    private static let dpadViewport: CGFloat = 135.46667

    private static func dpadArmPaths() -> [UIBezierPath] {
        func poly(_ pts: [CGPoint]) -> UIBezierPath {
            let b = UIBezierPath()
            guard let first = pts.first else { return b }
            b.move(to: first)
            for pt in pts.dropFirst() { b.addLine(to: pt) }
            b.close()
            return b
        }
        let up = poly([
            CGPoint(x: 45.244, y: 0), CGPoint(x: 45.244, y: 36.263), CGPoint(x: 62.162, y: 53.181),
            CGPoint(x: 73.306, y: 53.181), CGPoint(x: 90.223, y: 36.263), CGPoint(x: 90.223, y: 0)
        ])
        let left = poly([
            CGPoint(x: 0, y: 45.244), CGPoint(x: 0, y: 90.223), CGPoint(x: 36.263, y: 90.223),
            CGPoint(x: 53.181, y: 73.305), CGPoint(x: 53.181, y: 62.162), CGPoint(x: 36.263, y: 45.244)
        ])
        let right = poly([
            CGPoint(x: 99.203, y: 45.244), CGPoint(x: 82.285, y: 62.162), CGPoint(x: 82.285, y: 73.306),
            CGPoint(x: 99.203, y: 90.223), CGPoint(x: 135.467, y: 90.223), CGPoint(x: 135.467, y: 45.244)
        ])
        let down = poly([
            CGPoint(x: 62.162, y: 82.285), CGPoint(x: 45.244, y: 99.203), CGPoint(x: 45.244, y: 135.467),
            CGPoint(x: 90.223, y: 135.467), CGPoint(x: 90.223, y: 99.203), CGPoint(x: 73.305, y: 82.285)
        ])
        return [up, left, right, down]
    }

    override func draw(_ rect: CGRect) {
        // Match Android `DPadView` + vectors `control_dpad_idle` / `_left` / `_left_up` (padding 16dp on 160dp view).
        let pad = min(bounds.width, bounds.height) * (16.0 / 160.0)
        let inset = bounds.insetBy(dx: pad, dy: pad)
        guard inset.width > 1, inset.height > 1, let ctx = UIGraphicsGetCurrentContext() else { return }

        let dir = directionFrom(mask: currentMask)
        let arms = Self.dpadArmPaths()
        let pressed: [Bool]
        if let d = dir {
            pressed = d.isDiagonal ? [true, true, false, false] : [false, true, false, false]
        } else {
            pressed = [false, false, false, false]
        }

        let vb = Self.dpadViewport
        let sc = min(inset.width, inset.height) / vb
        ctx.saveGState()
        ctx.translateBy(x: inset.midX, y: inset.midY)
        if let d = dir {
            ctx.rotate(by: d.dpadCanvasRotation)
        }
        ctx.scaleBy(x: sc, y: sc)
        ctx.translateBy(x: -vb / 2, y: -vb / 2)

        for (i, path) in arms.enumerated() {
            (pressed[i] ? StreamControlTheme.fillPressed : StreamControlTheme.fillIdle).setFill()
            path.fill()
        }
        ctx.restoreGState()
    }
}
