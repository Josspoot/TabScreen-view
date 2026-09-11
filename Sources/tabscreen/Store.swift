import CryptoKit
import Foundation

/// Preferencias persistentes en ~/Library/Application Support/TabScreen/settings.json
/// (o en $TABSCREEN_CONFIG_DIR): última ubicación de la pantalla y
/// dispositivos de confianza. De los dispositivos solo se guarda un hash del ID.
final class Store {
    struct TrustedDevice: Codable {
        let idHash: String
        let name: String
        let addedAt: Date
    }

    private struct Contents: Codable {
        var token: String?
        var position: DisplayPosition?
        var trustedDevices: [TrustedDevice]?
    }

    let url: URL
    private var contents: Contents
    private let lock = NSLock()

    init() {
        let directory = ProcessInfo.processInfo.environment["TABSCREEN_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/TabScreen")
        url = directory.appendingPathComponent("settings.json")
        contents = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(Contents.self, from: $0) } ?? Contents()
    }

    /// Token del QR. Se conserva entre ejecuciones para que el QR siga sirviendo
    /// y la tablet se reconecte sola; el código de verificación es lo que
    /// protege el acceso.
    var token: String {
        locked {
            if let token = contents.token { return token }
            let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
            let token = String((0..<10).map { _ in alphabet.randomElement()! })
            contents.token = token
            save()
            return token
        }
    }

    var position: DisplayPosition? {
        get { locked { contents.position } }
        set { locked { contents.position = newValue; save() } }
    }

    var trustedCount: Int {
        locked { contents.trustedDevices?.count ?? 0 }
    }

    func isTrusted(_ deviceID: String) -> Bool {
        let hash = Self.hash(deviceID)
        return locked { contents.trustedDevices?.contains { $0.idHash == hash } ?? false }
    }

    func trust(deviceID: String, name: String) {
        let hash = Self.hash(deviceID)
        locked {
            var devices = contents.trustedDevices ?? []
            devices.removeAll { $0.idHash == hash }
            devices.append(TrustedDevice(idHash: hash, name: name, addedAt: Date()))
            contents.trustedDevices = devices
            save()
        }
    }

    /// Olvida los dispositivos y genera un QR nuevo la próxima vez.
    /// Devuelve cuántos dispositivos se olvidaron.
    func forgetDevices() -> Int {
        locked {
            let count = contents.trustedDevices?.count ?? 0
            contents.trustedDevices = nil
            contents.token = nil
            save()
            return count
        }
    }

    // MARK: - Privado

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Debe llamarse con el lock tomado.
    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(contents).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("⚠️  No se pudo guardar \(url.path): \(error.localizedDescription)")
        }
    }

    private static func hash(_ deviceID: String) -> String {
        SHA256.hash(data: Data(deviceID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
