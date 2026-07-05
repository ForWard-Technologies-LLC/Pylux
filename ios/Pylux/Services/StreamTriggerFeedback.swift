// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Drives a physical DualSense's adaptive triggers from the console's
// CHIAKI_EVENT_TRIGGER_EFFECTS stream data via Apple's GameController API.

import Foundation
import GameController

/// Translates the PS5's raw trigger-effect descriptors (a mode byte + 10 param
/// bytes per trigger, exactly as the DualSense HID output report carries them)
/// into `GCDualSenseAdaptiveTrigger` semantic calls.
///
/// This is a per-platform translation on purpose: Apple's API is semantic
/// (`setModeFeedback/Weapon/Vibration/…`), not raw-byte, so there is no shared-C
/// encoder to reuse — the console's byte layout is decoded here. Effect modes the
/// public API cannot express fall back to `setModeOff` (documented, not hacked).
enum StreamTriggerFeedback {
    /// PS5 DualSense trigger effect type ids (subset the firmware emits).
    private enum EffectType {
        static let off: UInt8 = 0x00
        static let feedback: UInt8 = 0x01     // constant resistance from a start position
        static let weapon: UInt8 = 0x02       // resistance between start/end that snaps back
        static let vibration: UInt8 = 0x06    // vibrate from a start position
        static let off2: UInt8 = 0x05         // some titles send 0x05 as "clear"
    }

    static func apply(controller: GCController?,
                      typeLeft: UInt8, left: [UInt8],
                      typeRight: UInt8, right: [UInt8]) {
        guard let ds = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        applyOne(ds.leftTrigger, type: typeLeft, params: left)
        applyOne(ds.rightTrigger, type: typeRight, params: right)
    }

    /// Release both triggers to their neutral state. Call on session quit and when
    /// adaptive triggers are disabled, so a resistance effect can't latch stiff.
    static func reset(controller: GCController?) {
        guard let ds = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        ds.leftTrigger.setModeOff()
        ds.rightTrigger.setModeOff()
    }

    private static func norm(_ b: UInt8) -> Float { Float(b) / 255.0 }

    private static func applyOne(_ trigger: GCDualSenseAdaptiveTrigger, type: UInt8, params: [UInt8]) {
        // params are the raw DS5 bytes; interpretation is per effect type. We map
        // the common cases to Apple's semantic API and clear anything else.
        // Note: the single-float mode setters import into Swift with the leading
        // "With<FirstArg>" kept in the base name (no NS_SWIFT_NAME on these ObjC
        // selectors), hence setModeFeedbackWithStartPosition(_:resistiveStrength:) etc.
        switch type {
        case EffectType.feedback:
            // byte 0 = start position, byte 1 = resistive strength
            trigger.setModeFeedbackWithStartPosition(norm(params.count > 0 ? params[0] : 0),
                                                     resistiveStrength: norm(params.count > 1 ? params[1] : 0))
        case EffectType.weapon:
            // byte 0 = start, byte 1 = end, byte 2 = strength
            let start = norm(params.count > 0 ? params[0] : 0)
            var end = norm(params.count > 1 ? params[1] : 0)
            if end <= start { end = min(1.0, start + 0.1) } // Apple requires end > start
            trigger.setModeWeaponWithStartPosition(start, endPosition: end,
                                                   resistiveStrength: norm(params.count > 2 ? params[2] : 0))
        case EffectType.vibration:
            // byte 0 = start, byte 1 = amplitude, byte 2 = frequency
            trigger.setModeVibrationWithStartPosition(norm(params.count > 0 ? params[0] : 0),
                                                      amplitude: norm(params.count > 1 ? params[1] : 0),
                                                      frequency: norm(params.count > 2 ? params[2] : 0))
        case EffectType.off, EffectType.off2:
            trigger.setModeOff()
        default:
            // Multi-zone / positional-resistance curves and any unknown type are not
            // expressible through the public semantic API here — clear rather than
            // approximate incorrectly.
            trigger.setModeOff()
        }
    }
}
