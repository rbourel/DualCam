import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: CameraEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                streamSection("Horizontal 16:9", icon: "rectangle",
                              stream: $engine.settings.horizontal, resolutions: [.uhd, .fhd, .hd],
                              size: engine.settings.horizontalSize)
                streamSection("Vertical 9:16", icon: "rectangle.portrait",
                              stream: $engine.settings.vertical, resolutions: [.fhd, .hd],
                              size: engine.settings.verticalSize)

                Section {
                    Picker("Cadence", selection: $engine.settings.fps) {
                        ForEach([24, 25, 30, 60], id: \.self) { Text("\($0) i/s").tag($0) }
                    }
                    Toggle("Stabilisation", isOn: $engine.settings.stabilization)
                    Toggle("Envoyer dans Photos", isOn: $engine.settings.saveToPhotos)
                } header: {
                    Text("Général")
                } footer: {
                    Text(engine.settings.saveToPhotos
                         ? "Les fichiers sont déplacés dans Photos à la fin de la prise."
                         : "Les fichiers restent dans Fichiers › Sur mon iPhone › DualCam.")
                }

                Section {
                    LabeledContent("Débit total", value: String(format: "≈ %.0f Mb/s", engine.settings.totalMbps()))
                    LabeledContent("Par minute", value: String(format: "≈ %.1f Go", engine.settings.totalMbps() * 60 / 8 / 1000))
                    if !engine.sourceLabel.isEmpty {
                        LabeledContent("Source", value: engine.sourceLabel)
                    }
                } footer: {
                    Text(engine.proResSupported
                         ? "Le vertical est recadré au centre de l'image 4K (1215×2160), donc 1080×1920 reste natif. Deux flux ProRes 4K simultanés peuvent dépasser les capacités de l'iPhone : en cas d'images perdues, passe le vertical en HEVC."
                         : "ProRes ne semble pas disponible sur cet iPhone (iPhone 13 Pro ou plus récent requis).")
                }
            }
            .navigationTitle("Formats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
    }

    private func streamSection(_ title: String, icon: String, stream: Binding<StreamSettings>,
                               resolutions: [StreamResolution], size: (Int, Int)) -> some View {
        Section {
            Toggle(isOn: stream.enabled) { Label(title, systemImage: icon) }
            if stream.wrappedValue.enabled {
                Picker("Codec", selection: stream.codec) {
                    ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
                }
                Picker("Résolution", selection: stream.resolution) {
                    ForEach(resolutions) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Fichier", value: String(format: "%d×%d · ≈ %.0f Mb/s", size.0, size.1,
                                                        stream.wrappedValue.codec.mbps(width: size.0, height: size.1, fps: engine.settings.fps)))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
