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
    /// PS5 DualSense trigger effect type ids (as carried in the DS HID output report).
    private enum EffectType {
        static let off: UInt8 = 0x00
        static let simpleFeedback: UInt8 = 0x01   // constant resistance from a start position
        static let simpleWeapon: UInt8 = 0x02     // resistance between start/end that snaps back
        static let off2: UInt8 = 0x05             // some titles send 0x05 as "clear"
        static let simpleVibration: UInt8 = 0x06  // vibrate from a start position
        static let feedback: UInt8 = 0x21         // per-zone resistance (10 zones, 3-bit strengths)
        static let bow: UInt8 = 0x22              // tension between two positions with snap
        static let galloping: UInt8 = 0x23        // periodic pulses between two positions
        static let weapon: UInt8 = 0x25           // trigger-pull resistance between two zones
        static let vibration: UInt8 = 0x26        // per-zone vibration + frequency ("automatic gun")
        static let machine: UInt8 = 0x27          // sustained mechanical vibration
    }

    /// intensityScale mirrors the console's Trigger Effect Intensity setting
    /// (Qt folds the equivalent attenuation byte into the raw HID report; here it
    /// scales the semantic strengths/amplitudes).
    static func apply(controller: GCController?,
                      typeLeft: UInt8, left: [UInt8],
                      typeRight: UInt8, right: [UInt8],
                      intensityScale: Float = 1.0) {
        guard let ds = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        applyOne(ds.leftTrigger, type: typeLeft, params: left, scale: intensityScale)
        applyOne(ds.rightTrigger, type: typeRight, params: right, scale: intensityScale)
    }

    /// Release both triggers to their neutral state. Call on session quit and when
    /// adaptive triggers are disabled, so a resistance effect can't latch stiff.
    static func reset(controller: GCController?) {
        guard let ds = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        ds.leftTrigger.setModeOff()
        ds.rightTrigger.setModeOff()
    }

    private static func norm(_ b: UInt8) -> Float { Float(b) / 255.0 }
    private static func byte(_ p: [UInt8], _ i: Int) -> UInt8 { i < p.count ? p[i] : 0 }

    /// The extended (0x2x) modes address 10 trigger-travel zones through a 10-bit
    /// mask in params[0..1]. Returns the first/last active zone as normalized
    /// trigger positions (0...1), or nil when no zone is set.
    private static func zoneSpan(_ p: [UInt8]) -> (start: Float, end: Float)? {
        let mask = UInt16(byte(p, 0)) | (UInt16(byte(p, 1)) << 8)
        guard mask != 0 else { return nil }
        var first = -1, last = -1
        for i in 0..<10 where mask & (1 << i) != 0 {
            if first < 0 { first = i }
            last = i
        }
        return (Float(first) / 9.0, Float(last) / 9.0)
    }

    /// Extended feedback/vibration modes pack per-zone 3-bit magnitudes after the
    /// zone mask; take the strongest zone as the single magnitude Apple's API takes.
    private static func maxPackedMagnitude(_ p: [UInt8], from firstByte: Int) -> Float {
        var maxVal: UInt32 = 0
        var bits: UInt32 = 0
        var acc: UInt32 = 0
        for i in firstByte..<min(p.count, firstByte + 4) {
            acc |= UInt32(p[i]) << bits
            bits += 8
            while bits >= 3 {
                maxVal = max(maxVal, acc & 0x7)
                acc >>= 3
                bits -= 3
            }
        }
        return maxVal == 0 ? 0 : Float(maxVal) / 7.0
    }

    private static func applyOne(_ trigger: GCDualSenseAdaptiveTrigger, type: UInt8, params: [UInt8], scale: Float) {
        func scaled(_ v: Float) -> Float { min(1.0, v * max(0, scale)) }
        // params are the raw DS5 bytes; interpretation is per effect type. Apple's
        // API is semantic (no raw HID pass-through on iOS, unlike SDL on desktop),
        // so the extended modes are approximated with the closest expressible
        // effect rather than dropped.
        // Note: the single-float mode setters import into Swift with the leading
        // "With<FirstArg>" kept in the base name (no NS_SWIFT_NAME on these ObjC
        // selectors), hence setModeFeedbackWithStartPosition(_:resistiveStrength:) etc.
        switch type {
        case EffectType.simpleFeedback:
            // byte 0 = start position, byte 1 = resistive strength
            let strength = norm(byte(params, 1))
            guard scaled(strength) > 0 else { trigger.setModeOff(); return }
            trigger.setModeFeedbackWithStartPosition(norm(byte(params, 0)),
                                                     resistiveStrength: scaled(strength))
        case EffectType.simpleWeapon:
            // byte 0 = start, byte 1 = end, byte 2 = strength
            let start = norm(byte(params, 0))
            var end = norm(byte(params, 1))
            if end <= start { end = min(1.0, start + 0.1) } // Apple requires end > start
            let strength = norm(byte(params, 2))
            guard scaled(strength) > 0 else { trigger.setModeOff(); return }
            trigger.setModeWeaponWithStartPosition(start, endPosition: end,
                                                   resistiveStrength: scaled(strength))
        case EffectType.simpleVibration:
            // byte 0 = start, byte 1 = amplitude, byte 2 = frequency
            let amplitude = norm(byte(params, 1))
            guard scaled(amplitude) > 0 else { trigger.setModeOff(); return }
            trigger.setModeVibrationWithStartPosition(norm(byte(params, 0)),
                                                      amplitude: scaled(amplitude),
                                                      frequency: max(0.05, norm(byte(params, 2))))
        case EffectType.feedback:
            // zone mask + packed 3-bit per-zone strengths -> constant resistance
            // from the first active zone at the strongest zone's strength.
            guard let span = zoneSpan(params) else { trigger.setModeOff(); return }
            let strength = maxPackedMagnitude(params, from: 2)
            guard scaled(strength) > 0 else { trigger.setModeOff(); return }
            trigger.setModeFeedbackWithStartPosition(span.start, resistiveStrength: scaled(strength))
        case EffectType.weapon, EffectType.bow:
            // two active zones (start/end) + 3-bit strength -> weapon resistance.
            guard let span = zoneSpan(params) else { trigger.setModeOff(); return }
            var end = span.end
            if end <= span.start { end = min(1.0, span.start + 0.1) }
            let strength = Float(byte(params, 2) & 0x7) / 7.0
            guard scaled(strength) > 0 else { trigger.setModeOff(); return }
            trigger.setModeWeaponWithStartPosition(span.start, endPosition: end,
                                                   resistiveStrength: scaled(strength))
        case EffectType.vibration, EffectType.galloping, EffectType.machine:
            // zone mask + per-zone amplitudes, frequency in the tail byte.
            guard let span = zoneSpan(params) else { trigger.setModeOff(); return }
            let amplitude = maxPackedMagnitude(params, from: 2)
            // A zero amplitude means the game wants the effect engaged but silent —
            // switch off instead of buzzing at an invented floor.
            guard scaled(amplitude) > 0 else { trigger.setModeOff(); return }
            // Frequency (Hz-ish byte) observed at offset 8 in on-device captures
            // (offset 9 as fallback); bytes 2..6 are the packed per-zone amplitudes.
            let freqByte = byte(params, 8) != 0 ? byte(params, 8) : byte(params, 9)
            trigger.setModeVibrationWithStartPosition(span.start,
                                                      amplitude: scaled(amplitude),
                                                      frequency: max(0.08, norm(freqByte)))
        case EffectType.off, EffectType.off2:
            trigger.setModeOff()
        default:
            // Unknown/calibration modes: clear rather than approximate incorrectly.
            trigger.setModeOff()
        }
    }
}
