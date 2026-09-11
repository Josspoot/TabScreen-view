import CoreGraphics
import CVirtualDisplay
import Foundation

enum VirtualDisplayError: LocalizedError {
    case creationFailed
    case settingsRejected

    var errorDescription: String? {
        switch self {
        case .creationFailed: return "macOS no permitió crear la pantalla virtual"
        case .settingsRejected: return "macOS rechazó la configuración de la pantalla virtual"
        }
    }
}

/// Lado de la pantalla principal donde va la pantalla virtual.
enum DisplayPosition: String, Codable, CaseIterable {
    case left, right, above, below

    /// Acepta los nombres en inglés o en español.
    init?(argument: String) {
        switch argument.lowercased() {
        case "left", "izquierda", "izq": self = .left
        case "right", "derecha", "der": self = .right
        case "above", "top", "arriba": self = .above
        case "below", "bottom", "abajo": self = .below
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .left: "a la izquierda"
        case .right: "a la derecha"
        case .above: "arriba"
        case .below: "abajo"
        }
    }
}

/// Pantalla virtual que macOS trata como un monitor real. Existe mientras
/// este objeto (y el proceso) sigan vivos.
///
/// La resolución se fija al crearla: cambiar los modos de una pantalla que ya
/// existe no es fiable (este proceso sigue viendo la lista de modos vieja), así
/// que para otra resolución hay que crear una pantalla nueva.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let displayID: CGDirectDisplayID
    /// Píxeles reales; en HiDPI la interfaz se ve como la mitad de tamaño.
    let width: Int
    let height: Int
    let hiDPI: Bool

    init(name: String, width: Int, height: Int, hiDPI: Bool, refreshRate: Double) throws {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        // Tamaño físico aproximado (~110 ppi) para que macOS elija una escala razonable.
        let mmPerPixel = 25.4 / 110.0
        descriptor.sizeInMillimeters = CGSize(width: Double(width) * mmPerPixel, height: Double(height) * mmPerPixel)
        descriptor.vendorID = 0x7AB5
        descriptor.productID = 0x0001

        // macOS rechaza dos pantallas con el mismo número de serie (p. ej. otra
        // instancia abierta). El serial 1 va primero para que macOS recuerde
        // dónde acomodó el usuario la pantalla entre ejecuciones.
        var created: CGVirtualDisplay?
        for serial in UInt32(1)...8 where created == nil {
            descriptor.serialNum = serial
            created = CGVirtualDisplay(descriptor: descriptor)
        }
        guard let display = created else {
            throw VirtualDisplayError.creationFailed
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        // El modo HiDPI sale del modo de la mitad de tamaño, duplicado a 2x.
        var modes = [CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: refreshRate)]
        if hiDPI {
            modes.append(CGVirtualDisplayMode(width: UInt(width / 2), height: UInt(height / 2), refreshRate: refreshRate))
        }
        settings.modes = modes
        guard display.apply(settings) else { throw VirtualDisplayError.settingsRejected }

        self.display = display
        self.displayID = display.displayID
        self.width = width
        self.height = height
        self.hiDPI = hiDPI
    }

    /// Activa el modo pedido. Recién creada, macOS usa el primer modo de la
    /// lista a 1x, así que en HiDPI hay que elegir el modo a 2x.
    @MainActor
    func activateMode() async {
        for _ in 0..<20 {
            if selectMode() {
                await waitForSize()
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        print("⚠️  No se pudo activar el modo \(width)x\(height)\(hiDPI ? " HiDPI" : ""); se usa el que eligió macOS")
    }

    /// Acomoda la pantalla junto a la principal, centrada en ese borde.
    /// Se reintenta porque macOS reacomoda por su cuenta las pantallas recién
    /// creadas o recién cambiadas de tamaño.
    @MainActor
    @discardableResult
    func place(_ position: DisplayPosition) async -> Bool {
        for _ in 0..<20 {
            let main = CGDisplayBounds(CGMainDisplayID())
            let own = CGDisplayBounds(displayID)
            let origin: CGPoint
            switch position {
            case .right: origin = CGPoint(x: main.maxX, y: main.midY - own.height / 2)
            case .left: origin = CGPoint(x: main.minX - own.width, y: main.midY - own.height / 2)
            case .above: origin = CGPoint(x: main.midX - own.width / 2, y: main.minY - own.height)
            case .below: origin = CGPoint(x: main.midX - own.width / 2, y: main.maxY)
            }

            if Self.isPlaced(own, position, relativeTo: main) {
                // Ya está del lado correcto (p. ej. macOS restauró una ubicación
                // recordada): se centra una vez, sin insistir.
                if abs(own.minX - origin.x) > 1 || abs(own.minY - origin.y) > 1 { move(to: origin) }
                return true
            }
            move(to: origin)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        print("⚠️  No se pudo mover la pantalla \(position.label); acomódala en Ajustes → Pantallas")
        return false
    }

    private func move(to origin: CGPoint) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, displayID, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    /// Solo importa de qué lado quedó: macOS puede ajustar unos puntos el origen.
    private static func isPlaced(_ own: CGRect, _ position: DisplayPosition, relativeTo main: CGRect) -> Bool {
        switch position {
        case .left: return own.maxX <= main.minX + 1
        case .right: return own.minX >= main.maxX - 1
        case .above: return own.maxY <= main.minY + 1
        case .below: return own.minY >= main.maxY - 1
        }
    }

    /// Tamaño en píxeles del modo actual (cambia si el usuario elige otra
    /// resolución en Ajustes → Pantallas).
    var currentPixelSize: (width: Int, height: Int)? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    private func selectMode() -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return false }
        let pointsWidth = hiDPI ? width / 2 : width
        guard let target = modes.first(where: {
            $0.pixelWidth == width && $0.pixelHeight == height && $0.width == pointsWidth
        }) else { return false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    /// CGDisplayBounds tarda un poco en reflejar el modo nuevo; hay que
    /// esperarlo antes de calcular la ubicación.
    @MainActor
    private func waitForSize() async {
        let pointsWidth = hiDPI ? width / 2 : width
        var attempts = 0
        while Int(CGDisplayBounds(displayID).width) != pointsWidth, attempts < 20 {
            attempts += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
