//
//  ScreenImage.swift
//  GhostMeet
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a screenshot into the bytes that actually go over the wire.
///
/// A Retina display is around 8 megapixels; sent as-is that is megabytes per
/// suggestion, and the loop fires on every `Them` turn (ADR-0003). Every one of
/// those megabytes is upload time in front of the first token, and money. So the
/// image is scaled down to a long edge that a model still reads comfortably.
///
/// Losing detail costs nothing here, because the exact characters are carried by
/// the OCR text alongside it (`ScreenContext.text`), which is produced from the
/// full-resolution image before this runs.
nonisolated enum ScreenImage {

    /// Longest edge of the image that is sent, in pixels.
    ///
    /// Chosen to sit under the point where the major providers downscale server
    /// side anyway (~1.15 MP), so nothing is paid for detail that is thrown away
    /// on arrival.
    static let maxDimension = 1280

    /// PNG bytes, scaled down so that neither side exceeds `maxDimension`.
    ///
    /// PNG rather than JPEG because that is the media type the wire formats
    /// declare (`ClaudeWireFormat`, `GeminiWireFormat`, `OpenAIWireFormat` all
    /// say `image/png`), and screen content — flat colour, sharp text — is what
    /// PNG is good at.
    static func png(from image: CGImage, maxDimension limit: Int = maxDimension) -> Data? {
        let target = fittedSize(width: image.width, height: image.height, within: limit)
        let scaled = target == (image.width, image.height) ? image : downscaled(image, to: target)
        guard let scaled else { return nil }
        return encode(scaled)
    }

    /// The size `width` × `height` becomes when made to fit a square of `limit`.
    ///
    /// Never enlarges: a small screen is already cheap, and upscaling would add
    /// bytes without adding a single pixel of information.
    static func fittedSize(width: Int, height: Int, within limit: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0, limit > 0 else { return (width, height) }
        let longest = max(width, height)
        guard longest > limit else { return (width, height) }
        let ratio = Double(limit) / Double(longest)
        return (
            max(1, Int((Double(width) * ratio).rounded())),
            max(1, Int((Double(height) * ratio).rounded()))
        )
    }

    private static func downscaled(_ image: CGImage, to size: (width: Int, height: Int)) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        // Text is what this image is mostly made of, and nearest-neighbour makes
        // it unreadable at this scale factor.
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: size.width, height: size.height)
        )
        return context.makeImage()
    }

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
