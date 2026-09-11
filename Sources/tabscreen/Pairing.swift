import Foundation

/// Decide qué dispositivos pueden ver la pantalla.
///
/// Los dispositivos de confianza entran directo. Uno nuevo recibe un código
/// de 6 dígitos que se muestra en su pantalla, y en la Mac aparece una ventana
/// donde hay que escribirlo: así solo entra el dispositivo que tienes enfrente,
/// aunque otra persona haya escaneado el QR.
final class Pairing {
    /// Tras un rechazo, esa IP no puede volver a pedir acceso durante este tiempo.
    private static let cooldown: TimeInterval = 60

    private let store: Store
    private let queue = DispatchQueue(label: "tabscreen.pairing")
    private var busy = false                       // solo en queue
    private var blockedUntil: [String: Date] = [:]  // IP → fecha; solo en queue

    init(store: Store) {
        self.store = store
    }

    func authorize(_ device: DeviceInfo, sendCode: @escaping (String) -> Void,
                   completion: @escaping (AuthResult) -> Void) {
        // Por cable USB (adb reverse) la tablet llega como localhost: está
        // conectada físicamente y ya autorizó la depuración USB.
        if store.isTrusted(device.id) || Self.isLoopback(device.address) {
            completion(.allowed)
            return
        }
        queue.async {
            if let until = self.blockedUntil[device.address], until > Date() {
                completion(.rejected("Esta Mac rechazó una solicitud desde aquí hace poco. Espera un minuto."))
                return
            }
            guard !self.busy else {
                completion(.rejected("Hay otra solicitud pendiente en la Mac. Intenta en un momento."))
                return
            }
            self.busy = true

            let code = String(format: "%06d", Int.random(in: 0...999_999))
            sendCode(code)
            print("🔐 \(device.name) (\(device.address)) pide conectarse. Escribe en la ventana de la Mac el código que muestra.")

            DispatchQueue.global(qos: .userInitiated).async {
                let answer = Self.askUser(device)
                self.queue.async {
                    self.busy = false
                    completion(self.decide(answer, expectedCode: code, device: device))
                }
            }
        }
    }

    private static func isLoopback(_ address: String) -> Bool {
        address.hasPrefix("127.") || address.hasPrefix("::1") || address.hasPrefix("::ffff:127.")
    }

    /// Debe llamarse en `queue`.
    private func decide(_ answer: (button: String, code: String), expectedCode: String, device: DeviceInfo) -> AuthResult {
        let remember = answer.button == "Permitir y recordar"
        let allow = remember || answer.button == "Solo esta vez"
        let typed = answer.code.filter(\.isNumber)

        if allow && typed == expectedCode {
            if remember {
                store.trust(deviceID: device.id, name: device.name)
                print("✅ \(device.name) permitido y guardado como dispositivo de confianza")
            } else {
                print("✅ \(device.name) permitido (solo esta vez)")
            }
            return .allowed
        }

        blockedUntil[device.address] = Date().addingTimeInterval(Self.cooldown)
        if allow {
            print("❌ Código incorrecto para \(device.name); se rechazó la conexión")
            return .rejected("Código incorrecto.")
        }
        if answer.button == "timeout" {
            print("⌛ Nadie respondió la solicitud de \(device.name)")
            return .rejected("Nadie respondió en la Mac.")
        }
        print("🚫 Se rechazó a \(device.name)")
        return .rejected("La Mac rechazó la conexión.")
    }

    /// Muestra una ventana nativa con AppleScript. El nombre y la IP van como
    /// argumentos (no interpolados en el script) porque vienen del dispositivo.
    private static func askUser(_ device: DeviceInfo) -> (button: String, code: String) {
        let script = """
        on run argv
          set deviceName to item 1 of argv
          set deviceAddress to item 2 of argv
          activate
          beep
          try
            set answer to display dialog "«" & deviceName & "» (" & deviceAddress & ") quiere conectarse como pantalla de esta Mac." & return & return & "Escribe el código de 6 dígitos que aparece en el dispositivo:" default answer "" buttons {"Rechazar", "Solo esta vez", "Permitir y recordar"} default button "Permitir y recordar" cancel button "Rechazar" with title "TabScreen" with icon caution giving up after 120
            if gave up of answer then return "timeout|"
            return (button returned of answer) & "|" & (text returned of answer)
          on error
            return "reject|"
          end try
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = script.split(separator: "\n").flatMap { ["-e", String($0)] } + [device.name, device.address]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            print("⚠️  No se pudo mostrar la ventana de confirmación: \(error.localizedDescription)")
            return ("reject", "")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts.first ?? "reject"), parts.count > 1 ? String(parts[1]) : "")
    }
}
