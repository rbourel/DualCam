import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let engine: CameraEngine

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = engine.session
        view.previewLayer.videoGravity = .resizeAspect
        view.onTap = { [weak view] point in
            guard let view else { return }
            engine.focus(at: view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
            view.showFocusSquare(at: point)
        }
        engine.attachPreview(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTap: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        onTap?(gesture.location(in: self))
    }

    func showFocusSquare(at point: CGPoint) {
        let square = UIView(frame: CGRect(x: 0, y: 0, width: 70, height: 70))
        square.center = point
        square.layer.borderColor = UIColor.systemYellow.cgColor
        square.layer.borderWidth = 1.5
        square.isUserInteractionEnabled = false
        square.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
        addSubview(square)
        UIView.animate(withDuration: 0.2) { square.transform = .identity }
        UIView.animate(withDuration: 0.3, delay: 0.9, options: []) { square.alpha = 0 } completion: { _ in
            square.removeFromSuperview()
        }
    }
}
