// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Controller input - external MFi/Bluetooth game controller (Phase 7)

import Foundation
import GameController
import QuartzCore

/// Controller input. Maps GameController input to ChiakiControllerState.
/// Phase 7 v1: external MFi/Bluetooth controller only.
class StreamInput {
    /// Called when controller state should be sent to the session.
    /// Pass a pointer to ChiakiControllerState (valid only for the duration of the call).
    var controllerStateChangedCallback: ((UnsafePointer<ChiakiControllerState>) -> Void)?

    private var controllerState = ChiakiControllerState()
    private var displayLink: CADisplayLink?
    private weak var attachedController: GCController?
    private var lastStateHash: Int = -1
    private let swapButtons: Bool  // cached at init, avoids JSON decode every frame

    init() {
        swapButtons = StreamPreferences.load().swapCrossMoon
        chiaki_controller_state_set_idle(&controllerState)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidDisconnect),
            name: .GCControllerDidDisconnect,
            object: nil
        )
        if let controller = GCController.controllers().first {
            attachController(controller)
        }
    }

    deinit {
        stopPolling()
        NotificationCenter.default.removeObserver(self)
    }

    /// Start polling controller state (e.g. when stream is active).
    func startPolling() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(pollControllerState))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stop polling (e.g. when stream is paused).
    func stopPolling() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        attachController(controller)
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        if notification.object as? GCController === attachedController {
            attachedController = nil
        }
        chiaki_controller_state_set_idle(&controllerState)
        notifyIfChanged()
    }

    private func attachController(_ controller: GCController) {
        attachedController = controller
        controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in
            self?.updateStateFromController(controller)
        }
        controller.microGamepad?.valueChangedHandler = { [weak self] _, _ in
            self?.updateStateFromController(controller)
        }
        updateStateFromController(controller)
    }

    private func updateStateFromController(_ controller: GCController) {
        chiaki_controller_state_set_idle(&controllerState)

        if let pad = controller.extendedGamepad {
            // Face buttons: Cross(1<<0), Moon(1<<1), Box(1<<2), Pyramid(1<<3)
            // When swapped (matches Android swap_cross_moon): A<->B and X<->Y
            let crossBit: UInt32  = swapButtons ? UInt32(1 << 1) : UInt32(1 << 0)
            let moonBit: UInt32   = swapButtons ? UInt32(1 << 0) : UInt32(1 << 1)
            let boxBit: UInt32    = swapButtons ? UInt32(1 << 3) : UInt32(1 << 2)
            let pyrBit: UInt32    = swapButtons ? UInt32(1 << 2) : UInt32(1 << 3)
            if pad.buttonA.isPressed { controllerState.buttons |= crossBit }
            if pad.buttonB.isPressed { controllerState.buttons |= moonBit }
            if pad.buttonX.isPressed { controllerState.buttons |= boxBit }
            if pad.buttonY.isPressed { controllerState.buttons |= pyrBit }
            // D-pad
            if pad.dpad.left.isPressed { controllerState.buttons |= UInt32(1 << 4) }
            if pad.dpad.right.isPressed { controllerState.buttons |= UInt32(1 << 5) }
            if pad.dpad.up.isPressed { controllerState.buttons |= UInt32(1 << 6) }
            if pad.dpad.down.isPressed { controllerState.buttons |= UInt32(1 << 7) }
            // Shoulders
            if pad.leftShoulder.isPressed { controllerState.buttons |= UInt32(1 << 8) }
            if pad.rightShoulder.isPressed { controllerState.buttons |= UInt32(1 << 9) }
            // Sticks
            if pad.leftThumbstickButton?.isPressed == true { controllerState.buttons |= UInt32(1 << 10) }
            if pad.rightThumbstickButton?.isPressed == true { controllerState.buttons |= UInt32(1 << 11) }
            // Options, Share, PS
            if pad.buttonOptions?.isPressed == true { controllerState.buttons |= UInt32(1 << 12) }
            if pad.buttonHome?.isPressed == true { controllerState.buttons |= UInt32(1 << 15) }
            // Triggers (0–255)
            controllerState.l2_state = UInt8(max(0, min(255, Int(pad.leftTrigger.value * 255))))
            controllerState.r2_state = UInt8(max(0, min(255, Int(pad.rightTrigger.value * 255))))
            // Sticks (-32768 to 32767) via xAxis/yAxis
            controllerState.left_x = Int16(pad.leftThumbstick.xAxis.value * 32767)
            controllerState.left_y = Int16(-pad.leftThumbstick.yAxis.value * 32767)
            controllerState.right_x = Int16(pad.rightThumbstick.xAxis.value * 32767)
            controllerState.right_y = Int16(-pad.rightThumbstick.yAxis.value * 32767)
        } else if let micro = controller.microGamepad {
            if micro.buttonA.isPressed { controllerState.buttons |= UInt32(1 << 0) }
            if micro.buttonX.isPressed { controllerState.buttons |= UInt32(1 << 2) }
            if micro.dpad.left.isPressed { controllerState.buttons |= UInt32(1 << 4) }
            if micro.dpad.right.isPressed { controllerState.buttons |= UInt32(1 << 5) }
            if micro.dpad.up.isPressed { controllerState.buttons |= UInt32(1 << 6) }
            if micro.dpad.down.isPressed { controllerState.buttons |= UInt32(1 << 7) }
        }

        notifyIfChanged()
    }

    @objc private func pollControllerState() {
        let controller = attachedController ?? GCController.controllers().first
        guard let controller = controller else {
            if lastStateHash != 0 {
                chiaki_controller_state_set_idle(&controllerState)
                lastStateHash = 0
                controllerStateChangedCallback?(&controllerState)
            }
            return
        }
        updateStateFromController(controller)
    }

    private func notifyIfChanged() {
        let h = stateHash()
        guard h != lastStateHash else { return }
        lastStateHash = h
        controllerStateChangedCallback?(&controllerState)
    }

    private func stateHash() -> Int {
        var h = Int(controllerState.buttons)
        h = h &* 31 &+ Int(controllerState.l2_state)
        h = h &* 31 &+ Int(controllerState.r2_state)
        h = h &* 31 &+ Int(controllerState.left_x)
        h = h &* 31 &+ Int(controllerState.left_y)
        h = h &* 31 &+ Int(controllerState.right_x)
        h = h &* 31 &+ Int(controllerState.right_y)
        return h
    }
}
