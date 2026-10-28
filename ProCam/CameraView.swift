import SwiftUI
import AVFoundation
import UIKit

struct CameraView: View {
    @StateObject private var camera = CameraModel.shared
    @State private var deviceOrientation: UIDeviceOrientation = .portrait

    private let orientationPublisher = NotificationCenter.default
        .publisher(for: UIDevice.orientationDidChangeNotification)

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()
                .background(Color.black)

            // Затемнение за пределами выбранной пропорции
            RatioOverlay(ratio: camera.ratio)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                Text(camera.statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(6)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
                    .padding(.bottom, 4)
                controls
            }
        }
        .onAppear { camera.configure() }
        .onReceive(orientationPublisher) { _ in
            let o = UIDevice.current.orientation
            guard o.isValidInterfaceOrientation else { return }
            deviceOrientation = o
            camera.setOrientation(orientationMapping(o))
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(AspectRatio.allCases) { r in
                    Button(r.rawValue) { camera.ratio = r }
                }
            } label: {
                labelChip(text: camera.ratio.rawValue, icon: "aspectratio")
            }
            if camera.mode == .video {
                Menu {
                    ForEach([30, 60], id: \.self) { f in
                        Button("\(f) fps") { camera.fps = f }
                    }
                } label: {
                    labelChip(text: "\(camera.fps) fps", icon: "speedometer")
                }
            }
            Spacer()
            if camera.isProcessing {
                ProgressView().tint(.white)
            }
        }
        .padding(.horizontal)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            Picker("Режим", selection: $camera.mode) {
                ForEach(CaptureMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .disabled(camera.isRecording || camera.isProcessing)

            HStack {
                // Левая кнопка-заглушка (медиатека позже)
                Color.clear.frame(width: 56, height: 56)

                Button {
                    if camera.mode == .photo {
                        camera.capturePhoto()
                    } else {
                        camera.toggleRecording()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 4)
                            .frame(width: 74, height: 74)
                        if camera.mode == .video && camera.isRecording {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red)
                                .frame(width: 32, height: 32)
                        } else {
                            Circle().fill(Color.white).frame(width: 62, height: 62)
                        }
                    }
                }
                .disabled(camera.isProcessing)

                Button {
                    guard !camera.isRecording else { return }
                    camera.position = camera.position == .back ? .front : .back
                } label: {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.25)).frame(width: 56, height: 56)
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                }
                .disabled(camera.isRecording || camera.isProcessing)
            }
        }
        .padding(.bottom, 24)
    }

    private func labelChip(text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.subheadline.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.45))
        .clipShape(Capsule())
    }

    private func orientationMapping(_ o: UIDeviceOrientation) -> AVCaptureVideoOrientation {
        switch o {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }
}

/// Затемняет зоны вне выбранной пропорции (как в штатной камере).
struct RatioOverlay: View {
    let ratio: AspectRatio

    var body: some View {
        GeometryReader { geo in
            let screen = geo.size
            let frame = Self.overlayFrame(screen: screen, ratioValue: ratio.ratioValue)
            let x = (screen.width - frame.width) / 2
            let y = (screen.height - frame.height) / 2
            Path { p in
                p.addRect(CGRect(origin: .zero, size: screen))
                p.addRect(CGRect(x: x, y: y, width: frame.width, height: frame.height))
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
        }
    }

    static func overlayFrame(screen: CGSize, ratioValue: CGFloat) -> CGSize {
        let screenRatio = screen.width / max(screen.height, 1)
        if screenRatio > ratioValue {
            return CGSize(width: screen.height * ratioValue, height: screen.height)
        }
        return CGSize(width: screen.width, height: screen.width / ratioValue)
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
