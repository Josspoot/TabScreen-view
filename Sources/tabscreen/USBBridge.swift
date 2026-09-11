import Foundation

/// Conexión por cable USB con `adb` (Android platform-tools).
///
/// Cuando se conecta una tablet con la depuración USB activada, crea un túnel
/// (`adb reverse`) para que la tablet llegue a este servidor como localhost y
/// abre TabScreen en su Chrome. Así el video no pasa por el Wi-Fi y, como
/// localhost es un contexto seguro, la página puede usar WebCodecs.
final class USBBridge {
    private let adbPath: String?
    private let port: UInt16
    private let token: String
    private let queue = DispatchQueue(label: "tabscreen.usb")
    private var timer: DispatchSourceTimer?
    private var states: [String: String] = [:]   // serial → estado según adb; solo en queue

    init(port: UInt16, token: String, enabled: Bool) {
        self.port = port
        self.token = token
        self.adbPath = enabled ? Self.findADB() : nil
    }

    var isAvailable: Bool { adbPath != nil }

    func start() {
        guard adbPath != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        guard let output = adb(["devices"]) else { return }
        var current: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }
            current[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        for (serial, state) in current where states[serial] != state {
            switch state {
            case "device": open(on: serial)
            case "unauthorized": print("🔌 Tablet conectada por USB: en la tablet acepta «¿Permitir la depuración por USB?»")
            default: break
            }
        }
        for serial in states.keys where current[serial] == nil {
            print("🔌 Tablet desconectada del USB")
        }
        states = current
    }

    private func open(on serial: String) {
        guard adb(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"]) != nil else {
            print("⚠️  No se pudo crear el túnel USB con la tablet")
            return
        }
        let model = adb(["-s", serial, "shell", "getprop", "ro.product.model"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        print("🔌 \(model.isEmpty ? "Tablet" : model) conectada por USB: abriendo TabScreen en la tablet…")

        // `adb shell` pasa el comando a un shell remoto, por eso el URL va entre comillas.
        let url = "http://localhost:\(port)/?t=\(token)"
        let intent = "am start -a android.intent.action.VIEW -d '\(url)'"
        let result = adb(["-s", serial, "shell", intent + " -p com.android.chrome"])
        if result == nil || result?.contains("Error") == true {
            adb(["-s", serial, "shell", intent]) // sin Chrome: el navegador por defecto
        }
    }

    /// Ejecuta adb y devuelve su salida estándar, o nil si falla.
    @discardableResult
    private func adb(_ arguments: [String]) -> String? {
        guard let adbPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func findADB() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fromPath = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map { "\($0)/adb" } ?? []
        let candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                          "\(home)/Library/Android/sdk/platform-tools/adb"] + fromPath
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
