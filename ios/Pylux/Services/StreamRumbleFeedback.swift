// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Console rumble → device haptics.
//
// When a physical controller with haptics is connected (e.g. DualSense via Bluetooth),
// rumble is routed to the controller's motors. Otherwise falls back to the iPhone's
// Taptic Engine, matching the Android approach (average L/R, ~1s pulse).
//
// No-haptics devices: `supportsHaptics == false` uses `kSystemSoundID_Vibrate` (no-op on many iPads; harmless).

import AudioToolbox
import CoreHaptics
import Foundation
import GameController
import os.log

private let rumbleLog = OSLog(subsystem: "com.pylux.stream", category: "StreamRumble")

@MainActor
final class StreamRumbleFeedback {
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private weak var input: StreamInput?
    private weak var controllerWithEngine: GCController?

    init(input: StreamInput? = nil) {
        self.input = input
    }

    func prepare() {
        prepareEngine(for: input?.currentController)
    }

    private func prepareEngine(for controller: GCController?) {
        shutdownEngine()

        if let controller = controller, let haptics = controller.haptics {
            if let eng = haptics.createEngine(withLocality: .default) {
                do {
                    eng.resetHandler = { [weak self] in
                        Task { @MainActor in self?.handleEngineReset() }
                    }
                    try eng.start()
                    engine = eng
                    controllerWithEngine = controller
                    os_log(.info, log: rumbleLog, "Haptic engine created on controller")
                    return
                } catch {
                    os_log(.info, log: rumbleLog, "Controller haptic engine start failed: %{public}@", String(describing: error))
                }
            } else {
                os_log(.info, log: rumbleLog, "Controller does not support haptic locality")
            }
        }

        controllerWithEngine = nil
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let eng = try CHHapticEngine()
            eng.resetHandler = { [weak self] in
                Task { @MainActor in self?.handleEngineReset() }
            }
            try eng.start()
            engine = eng
        } catch {
            os_log(.error, log: rumbleLog, "CHHapticEngine start failed: %{public}@", String(describing: error))
            engine = nil
        }
    }

    private func handleEngineReset() {
        player = nil
        do {
            try engine?.start()
        } catch {
            os_log(.error, log: rumbleLog, "CHHapticEngine restart failed: %{public}@", String(describing: error))
        }
    }

    func shutdown() {
        shutdownEngine()
    }

    private func shutdownEngine() {
        if let player = player {
            try? player.stop(atTime: CHHapticTimeImmediate)
        }
        player = nil
        engine?.resetHandler = {}
        engine?.stop(completionHandler: nil)
        engine = nil
        controllerWithEngine = nil
    }

    func applyRumble(left: UInt8, right: UInt8, rumbleEnabled: Bool) {
        if let player = player {
            try? player.stop(atTime: CHHapticTimeImmediate)
        }
        player = nil
        guard rumbleEnabled else { return }
        let amp = min(255, (Int(left) + Int(right)) / 2)
        guard amp > 0 else { return }

        let currentController = input?.currentController
        if currentController !== controllerWithEngine {
            prepareEngine(for: currentController)
        }

        if let engine = engine {
            playContinuous(engine: engine, amplitude: amp)
        } else if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            prepareEngine(for: currentController)
            if let engine = engine {
                playContinuous(engine: engine, amplitude: amp)
            } else {
                legacyVibrate()
            }
        } else {
            legacyVibrate()
        }
    }

    private func playContinuous(engine: CHHapticEngine, amplitude amp: Int) {
        let intensity = max(0.12, min(1.0, Float(amp) / 255.0))
        do {
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35),
                ],
                relativeTime: 0,
                duration: 1.0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let p = try engine.makePlayer(with: pattern)
            try p.start(atTime: 0)
            player = p
        } catch {
            os_log(.error, log: rumbleLog, "rumble pattern failed: %{public}@", String(describing: error))
            legacyVibrate()
        }
    }

    private func legacyVibrate() {
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
    }
}
