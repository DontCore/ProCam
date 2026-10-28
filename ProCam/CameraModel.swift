import AVFoundation
import UIKit
import Photos

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo = "Фото"
    case video = "Видео"
    var id: String { rawValue }
}

enum AspectRatio: String, CaseIterable, Identifiable {
    case r4x3 = "4:3"
    case r16x9 = "16:9"
    case r1x1 = "1:1"
    var id: String { rawValue }

    var ratioValue: CGFloat {
        switch self {
        case .r4x3: return 4.0 / 3.0
        case .r16x9: return 16.0 / 9.0
        case .r1x1: return 1.0
        }
    }

    /// Размер центрального кропа под эту пропорцию из нативного кадра.
    func cropSize(for native: CGSize) -> CGSize {
        let nativeRatio = native.width / max(native.height, 1)
        if nativeRatio > ratioValue {
            return CGSize(width: native.height * ratioValue, height: native.height)
        }
        return CGSize(width: native.width, height: native.width / ratioValue)
    }
}

final class CameraModel: NSObject, ObservableObject {
    static let shared = CameraModel()

    let session = AVCaptureSession()

    @Published var mode: CaptureMode = .video { didSet { scheduleConfigure() } }
    @Published var ratio: AspectRatio = .r16x9
    @Published var fps = 60 { didSet { if mode == .video { scheduleConfigure() } } }
    @Published var position: AVCaptureDevice.Position = .back { didSet { scheduleConfigure() } }
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var statusText = "Готово"
    @Published var captureDescription = ""

    private let sessionQueue = DispatchQueue(label: "procam.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var input: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var configuredKey = ""

    private init() {
        super.init()
        scheduleConfigure()
    }

    /// Публичный запуск переконфигурации (например, из onAppear).
    func configure() {
        configuredKey = "" // форс-перенастройка
        scheduleConfigure()
    }

    func setOrientation(_ orientation: AVCaptureVideoOrientation) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if let conn = self.photoOutput.connection(with: .video), conn.isVideoOrientationSupported {
                conn.videoOrientation = orientation
            }
            if let conn = self.movieOutput.connection(with: .video), conn.isVideoOrientationSupported, self.isRecording == false {
                conn.videoOrientation = orientation
            }
        }
        DispatchQueue.main.async { self.statusText = "Ориентация: \(orientationLabel(orientation))" }
    }

    private func orientationLabel(_ o: AVCaptureVideoOrientation) -> String {
        switch o {
        case .portrait: return "вертикальная"
        case .landscapeLeft, .landscapeRight: return "горизонтальная"
        case .portraitUpsideDown: return "вертикальная (перевёрнутая)"
        default: return "авто"
        }
    }

    // MARK: - Конфигурация сессии

    private func scheduleConfigure() {
        sessionQueue.async { [weak self] in self?.configureLocked() }
    }

    private func configureLocked() {
        let mode = mode
        let position = position
        let fps = fps
        let key = "\(mode)|\(position.rawValue)|\(fps)"
        guard key != configuredKey else { return }
        configuredKey = key

        session.beginConfiguration()
        session.sessionPreset = mode == .photo ? .photo : .inputPriority

        if let input = input { session.removeInput(input); self.input = nil }
        if let audioInput = audioInput { session.removeInput(audioInput); self.audioInput = nil }
        if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
        if session.outputs.contains(photoOutput) { session.removeOutput(photoOutput) }

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
        guard let device = device else {
            session.commitConfiguration()
            setStatusMain("Камера недоступна")
            return
        }

        do {
            let deviceInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(deviceInput) else {
                throw NSError(domain: "procam", code: -1)
            }
            session.addInput(deviceInput)
            input = deviceInput
        } catch {
            session.commitConfiguration()
            setStatusMain("Не удалось подключить камеру")
            return
        }

        var description = ""

        if mode == .video {
            let (format, chosenFps) = Self.pickFormat(device: device, fps: fps)
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(chosenFps))
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
                device.unlockForConfiguration()
            } catch {
                setStatusMain("Конфигурация камеры не удалась")
            }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            description = "видео \(dims.width)×\(dims.height) @ \(chosenFps) fps"

            if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
            if let conn = movieOutput.connection(with: .video) {
                if conn.isVideoOrientationSupported { conn.videoOrientation = currentVideoOrientation() }
                if conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = (position == .front)
                }
            }
            if let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(micInput) {
                session.addInput(micInput)
                audioInput = micInput
            }
        } else {
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            photoOutput.maxPhotoQualityPrioritization = .balanced
            if let conn = photoOutput.connection(with: .video) {
                if conn.isVideoOrientationSupported { conn.videoOrientation = currentVideoOrientation() }
                if conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = (position == .front)
                }
            }
            description = "фото, кроп \(ratio.rawValue)"
        }

        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        setStatusMain(description)
    }

    private func currentVideoOrientation() -> AVCaptureVideoOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .landscapeRight // камера компенсирует поворот
        case .landscapeRight: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    private func setStatusMain(_ text: String) {
        DispatchQueue.main.async {
            self.statusText = text
            self.captureDescription = text
        }
    }

    /// Формат с минимальным запасом по разрешению и поддержкой fps (как в GiveSharing).
    private static func pickFormat(device: AVCaptureDevice, fps: Int) -> (AVCaptureDevice.Format, Int) {
        var best: AVCaptureDevice.Format?
        var bestFps = 30
        var bestScore = Int.max
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let h = Int(dims.height)
            guard h >= 1080 else { continue }
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let chosen = fps <= Int(maxRate) ? fps : max(24, Int(maxRate))
            let score = h + (chosen >= fps ? 0 : 1000)
            if score < bestScore {
                bestScore = score
                best = format
                bestFps = chosen
            }
        }
        if let best = best { return (best, bestFps) }
        let maxRate = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        return (device.activeFormat, fps <= Int(maxRate) ? fps : max(24, Int(maxRate)))
    }

    // MARK: - Фото

    func capturePhoto() {
        guard mode == .photo else { return }
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Видео

    func toggleRecording() {
        if isRecording {
            movieOutput.stopRecording()
            return
        }
        guard mode == .video, movieOutput.connection(with: .video) != nil else { return }
        if let conn = movieOutput.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = currentVideoOrientation()
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("procam_\(Int(Date().timeIntervalSince1970)).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    // MARK: - Сохранение в медиатеку

    private func saveToPhotos(url: URL, completion: @escaping (String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion("Нет доступа к медиатеке (Настройки → Конфиденциальность → Фото)")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                if url.pathExtension == "mov" {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAsset(from: UIImage(contentsOfFile: url.path) ?? UIImage())
                }
            }) { ok, _ in
                completion(ok ? "Сохранено в медиатеку" : "Не удалось сохранить")
            }
        }
    }
}

// MARK: - Фото делегат

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil,
              let cgImage = photo.cgImageRepresentation() else {
            setStatusMain("Снимок не удался")
            return
        }
        let native = CGSize(width: cgImage.width, height: cgImage.height)
        let crop = ratio.cropSize(for: native)
        let rect = CGRect(
            x: (native.width - crop.width) / 2,
            y: (native.height - crop.height) / 2,
            width: crop.width, height: crop.height)
        let cropped = cgImage.cropping(to: rect) ?? cgImage

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("procam_\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
        guard let data = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.95),
              (try? data.write(to: url)) != nil else {
            setStatusMain("Не удалось записать снимок")
            return
        }
        setStatusMain("Обработка снимка…")
        saveToPhotos(url: url) { [weak self] message in
            try? FileManager.default.removeItem(at: url)
            self?.setStatusMain(message)
        }
    }
}

// MARK: - Видео делегат + кроп-экспорт

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.isRecording = true }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async { self.isRecording = false }
        guard error == nil else {
            setStatusMain("Запись прервана: \(error!.localizedDescription)")
            return
        }
        exportCropped(url: outputFileURL, ratio: ratio)
    }

    /// Кадрирует записанный ролик под выбранную пропорцию и сохраняет в медиатеку.
    private func exportCropped(url: URL, ratio: AspectRatio) {
        setStatusMain("Обработка видео…")
        DispatchQueue.main.async { self.isProcessing = true }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: String
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first else {
                result = "В видео нет видеодорожки"
            } else {
                let transform = track.preferredTransform
                let orientedRect = CGRect(origin: .zero, size: track.naturalSize).applying(transform)
                let oriented = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
                let target = ratio.cropSize(for: oriented)

                // 16:9 без поворота — экспорт не нужен, сохраняем как есть
                let isAlreadyFine = ratio == .r16x9
                    && abs(oriented.width / oriented.height - 16.0 / 9.0) < 0.01
                    && abs(transform.b) < 0.01

                if isAlreadyFine {
                    result = "Экспорт без изменений"
                    self?.saveToPhotos(url: url) { message in
                        try? FileManager.default.removeItem(at: url)
                        self?.finishProcessing(message)
                    }
                } else {
                    let angle = atan2(transform.b, transform.a)
                    let scale = max(target.width / oriented.width, target.height / oriented.height)

                    let composition = AVMutableVideoComposition()
                    composition.renderSize = target
                    composition.frameDuration = CMTime(value: 1, timescale: 60)

                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

                    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                    var matrix = CGAffineTransform(translationX: target.width / 2, y: target.height / 2)
                    matrix = matrix.rotated(by: angle)
                    matrix = matrix.scaledBy(x: scale, y: scale)
                    matrix = matrix.translatedBy(x: -track.naturalSize.width / 2, y: -track.naturalSize.height / 2)
                    layerInstruction.setTransform(matrix, at: .zero)
                    instruction.layerInstructions = [layerInstruction]
                    composition.instructions = [instruction]

                    let outUrl = FileManager.default.temporaryDirectory
                        .appendingPathComponent("procam_out_\(Int(Date().timeIntervalSince1970 * 1000)).mov")
                    try? FileManager.default.removeItem(at: outUrl)
                    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                        result = "Экспорт недоступен"
                    } else {
                        export.videoComposition = composition
                        export.outputFileType = .mov
                        export.outputURL = outUrl
                        export.exportAsynchronously {
                            let message: String
                            if export.status == .completed {
                                message = "Готово (\(ratio.rawValue))"
                            } else {
                                message = "Ошибка экспорта: \(export.error?.localizedDescription ?? "?")"
                            }
                            if export.status == .completed {
                                self?.saveToPhotos(url: outUrl) { saved in
                                    try? FileManager.default.removeItem(at: outUrl)
                                    try? FileManager.default.removeItem(at: url)
                                    self?.finishProcessing(saved)
                                }
                            } else {
                                self?.finishProcessing(message)
                            }
                        }
                        result = "" // завершится в колбэке
                    }
                }
                if !result.isEmpty { self?.finishProcessing(result) }
            }
        }
    }

    private func finishProcessing(_ message: String) {
        DispatchQueue.main.async {
            self.isProcessing = false
            self.statusText = message
        }
    }
}
