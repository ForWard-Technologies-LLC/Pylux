// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Merges physical `GameController` input with on-screen touch controls into `ChiakiControllerState` (Android `StreamInput`).

#if !os(tvOS)
import CoreMotion
#endif
import Foundation
import GameController

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
    // Motion (gyro/accel/orientation) streamed to the console, per the user's
    // MotionSource setting: the controller's sensors (GCMotion), this device's
    // sensors (CoreMotion), or off. Raw gyro/accel are fed through the shared C
    // orientation tracker exactly like Qt's SDL path.
    private var motionSource: MotionSource
    private var orientationTracker = ChiakiOrientationTracker()
    private var accelZero = ChiakiAccelNewZero()
    #if !os(tvOS)
    private let deviceMotion = CMMotionManager()
    #endif
    private var prefsObserver: NSObjectProtocol?

    /// The currently attached physical controller (if any). Used by `StreamRumbleFeedback` to route haptics.
    var currentController: GCController? { attachedController ?? GCController.controllers().first }

    // MARK: - Lifecycle

    init() {
        let prefs = StreamPreferences.load()
        swapButtons = prefs.swapCrossMoon
        motionSource = prefs.motionSource
        chiaki_controller_state_set_idle(&controllerState)
        chiaki_controller_state_set_idle(&touchOverlayState)
        chiaki_controller_state_set_idle(&physicalTouchpadState)
        chiaki_orientation_tracker_init(&orientationTracker)
        chiaki_accel_new_zero_set_inactive(&accelZero, false)
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
        prefsObserver = NotificationCenter.default.addObserver(
            forName: .streamPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.motionSource = StreamPreferences.load().motionSource
            self.reconfigureMotionSources()
        }
        if let controller = GCController.controllers().first {
            attachController(controller)
        } else {
            reconfigureMotionSources()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let obs = prefsObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        #if !os(tvOS)
        deviceMotion.stopDeviceMotionUpdates()
        #endif
        // Power down the controller's sensors too (they were manually activated);
        // leaving them on drains a Bluetooth DualSense after the stream ends.
        if let motion = (attachedController ?? GCController.controllers().first)?.motion {
            motion.valueChangedHandler = nil
            if motion.sensorsRequireManualActivation && motion.sensorsActive {
                motion.sensorsActive = false
            }
        }
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
        reconfigureMotionSources()
        mergeGamepadWithTouchAndNotify()
    }

    private func attachController(_ controller: GCController) {
        attachedController = controller
        // By default iOS binds the Create/Share button to the system capture
        // gestures (press = screenshot, long-press = recording) and swallows the
        // presses, so the OPTIONS+SHARE menu chord could never fire from a
        // physical controller. Claim these buttons for the stream: SHARE/OPTIONS
        // must reach the console, and Home is the PS button.
        if let pad = controller.extendedGamepad {
            #if !os(tvOS)
            for button in [pad.buttonOptions, pad.buttonMenu, pad.buttonHome].compactMap({ $0 }) {
                button.preferredSystemGestureState = .disabled
            }
            #endif
        }
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
        reconfigureMotionSources()
        mergeGamepadWithTouchAndNotify()
    }

    // MARK: - Motion sources

    /// True when the current MotionSource resolves to the controller's sensors.
    private var usesControllerMotion: Bool {
        // Resolve against the same controller the merge uses (currentController
        // falls back to GCController.controllers().first before the connect
        // notification lands), so buttons and motion always agree on the source.
        guard currentController?.motion != nil else { return false }
        return motionSource == .auto || motionSource == .controller
    }

    /// True when the current MotionSource resolves to this device's sensors.
    private var usesPhoneMotion: Bool {
        #if os(tvOS)
        return false
        #else
        switch motionSource {
        case .phone: return true
        case .auto: return currentController?.motion == nil
        case .controller, .off: return false
        }
        #endif
    }

    /// Start/stop the controller's and the phone's motion sensors to match the
    /// MotionSource setting and what is currently attached. Called at init, on
    /// controller connect/disconnect, and on preference changes (live).
    private func reconfigureMotionSources() {
        // Controller sensors (DualSense/DS4 need manual activation on iOS). Each
        // sample drives a merge so the feedback stream carries continuously-live
        // motion.
        if let motion = currentController?.motion {
            if usesControllerMotion {
                if motion.sensorsRequireManualActivation && !motion.sensorsActive {
                    motion.sensorsActive = true
                }
                motion.valueChangedHandler = { [weak self] _ in self?.mergeGamepadWithTouchAndNotify() }
            } else {
                motion.valueChangedHandler = nil
                if motion.sensorsRequireManualActivation && motion.sensorsActive {
                    motion.sensorsActive = false
                }
            }
        }

        #if !os(tvOS)
        // Phone sensors via CoreMotion, at the controller-sensor-comparable 60Hz.
        if usesPhoneMotion {
            if !deviceMotion.isDeviceMotionActive && deviceMotion.isDeviceMotionAvailable {
                deviceMotion.deviceMotionUpdateInterval = 1.0 / 60.0
                deviceMotion.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                    guard motion != nil else { return }
                    self?.mergeGamepadWithTouchAndNotify()
                }
            }
        } else if deviceMotion.isDeviceMotionActive {
            deviceMotion.stopDeviceMotionUpdates()
        }
        #endif
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
        applyMotion(to: &gamepad, controller: controller)
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

        // Finger presence: on iOS, GameController does not reliably surface the
        // DualSense capacitive touch through touchpadButton.isTouched — it tracks
        // the CLICK, which forced click-and-drag before swipes registered (and made
        // a plain click unusable). Treat non-zero axes as presence (like finger 2
        // always did), keeping isTouched as a bonus signal where it works. Only
        // false-negative is a finger resting exactly at dead center — a public-API
        // limitation, not worked around.
        let pri = ds.touchpadPrimary
        updatePadFinger(present: ds.touchpadButton.isTouched || pri.xAxis.value != 0 || pri.yAxis.value != 0,
                        dpad: pri, id: &padFinger1Id)
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

    /// Feed the active motion source (per MotionSource) through the shared C
    /// orientation tracker and stamp gyro/accel/orientation into `state`.
    private func applyMotion(to state: inout ChiakiControllerState, controller: GCController?) {
        if usesControllerMotion, let motion = controller?.motion,
           motion.sensorsActive || !motion.sensorsRequireManualActivation {
            // GCMotion units match chiaki: rotationRate is rad/s, acceleration is in G.
            // Frames differ though: Apple's controller frame is Z-up (observed: at rest
            // -(gravity) ≈ (0,0,1)) while the PS/chiaki frame is Y-up with +Z toward the
            // player. Right-handed remap: PS(x,y,z) = Apple(x, z, -y), applied to both
            // gyro and accel; Apple's acceleration also points along gravity while PS
            // reports the reaction force, hence the negation.
            let rr = motion.rotationRate
            let aX: Double, aY: Double, aZ: Double
            if motion.hasGravityAndUserAcceleration {
                aX = -(motion.gravity.x + motion.userAcceleration.x)
                aY = -(motion.gravity.y + motion.userAcceleration.y)
                aZ = -(motion.gravity.z + motion.userAcceleration.z)
            } else {
                aX = -motion.acceleration.x
                aY = -motion.acceleration.y
                aZ = -motion.acceleration.z
            }
            updateOrientationTracker(
                gyro: (Float(rr.x), Float(rr.z), Float(-rr.y)),
                accel: (Float(aX), Float(aZ), Float(-aY))
            )
            chiaki_orientation_tracker_apply_to_controller_state(&orientationTracker, &state)
        } else {
            #if !os(tvOS)
            if usesPhoneMotion, let motion = deviceMotion.deviceMotion {
            // This device's sensors (CoreMotion), Android-parity mapping for a phone
            // held landscape: PS(x,y,z) = device(y, z, x). CoreMotion's portrait device
            // frame is X right / Y toward earpiece / Z out of the screen, and its
            // acceleration points along gravity while PS reports the reaction force,
            // hence the negation (same as the controller path).
            let rr = motion.rotationRate
            let aX = -(motion.gravity.x + motion.userAcceleration.x)
            let aY = -(motion.gravity.y + motion.userAcceleration.y)
            let aZ = -(motion.gravity.z + motion.userAcceleration.z)
            updateOrientationTracker(
                gyro: (Float(rr.y), Float(rr.z), Float(rr.x)),
                accel: (Float(aY), Float(aZ), Float(aX))
            )
            chiaki_orientation_tracker_apply_to_controller_state(&orientationTracker, &state)
            }
            #endif
        }
    }

    private func updateOrientationTracker(gyro: (Float, Float, Float), accel: (Float, Float, Float)) {
        let timestampUs = UInt32(truncatingIfNeeded: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000))
        chiaki_orientation_tracker_update(&orientationTracker,
                                          gyro.0, gyro.1, gyro.2,
                                          accel.0, accel.1, accel.2,
                                          &accelZero, true, timestampUs)
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
        // sample_index increments per tracker update, so hashing it defeats the
        // change-gate for motion-only updates (gyro aiming needs every sample).
        h = h &* 31 &+ Int(bitPattern: UInt(truncatingIfNeeded: orientationTracker.sample_index))
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
