//
//  LogoImageConverter.swift
//  ESP32Controller
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import OSLog

struct LogoImageConversionResult {
    let payload: Data
    let previewImage: CGImage
}

enum LogoImageImportSource: String, Equatable, Sendable {
    case photos = "Photos"
    case files = "Files"
    case unknown = "Unknown"
}

struct LogoImageSourceDiagnostics: Equatable {
    let byteCount: Int
    let typeIdentifier: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let orientation: CGImagePropertyOrientation
    let nativePath: Bool

    var sourceDisplayName: String {
        switch typeIdentifier {
        case "public.png":
            "PNG"
        case "public.jpeg", "public.jpg":
            "JPEG"
        case "public.heic":
            "HEIC"
        case "public.heif":
            "HEIF"
        case let type?:
            type
        case nil:
            "Unknown"
        }
    }

    var dimensionsDisplayText: String {
        "\(orientedWidth) × \(orientedHeight)"
    }

    var conversionDisplayName: String {
        if nativePath {
            return isLossySource ? "Native dimensions, lossy source" : "Native pixel path"
        }

        return "Resized with Lanczos"
    }

    var isPNG: Bool {
        typeIdentifier == "public.png"
    }

    var isLossySource: Bool {
        switch typeIdentifier {
        case "public.jpeg", "public.jpg", "public.heic", "public.heif":
            true
        default:
            false
        }
    }

    var compressionWarning: String? {
        isLossySource ? Self.lossyCompressionWarning : nil
    }

    static let lossyCompressionWarning =
        "JPEG and HEIC compression may create colored shadows around sharp logo edges. Use Import Lossless PNG File for pixel-exact logos."

    private var orientedWidth: Int {
        orientation.swapsWidthAndHeight ? pixelHeight : pixelWidth
    }

    private var orientedHeight: Int {
        orientation.swapsWidthAndHeight ? pixelWidth : pixelHeight
    }
}

struct LogoImageConverter {
    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ESP32Controller",
        category: "LogoImageConverter"
    )

    func convert(
        data: Data,
        source: LogoImageImportSource = .unknown
    ) throws -> LogoImageConversionResult {
        if let diagnostics = Self.makeSourceDiagnostics(from: data) {
            Self.logSourceDiagnostics(diagnostics, source: source)
        }

        if let nativeRGBA = try renderNativeSizeRGBAIfAvailable(from: data) {
            return try makeConversionResult(fromRGBA: nativeRGBA)
        }

        let resizedRGBA = try renderResizedRGBA(from: data)
        return try makeConversionResult(fromRGBA: resizedRGBA)
    }

    static func sourceDiagnostics(from data: Data) throws -> LogoImageSourceDiagnostics {
        guard let diagnostics = makeSourceDiagnostics(from: data) else {
            throw LogoImageConversionError.unsupportedImageData
        }

        return diagnostics
    }

    static func validateLosslessPNGData(_ data: Data) throws -> LogoImageSourceDiagnostics {
        let diagnostics = try sourceDiagnostics(from: data)
        guard diagnostics.isPNG else {
            throw LogoImageConversionError.notLosslessPNG
        }

        return diagnostics
    }

    private static func makeSourceDiagnostics(from data: Data) -> LogoImageSourceDiagnostics? {
        guard
            let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
            let sourceCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            return nil
        }

        let orientation = imageOrientation(from: imageSource)
        let orientedWidth = orientation.swapsWidthAndHeight ? sourceCGImage.height : sourceCGImage.width
        let orientedHeight = orientation.swapsWidthAndHeight ? sourceCGImage.width : sourceCGImage.height
        let nativePath = orientedWidth == Int(LogoFileFormat.width) &&
            orientedHeight == Int(LogoFileFormat.height)

        return LogoImageSourceDiagnostics(
            byteCount: data.count,
            typeIdentifier: CGImageSourceGetType(imageSource) as String?,
            pixelWidth: sourceCGImage.width,
            pixelHeight: sourceCGImage.height,
            orientation: orientation,
            nativePath: nativePath
        )
    }

    private static func logSourceDiagnostics(
        _ diagnostics: LogoImageSourceDiagnostics,
        source: LogoImageImportSource
    ) {
        logger.info(
            """
            Logo source: type=\(diagnostics.typeIdentifier ?? "unknown", privacy: .public) \
            size=\(diagnostics.pixelWidth)x\(diagnostics.pixelHeight) \
            bytes=\(diagnostics.byteCount) nativePath=\(diagnostics.nativePath) \
            source=\(source.rawValue, privacy: .public)
            """
        )
    }

    private func renderResizedRGBA(from data: Data) throws -> [UInt8] {
        guard let sourceImage = CIImage(
            data: data,
            options: [
                .applyOrientationProperty: true,
                .colorSpace: Self.sRGBColorSpace
            ]
        ) else {
            throw LogoImageConversionError.unsupportedImageData
        }

        guard sourceImage.extent.width > 0, sourceImage.extent.height > 0 else {
            throw LogoImageConversionError.invalidSourceExtent
        }

        let scaledImage = try resizeDirectlyToLogoDimensions(sourceImage)
        let outputBounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(LogoFileFormat.width),
            height: CGFloat(LogoFileFormat.height)
        )
        let blackBackground = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: outputBounds)
        let compositedImage = scaledImage
            .cropped(to: outputBounds)
            .composited(over: blackBackground)
            .cropped(to: outputBounds)

        let width = Int(LogoFileFormat.width)
        let height = Int(LogoFileFormat.height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [
            .workingColorSpace: Self.sRGBColorSpace,
            .outputColorSpace: Self.sRGBColorSpace,
            .cacheIntermediates: false
        ])
        context.render(
            compositedImage,
            toBitmap: &rgba,
            rowBytes: width * 4,
            bounds: outputBounds,
            format: .RGBA8,
            colorSpace: Self.sRGBColorSpace
        )

        return rgba
    }

    private func renderNativeSizeRGBAIfAvailable(from data: Data) throws -> [UInt8]? {
        guard
            let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
            let sourceCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            return nil
        }

        let orientation = Self.imageOrientation(from: imageSource)
        let orientedWidth = orientation.swapsWidthAndHeight ? sourceCGImage.height : sourceCGImage.width
        let orientedHeight = orientation.swapsWidthAndHeight ? sourceCGImage.width : sourceCGImage.height
        let width = Int(LogoFileFormat.width)
        let height = Int(LogoFileFormat.height)

        guard orientedWidth == width, orientedHeight == height else {
            return nil
        }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer in
            guard
                let baseAddress = buffer.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: Self.sRGBColorSpace,
                    bitmapInfo: CGBitmapInfo(
                        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                            CGBitmapInfo.byteOrder32Big.rawValue
                    ).rawValue
                )
            else {
                return false
            }

            let outputBounds = CGRect(
                x: 0,
                y: 0,
                width: CGFloat(width),
                height: CGFloat(height)
            )
            context.interpolationQuality = .none
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(outputBounds)
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            Self.drawNativeImage(
                sourceCGImage,
                orientation: orientation,
                in: context,
                outputBounds: outputBounds
            )

            return true
        }

        guard rendered else {
            throw LogoImageConversionError.renderFailed
        }

        return rgba
    }

    private func makeConversionResult(fromRGBA rgba: [UInt8]) throws -> LogoImageConversionResult {
        var payload = Data()
        payload.reserveCapacity(LogoFileFormat.payloadLength)
        for pixelOffset in stride(from: 0, to: rgba.count, by: 4) {
            let normalized = Self.applyPixelRules(
                r: rgba[pixelOffset],
                g: rgba[pixelOffset + 1],
                b: rgba[pixelOffset + 2]
            )
            payload.append(normalized.r)
            payload.append(normalized.g)
            payload.append(normalized.b)
        }

        guard payload.count == LogoFileFormat.payloadLength else {
            throw LogoImageConversionError.invalidPayloadLength(payload.count)
        }

        return LogoImageConversionResult(
            payload: payload,
            previewImage: try Self.makePreviewImage(from: payload)
        )
    }

    private static func imageOrientation(from imageSource: CGImageSource) -> CGImagePropertyOrientation {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let rawOrientation = properties[kCGImagePropertyOrientation] as? UInt32,
            let orientation = CGImagePropertyOrientation(rawValue: rawOrientation)
        else {
            return .up
        }

        return orientation
    }

    private static func drawNativeImage(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation,
        in context: CGContext,
        outputBounds: CGRect
    ) {
        context.saveGState()
        context.concatenate(
            orientation.transform(
                sourceWidth: CGFloat(image.width),
                sourceHeight: CGFloat(image.height),
                orientedWidth: outputBounds.width,
                orientedHeight: outputBounds.height
            )
        )
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        context.restoreGState()
    }

    private func resizeDirectlyToLogoDimensions(_ image: CIImage) throws -> CIImage {
        let source = image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            )
        )
        let targetWidth = CGFloat(LogoFileFormat.width)
        let targetHeight = CGFloat(LogoFileFormat.height)
        let scaleX = targetWidth / source.extent.width
        let scaleY = targetHeight / source.extent.height

        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            throw LogoImageConversionError.renderFailed
        }

        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(scaleY, forKey: kCIInputScaleKey)
        filter.setValue(scaleX / scaleY, forKey: kCIInputAspectRatioKey)

        guard let outputImage = filter.outputImage else {
            throw LogoImageConversionError.renderFailed
        }

        return outputImage.transformed(
            by: CGAffineTransform(
                translationX: -outputImage.extent.origin.x,
                y: -outputImage.extent.origin.y
            )
        )
    }

    static func makePreviewImage(from payload: Data) throws -> CGImage {
        guard payload.count == LogoFileFormat.payloadLength else {
            throw LogoFileFormatError.invalidPayloadLength(payload.count)
        }

        let width = Int(LogoFileFormat.width)
        let height = Int(LogoFileFormat.height)
        var rgba = Data()
        rgba.reserveCapacity(width * height * 4)

        for pixelOffset in stride(from: 0, to: payload.count, by: 3) {
            rgba.append(payload[pixelOffset])
            rgba.append(payload[pixelOffset + 1])
            rgba.append(payload[pixelOffset + 2])
            rgba.append(0xFF)
        }

        guard
            let provider = CGDataProvider(data: rgba as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: sRGBColorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                        CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw LogoImageConversionError.previewCreationFailed
        }

        return image
    }

    static func applyPixelRules(r: UInt8, g: UInt8, b: UInt8) -> (r: UInt8, g: UInt8, b: UInt8) {
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)

        if maximum <= 12 {
            return (0, 0, 0)
        } else if maximum - minimum <= 3, maximum < 24 {
            return (24, 24, 24)
        } else {
            return (r, g, b)
        }
    }
}

enum LogoImageConversionError: LocalizedError, Equatable {
    case unsupportedImageData
    case notLosslessPNG
    case invalidSourceExtent
    case renderFailed
    case invalidPayloadLength(Int)
    case previewCreationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedImageData:
            "Choose a PNG, JPEG, or HEIC image."
        case .notLosslessPNG:
            "The selected file is not a lossless PNG image."
        case .invalidSourceExtent:
            "The selected image has invalid dimensions."
        case .renderFailed:
            "Unable to process the selected image."
        case let .invalidPayloadLength(length):
            "Converted logo payload must be exactly \(LogoFileFormat.payloadLength) bytes, got \(length)."
        case .previewCreationFailed:
            "Unable to create the processed logo preview."
        }
    }
}

private extension CGImagePropertyOrientation {
    var swapsWidthAndHeight: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored:
            true
        case .up, .upMirrored, .down, .downMirrored:
            false
        @unknown default:
            false
        }
    }

    func transform(
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        orientedWidth: CGFloat,
        orientedHeight: CGFloat
    ) -> CGAffineTransform {
        switch self {
        case .up:
            .identity
        case .upMirrored:
            CGAffineTransform(translationX: sourceWidth, y: 0)
                .scaledBy(x: -1, y: 1)
        case .down:
            CGAffineTransform(translationX: sourceWidth, y: sourceHeight)
                .rotated(by: .pi)
        case .downMirrored:
            CGAffineTransform(translationX: 0, y: sourceHeight)
                .scaledBy(x: 1, y: -1)
        case .left:
            CGAffineTransform(translationX: 0, y: orientedHeight)
                .rotated(by: -.pi / 2)
        case .leftMirrored:
            CGAffineTransform(translationX: orientedWidth, y: orientedHeight)
                .scaledBy(x: -1, y: 1)
                .rotated(by: -.pi / 2)
        case .right:
            CGAffineTransform(translationX: orientedWidth, y: 0)
                .rotated(by: .pi / 2)
        case .rightMirrored:
            CGAffineTransform(scaleX: -1, y: 1)
                .rotated(by: .pi / 2)
        @unknown default:
            .identity
        }
    }
}
