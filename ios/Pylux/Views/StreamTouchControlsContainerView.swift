// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Root UIView: wires child controls to `StreamInput` / `ChiakiControllerState` (Android DefaultTouchControlsFragment).

import UIKit

/// Full-screen tap target to bring back auto-hidden PS; in touchpad-only mode, returns `nil` for hits on `passThroughTarget` so the pad still receives touches.
private final class StreamPsRevealTapView: UIView {
    weak var passThroughTarget: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        if let t = passThroughTarget, !t.isHidden, t.alpha > 0.01 {
            let q = convert(point, to: t)
            if t.point(inside: q, with: event) {
                return nil
            }
        }
        return self
    }
}

// MARK: - Container

/// On-screen controls root. Layout mirrors `fragment_controls.xml` / `fragment_touchpad_only.xml`; wiring mirrors `TouchControlsFragment.kt`.
final class StreamTouchControlsContainerView: UIView {
    private weak var streamInput: StreamInput?
    private var mode: StreamTouchControlsMode = .hidden

    /// PS touch-down: show stream chrome (Disconnect) in addition to `CHIAKI_CONTROLLER_BUTTON_PS`.
    var onPSButtonPressed: (() -> Void)?

    // MARK: - Haptics

    private let touchHapticsEnabled: Bool
    private let lightImpact: UIImpactFeedbackGenerator
    private let mediumImpact: UIImpactFeedbackGenerator

    private var controlsState = ChiakiControllerState()

    /// PS-only / touchpad-only: after 5s hide PS; tap outside the touchpad (or anywhere in PS-only) to show PS again.
    private static let psMinimalChromeAutoHideDelay: TimeInterval = 5
    private var psOnlyPsButtonVisible = true
    private var psOnlyHidePsWorkItem: DispatchWorkItem?
    private let psOnlyTapRevealView: StreamPsRevealTapView = {
        let v = StreamPsRevealTapView()
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        v.accessibilityElementsHidden = true
        return v
    }()

    // MARK: - Subviews (add order = back → front)

    private let touchpad = PyluxTouchpadView()
    private let dpad = PyluxDPadView()
    private let leftStick = PyluxAnalogStickView()
    private let rightStick = PyluxAnalogStickView()
    private let face: PyluxFaceClusterView

    private let l1 = PyluxPadButtonView(maskBit: UInt32(1 << 8))
    private let r1 = PyluxPadButtonView(maskBit: UInt32(1 << 9))
    private let l2v = PyluxTriggerPadView()
    private let r2v = PyluxTriggerPadView()
    private let l3 = PyluxPadButtonView(maskBit: UInt32(1 << 10))
    private let r3 = PyluxPadButtonView(maskBit: UInt32(1 << 11))
    private let optionsB = PyluxPadButtonView(maskBit: UInt32(1 << 12))
    private let shareB = PyluxPadButtonView(maskBit: UInt32(1 << 13))
    private let psB = PyluxPadButtonView(maskBit: UInt32(1 << 15))

    /// Z-order: shoulders before sticks so L1/R1 do not paint over L3/R3 when frames overlap; PS centered last among bottom row before sticks.
    private lazy var fullChildren: [UIView] = [
        touchpad, leftStick, rightStick, dpad, face,
        psB, l2v, l1, shareB, r2v, r1, optionsB, l3, r3
    ]

    // MARK: - Init

    init(streamInput: StreamInput) {
        let prefs = StreamPreferences.load()
        touchHapticsEnabled = prefs.touchHapticsEnabled
        lightImpact = UIImpactFeedbackGenerator(style: .light)
        mediumImpact = UIImpactFeedbackGenerator(style: .medium)
        self.streamInput = streamInput
        face = PyluxFaceClusterView(swapCrossMoon: prefs.swapCrossMoon)
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        clipsToBounds = false
        chiaki_controller_state_set_idle(&controlsState)

        l1.label = ""
        l1.chiakiShoulderPathData = ChiakiShoulderVector.l1
        r1.label = ""
        r1.chiakiShoulderPathData = ChiakiShoulderVector.r1
        l3.label = ""
        l3.chiakiShoulderPathData = ChiakiShoulderVector.l3
        r3.label = ""
        r3.chiakiShoulderPathData = ChiakiShoulderVector.r3
        optionsB.symbolName = "line.horizontal.3"
        optionsB.symbolPointSizeFraction = 0.56
        shareB.symbolName = "square.and.arrow.up"
        shareB.symbolPointSizeFraction = 0.40
        psB.label = ""
        psB.symbolName = "circle.fill"
        psB.symbolPointSizeFraction = 0.56
        psB.symbolTintAlphaIdle = 0.26
        psB.symbolTintAlphaPressed = 0.48
        l2v.chiakiShoulderPathData = ChiakiShoulderVector.l2
        r2v.chiakiShoulderPathData = ChiakiShoulderVector.r2

        fullChildren.forEach { addSubview($0) }
        sendSubviewToBack(touchpad)

        addSubview(psOnlyTapRevealView)
        psOnlyTapRevealView.isUserInteractionEnabled = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(psOnlyTapRevealTapped))
        tap.cancelsTouchesInView = true
        psOnlyTapRevealView.addGestureRecognizer(tap)

        touchpad.onChange = { [weak self] in self?.publish() }
        touchpad.hapticLight = { [weak self] in self?.playLightHaptic() }
        touchpad.hapticMedium = { [weak self] in self?.playMediumHaptic() }
        dpad.hapticOnDirectionChange = { [weak self] in self?.playLightHaptic() }
        l2v.hapticOnBegan = { [weak self] in self?.playLightHaptic() }
        r2v.hapticOnBegan = { [weak self] in self?.playLightHaptic() }
        wireButtons()
        wireSticks()
        wireDpad()
        wireTriggers()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        cancelPsOnlyHideTimer()
    }

    // MARK: - PS auto-hide (PS-only + touchpad-only)

    private func cancelPsOnlyHideTimer() {
        psOnlyHidePsWorkItem?.cancel()
        psOnlyHidePsWorkItem = nil
    }

    private func schedulePsOnlyPsButtonHide() {
        cancelPsOnlyHideTimer()
        let item = DispatchWorkItem { [weak self] in
            self?.applyPsOnlyPsButtonHiddenForButtonlessView()
        }
        psOnlyHidePsWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.psMinimalChromeAutoHideDelay, execute: item)
    }

    private func applyPsOnlyPsButtonHiddenForButtonlessView() {
        guard mode == .psOnly || mode == .touchpadOnly else { return }
        psOnlyPsButtonVisible = false
        psB.isHidden = true
        psOnlyTapRevealView.passThroughTarget = (mode == .touchpadOnly) ? touchpad : nil
        psOnlyTapRevealView.isUserInteractionEnabled = true
        setNeedsLayout()
    }

    @objc private func psOnlyTapRevealTapped() {
        guard mode == .psOnly || mode == .touchpadOnly, !psOnlyPsButtonVisible else { return }
        psOnlyPsButtonVisible = true
        psB.isHidden = false
        psOnlyTapRevealView.isUserInteractionEnabled = false
        psOnlyTapRevealView.passThroughTarget = nil
        schedulePsOnlyPsButtonHide()
        setNeedsLayout()
    }

    // MARK: - Wire + publish

    private func playLightHaptic() {
        guard touchHapticsEnabled else { return }
        lightImpact.impactOccurred()
    }

    private func playMediumHaptic() {
        guard touchHapticsEnabled else { return }
        mediumImpact.impactOccurred()
    }

    private func wireTriggers() {
        l2v.onAnalog = { [weak self] down in
            guard let self = self else { return }
            self.controlsState.l2_state = down ? 255 : 0
            self.publish()
        }
        r2v.onAnalog = { [weak self] down in
            guard let self = self else { return }
            self.controlsState.r2_state = down ? 255 : 0
            self.publish()
        }
    }

    private func wireDpad() {
        dpad.onDirection = { [weak self] mask in
            guard let self = self else { return }
            var b = self.controlsState.buttons
            b &= ~UInt32((1 << 4) | (1 << 5) | (1 << 6) | (1 << 7))
            if let m = mask { b |= m }
            self.controlsState.buttons = b
            self.publish()
        }
    }

    private func wireSticks() {
        leftStick.onStick = { [weak self] x, y in
            guard let self = self else { return }
            let maxV = CGFloat(Int16.max)
            self.controlsState.left_x = Int16(clamping: Int(x * maxV))
            self.controlsState.left_y = Int16(clamping: Int(y * maxV))
            self.publish()
        }
        rightStick.onStick = { [weak self] x, y in
            guard let self = self else { return }
            let maxV = CGFloat(Int16.max)
            self.controlsState.right_x = Int16(clamping: Int(x * maxV))
            self.controlsState.right_y = Int16(clamping: Int(y * maxV))
            self.publish()
        }
    }

    private func wireButtons() {
        let psBit = UInt32(1 << 15)
        let buttons: [PyluxPadButtonView] = [face.cross, face.moon, face.pyramid, face.box, l1, r1, l3, r3, optionsB, shareB]
        for b in buttons {
            let bit = b.maskBit
            b.hapticOnDown = { [weak self] in self?.playLightHaptic() }
            b.onPressed = { [weak self] down in
                guard let self = self else { return }
                if down {
                    self.controlsState.buttons |= bit
                } else {
                    self.controlsState.buttons &= ~bit
                }
                self.publish()
            }
        }
        psB.hapticOnDown = { [weak self] in self?.playLightHaptic() }
        psB.onPressed = { [weak self] down in
            guard let self = self else { return }
            if down {
                self.controlsState.buttons |= psBit
                self.onPSButtonPressed?()
            } else {
                self.controlsState.buttons &= ~psBit
            }
            self.publish()
        }
    }

    private func publish() {
        var tp = touchpad.exportState()
        var out = ChiakiControllerState()
        chiaki_controller_state_or(&out, &controlsState, &tp)
        streamInput?.syncTouchOverlayState(out)
    }

    // MARK: - Mode (SwiftUI)

    func apply(mode: StreamTouchControlsMode, streamInput: StreamInput) {
        if self.mode == mode, self.streamInput === streamInput {
            return
        }
        self.streamInput = streamInput
        self.mode = mode
        switch mode {
        case .hidden:
            cancelPsOnlyHideTimer()
            psOnlyTapRevealView.isUserInteractionEnabled = false
            psOnlyTapRevealView.passThroughTarget = nil
            isHidden = true
            resetAll()
            streamInput.clearTouchOverlayState()
        case .full:
            cancelPsOnlyHideTimer()
            psOnlyTapRevealView.isUserInteractionEnabled = false
            psOnlyTapRevealView.passThroughTarget = nil
            isHidden = false
            fullChildren.forEach { $0.isHidden = false }
            setNeedsLayout()
            DispatchQueue.main.async { [weak self] in
                self?.publish()
            }
        case .touchpadOnly:
            cancelPsOnlyHideTimer()
            psOnlyTapRevealView.isUserInteractionEnabled = false
            psOnlyTapRevealView.passThroughTarget = nil
            isHidden = false
            fullChildren.forEach { $0.isHidden = ($0 !== touchpad && $0 !== psB) }
            psOnlyPsButtonVisible = true
            psB.isHidden = false
            schedulePsOnlyPsButtonHide()
            setNeedsLayout()
            DispatchQueue.main.async { [weak self] in
                self?.publish()
            }
        case .psOnly:
            isHidden = false
            resetAll()
            fullChildren.forEach { $0.isHidden = ($0 !== psB) }
            psOnlyPsButtonVisible = true
            psB.isHidden = false
            psOnlyTapRevealView.isUserInteractionEnabled = false
            psOnlyTapRevealView.passThroughTarget = nil
            schedulePsOnlyPsButtonHide()
            setNeedsLayout()
            DispatchQueue.main.async { [weak self] in
                self?.publish()
            }
        }
    }

    private func resetAll() {
        chiaki_controller_state_set_idle(&controlsState)
        touchpad.resetState()
        leftStick.resetInteraction()
        rightStick.resetInteraction()
    }

    // MARK: - Hit testing (Android `ButtonView.bestFittingTouchView`)

    /// Options/Share first: same vertical band as R1/L1; on equal hit-test distance, prefer the small pads.
    private var rootButtonDisambiguationViews: [UIView] {
        [optionsB, shareB, l2v, l1, r2v, r1, l3, r3, psB]
    }

    private func distanceSquaredFromBoundsCenter(of view: UIView, to point: CGPoint) -> CGFloat {
        let c = convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
        let dx = point.x - c.x
        let dy = point.y - c.y
        return dx * dx + dy * dy
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, mode != .hidden else { return nil }
        if mode == .psOnly {
            if psOnlyPsButtonVisible {
                guard psB.point(inside: convert(point, to: psB), with: event) else { return nil }
                let local = convert(point, to: psB)
                return psB.hitTest(local, with: event) ?? psB
            }
            return super.hitTest(point, with: event)
        }
        guard bounds.contains(point) else { return nil }

        let candidates = rootButtonDisambiguationViews.filter { v in
            !v.isHidden && v.alpha > 0.01 && v.isUserInteractionEnabled && v.point(inside: convert(point, to: v), with: event)
        }
        if candidates.count == 1, let only = candidates.first {
            let local = convert(point, to: only)
            return only.hitTest(local, with: event) ?? only
        }
        if candidates.count > 1 {
            let best = candidates.enumerated().min(by: { a, b in
                let da = distanceSquaredFromBoundsCenter(of: a.element, to: point)
                let db = distanceSquaredFromBoundsCenter(of: b.element, to: point)
                if da != db { return da < db }
                return a.offset < b.offset
            })!.element
            let local = convert(point, to: best)
            return best.hitTest(local, with: event) ?? best
        }

        let v = super.hitTest(point, with: event)
        if v === self { return nil }
        return v
    }

    // MARK: - Layout (`fragment_controls.xml` dp → points)

    override func layoutSubviews() {
        super.layoutSubviews()
        guard mode != .hidden else { return }
        let w = bounds.width
        let h = bounds.height
        let m = min(w, h)
        // Android uses fixed dp; ~390pt min dimension ≈ baseline phone. Cap so iPad / large layouts do not
        // scale controls to unusable sizes (was: max(0.9, m/390) → ~2×+ on tablets).
        let s = min(CGFloat(1.12), max(CGFloat(0.88), m / 390))

        if mode == .touchpadOnly {
            // Match Android fragment_touchpad_only: ~80dp horizontal margin, 1920:942; leave bottom for PS (overlay).
            let pss: CGFloat = 48 * s
            let margin: CGFloat = 80 * s
            let topPad = safeAreaInsets.top + 24
            let bottomPad = pss + 8 * s + safeAreaInsets.bottom
            var tpW = max(120, w - 2 * margin)
            var tpH = tpW * 942 / 1920
            let maxH = h - topPad - bottomPad
            if tpH > maxH, maxH > 40 {
                tpH = maxH
                tpW = tpH * 1920 / 942
            }
            let touchY = topPad + max(0, (maxH - tpH) / 2)
            touchpad.frame = CGRect(x: (w - tpW) / 2, y: touchY, width: tpW, height: tpH)
            psB.frame = CGRect(x: (w - pss) / 2, y: h - pss, width: pss, height: pss)
            psOnlyTapRevealView.frame = bounds
            if psOnlyPsButtonVisible {
                bringSubviewToFront(psB)
            } else {
                bringSubviewToFront(psOnlyTapRevealView)
            }
            return
        }

        if mode == .psOnly {
            psOnlyTapRevealView.frame = bounds
            let pss: CGFloat = 48 * s
            psB.frame = CGRect(x: (w - pss) / 2, y: h - pss, width: pss, height: pss)
            bringSubviewToFront(psOnlyTapRevealView)
            return
        }

        // --- `fragment_controls.xml` proportions (dp → points via s) ---
        let midX = w * 0.5
        let sl = safeAreaInsets.left
        let sr = safeAreaInsets.right
        let st = safeAreaInsets.top

        // Touchpad: top +32dp, max width 300dp, ratio 1920:942, centered H (behind dpad/face in z-order).
        let tpMaxW = min(300 * s, w - 20 * s)
        let tpWf = tpMaxW
        let tpHf = tpWf * 942 / 1920
        touchpad.frame = CGRect(x: (w - tpWf) / 2, y: 32 * s + st, width: tpWf, height: tpHf)

        // L1/R1 bottom (fragment_controls: marginTop 32dp + 80dp height from parent top).
        let shoulderRowBottom = 32 * s + st + 80 * s

        // D-pad: 160dp, marginLeft 16dp; vertically centered in XML, but must sit below L1 or it overlaps.
        let dSize = 160 * s
        let dpadX = 16 * s + sl
        let dpadIdealY = (h - dSize - 16 * s) / 2
        let dpadYRaw = max(st, shoulderRowBottom + 10 * s, dpadIdealY)
        let dpadY = min(dpadYRaw, h - dSize - 16 * s)
        dpad.frame = CGRect(x: dpadX, y: dpadY, width: dSize, height: dSize)

        // Face: 176dp, marginRight 32dp; same vertical rule vs R1.
        let faceSize = 176 * s
        let faceX = w - faceSize - 32 * s - sr
        let faceIdealY = (h - faceSize - 32 * s) / 2
        let faceYRaw = max(st, shoulderRowBottom + 10 * s, faceIdealY)
        let faceY = min(faceYRaw, h - faceSize - 32 * s)
        face.frame = CGRect(x: faceX, y: faceY, width: faceSize, height: faceSize)

        // Analog sticks: Android radius 48dp handle 32dp; below dpad / below face, each half-screen wide
        leftStick.radius = 48 * s
        leftStick.handleRadius = 32 * s
        rightStick.radius = 48 * s
        rightStick.handleRadius = 32 * s

        // Android: sticks sit below dpad/face; draw uses R = radius + handleRadius around the touch center.
        // UIKit clips `draw(_:)` to bounds — if the first touch is near the top of the stick area, the base ring
        // extends `stickPad` above center and was clipped. Extra `stickPad` above + symmetric hit insets fix that.
        let stickPad = leftStick.radius + leftStick.handleRadius
        let leftStickTop = dpadY + dSize
        let leftW = max(0, midX - sl)
        leftStick.frame = CGRect(
            x: sl - stickPad,
            y: leftStickTop - 2 * stickPad,
            width: leftW + 2 * stickPad,
            height: max(1, h - leftStickTop + 3 * stickPad)
        )

        let rightStickTop = faceY + faceSize
        let rightW = max(0, w - sr - midX)
        rightStick.frame = CGRect(
            x: midX - stickPad,
            y: rightStickTop - 2 * stickPad,
            width: rightW + 2 * stickPad,
            height: max(1, h - rightStickTop + 3 * stickPad)
        )

        // Shoulder rows: parent left/right/top like Android (minimal horizontal inset — only true safe area).
        let edgeL = sl
        let edgeR = sr
        l2v.frame = CGRect(x: edgeL, y: st, width: 88 * s, height: 80 * s)
        shareB.frame = CGRect(x: l2v.frame.maxX + 32 * s, y: st, width: 48 * s, height: 48 * s)
        l1.frame = CGRect(x: 40 * s + edgeL, y: 32 * s + st, width: 80 * s, height: 80 * s)

        r2v.frame = CGRect(x: w - 88 * s - edgeR, y: st, width: 88 * s, height: 80 * s)
        optionsB.frame = CGRect(x: r2v.frame.minX - 32 * s - 48 * s, y: st, width: 48 * s, height: 48 * s)
        r1.frame = CGRect(x: w - 40 * s - 80 * s - edgeR, y: 32 * s + st, width: 80 * s, height: 80 * s)

        // `fragment_controls.xml` padding on L2/R2/L1/R1 — drawable bounds match Android `ButtonView`.
        let p8 = 8 * s
        let p16 = 16 * s
        l1.chiakiShoulderPathInsets = UIEdgeInsets(top: p8, left: p8, bottom: p8, right: p8)
        r1.chiakiShoulderPathInsets = UIEdgeInsets(top: p8, left: p8, bottom: p8, right: p8)
        l2v.chiakiShoulderPathInsets = UIEdgeInsets(top: p8, left: p16, bottom: p8, right: p8)
        r2v.chiakiShoulderPathInsets = UIEdgeInsets(top: p8, left: p8, bottom: p8, right: p16)

        // L3 / R3 / PS: flush to bottom like Android (y = h - size; view fills screen under safe area).
        let l3s: CGFloat = 64 * s
        l3.frame = CGRect(x: edgeL, y: h - l3s, width: l3s, height: l3s)
        r3.frame = CGRect(x: w - l3s - edgeR, y: h - l3s, width: l3s, height: l3s)
        let pss: CGFloat = 48 * s
        psB.frame = CGRect(x: (w - pss) / 2, y: h - pss, width: pss, height: pss)
    }
}
