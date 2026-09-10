import CoreImage
import Foundation

enum Terminal {
    /// Dibuja un código QR con medios bloques y colores ANSI explícitos
    /// (negro sobre blanco), así se puede escanear con tema claro u oscuro.
    static func qrCode(_ text: String) -> String? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage,
              let cgImage = CIContext().createCGImage(image, from: image.extent)
        else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        func isDark(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return pixels[y * width + x] < 128
        }

        let quiet = 2
        var output = ""
        for y in stride(from: -quiet, to: height + quiet, by: 2) {
            output += "  "
            for x in -quiet..<(width + quiet) {
                let fg = isDark(x, y) ? "30" : "97"
                let bg = isDark(x, y + 1) ? "40" : "107"
                output += "\u{1B}[\(fg);\(bg)m▀"
            }
            output += "\u{1B}[0m\n"
        }
        return output
    }

    /// IPv4 locales activas, con Wi-Fi/Ethernet (en*) primero.
    static func localIPv4Addresses() -> [(interface: String, address: String)] {
        var result: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            let name = String(cString: entry.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append((name, String(cString: host)))
        }
        return result.sorted { a, b in
            func rank(_ name: String) -> Int { name == "en0" ? 0 : name.hasPrefix("en") ? 1 : 2 }
            return rank(a.0) < rank(b.0)
        }
    }
}
