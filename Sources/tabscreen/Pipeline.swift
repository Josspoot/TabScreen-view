import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum PipelineError: LocalizedError {
    case displayNotFound

    var errorDescription: String? {
        "La pantalla virtual no apareció en ScreenCaptureKit"
    }
}

/// Pantalla virtual → captura → codificador → servidor.
///
/// Se codifica a un ritmo constante (`fps`) reutilizando el último cuadro
/// capturado: así el reproductor MSE de la tablet recibe un flujo continuo
/// aunque la pantalla esté quieta, y una tablet nueva recibe imagen al instante.
final class Pipeline {
    private let options: Options
    private let server: Server
    private(set) var display: VirtualDisplay?
    private let capturer = ScreenCapturer()
    private var captureSize = (width: 0, height: 0)
    private var resolution = (width: 0, height: 0, hiDPI: false)   // solo en main

    private let encodeQueue = DispatchQueue(label: "tabscreen.encode", qos: .userInteractive)
    private var encoder: H264Encoder?      // solo en encodeQueue
    private var forceKeyframe = true       // solo en encodeQueue
    private var timers: [DispatchSourceTimer] = []

    private let bufferLock = NSLock()
    private var latestBuffer: CVPixelBuffer?

    private let statsLock = NSLock()
    private var statFrames = 0
    private var statBytes = 0

    init(options: Options, server: Server) {
        self.options = options
        self.server = server
    }

    @MainActor
    func start() async throws {
        let display = try VirtualDisplay(
            name: "TabScreen",
            maxWidth: options.autoResolution ? Options.maxAutoWidth : options.width,
            maxHeight: options.autoResolution ? Options.maxAutoHeight : options.height,
            refreshRate: Double(options.fps))
        self.display = display
        try display.setResolution(width: options.width, height: options.height, hiDPI: options.hiDPI)
        resolution = (options.width, options.height, options.hiDPI)

        let scDisplay = try await waitForShareableDisplay(display.displayID)
        let size = display.currentPixelSize ?? (options.width, options.height)
        captureSize = size

        capturer.onFrame = { [weak self] pixelBuffer in
            guard let self else { return }
            self.bufferLock.lock()
            self.latestBuffer = pixelBuffer
            self.bufferLock.unlock()
        }
        try await capturer.start(display: scDisplay, width: size.width, height: size.height, fps: options.fps)

        startFrameTimer()
        startModeWatcher()
        startStatsTimer()
    }

    func requestKeyframe() {
        encodeQueue.async { self.forceKeyframe = true }
    }

    /// En modo automático la pantalla virtual adopta la resolución física de
    /// la tablet. En tablets de alta densidad usa HiDPI para que el texto no
    /// se vea diminuto. La captura y el codificador se adaptan solos.
    func adapt(toTabletWidth tabletWidth: Int, height tabletHeight: Int) {
        DispatchQueue.main.async {
            guard let display = self.display else { return }
            guard self.options.autoResolution else {
                if (tabletWidth, tabletHeight) != (self.resolution.width, self.resolution.height) {
                    print("   Para máxima nitidez usa: --res \(tabletWidth)x\(tabletHeight)")
                }
                return
            }

            let scale = min(1, Double(Options.maxAutoWidth) / Double(tabletWidth),
                            Double(Options.maxAutoHeight) / Double(tabletHeight))
            let width = Int(Double(tabletWidth) * scale) / 4 * 4
            let height = Int(Double(tabletHeight) * scale) / 4 * 4
            let hiDPI = self.options.hiDPI || max(width, height) >= 2400
            guard width >= 640, height >= 480, (width, height, hiDPI) != self.resolution else { return }

            do {
                try display.setResolution(width: width, height: height, hiDPI: hiDPI)
                self.resolution = (width, height, hiDPI)
                let looksLike = hiDPI ? " (HiDPI, se ve como \(width / 2)x\(height / 2))" : ""
                print("📐 Pantalla virtual ajustada a la tablet: \(width)x\(height)\(looksLike)")
            } catch {
                print("⚠️  No se pudo ajustar la resolución: \(error.localizedDescription)")
            }
        }
    }

    private func waitForShareableDisplay(_ id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<25 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == id }) { return display }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw PipelineError.displayNotFound
    }

    // MARK: - Codificación

    private func startFrameTimer() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: encodeQueue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / options.fps), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        timers.append(timer)
    }

    private func tick() {
        guard server.clientCount > 0 else {
            // Sin tablets no gastamos energía codificando.
            encoder = nil
            forceKeyframe = true
            return
        }
        bufferLock.lock()
        let pixelBuffer = latestBuffer
        bufferLock.unlock()
        guard let pixelBuffer else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if encoder?.width != width || encoder?.height != height {
            do {
                encoder = try makeEncoder(width: width, height: height)
            } catch {
                print("❌ \(error.localizedDescription)")
                encoder = nil
                return
            }
            forceKeyframe = true
        }

        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        encoder?.encode(pixelBuffer, pts: pts, forceKeyframe: forceKeyframe)
        forceKeyframe = false
    }

    private func makeEncoder(width: Int, height: Int) throws -> H264Encoder {
        let fps = options.fps
        let encoder = try H264Encoder(width: width, height: height, fps: fps,
                                      bitrate: options.bitrate(width: width, height: height))
        encoder.onParameterSets = { [weak self] sps, pps in
            self?.server.broadcastConfig(width: width, height: height, fps: fps, sps: sps, pps: pps)
        }
        encoder.onFrame = { [weak self] frame in
            guard let self else { return }
            self.server.broadcastFrame(frame)
            self.statsLock.lock()
            self.statFrames += 1
            self.statBytes += frame.data.count
            self.statsLock.unlock()
        }
        return encoder
    }

    // MARK: - Resolución y estadísticas

    /// Si el usuario cambia la resolución en Ajustes → Pantallas, la captura
    /// (y con ella el codificador y la tablet) se adapta sola.
    private func startModeWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let size = self.display?.currentPixelSize,
                  size.width != self.captureSize.width || size.height != self.captureSize.height
            else { return }
            self.captureSize = size
            print("🔁 Resolución cambiada a \(size.width)x\(size.height)")
            Task {
                do {
                    try await self.capturer.update(width: size.width, height: size.height, fps: self.options.fps)
                } catch {
                    print("⚠️  No se pudo actualizar la captura: \(error.localizedDescription)")
                }
            }
        }
        timer.resume()
        timers.append(timer)
    }

    private func startStatsTimer() {
        let interval = 10.0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.statsLock.lock()
            let frames = self.statFrames, bytes = self.statBytes
            self.statFrames = 0
            self.statBytes = 0
            self.statsLock.unlock()
            guard self.server.clientCount > 0 else { return }
            let fps = Double(frames) / interval
            let mbps = Double(bytes * 8) / interval / 1_000_000
            print(String(format: "📊 %.0f fps · %.1f Mbps · %dx%d", fps, mbps, self.captureSize.width, self.captureSize.height))        }
        timer.resume()
        timers.append(timer)
    }
}
