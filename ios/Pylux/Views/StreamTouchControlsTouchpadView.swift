// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// DualSense touchpad region (Android TouchpadView).

import UIKit

// MARK: - Touchpad (TouchpadView.kt)

final class PyluxTouchpadView: UIView {
    private static let tpW: CGFloat = 1920
    private static let tpH: CGFloat = 942
    private static let maxMovePts: CGFloat = 32
    private static let shortPressMs: TimeInterval = 0.2
    private static let holdDelayMs: TimeInterval = 0.5

    private var padState = ChiakiControllerState()
    private final class TouchRec {
        let stateId: UInt8
        let start: CGPoint
        var maxDist: CGFloat = 0
        var lifted = false
        var holdWork: DispatchWorkItem?
        init(stateId: UInt8, start: CGPoint) {
            self.stateId = stateId
            self.start = start
        }
        var moveInsignificant: Bool { maxDist < PyluxTouchpadView.maxMovePts }
    }

    private var byPointer: [ObjectIdentifier: TouchRec] = [:]
    private var buttonHeld = false
    private var shortLiftWork: DispatchWorkItem?
    private var shortIds: [UInt8] = []

    var onChange: (() -> Void)?
    var hapticLight: (() -> Void)?
    var hapticMedium: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        layer.cornerRadius = 0
        isOpaque = false
        chiaki_controller_state_set_idle(&padState)
    }

    required init?(coder: NSCoder) { fatalError() }

    func exportState() -> ChiakiControllerState { padState }

    func resetState() {
        shortLiftWork?.cancel()
        byPointer.values.forEach { $0.holdWork?.cancel() }
        byPointer.removeAll()
        buttonHeld = false
        shortIds.removeAll()
        chiaki_controller_state_set_idle(&padState)
        onChange?()
        setNeedsDisplay()
    }

    private func touchX(_ x: CGFloat) -> UInt16 {
        let w = max(bounds.width, 1)
        guard x.isFinite, w.isFinite else { return 0 }
        let xf = min(max(x, 0), w)
        let r = Self.tpW * xf / w
        let bounded = min(max(r, 0), Self.tpW - 1)
        return UInt16(clamping: Int(bounded.rounded(.towardZero)))
    }

    private func touchY(_ y: CGFloat) -> UInt16 {
        let h = max(bounds.height, 1)
        guard y.isFinite, h.isFinite else { return 0 }
        let yf = min(max(y, 0), h)
        let r = Self.tpH * yf / h
        let bounded = min(max(r, 0), Self.tpH - 1)
        return UInt16(clamping: Int(bounded.rounded(.towardZero)))
    }

    private func triggerShortPress(_ id: UInt8) {
        shortIds.append(id)
        shortLiftWork?.cancel()
        padState.buttons |= UInt32(1 << 14)
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.padState.buttons &= ~UInt32(1 << 14)
            for sid in self.shortIds {
                chiaki_controller_state_stop_touch(&self.padState, sid)
            }
            self.shortIds.removeAll()
            self.onChange?()
            self.setNeedsDisplay()
        }
        shortLiftWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shortPressMs, execute: w)
        onChange?()
        setNeedsDisplay()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.view === self {
            let key = ObjectIdentifier(touch)
            let loc = touch.location(in: self)
            let ix = touchX(loc.x)
            let iy = touchY(loc.y)
            let sid8 = chiaki_controller_state_start_touch(&padState, ix, iy)
            if sid8 < 0 { continue }
            let sid = UInt8(bitPattern: sid8)
            hapticLight?()
            let rec = TouchRec(stateId: sid, start: loc)
            if !buttonHeld {
                let hold = DispatchWorkItem { [weak self, weak rec] in
                    guard let self = self, let rec = rec, rec.moveInsignificant, !self.buttonHeld else { return }
                    self.buttonHeld = true
                    self.hapticMedium?()
                    self.padState.buttons |= UInt32(1 << 14)
                    self.onChange?()
                    self.setNeedsDisplay()
                }
                rec.holdWork = hold
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelayMs, execute: hold)
            }
            byPointer[key] = rec
            onChange?()
            setNeedsDisplay()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var changed = false
        for touch in touches where touch.view === self {
            let key = ObjectIdentifier(touch)
            guard let rec = byPointer[key] else { continue }
            let loc = touch.location(in: self)
            let d = hypot(loc.x - rec.start.x, loc.y - rec.start.y)
            rec.maxDist = max(rec.maxDist, d)
            chiaki_controller_state_set_touch_pos(&padState, rec.stateId, touchX(loc.x), touchY(loc.y))
            changed = true
        }
        if changed {
            onChange?()
            setNeedsDisplay()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.view === self {
            let key = ObjectIdentifier(touch)
            guard let rec = byPointer.removeValue(forKey: key) else { continue }
            rec.holdWork?.cancel()
            if buttonHeld {
                buttonHeld = false
                padState.buttons &= ~UInt32(1 << 14)
                chiaki_controller_state_stop_touch(&padState, rec.stateId)
            } else if rec.moveInsignificant {
                triggerShortPress(rec.stateId)
            } else {
                chiaki_controller_state_stop_touch(&padState, rec.stateId)
            }
            onChange?()
            setNeedsDisplay()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    override func draw(_ rect: CGRect) {
        // Android `TouchpadView.onDraw`: no drawable unless `pointerTouches` has an active finger (idle = invisible).
        let buttonOn = (padState.buttons & UInt32(1 << 14)) != 0
        let touching = !byPointer.isEmpty
        guard touching, let ctx = UIGraphicsGetCurrentContext() else { return }
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let cr = min(StreamControlTheme.touchpadCornerRadius(forWidth: bounds.width), inset.height * 0.5)
        let path = UIBezierPath(roundedRect: inset, cornerRadius: cr)
        let fill = buttonOn ? StreamControlTheme.fillPressed : StreamControlTheme.fillIdle
        ctx.setFillColor(fill.cgColor)
        path.fill()
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(buttonOn ? 0.4 : 0.28).cgColor)
        ctx.setLineWidth(buttonOn ? 2 : 1.5)
        path.stroke()
    }
}
