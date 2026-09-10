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

/// Pantalla virtual que macOS trata como un monitor real. Existe mientras
/// este objeto (y el proceso) sigan vivos.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let displayID: CGDirectDisplayID

    init(name: String, width: Int, height: Int, refreshRate: Double, hiDPI: Bool) throws {
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
        descriptor.serialNum = 0x0001

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw VirtualDisplayError.creationFailed
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        var modes = [CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: refreshRate)]
        if hiDPI {
            modes.append(CGVirtualDisplayMode(width: UInt(width / 2), height: UInt(height / 2), refreshRate: refreshRate))
        }
        settings.modes = modes
        guard display.apply(settings) else { throw VirtualDisplayError.settingsRejected }

        self.display = display
        self.displayID = display.displayID
    }

    /// Tamaño en píxeles del modo actual (cambia si el usuario elige otra
    /// resolución en Ajustes → Pantallas).
    var currentPixelSize: (width: Int, height: Int)? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    /// Activa el modo con exactamente `width`x`height` píxeles; en HiDPI, el
    /// que se ve como la mitad de tamaño.
    @discardableResult
    func selectMode(width: Int, height: Int, hiDPI: Bool) -> Bool {
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
}
