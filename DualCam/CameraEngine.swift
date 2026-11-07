import AVFoundation
import CoreImage
import Metal
import Photos
import UIKit

/// Image miniature du flux vertical (séparée pour ne pas redessiner toute l'UI à chaque frame).
final class PiPModel: ObservableObject {
    @Published var image: CGImage?
}

/// Capture 4K unique → deux fichiers : 16:9 (image complète) et 9:16 (recadrage central),
/// chacun avec son propre codec et sa propre résolution.
final class CameraEngine: NSObject, ObservableObject {

    // MARK: État UI (thread principal)
    @Published var settings = CaptureSettings.load() {
        didSet {
            settings.save()
            if settings.fps != oldValue.fps || settings.stabilization != oldValue.stabilization {
                let s = settings
                sessionQueue.async { self.applyDeviceSettings(s) }
            }
            refreshMinutesLeft()
        }
    }
    @Published private(set) var isRecording = false
    @Published private(set) var busy = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var minutesLeft: Int?
    @Published private(set) var captureAngle: CGFloat = 0
    @Published private(set) var locked = false
    @Published private(set) var droppedFrames = 0
    @Published private(set) var audioLabel = "Micro"
    @Published private(set) var sourceLabel = ""
    @Published private(set) var proResSupported = true
    @Published private(set) var thermalWarning = false
    @Published var message: String?

    let pip = PiPModel()
    let session = AVCaptureSession()

    // MARK: Privé
    private let sessionQueue = DispatchQueue(label: "dualcam.session")
    private let dataQueue = DispatchQueue(label: "dualcam.data", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoDevice: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []
    private var timer: Timer?
    private var tick = 0

    // Accédés uniquement sur dataQueue
    private let ciContext: CIContext = {
        let opts: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .cacheIntermediates: false]
        if let mtl = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: mtl, options: opts) }
        return CIContext(options: opts)
    }()
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private var recH: StreamRecorder?
    private var recV: StreamRecorder?
    private var frameCount = 0
    private var lastAudioFormat: CMFormatDescription?
    private var audioLabelSet = false
    private var failureReported = false

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    // MARK: Démarrage

    func start() {
        let s = settings
        checkProResSupport()
        refreshMinutesLeft()
        Task {
            let camOK = await AVCaptureDevice.requestAccess(for: .video)
            let micOK = await AVCaptureDevice.requestAccess(for: .audio)
            guard camOK else {
                await MainActor.run { self.post("Accès caméra refusé (Réglages › DualCam)") }
                return
            }
            self.sessionQueue.async { self.configureSession(settings: s, withAudio: micOK) }
        }
    }

    private func configureSession(settings s: CaptureSettings, withAudio: Bool) {
        guard videoDevice == nil else { return }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.post("Caméra indisponible") }
            return
        }
        session.addInput(input)
        videoDevice = device

        if withAudio, let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if withAudio {
            audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        }
        session.commitConfiguration()

        applyDeviceSettings(s)
        session.startRunning()
        DispatchQueue.main.async { self.makeRotationCoordinatorIfReady() }
    }

    /// Choisit un format capteur 4K (sinon 1080p) compatible avec la cadence demandée.
    private func applyDeviceSettings(_ s: CaptureSettings) {
        guard let device = videoDevice else { return }
        let fps = Double(s.fps)
        func matches(_ f: AVCaptureDevice.Format, _ w: Int32, _ h: Int32) -> Bool {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return d.width == w && d.height == h
                && (sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        }
        let uhd = device.formats.filter { matches($0, 3840, 2160) }
        let fhd = device.formats.filter { matches($0, 1920, 1080) }
        guard let format = uhd.first(where: { !$0.isVideoBinned }) ?? uhd.first ?? fhd.last else {
            DispatchQueue.main.async { self.post("Aucun format caméra à \(s.fps) i/s") }
            return
        }

        session.beginConfiguration()
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(s.fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.post("Config caméra impossible : \(error.localizedDescription)") }
        }
        if let connection = videoOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = s.stabilization ? .standard : .off
        }
        session.commitConfiguration()

        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        DispatchQueue.main.async {
            self.sourceLabel = "Capteur \(d.width)×\(d.height) · \(s.fps) i/s"
            if d.width < 3840 { self.post("4K indisponible à \(s.fps) i/s : source 1080p") }
        }
    }

    private func checkProResSupport() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe.mov")
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        proResSupported = w.canApply(outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
        ], forMediaType: .video)
    }

    // MARK: Orientation (main)

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        makeRotationCoordinatorIfReady()
    }

    private func makeRotationCoordinatorIfReady() {
        guard rotationCoordinator == nil, let device = videoDevice, let layer = previewLayer else { return }
        let rc = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = rc
        updatePreviewAngle(rc.videoRotationAngleForHorizonLevelPreview)
        updateCaptureAngle(rc.videoRotationAngleForHorizonLevelCapture)
        observations = [
            rc.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] rc, _ in
                let a = rc.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.updatePreviewAngle(a) }
            },
            rc.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] rc, _ in
                let a = rc.videoRotationAngleForHorizonLevelCapture
                DispatchQueue.main.async { self?.updateCaptureAngle(a) }
            },
        ]
    }

    private func updatePreviewAngle(_ angle: CGFloat) {
        if let c = previewLayer?.connection, c.isVideoRotationAngleSupported(angle) {
            c.videoRotationAngle = angle
        }
    }

    /// On ne garde que les deux paysages (0° / 180°) et on fige pendant l'enregistrement.
    private func updateCaptureAngle(_ angle: CGFloat) {
        guard !isRecording, angle == 0 || angle == 180 else { return }
        captureAngle = angle
    }

    // MARK: Mise au point / verrouillage

    func focus(at devicePoint: CGPoint) {
        locked = false
        sessionQueue.async {
            guard let d = self.videoDevice, (try? d.lockForConfiguration()) != nil else { return }
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusPointOfInterest = devicePoint
                d.focusMode = .continuousAutoFocus
            }
            if d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposurePointOfInterest = devicePoint
                d.exposureMode = .continuousAutoExposure
            }
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                d.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            d.unlockForConfiguration()
        }
    }

    /// Verrouille mise au point + exposition + balance des blancs (bouton cadenas).
    func toggleLock() {
        let lock = !locked
        locked = lock
        sessionQueue.async {
            guard let d = self.videoDevice, (try? d.lockForConfiguration()) != nil else { return }
            let focus: AVCaptureDevice.FocusMode = lock ? .locked : .continuousAutoFocus
            let exposure: AVCaptureDevice.ExposureMode = lock ? .locked : .continuousAutoExposure
            let wb: AVCaptureDevice.WhiteBalanceMode = lock ? .locked : .continuousAutoWhiteBalance
            if d.isFocusModeSupported(focus) { d.focusMode = focus }
            if d.isExposureModeSupported(exposure) { d.exposureMode = exposure }
            if d.isWhiteBalanceModeSupported(wb) { d.whiteBalanceMode = wb }
            d.unlockForConfiguration()
        }
    }

    // MARK: Enregistrement (main)

    func toggleRecording() {
        guard !busy else { return }
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        let s = settings
        guard s.horizontal.enabled || s.vertical.enabled else {
            post("Active au moins un format")
            return
        }
        busy = true
        let transform = CGAffineTransform(rotationAngle: captureAngle * .pi / 180)
        let stamp = Self.stampFormatter.string(from: Date())
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        dataQueue.async {
            var h: StreamRecorder?
            var v: StreamRecorder?
            do {
                if s.horizontal.enabled {
                    let (w, ht) = s.horizontalSize
                    h = try StreamRecorder(url: docs.appendingPathComponent("DualCam_\(stamp)_16x9.mov"),
                                           width: w, height: ht, codec: s.horizontal.codec, fps: s.fps,
                                           transform: transform, audioFormat: self.lastAudioFormat)
                }
                if s.vertical.enabled {
                    let (w, ht) = s.verticalSize
                    v = try StreamRecorder(url: docs.appendingPathComponent("DualCam_\(stamp)_9x16.mov"),
                                           width: w, height: ht, codec: s.vertical.codec, fps: s.fps,
                                           transform: transform, audioFormat: self.lastAudioFormat)
                }
            } catch {
                h?.cancel()
                v?.cancel()
                DispatchQueue.main.async {
                    self.busy = false
                    self.post("Impossible de démarrer : \(error.localizedDescription)")
                }
                return
            }
            self.failureReported = false
            self.recH = h
            self.recV = v
            DispatchQueue.main.async {
                self.isRecording = true
                self.busy = false
                self.elapsed = 0
                self.droppedFrames = 0
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                self.startTimer()
            }
        }
    }

    private func stopRecording() {
        busy = true
        isRecording = false
        timer?.invalidate()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let toPhotos = settings.saveToPhotos

        dataQueue.async {
            let recorders = [self.recH, self.recV].compactMap { $0 }
            self.recH = nil
            self.recV = nil
            let group = DispatchGroup()
            var ok: [URL] = []
            var errors: [String] = []
            for r in recorders {
                group.enter()
                r.finish { error in
                    self.dataQueue.async {
                        if let error { errors.append(error.localizedDescription) } else { ok.append(r.url) }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                if !errors.isEmpty { self.post("Erreur : \(errors.joined(separator: " / "))") }
                if toPhotos, !ok.isEmpty {
                    self.saveToPhotos(ok)
                } else {
                    self.busy = false
                    if !ok.isEmpty { self.post("\(ok.count) fichier(s) dans Fichiers › Sur mon iPhone › DualCam") }
                    self.refreshMinutesLeft()
                }
            }
        }
    }

    private func saveToPhotos(_ urls: [URL]) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.busy = false
                    self.post("Accès Photos refusé : fichiers dans l'app Fichiers › DualCam")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for url in urls {
                    let opts = PHAssetResourceCreationOptions()
                    opts.shouldMoveFile = true // pas de doublon sur le stockage
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: opts)
                }
            }) { success, error in
                DispatchQueue.main.async {
                    self.busy = false
                    self.post(success ? "\(urls.count) vidéo(s) dans Photos ✓"
                                      : "Erreur Photos : \(error?.localizedDescription ?? "?") (fichiers dans l'app Fichiers)")
                    self.refreshMinutesLeft()
                }
            }
        }
    }

    private func startTimer() {
        let start = Date()
        tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = Date().timeIntervalSince(start)
            self.tick += 1
            if self.tick % 20 == 0 { self.refreshMinutesLeft() }
            if self.tick % 4 == 0 {
                self.dataQueue.async {
                    let d = (self.recH?.dropped ?? 0) + (self.recV?.dropped ?? 0)
                    DispatchQueue.main.async { self.droppedFrames = d }
                }
            }
        }
    }

    // MARK: Divers (main)

    func refreshMinutesLeft() {
        thermalWarning = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let free = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return }
        let mbps = settings.totalMbps()
        minutesLeft = mbps > 0 ? Int(Double(free) * 8 / (mbps * 1_000_000) / 60) : nil
    }

    func post(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.message == text { self?.message = nil }
        }
    }
}

// MARK: - Traitement des frames (dataQueue)

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            handleAudio(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        frameCount &+= 1

        let srcW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let srcH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let source = CIImage(cvPixelBuffer: pixelBuffer)

        // Recadrage 9:16 au centre de l'image 16:9
        let cropW = (srcH * 9 / 16).rounded()
        let cropRect = CGRect(x: ((srcW - cropW) / 2).rounded(), y: 0, width: cropW, height: srcH)
        let vertical = source.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: 0))

        if frameCount % 3 == 0 { updatePiP(vertical, size: cropRect.size) }

        if let r = recH {
            if r.width == Int(srcW) && r.height == Int(srcH) {
                r.appendVideo(pixelBuffer, at: pts) // 4K → 4K : aucune copie
            } else {
                render(source, size: CGSize(width: srcW, height: srcH), from: pixelBuffer, into: r, at: pts)
            }
        }
        if let r = recV {
            render(vertical, size: cropRect.size, from: pixelBuffer, into: r, at: pts)
        }
        checkFailures()
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            recH?.dropped += 1
            recV?.dropped += 1
        }
    }

    private func handleAudio(_ sample: CMSampleBuffer) {
        if let fmt = CMSampleBufferGetFormatDescription(sample) {
            lastAudioFormat = fmt
            if !audioLabelSet, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                audioLabelSet = true
                let khz = Int((asbd.mSampleRate / 1000).rounded())
                let ch = asbd.mChannelsPerFrame >= 2 ? "Stéréo" : "Mono"
                DispatchQueue.main.async { self.audioLabel = "Micro · \(ch) · \(khz) kHz" }
            }
        }
        recH?.appendAudio(sample)
        recV?.appendAudio(sample)
    }

    private func render(_ image: CIImage, size: CGSize, from source: CVPixelBuffer, into r: StreamRecorder, at pts: CMTime) {
        guard r.isReadyForVideo, let pool = r.pixelBufferPool else {
            r.dropped += 1
            return
        }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else {
            r.dropped += 1
            return
        }
        CVBufferPropagateAttachments(source, out) // garde la matrice BT.709
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(r.width) / size.width,
                                                              y: CGFloat(r.height) / size.height),
                                       highQualityDownsample: true)
        ciContext.render(scaled, to: out, bounds: CGRect(x: 0, y: 0, width: r.width, height: r.height), colorSpace: nil)
        r.appendVideo(out, at: pts)
    }

    private func updatePiP(_ image: CIImage, size: CGSize) {
        let s = 360 / size.height
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
        let rect = CGRect(x: 0, y: 0, width: (size.width * s).rounded(.down), height: 360)
        guard let cg = ciContext.createCGImage(small, from: rect, format: .RGBA8, colorSpace: srgb) else { return }
        DispatchQueue.main.async { self.pip.image = cg }
    }

    private func checkFailures() {
        guard !failureReported else { return }
        for r in [recH, recV].compactMap({ $0 }) where r.failed {
            failureReported = true
            let text = r.errorText
            DispatchQueue.main.async {
                self.post("Erreur d'écriture : \(text)")
                if self.isRecording { self.stopRecording() }
            }
            return
        }
    }
}
