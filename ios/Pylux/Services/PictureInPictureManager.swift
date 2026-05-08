// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Manages AVPictureInPictureController for the game stream

import AVKit
import Combine
import os.log

private let pipLog = OSLog(subsystem: "com.pylux.stream", category: "PiP")

@MainActor
final class PictureInPictureManager: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false

    private var pipController: AVPictureInPictureController?
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var possibleObservation: NSKeyValueObservation?
    private var isRestoring = false
    private var resignActiveObserver: NSObjectProtocol?

    /// Called when the user taps the PiP window to return to the app.
    var restoreUserInterface: (() -> Void)?
    /// Called only when the user explicitly closed the PiP window (not when restoring to inline).
    var pipClosedByUser: (() -> Void)?

    func configure(with layer: AVSampleBufferDisplayLayer) {
        guard displayLayer !== layer else { return }
        tearDown()
        displayLayer = layer

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            os_log(.error, log: pipLog, "PiP not supported on this device")
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller

        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] ctrl, _ in
            Task { @MainActor [weak self] in
                self?.isPossible = ctrl.isPictureInPicturePossible
            }
        }

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let ctrl = self.pipController else { return }
                if ctrl.isPictureInPicturePossible && !ctrl.isPictureInPictureActive {
                    ctrl.startPictureInPicture()
                }
            }
        }
    }

    func startIfPossible() {
        guard let controller = pipController,
              controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller = pipController, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    func tearDown() {
        if let obs = resignActiveObserver { NotificationCenter.default.removeObserver(obs) }
        resignActiveObserver = nil
        possibleObservation?.invalidate()
        possibleObservation = nil
        if let controller = pipController, controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        }
        pipController = nil
        displayLayer = nil
        isActive = false
        isPossible = false
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {}

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {}

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            let wasRestoring = self.isRestoring
            self.isRestoring = false
            self.isActive = false
            if !wasRestoring {
                self.pipClosedByUser?()
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        os_log(.error, log: pipLog, "PiP failed to start: %{public}@", error.localizedDescription)
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            self.isRestoring = true
            self.restoreUserInterface?()
            completionHandler(true)
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // Stream is always live; nothing to do.
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime
    ) async {
        // Live stream — skip is not applicable.
    }
}
