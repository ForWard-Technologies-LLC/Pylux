// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Face / shoulder / utility buttons and face cluster (Android ButtonView, face layout).

import UIKit

// MARK: - Digital button

/// PlayStation face buttons: `control_button_*` vector geometry (filled paths), not SF Symbols.
enum StreamFaceButtonGlyph {
    case cross, circle, triangle, square
}

final class PyluxPadButtonView: UIView {
    let maskBit: UInt32
    var onPressed: ((Bool) -> Void)?
    /// Matches Android `buttonHapticEnabled` / iOS Touch Haptics setting.
    var hapticOnDown: (() -> Void)?
    private(set) var isDown = false {
        didSet {
            guard isDown != oldValue else { return }
            if isDown { hapticOnDown?() }
            onPressed?(isDown)
            setNeedsDisplay()
        }
    }

    var label: String = ""
    /// Share / options / PS — SF Symbol when `faceGlyph` is nil. Scales with `min(bounds)`; raise for less empty margin.
    var symbolPointSizeFraction: CGFloat = 0.38
    /// Share / options / etc. — SF Symbol when `faceGlyph` is nil.
    var symbolName: String?
    /// When set, SF Symbol tint alphas instead of `StreamControlTheme.auxiliarySymbolAlpha*` (e.g. subtler PS icon).
    var symbolTintAlphaIdle: CGFloat?
    var symbolTintAlphaPressed: CGFloat?
    /// When set, draws Android-style face control with filled symbol paths (`control_button_*`).
    var faceGlyph: StreamFaceButtonGlyph?
    /// `fragment_controls.xml` face padding → ~48dp disc; center in cell (not `bounds.mid`) so circles do not overlap like oversized disks.
    var faceDiscLayout: (diameter: CGFloat, center: CGPoint)?
    /// Android `control_button_l1` / `r1` vector (`pathData`); fills in `bounds.inset(by: chiakiShoulderPathInsets)` like `ButtonView`.
    var chiakiShoulderPathData: String?
    var chiakiShoulderPathInsets = UIEdgeInsets.zero {
        didSet { setNeedsDisplay() }
    }

    init(maskBit: UInt32) {
        self.maskBit = maskBit
        super.init(frame: .zero)
        isMultipleTouchEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        isDown = true
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        isDown = false
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        isDown = false
    }

    override func draw(_ rect: CGRect) {
        if let g = faceGlyph {
            drawFaceButton(glyph: g)
            return
        }
        if let d = chiakiShoulderPathData {
            let content = bounds.inset(by: chiakiShoulderPathInsets)
            let fill = isDown ? StreamControlTheme.fillPressed : StreamControlTheme.fillIdle
            ChiakiShoulderVector.drawShoulder(d, in: content, fill: fill)
            return
        }
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let cr = min(inset.width, inset.height) * 0.12
        let path = UIBezierPath(roundedRect: inset, cornerRadius: min(cr, 14))
        (isDown ? StreamControlTheme.fillPressed : StreamControlTheme.fillIdle).setFill()
        path.fill()
        let symIdle = symbolTintAlphaIdle ?? StreamControlTheme.auxiliarySymbolAlphaIdle
        let symPressed = symbolTintAlphaPressed ?? StreamControlTheme.auxiliarySymbolAlphaPressed
        if let name = symbolName,
           let img = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: min(bounds.width, bounds.height) * symbolPointSizeFraction, weight: .medium))?.withTintColor(
                UIColor.white.withAlphaComponent(isDown ? symPressed : symIdle),
                renderingMode: .alwaysOriginal
           ) {
            let sz = img.size
            img.draw(in: CGRect(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height))
        } else if !label.isEmpty {
            let labelTint = UIColor.white.withAlphaComponent(isDown ? 0.95 : 0.88)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: min(bounds.width, bounds.height) * 0.32, weight: .bold),
                .foregroundColor: labelTint
            ]
            let s = label as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
        }
    }

    private func drawFaceButton(glyph: StreamFaceButtonGlyph) {
        let discD: CGFloat
        let c: CGPoint
        if let layout = faceDiscLayout {
            discD = layout.diameter
            c = layout.center
        } else {
            let d = min(bounds.width, bounds.height)
            let margin = max(2, d * 0.08)
            discD = max(4, d - 2 * margin)
            c = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        let r = discD / 2
        let disc = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: discD, height: discD))
        (isDown ? StreamControlTheme.fillPressed : StreamControlTheme.fillIdle).setFill()
        disc.fill()

        // Filled shapes from Android `control_button_*.xml` (viewport 135.46666, center 67.733) — not stroked primitives.
        let symbol = UIColor(white: 0.02, alpha: isDown ? 0.5 : 0.58)
        symbol.setFill()
        let vpMid: CGFloat = 67.733
        let scale = (discD * 0.86) / 135.46666
        func vp(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: c.x + (x - vpMid) * scale, y: c.y + (y - vpMid) * scale)
        }

        switch glyph {
        case .cross:
            let pts: [(CGFloat, CGFloat)] = [
                (33.309, 24.328), (67.733, 58.753), (102.158, 24.328), (111.138, 33.309),
                (76.714, 67.733), (111.138, 102.158), (102.158, 111.138), (67.733, 76.714),
                (33.309, 111.138), (24.328, 102.158), (58.753, 67.733), (24.328, 33.309)
            ]
            let p = UIBezierPath()
            p.move(to: vp(pts[0].0, pts[0].1))
            for i in 1 ..< pts.count { p.addLine(to: vp(pts[i].0, pts[i].1)) }
            p.close()
            p.fill()
        case .circle:
            let ro = 52.934 * scale
            let ri = 40.233 * scale
            let outer = UIBezierPath(arcCenter: c, radius: ro, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            let inner = UIBezierPath(arcCenter: c, radius: ri, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            outer.append(inner)
            outer.usesEvenOddFillRule = true
            outer.fill()
        case .triangle:
            let p = UIBezierPath()
            p.move(to: vp(67.732, 9.576))
            p.addLine(to: vp(112.6, 87.287))
            p.addLine(to: vp(118.1, 96.812))
            p.addLine(to: vp(17.367, 96.812))
            p.close()
            p.move(to: vp(67.734, 34.977))
            p.addLine(to: vp(39.365, 84.111))
            p.addLine(to: vp(96.102, 84.111))
            p.close()
            p.usesEvenOddFillRule = true
            p.fill()
        case .square:
            let t = CGAffineTransform(translationX: c.x - vpMid * scale, y: c.y - vpMid * scale).scaledBy(x: scale, y: scale)
            let outerRect = CGRect(x: 25.401, y: 25.401, width: 84.666, height: 84.666).applying(t)
            let innerRect = CGRect(x: 37.277, y: 37.277, width: 60.912, height: 60.912).applying(t)
            let outerCR: CGFloat = 10.5 * scale
            let innerCR: CGFloat = 7.5 * scale
            let p = UIBezierPath(roundedRect: outerRect, cornerRadius: min(outerCR, min(outerRect.width, outerRect.height) / 2 - 0.5))
            p.append(UIBezierPath(roundedRect: innerRect, cornerRadius: min(innerCR, min(innerRect.width, innerRect.height) / 2 - 0.5)))
            p.usesEvenOddFillRule = true
            p.fill()
        }
    }
}
// MARK: - Trigger as full press

final class PyluxTriggerPadView: UIView {
    var onAnalog: ((Bool) -> Void)?
    var hapticOnBegan: (() -> Void)?

    private let titleLabel = UILabel()
    private var pressed = false

    /// Android `control_button_l2` / `r2`; hides `titleLabel` when set.
    var chiakiShoulderPathData: String? {
        didSet {
            titleLabel.isHidden = chiakiShoulderPathData != nil
            setNeedsDisplay()
        }
    }

    var chiakiShoulderPathInsets = UIEdgeInsets.zero {
        didSet { setNeedsDisplay() }
    }

    var titleText: String = "" {
        didSet { titleLabel.text = titleText }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        titleLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        titleLabel.textAlignment = .center
        addSubview(titleLabel)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = bounds.insetBy(dx: 4, dy: 4)
    }

    override func draw(_ rect: CGRect) {
        if let d = chiakiShoulderPathData {
            let content = bounds.inset(by: chiakiShoulderPathInsets)
            let fill = pressed ? StreamControlTheme.fillPressed : StreamControlTheme.fillIdle
            ChiakiShoulderVector.drawShoulder(d, in: content, fill: fill)
            return
        }
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let p = UIBezierPath(roundedRect: inset, cornerRadius: 8)
        (pressed ? StreamControlTheme.fillPressed : StreamControlTheme.fillIdle).setFill()
        p.fill()
        UIColor.white.withAlphaComponent(0.2).setStroke()
        p.lineWidth = 1
        p.stroke()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        pressed = true
        setNeedsDisplay()
        hapticOnBegan?()
        onAnalog?(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        pressed = false
        setNeedsDisplay()
        onAnalog?(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        pressed = false
        setNeedsDisplay()
        onAnalog?(false)
    }
}
// MARK: - Face cluster (cross / moon / pyramid / box)

final class PyluxFaceClusterView: UIView {
    let cross: PyluxPadButtonView
    let moon: PyluxPadButtonView
    let pyramid = PyluxPadButtonView(maskBit: UInt32(1 << 3))
    let box = PyluxPadButtonView(maskBit: UInt32(1 << 2))

    init(swapCrossMoon: Bool) {
        let crossBit: UInt32 = swapCrossMoon ? UInt32(1 << 1) : UInt32(1 << 0)
        let moonBit: UInt32 = swapCrossMoon ? UInt32(1 << 0) : UInt32(1 << 1)
        cross = PyluxPadButtonView(maskBit: crossBit)
        moon = PyluxPadButtonView(maskBit: moonBit)
        super.init(frame: .zero)
        cross.faceGlyph = .cross
        moon.faceGlyph = .circle
        pyramid.faceGlyph = .triangle
        box.faceGlyph = .square
        [box, pyramid, moon, cross].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let h = bounds.height
        let hw = w / 2
        let hh = h / 2
        pyramid.frame = CGRect(x: 0, y: 0, width: w, height: hh)
        cross.frame = CGRect(x: 0, y: hh, width: w, height: hh)
        moon.frame = CGRect(x: hw, y: 0, width: hw, height: h)
        box.frame = CGRect(x: 0, y: 0, width: hw, height: h)

        // Android `dimens` + `fragment_controls` face paddings: drawable ~48×48dp inside 176dp square layout
        // (64+64 horizontal on full-width half, 16+24+48 vertical on half-height rows, etc.).
        let disc = w * (48.0 / 176.0)
        let f40: CGFloat = 40.0 / 88.0
        let f48: CGFloat = 48.0 / 88.0
        pyramid.faceDiscLayout = (disc, CGPoint(x: w / 2, y: f40 * hh))
        cross.faceDiscLayout = (disc, CGPoint(x: w / 2, y: f48 * hh))
        box.faceDiscLayout = (disc, CGPoint(x: f40 * hw, y: h / 2))
        moon.faceDiscLayout = (disc, CGPoint(x: f48 * hw, y: h / 2))
    }

    /// Matches Android `ButtonView.bestFittingTouchView`: among overlapping siblings, the one whose center is closest to the touch wins.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }

        let buttons: [PyluxPadButtonView] = [box, pyramid, moon, cross]
        var best: PyluxPadButtonView?
        var bestDistSq: CGFloat = .greatestFiniteMagnitude

        for b in buttons {
            guard !b.isHidden, b.alpha > 0.01, b.isUserInteractionEnabled else { continue }
            let local = convert(point, to: b)
            guard b.bounds.contains(local) else { continue }
            let dx = local.x - b.bounds.midX
            let dy = local.y - b.bounds.midY
            let dSq = dx * dx + dy * dy
            if dSq < bestDistSq {
                bestDistSq = dSq
                best = b
            }
        }

        guard let winner = best else { return nil }
        let q = convert(point, to: winner)
        return winner.hitTest(q, with: event) ?? winner
    }
}
