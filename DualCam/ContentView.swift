import SwiftUI

struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            previewArea
            controls
                .frame(width: 84)
        }
        .padding(.vertical, 8)
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .bottom) { toast }
        .sheet(isPresented: $showSettings) { SettingsView(engine: engine) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            engine.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && engine.isRecording { engine.toggleRecording() }
            if phase == .active { engine.refreshMinutesLeft() }
        }
    }

    // MARK: Aperçu 16:9 + incrustation 9:16

    private var previewArea: some View {
        ZStack {
            CameraPreview(engine: engine)

            if engine.settings.vertical.enabled {
                GeometryReader { geo in
                    let w = geo.size.height * 9 / 16
                    Rectangle()
                        .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                        .frame(width: w, height: geo.size.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .allowsHitTesting(false)
            }

            VStack {
                badges
                Spacer()
                formatChips
            }
            .padding(10)
            .allowsHitTesting(false)

            if engine.settings.vertical.enabled {
                PiPView(model: engine.pip, angle: engine.captureAngle, recording: engine.isRecording)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 34)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(engine.isRecording ? Color.red : Color.clear, lineWidth: 3)
        )
    }

    private var badges: some View {
        HStack(spacing: 8) {
            badge {
                Circle().fill(engine.isRecording ? Color.red : Color.gray).frame(width: 8, height: 8)
                Text(timeString(engine.elapsed)).monospacedDigit()
            }
            badge {
                Image(systemName: "waveform")
                Text(engine.audioLabel)
            }
            if let m = engine.minutesLeft {
                badge {
                    Image(systemName: "internaldrive")
                    Text("\(m) min")
                }
            }
            if engine.thermalWarning {
                badge {
                    Image(systemName: "thermometer.high").foregroundStyle(.orange)
                }
            }
        }
    }

    private var formatChips: some View {
        HStack(spacing: 8) {
            let s = engine.settings
            if s.horizontal.enabled {
                badge {
                    Image(systemName: "rectangle")
                    Text("\(s.horizontal.resolution.label) · \(s.horizontal.codec.short)")
                }
            }
            if s.vertical.enabled {
                badge {
                    Image(systemName: "rectangle.portrait")
                    Text("\(s.vertical.resolution.label) · \(s.vertical.codec.short)")
                }
            }
            badge { Text("\(s.fps) i/s") }
            if engine.droppedFrames > 0 {
                badge {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("\(engine.droppedFrames) img perdues")
                }
            }
        }
    }

    private func badge<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
    }

    // MARK: Colonne de contrôles

    private var controls: some View {
        VStack(spacing: 28) {
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .disabled(engine.isRecording || engine.busy)
            .opacity(engine.isRecording ? 0.3 : 1)

            Spacer(minLength: 0)

            Button { engine.toggleRecording() } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                    RoundedRectangle(cornerRadius: engine.isRecording ? 6 : 29, style: .continuous)
                        .fill(Color.red)
                        .frame(width: engine.isRecording ? 28 : 58, height: engine.isRecording ? 28 : 58)
                    if engine.busy { ProgressView().tint(.white) }
                }
                .animation(.easeInOut(duration: 0.2), value: engine.isRecording)
            }
            .disabled(engine.busy)

            Button { engine.toggleLock() } label: {
                Image(systemName: engine.locked ? "lock.fill" : "lock.open")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(engine.locked ? Color.black : Color.white)
                    .frame(width: 48, height: 48)
                    .background(engine.locked ? Color.yellow : Color.white.opacity(0.15), in: Circle())
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var toast: some View {
        if let msg = engine.message {
            Text(msg)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.8), in: Capsule())
                .padding(.bottom, 16)
                .onTapGesture { engine.message = nil }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct PiPView: View {
    @ObservedObject var model: PiPModel
    let angle: CGFloat
    let recording: Bool

    var body: some View {
        ZStack {
            Color.black
            if let cg = model.image {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .rotationEffect(.degrees(angle))
            }
        }
        .frame(width: 96, height: 171)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(recording ? Color.red : Color.white.opacity(0.6), lineWidth: 2.5)
        )
        .shadow(radius: 6)
    }
}
