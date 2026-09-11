import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let options = Options.parse(CommandLine.arguments)
let store = Store()

if options.forgetDevices {
    let count = store.forgetDevices()
    print("🗑  Se olvidaron \(count) dispositivo(s) de confianza y el próximo QR será nuevo.")
    exit(0)
}

// Evita que macOS (App Nap / ahorro de energía) retrase los temporizadores
// del codificador cuando la terminal no está en primer plano.
let activity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiated, .latencyCritical],
    reason: "Transmitiendo la pantalla virtual")

if !CGPreflightScreenCaptureAccess() {
    CGRequestScreenCaptureAccess()
    print("""
    ⚠️  TabScreen necesita permiso de Grabación de pantalla.
       Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema
       Activa tu app de terminal (Terminal, iTerm, VS Code…), ciérrala y vuelve a abrirla.

    """)
}

let token = store.token

guard let webRoot = Bundle.module.url(forResource: "Web", withExtension: nil) else {
    fail("No se encontraron los archivos del cliente web")
}

let server: Server
do {
    server = try Server(port: options.port, token: token, webRoot: webRoot)
} catch {
    fail("No se pudo abrir el puerto \(options.port): \(error)")
}

let pipeline = Pipeline(options: options, server: server, store: store)
let pairing = Pairing(store: store)
server.onAuthorize = pairing.authorize
server.onKeyframeRequest = { pipeline.requestKeyframe() }
server.onTabletScreen = { width, height in pipeline.adapt(toTabletWidth: width, height: height) }
server.onPosition = { position in pipeline.place(position) }
server.start()

let usb = USBBridge(port: options.port, token: token, enabled: options.usb)

func printBanner() {
    let addresses = Terminal.localIPv4Addresses()
    let urls = addresses.map { "http://\($0.address):\(options.port)/?t=\(token)" }
    print("")
    if options.autoResolution {
        print("🖥  La pantalla virtual se creará al conectar la tablet, con su resolución.")
    } else {
        print("🖥  Pantalla virtual lista: \(options.width)x\(options.height) @ \(options.fps) Hz\(options.hiDPI ? " (HiDPI)" : "")")
    }
    print("   Ubicación: \(pipeline.position.label) de la principal (cámbiala desde la tablet o con --position).")
    print("🔐 Cada dispositivo nuevo debe confirmarse con un código en esta Mac. De confianza: \(store.trustedCount).")
    if usb.isAvailable {
        print("🔌 USB: conecta la tablet por cable (con Depuración USB activada) y TabScreen se abrirá sola.")
    } else if options.usb {
        print("🔌 Para conectar por cable instala adb:  brew install --cask android-platform-tools")
    }
    print("")
    guard let url = urls.first else {
        print("⚠️  No se encontró ninguna red. Conecta la Mac al Wi-Fi.")
        return
    }
    print("📷 Escanea con la tablet (misma red Wi-Fi):\n")
    if let qr = Terminal.qrCode(url) { print(qr) }
    print("   \(url)")
    for (other, address) in zip(urls.dropFirst(), addresses.dropFirst()) {
        print("   \(other)  (\(address.interface))")
    }
    print("\nCtrl+C para salir.\n")
}

Task { @MainActor in
    do {
        try await pipeline.start()
        printBanner()
        usb.start()
    } catch {
        print("❌ \(error.localizedDescription)")
        if !CGPreflightScreenCaptureAccess() {
            print("   Falta el permiso de Grabación de pantalla (ver arriba).")
        }
        exit(1)
    }
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    print("\n👋 Cerrando TabScreen…")
    exit(0)
}
sigint.resume()

dispatchMain()
