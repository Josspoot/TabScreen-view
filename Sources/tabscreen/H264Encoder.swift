import CoreMedia
import Foundation
import VideoToolbox

enum EncoderError: LocalizedError {
    case createFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .createFailed(let status): return "No se pudo crear el codificador H.264 (OSStatus \(status))"
        }
    }
}

/// Codificador H.264 por hardware (VideoToolbox) en modo de baja latencia.
/// Entrega los cuadros en formato AVCC (NALs con prefijo de 4 bytes).
final class H264Encoder {
    struct Frame {
        let data: Data
        let isKeyframe: Bool
        let ptsMicros: Int64
    }

    let width: Int
    let height: Int

    /// Se llama cuando cambian SPS/PPS, siempre antes del keyframe que los usa.
    var onParameterSets: ((_ sps: Data, _ pps: Data) -> Void)?
    var onFrame: ((Frame) -> Void)?

    private var session: VTCompressionSession?
    private var lastSPS: Data?
    private var lastPPS: Data?

    init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        self.width = width
        self.height = height

        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true] as CFDictionary
        var session = Self.makeSession(width: width, height: height, spec: lowLatency)
        if session == nil { session = Self.makeSession(width: width, height: height, spec: nil) }
        guard let session else { throw EncoderError.createFailed(-1) }

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        if VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel) != noErr {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        }
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 10))
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    private static func makeSession(width: Int, height: Int, spec: CFDictionary?) -> VTCompressionSession? {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        return status == noErr ? session : nil
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool) {
        guard let session else { return }
        let properties = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.handle(sampleBuffer)
        }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            isKeyframe = !CFDictionaryContainsKey(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        }

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let sps = Self.parameterSet(format, index: 0),
           let pps = Self.parameterSet(format, index: 1),
           sps != lastSPS || pps != lastPPS {
            lastSPS = sps
            lastPPS = pps
            onParameterSets?(sps, pps)
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(Frame(data: data, isKeyframe: isKeyframe, ptsMicros: Int64(pts.seconds * 1_000_000)))
    }

    private static func parameterSet(_ format: CMFormatDescription, index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard status == noErr, let pointer else { return nil }
        return Data(bytes: pointer, count: size)
    }
}
