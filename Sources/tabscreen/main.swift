import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let options = Options.parse(CommandLine.arguments)

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

let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
let token = String((0..<10).map { _ in alphabet.randomElement()! })

guard let webRoot = Bundle.module.url(forResource: "Web", withExtension: nil) else {
    fail("No se encontraron los archivos del cliente web")
}

let server: Server
do {
    server = try Server(port: options.port, token: token, webRoot: webRoot)
} catch {
    fail("No se pudo abrir el puerto \(options.port): \(error)")
}

let pipeline = Pipeline(options: options, server: server)
server.onKeyframeRequest = { pipeline.requestKeyframe() }
server.onTabletScreen = { width, height in pipeline.adapt(toTabletWidth: width, height: height) }
server.start()

func printBanner() {
    let addresses = Terminal.localIPv4Addresses()
    let urls = addresses.map { "http://\($0.address):\(options.port)/?t=\(token)" }
    print("")
    print("🖥  Pantalla virtual lista: \(options.width)x\(options.height) @ \(options.fps) Hz\(options.hiDPI ? " (HiDPI)" : "")")
    if options.autoResolution {
        print("   Se ajustará sola a la resolución de la tablet al conectarse.")
    }
    print("   Acomódala en Ajustes del Sistema → Pantallas.")
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
