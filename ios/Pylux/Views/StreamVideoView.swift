// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// SwiftUI view for displaying decoded video stream

import SwiftUI
import AVFoundation

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
        onViewCreated?(view)
        return view
    }

    func updateUIView(_ uiView: StreamVideoUIView, context: Context) {
        context.coordinator.aspectRatio = aspectRatio
        uiView.updateVideoGravity(displayMode)
    }

    class Coordinator {
        var aspectRatio: CGFloat
        init(aspectRatio: CGFloat) { self.aspectRatio = aspectRatio }
    }
}

/// UIView that hosts AVSampleBufferDisplayLayer for video display.
final class StreamVideoUIView: UIView {
    weak var coordinator: StreamVideoView.Coordinator?

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func setupDisplayLayer() {
        (layer as? AVSampleBufferDisplayLayer)?.videoGravity = .resizeAspect
        (layer as? AVSampleBufferDisplayLayer)?.backgroundColor = UIColor.black.cgColor
    }

    func updateVideoGravity(_ mode: DisplayMode) {
        let gravity: AVLayerVideoGravity
        switch mode {
        case .fit: gravity = .resizeAspect
        case .zoom: gravity = .resizeAspectFill
        case .stretch: gravity = .resize
        }
        (layer as? AVSampleBufferDisplayLayer)?.videoGravity = gravity
    }

    /// Display layer for attaching to VideoDecoder.
    var videoDisplayLayer: AVSampleBufferDisplayLayer? {
        layer as? AVSampleBufferDisplayLayer
    }
}
