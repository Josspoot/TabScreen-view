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
    private let store: Store
    private(set) var display: VirtualDisplay?     // solo en main
    private(set) var position: DisplayPosition   // solo en main
    private let capturer = ScreenCapturer()
    private var displayPixelSize = (width: 0, height: 0)   // solo en main
    private var captureSize = (width: 0, height: 0)        // tamaño del video
    private var displayWork: Task<Void, Never>?   // solo en main

    private let encodeQueue = DispatchQueue(label: "tabscreen.encode", qos: .userInteractive)
    private var encoder: H264Encoder?      // solo en encodeQueue
    private var forceKeyframe = true       // solo en encodeQueue
    private var timers: [DispatchSourceTimer] = []

    private let bufferLock = NSLock()
    private var latestBuffer: CVPixelBuffer?

    private let statsLock = NSLock()
    private var statFrames = 0
    private var statBytes = 0

    init(options: Options, server: Server, store: Store) {
        self.options = options
        self.server = server
        self.store = store
        self.position = options.position ?? store.position ?? .right
    }

    /// Con --res la pantalla virtual se crea ya; en modo automático se crea
    /// cuando se conecta la tablet, directamente con su resolución.
    @MainActor
    func start() async throws {
        capturer.onFrame = { [weak self] pixelBuffer in self?.setLatestBuffer(pixelBuffer) }
        server.broadcastPosition(position)
        if !options.autoResolution {
            try await showDisplay(width: options.width, height: options.height, hiDPI: options.hiDPI)
        }
        startFrameTimer()
        startModeWatcher()
        startStatsTimer()
    }

    func requestKeyframe() {
        encodeQueue.async { self.forceKeyframe = true }
    }

    /// En modo automático la pantalla virtual adopta la resolución física de
    /// la tablet. En tablets de alta densidad usa HiDPI para que el texto no
    /// se vea diminuto.
    func adapt(toTabletWidth tabletWidth: Int, height tabletHeight: Int) {
        enqueueDisplayWork {
            guard self.options.autoResolution else {
                if (tabletWidth, tabletHeight) != (self.options.width, self.options.height) {
                    print("   Para máxima nitidez usa: --res \(tabletWidth)x\(tabletHeight)")
                }
                return
            }

            let scale = min(1, Double(Options.maxAutoWidth) / Double(tabletWidth),
                            Double(Options.maxAutoHeight) / Double(tabletHeight))
            let width = Int(Double(tabletWidth) * scale) / 4 * 4
            let height = Int(Double(tabletHeight) * scale) / 4 * 4
            let hiDPI = self.options.hiDPI || max(width, height) >= 2400
            guard width >= 640, height >= 480 else { return }

            do {
                let replaced = self.display != nil
                guard try await self.showDisplay(width: width, height: height, hiDPI: hiDPI) else { return }
                let looksLike = hiDPI ? " (HiDPI, se ve como \(width / 2)x\(height / 2))" : ""
                print("🖥  Pantalla virtual \(replaced ? "recreada" : "creada") para la tablet: \(width)x\(height)\(looksLike)"
                      + " · video \(self.captureSize.width)x\(self.captureSize.height)")
            } catch {
                print("❌ No se pudo crear la pantalla virtual: \(error.localizedDescription)")
            }
        }
    }

    /// Mueve la pantalla virtual a otro lado de la principal y lo recuerda.
    func place(_ position: DisplayPosition) {
        enqueueDisplayWork {
            self.position = position
            self.store.position = position
            await self.display?.place(position)
            self.server.broadcastPosition(position)
            print("↔️  Pantalla TabScreen \(position.label) de la principal")
        }
    }

    // MARK: - Pantalla virtual

    /// Crea (o recrea con otra resolución) la pantalla virtual, la acomoda y
    /// empieza a capturarla. Devuelve false si ya tenía esa resolución.
    @MainActor
    @discardableResult
    private func showDisplay(width: Int, height: Int, hiDPI: Bool) async throws -> Bool {
        if let display, display.width == width, display.height == height, display.hiDPI == hiDPI {
            return false
        }
        if display != nil {
            await capturer.stop()
            display = nil // al liberarla, macOS la quita
            setLatestBuffer(nil)
        }

        let display = try VirtualDisplay(name: "TabScreen", width: width, height: height, hiDPI: hiDPI,
                                         refreshRate: Double(options.fps))
        self.display = display
        await display.activateMode()
        await display.place(position)

        let scDisplay = try await waitForShareableDisplay(display.displayID)
        displayPixelSize = display.currentPixelSize ?? (width, height)
        captureSize = streamSize(for: displayPixelSize)
        try await capturer.start(display: scDisplay, width: captureSize.width, height: captureSize.height, fps: options.fps)
        return true
    }

    /// Tamaño del video: el de la pantalla, salvo que pase de ~1920x1200;
    /// entonces se reduce y la tablet lo reescala. Decodificar 2880x1800 a
    /// 60 fps en el navegador satura a muchas tablets y genera retraso.
    private func streamSize(for size: (width: Int, height: Int)) -> (width: Int, height: Int) {
        guard !options.fullResolution else { return size }
        let scale = min(1, (Double(Options.maxStreamPixels) / Double(size.width * size.height)).squareRoot())
        return (Int(Double(size.width) * scale) / 2 * 2, Int(Double(size.height) * scale) / 2 * 2)
    }

    private func setLatestBuffer(_ pixelBuffer: CVPixelBuffer?) {
        bufferLock.lock()
        latestBuffer = pixelBuffer
        bufferLock.unlock()
    }

    /// Los cambios de pantalla y de ubicación se ejecutan en fila: si se
    /// mezclan, la ubicación se calcula con el tamaño viejo de la pantalla.
    private func enqueueDisplayWork(_ work: @escaping @MainActor () async -> Void) {
        DispatchQueue.main.async {
            let previous = self.displayWork
            self.displayWork = Task { @MainActor in
                await previous?.value
                await work()
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
                  size.width != self.displayPixelSize.width || size.height != self.displayPixelSize.height
            else { return }
            self.displayPixelSize = size
            let stream = self.streamSize(for: size)
            self.captureSize = stream
            print("🔁 Resolución cambiada a \(size.width)x\(size.height) (video \(stream.width)x\(stream.height))")
            Task {
                do {
                    try await self.capturer.update(width: stream.width, height: stream.height, fps: self.options.fps)
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
            print(String(format: "📊 Mac: %.0f fps · %.1f Mbps · video %dx%d", fps, mbps, self.captureSize.width, self.captureSize.height))
        }
        timer.resume()
        timers.append(timer)
    }
}
