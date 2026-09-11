import Foundation

struct Options {
    var width = 1920
    var height = 1200
    var fps = 60
    var hiDPI = false
    var port: UInt16 = 8420
    var bitrateMbps: Double?
    /// Sin --res, la pantalla virtual adopta la resolución de la tablet.
    var autoResolution = true
    var position: DisplayPosition?
    var forgetDevices = false
    /// Sin --full-res el video se limita a `maxStreamPixels` y la tablet lo reescala.
    var fullResolution = false
    var usb = true

    static let maxAutoWidth = 3840
    static let maxAutoHeight = 2400
    static let maxStreamPixels = 1920 * 1200

    static let presets: [(name: String, width: Int, height: Int)] = [
        ("hd", 1280, 800),
        ("fhd", 1920, 1080),
        ("wuxga", 1920, 1200),
        ("2k", 2560, 1600),
    ]

    static let usage = """
    Uso: tabscreen [opciones]

    Crea una pantalla virtual en tu Mac y la transmite a una tablet por Wi-Fi.
    Escanea el QR con la tablet (misma red) y se abre en el navegador.

    Opciones:
      -r, --res <WxH|preset>  Resolución fija (por defecto: automática, la de la tablet)
                              Presets: hd=1280x800, fhd=1920x1080, wuxga=1920x1200, 2k=2560x1600
          --hidpi             Modo Retina: la interfaz se ve a la mitad de tamaño (más nítida).
                              En modo automático se activa solo en tablets de alta resolución.
          --fps <n>           Cuadros por segundo (por defecto 60)
          --full-res          Envía el video a la resolución completa de la pantalla (más
                              nítido, pero más retraso en tablets de alta resolución)
          --bitrate <Mbps>    Bitrate del video (por defecto: automático según resolución)
      -p, --port <n>          Puerto HTTP (por defecto 8420)
          --position <lado>   Dónde va la pantalla respecto a la principal: izquierda,
                              derecha, arriba o abajo (por defecto: la última usada)
          --forget-devices    Olvida los dispositivos de confianza y sale
          --no-usb            No usa la conexión por cable USB (adb)
      -h, --help              Muestra esta ayuda
    """

    /// Bitrate automático: ~0.07 bits por píxel por cuadro, entre 4 y 30 Mbps.
    func bitrate(width: Int, height: Int) -> Int {
        if let bitrateMbps { return Int(bitrateMbps * 1_000_000) }
        let auto = Double(width * height * fps) * 0.07
        return Int(min(max(auto, 4_000_000), 30_000_000))
    }

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var it = arguments.dropFirst().makeIterator()

        func value(for flag: String) -> String {
            guard let v = it.next() else { fail("Falta el valor de \(flag)") }
            return v
        }

        while let arg = it.next() {
            switch arg {
            case "-r", "--res":
                let v = value(for: arg).lowercased()
                options.autoResolution = false
                if let preset = presets.first(where: { $0.name == v }) {
                    options.width = preset.width
                    options.height = preset.height
                } else {
                    let parts = v.split(separator: "x").compactMap { Int($0) }
                    guard parts.count == 2 else { fail("Resolución inválida: \(v) (usa por ejemplo 2560x1600)") }
                    options.width = parts[0]
                    options.height = parts[1]
                }
            case "--hidpi":
                options.hiDPI = true
            case "--fps":
                guard let fps = Int(value(for: arg)), (1...120).contains(fps) else { fail("--fps debe estar entre 1 y 120") }
                options.fps = fps
            case "--bitrate":
                guard let mbps = Double(value(for: arg)), mbps > 0 else { fail("--bitrate debe ser un número en Mbps") }
                options.bitrateMbps = mbps
            case "-p", "--port":
                guard let port = UInt16(value(for: arg)), port > 0 else { fail("Puerto inválido") }
                options.port = port
            case "--position":
                let v = value(for: arg)
                guard let position = DisplayPosition(argument: v) else {
                    fail("Posición inválida: \(v) (usa izquierda, derecha, arriba o abajo)")
                }
                options.position = position
            case "--forget-devices":
                options.forgetDevices = true
            case "--full-res":
                options.fullResolution = true
            case "--no-usb":
                options.usb = false
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                fail("Opción desconocida: \(arg)")
            }
        }

        guard (640...4096).contains(options.width), (480...4096).contains(options.height) else {
            fail("La resolución debe estar entre 640x480 y 4096x4096")
        }
        let multiple = options.hiDPI ? 4 : 2
        guard options.width % multiple == 0, options.height % multiple == 0 else {
            fail("El ancho y alto deben ser múltiplos de \(multiple)")
        }
        return options
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n\n".utf8))
    print(Options.usage)
    exit(2)
}
