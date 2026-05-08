// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// SwiftUI view for displaying decoded video stream

import SwiftUI
import AVFoundation
import os.log

private let videoViewLog = OSLog(subsystem: "com.pylux.stream", category: "StreamVideoView")

/// UIViewRepresentable that displays video via AVSampleBufferDisplayLayer.
/// Attach a PyluxVideoDecoder via setDecoder to receive decoded frames.
struct StreamVideoView: UIViewRepresentable {
    let aspectRatio: CGFloat
    var displayMode: DisplayMode = .fit
    var onViewCreated: ((StreamVideoUIView) -> Void)?

    init(aspectRatio: CGFloat = 16.0 / 9.0, displayMode: DisplayMode = .fit, onViewCreated: ((StreamVideoUIView) -> Void)? = nil) {
        self.aspectRatio = aspectRatio
        self.displayMode = displayMode
        self.onViewCreated = onViewCreated
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(aspectRatio: aspectRatio)
    }

    func makeUIView(context: Context) -> StreamVideoUIView {
        let view = StreamVideoUIView()
        view.coordinator = context.coordinator
        view.setupDisplayLayer()
        view.updateVideoGravity(displayMode)
        let b = view.bounds
        os_log(.default, log: videoViewLog, "[StreamVideoView] makeUIView created bounds=%.0fx%.0f (may be 0 before layout)", b.width, b.height)
        onViewCreated?(view)
        return view
    }

    func updateUIView(_ uiView: StreamVideoUIView, context: Context) {
        context.coordinator.aspectRatio = aspectRatio
        uiView.updateVideoGravity(displayMode)
        let b = uiView.bounds
        if b.width > 0 && b.height > 0 && (context.coordinator.lastLoggedBounds?.width != b.width || context.coordinator.lastLoggedBounds?.height != b.height) {
            os_log(.default, log: videoViewLog, "[StreamVideoView] updateUIView bounds=%.0fx%.0f", b.width, b.height)
            context.coordinator.lastLoggedBounds = b
        }
    }

    class Coordinator {
        var aspectRatio: CGFloat
        var lastLoggedBounds: CGRect?
        init(aspectRatio: CGFloat) { self.aspectRatio = aspectRatio }
    }
}

/// UIView that hosts AVSampleBufferDisplayLayer for video display.
final class StreamVideoUIView: UIView {
    weak var coordinator: StreamVideoView.Coordinator?

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }

	func setupDisplayLayer() {
		guard let avLayer = layer as? AVSampleBufferDisplayLayer else { return }
		avLayer.videoGravity = .resizeAspect
		avLayer.backgroundColor = UIColor.black.cgColor
		os_log(.default, log: videoViewLog, "[StreamVideoUIView] setupDisplayLayer ok")
    }

    func updateVideoGravity(_ mode: DisplayMode) {
        let gravity: AVLayerVideoGravity
        switch mode {
        case .fit: gravity = .resizeAspect
        case .zoom: gravity = .resizeAspectFill
        case .stretch: gravity = .resize
        }
        guard let avLayer = layer as? AVSampleBufferDisplayLayer else { return }
        if avLayer.videoGravity == gravity { return }
        avLayer.videoGravity = gravity
        // Nudge the layer to re-apply videoGravity (otherwise it can look like "fit" until layout/orientation changes).
        avLayer.flush()
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Display layer for attaching to VideoDecoder.
    var videoDisplayLayer: AVSampleBufferDisplayLayer? {
        layer as? AVSampleBufferDisplayLayer
    }
}
