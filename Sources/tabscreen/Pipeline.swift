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
            name: "TabScreen", width: options.width, height: options.height,
            refreshRate: Double(options.fps), hiDPI: options.hiDPI)
        self.display = display
        if !display.selectMode(width: options.width, height: options.height, hiDPI: options.hiDPI) {
            print("⚠️  No se pudo activar el modo \(options.width)x\(options.height)\(options.hiDPI ? " HiDPI" : ""); se usa el que eligió macOS")
        }

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
