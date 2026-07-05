// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Merges physical `GameController` input with on-screen touch controls into `ChiakiControllerState` (Android `StreamInput`).

import Foundation
import GameController

// TODO: Device motion when `StreamPreferences.motionEnabled` (Android parity).

/// Owns merged `ChiakiControllerState` and notifies `StreamSession` when it changes.
/// Merges are **event-driven** like Android: touch overlay updates, `GCController` `valueChangedHandler`,
/// and connect/disconnect — not on a display link. Android's `StreamInput` calls `controllerStateUpdated()`
/// only from touch/sensor/key/motion handlers, which avoids stacking many `set_controller_state` calls per
/// frame and losing brief button edges in the feedback sender before its thread runs.
class StreamInput {
    // MARK: - Session hook

    var controllerStateChangedCallback: ((UnsafePointer<ChiakiControllerState>) -> Void)?

    // MARK: - State

    private var controllerState = ChiakiControllerState()
    private var touchOverlayState = ChiakiControllerState()
    // Physical DualSense touchpad (click + up to two fingers). Tracked persistently
    // because chiaki touch ids are handles that must survive across merges.
    private var physicalTouchpadState = ChiakiControllerState()
    private var padFinger1Id: Int8 = -1
    private var padFinger2Id: Int8 = -1
    private weak var attachedController: GCController?
    private var lastStateHash: Int = -1
    private let swapButtons: Bool

    /// The currently attached physical controller (if any). Used by `StreamRumbleFeedback` to route haptics.
    var currentController: GCController? { attachedController ?? GCController.controllers().first }

    /// True when the attached controller is a physical DualSense. Gates
    /// `enable_dualsense`: only advertise DualSense to the console when one is
    /// actually connected, so non-DualSense users keep classic rumble.
    var hasDualSense: Bool { (currentController?.extendedGamepad as? GCDualSenseGamepad) != nil }

    // MARK: - Lifecycle

    init() {
        swapButtons = StreamPreferences.load().swapCrossMoon
        chiaki_controller_state_set_idle(&controllerState)
        chiaki_controller_state_set_idle(&touchOverlayState)
        chiaki_controller_state_set_idle(&physicalTouchpadState)
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
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Touch overlay (from `StreamTouchControlsContainerView`)

    /// Replaces cached overlay state and recomputes merge (always applied so button-only deltas are not skipped).
    func syncTouchOverlayState(_ state: ChiakiControllerState) {
        touchOverlayState = state
        mergeGamepadWithTouchAndNotify()
    }

    func clearTouchOverlayState() {
        chiaki_controller_state_set_idle(&touchOverlayState)
        mergeGamepadWithTouchAndNotify()
    }

    /// Call when the Chiaki session is ready to send feedback so the first post-connect `set_controller_state` is not skipped.
    func resendMergedControllerStateIfNeeded() {
        lastStateHash = -1
        mergeGamepadWithTouchAndNotify()
    }

    // MARK: - GameController

    @objc private func controllerDidConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        attachController(controller)
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        if notification.object as? GCController === attachedController {
            attachedController = nil
        }
        mergeGamepadWithTouchAndNotify()
    }

    private func attachController(_ controller: GCController) {
        attachedController = controller
        controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in
            self?.mergeGamepadWithTouchAndNotify()
        }
        controller.microGamepad?.valueChangedHandler = { [weak self] _, _ in
            self?.mergeGamepadWithTouchAndNotify()
        }
        // DualSense touchpad elements aren't reliably covered by the extendedGamepad
        // handler, so subscribe to them directly to drive merges on pad activity.
        if let ds = controller.extendedGamepad as? GCDualSenseGamepad {
            let onChange: () -> Void = { [weak self] in self?.mergeGamepadWithTouchAndNotify() }
            ds.touchpadButton.pressedChangedHandler = { _, _, _ in onChange() }
            ds.touchpadPrimary.valueChangedHandler = { _, _, _ in onChange() }
            ds.touchpadSecondary.valueChangedHandler = { _, _, _ in onChange() }
        }
        mergeGamepadWithTouchAndNotify()
    }

    // MARK: - Merge + notify

    private func mergeGamepadWithTouchAndNotify() {
        var gamepad = ChiakiControllerState()
        chiaki_controller_state_set_idle(&gamepad)
        let controller = attachedController ?? GCController.controllers().first
        if let c = controller {
            fillGamepadState(&gamepad, controller: c)
            updatePhysicalTouchpad(c)
        } else {
            clearPhysicalTouchpad()
        }
        var merged = ChiakiControllerState()
        chiaki_controller_state_set_idle(&merged)
        chiaki_controller_state_or(&merged, &gamepad, &touchOverlayState)
        chiaki_controller_state_or(&controllerState, &merged, &physicalTouchpadState)
        notifyIfChanged()
    }

    // MARK: - Physical DualSense touchpad

    /// Poll the physical DualSense touchpad into `physicalTouchpadState`: the pad
    /// click -> BUTTON_TOUCHPAD (bit 14), and up to two fingers -> `touches[]`.
    /// DS4 and non-DualSense controllers expose no touchpad through GameController,
    /// so this is a no-op for them (physical pad unavailable — the on-screen
    /// overlay remains the touchpad path).
    private func updatePhysicalTouchpad(_ controller: GCController) {
        guard let ds = controller.extendedGamepad as? GCDualSenseGamepad else {
            clearPhysicalTouchpad()
            return
        }
        let touchpadBit = UInt32(1 << 14)
        if ds.touchpadButton.isPressed { physicalTouchpadState.buttons |= touchpadBit }
        else { physicalTouchpadState.buttons &= ~touchpadBit }

        // Finger 1 presence comes from touchpadButton.isTouched (a finger resting on
        // the surface, distinct from a physical click).
        updatePadFinger(present: ds.touchpadButton.isTouched, dpad: ds.touchpadPrimary, id: &padFinger1Id)
        // Finger 2 has no dedicated touch flag; treat non-zero secondary axes as
        // present. Only false-negative is a second finger resting exactly at center
        // — a public-API limitation, not worked around.
        let sec = ds.touchpadSecondary
        updatePadFinger(present: sec.xAxis.value != 0 || sec.yAxis.value != 0, dpad: sec, id: &padFinger2Id)
    }

    private func updatePadFinger(present: Bool, dpad: GCControllerDirectionPad, id: inout Int8) {
        if present {
            // touchpad axes are [-1, 1]; PS touchpad space is [0, 1919] x [0, 941],
            // y down-positive (GameController y is up-positive, so invert).
            let x = UInt16(max(0, min(1919, Int(((dpad.xAxis.value + 1) / 2) * 1919))))
            let y = UInt16(max(0, min(941, Int(((1 - dpad.yAxis.value) / 2) * 941))))
            if id < 0 {
                id = chiaki_controller_state_start_touch(&physicalTouchpadState, x, y)
            } else {
                chiaki_controller_state_set_touch_pos(&physicalTouchpadState, UInt8(id), x, y)
            }
        } else if id >= 0 {
            chiaki_controller_state_stop_touch(&physicalTouchpadState, UInt8(id))
            id = -1
        }
    }

    private func clearPhysicalTouchpad() {
        if padFinger1Id >= 0 { chiaki_controller_state_stop_touch(&physicalTouchpadState, UInt8(padFinger1Id)); padFinger1Id = -1 }
        if padFinger2Id >= 0 { chiaki_controller_state_stop_touch(&physicalTouchpadState, UInt8(padFinger2Id)); padFinger2Id = -1 }
        physicalTouchpadState.buttons &= ~UInt32(1 << 14)
    }

    private func fillGamepadState(_ state: inout ChiakiControllerState, controller: GCController) {
        chiaki_controller_state_set_idle(&state)

        if let pad = controller.extendedGamepad {
            let crossBit: UInt32 = swapButtons ? UInt32(1 << 1) : UInt32(1 << 0)
            let moonBit: UInt32 = swapButtons ? UInt32(1 << 0) : UInt32(1 << 1)
            let boxBit: UInt32 = swapButtons ? UInt32(1 << 3) : UInt32(1 << 2)
            let pyrBit: UInt32 = swapButtons ? UInt32(1 << 2) : UInt32(1 << 3)
            if pad.buttonA.isPressed { state.buttons |= crossBit }
            if pad.buttonB.isPressed { state.buttons |= moonBit }
            if pad.buttonX.isPressed { state.buttons |= boxBit }
            if pad.buttonY.isPressed { state.buttons |= pyrBit }
            if pad.dpad.left.isPressed { state.buttons |= UInt32(1 << 4) }
            if pad.dpad.right.isPressed { state.buttons |= UInt32(1 << 5) }
            if pad.dpad.up.isPressed { state.buttons |= UInt32(1 << 6) }
            if pad.dpad.down.isPressed { state.buttons |= UInt32(1 << 7) }
            if pad.leftShoulder.isPressed { state.buttons |= UInt32(1 << 8) }
            if pad.rightShoulder.isPressed { state.buttons |= UInt32(1 << 9) }
            if pad.leftThumbstickButton?.isPressed == true { state.buttons |= UInt32(1 << 10) }
            if pad.rightThumbstickButton?.isPressed == true { state.buttons |= UInt32(1 << 11) }
            // Match SDL/Qt/Android: START → OPTIONS, BACK → SHARE. Apple maps Menu ≈ Start, Options ≈ View/Back.
            if pad.buttonMenu.isPressed { state.buttons |= UInt32(1 << 12) }
            if pad.buttonOptions?.isPressed == true { state.buttons |= UInt32(1 << 13) }
            if pad.buttonHome?.isPressed == true { state.buttons |= UInt32(1 << 15) }
            state.l2_state = UInt8(max(0, min(255, Int(pad.leftTrigger.value * 255))))
            state.r2_state = UInt8(max(0, min(255, Int(pad.rightTrigger.value * 255))))
            state.left_x = Int16(pad.leftThumbstick.xAxis.value * 32767)
            state.left_y = Int16(-pad.leftThumbstick.yAxis.value * 32767)
            state.right_x = Int16(pad.rightThumbstick.xAxis.value * 32767)
            state.right_y = Int16(-pad.rightThumbstick.yAxis.value * 32767)
        } else if let micro = controller.microGamepad {
            if micro.buttonA.isPressed { state.buttons |= UInt32(1 << 0) }
            if micro.buttonX.isPressed { state.buttons |= UInt32(1 << 2) }
            if micro.dpad.left.isPressed { state.buttons |= UInt32(1 << 4) }
            if micro.dpad.right.isPressed { state.buttons |= UInt32(1 << 5) }
            if micro.dpad.up.isPressed { state.buttons |= UInt32(1 << 6) }
            if micro.dpad.down.isPressed { state.buttons |= UInt32(1 << 7) }
        }
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
        h = hashTouchSlot(controllerState.touches.0, h)
        h = hashTouchSlot(controllerState.touches.1, h)
        return h
    }

    private func hashTouchSlot(_ t: chiaki_controller_touch_t, _ h: Int) -> Int {
        var x = h
        x = x &* 31 &+ Int(t.id)
        x = x &* 31 &+ Int(t.x)
        x = x &* 31 &+ Int(t.y)
        return x
    }
}
