import AVFoundation

enum RecorderError: LocalizedError {
    case unsupported(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unsupported(let what): "\(what) non supporté sur cet iPhone"
        case .empty: "Aucune image enregistrée"
        }
    }
}

/// Un fichier .mov en cours d'écriture (un par orientation).
/// Toutes les méthodes sont appelées depuis la file de traitement vidéo.
final class StreamRecorder {
    let url: URL
    let width: Int
    let height: Int
    var dropped = 0

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private var started = false
    private var startTime = CMTime.zero

    init(url: URL, width: Int, height: Int, codec: VideoCodecChoice, fps: Int,
         transform: CGAffineTransform, audioFormat: CMFormatDescription?) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        var video: [String: Any] = [
            AVVideoCodecKey: codec.codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !codec.isProRes {
            var props: [String: Any] = [
                AVVideoAverageBitRateKey: Int(codec.mbps(width: width, height: height, fps: fps) * 1_000_000),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
            ]
            if codec == .h264 {
                props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            video[AVVideoCompressionPropertiesKey] = props
        }
        guard writer.canApply(outputSettings: video, forMediaType: .video) else {
            throw RecorderError.unsupported("\(codec.label) \(width)×\(height)")
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
        guard writer.canAdd(videoInput) else { throw RecorderError.unsupported(codec.label) }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let fmt = audioFormat, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
            let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
            let audio: [String: Any] = codec.isProRes
                ? [ // PCM 24 bits, comme la caméra native en ProRes
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                : [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: channels == 2 ? 256_000 : 128_000,
                ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audio, sourceFormatHint: fmt)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.unsupported(codec.label)
        }

        self.url = url
        self.width = width
        self.height = height
        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.audioInput = audioInput
    }

    var pixelBufferPool: CVPixelBufferPool? { adaptor.pixelBufferPool }
    var isReadyForVideo: Bool { writer.status == .writing && videoInput.isReadyForMoreMediaData }
    var failed: Bool { writer.status == .failed }
    var errorText: String { writer.error?.localizedDescription ?? "erreur inconnue" }

    func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) {
        guard writer.status == .writing else { return }
        if !started {
            writer.startSession(atSourceTime: time)
            startTime = time
            started = true
        }
        guard videoInput.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: time) else {
            dropped += 1
            return
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard let audioInput, started, writer.status == .writing else { return }
        guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), startTime) >= 0 else { return }
        if audioInput.isReadyForMoreMediaData {
            audioInput.append(sample)
        }
    }

    func finish(_ done: @escaping (Error?) -> Void) {
        guard writer.status == .writing else {
            done(writer.error ?? RecorderError.empty)
            return
        }
        guard started else {
            writer.cancelWriting()
            done(RecorderError.empty)
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let writer = self.writer
        writer.finishWriting {
            done(writer.status == .completed ? nil : (writer.error ?? RecorderError.empty))
        }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
