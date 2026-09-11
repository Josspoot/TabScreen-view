import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Captura una pantalla con ScreenCaptureKit y entrega buffers NV12.
/// ScreenCaptureKit solo emite cuadros cuando cambia el contenido.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "tabscreen.capture", qos: .userInteractive)

    func start(display: SCDisplay, width: Int, height: Int, fps: Int) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = Self.configuration(width: width, height: height, fps: fps)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func update(width: Int, height: Int, fps: Int) async throws {
        try await stream?.updateConfiguration(Self.configuration(width: width, height: height, fps: fps))
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    private static func configuration(width: Int, height: Int, fps: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.queueDepth = 6
        config.showsCursor = true
        if #available(macOS 14.0, *) {
            config.scalesToFit = true // el video puede ser más chico que la pantalla
        }
        return config
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onFrame?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("⚠️  La captura se detuvo: \(error.localizedDescription)")
    }
}
