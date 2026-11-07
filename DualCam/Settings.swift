import AVFoundation

enum VideoCodecChoice: String, Codable, CaseIterable, Identifiable {
    case proRes422HQ, proRes422, proRes422LT, proRes422Proxy, hevc, h264

    var id: String { rawValue }

    var label: String {
        switch self {
        case .proRes422HQ: "ProRes 422 HQ"
        case .proRes422: "ProRes 422"
        case .proRes422LT: "ProRes 422 LT"
        case .proRes422Proxy: "ProRes Proxy"
        case .hevc: "HEVC (H.265)"
        case .h264: "H.264"
        }
    }

    var short: String {
        switch self {
        case .proRes422HQ: "ProRes HQ"
        case .proRes422: "ProRes"
        case .proRes422LT: "ProRes LT"
        case .proRes422Proxy: "Proxy"
        case .hevc: "HEVC"
        case .h264: "H.264"
        }
    }

    var codecType: AVVideoCodecType {
        switch self {
        case .proRes422HQ: .proRes422HQ
        case .proRes422: .proRes422
        case .proRes422LT: .proRes422LT
        case .proRes422Proxy: .proRes422Proxy
        case .hevc: .hevc
        case .h264: .h264
        }
    }

    var isProRes: Bool { self != .hevc && self != .h264 }

    /// Débit de référence en Mb/s pour 1920×1080 à 29,97 i/s
    /// (ProRes : livre blanc Apple ; HEVC/H.264 : débit cible choisi par l'app).
    private var baseMbps: Double {
        switch self {
        case .proRes422HQ: 220
        case .proRes422: 147
        case .proRes422LT: 102
        case .proRes422Proxy: 45
        case .hevc: 14
        case .h264: 20
        }
    }

    func mbps(width: Int, height: Int, fps: Int) -> Double {
        baseMbps * Double(width * height) / (1920.0 * 1080.0) * Double(fps) / 30.0
    }
}

enum StreamResolution: String, Codable, CaseIterable, Identifiable {
    case uhd, fhd, hd

    var id: String { rawValue }
    var label: String {
        switch self {
        case .uhd: "4K"
        case .fhd: "1080p"
        case .hd: "720p"
        }
    }
    var longSide: Int {
        switch self {
        case .uhd: 3840
        case .fhd: 1920
        case .hd: 1280
        }
    }
    var shortSide: Int {
        switch self {
        case .uhd: 2160
        case .fhd: 1080
        case .hd: 720
        }
    }
}

struct StreamSettings: Codable, Equatable {
    var enabled: Bool
    var codec: VideoCodecChoice
    var resolution: StreamResolution
}

struct CaptureSettings: Codable, Equatable {
    var horizontal = StreamSettings(enabled: true, codec: .hevc, resolution: .uhd)
    var vertical = StreamSettings(enabled: true, codec: .hevc, resolution: .fhd)
    var fps = 30
    var stabilization = true
    var saveToPhotos = true

    /// Dimensions (largeur, hauteur) de chaque fichier produit
    var horizontalSize: (Int, Int) { (horizontal.resolution.longSide, horizontal.resolution.shortSide) }
    var verticalSize: (Int, Int) { (vertical.resolution.shortSide, vertical.resolution.longSide) }

    func totalMbps() -> Double {
        var total = 0.0
        if horizontal.enabled {
            let (w, h) = horizontalSize
            total += horizontal.codec.mbps(width: w, height: h, fps: fps) + (horizontal.codec.isProRes ? 2.3 : 0.25)
        }
        if vertical.enabled {
            let (w, h) = verticalSize
            total += vertical.codec.mbps(width: w, height: h, fps: fps) + (vertical.codec.isProRes ? 2.3 : 0.25)
        }
        return total
    }

    private static let key = "captureSettings"

    static func load() -> CaptureSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(CaptureSettings.self, from: data) else { return CaptureSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
