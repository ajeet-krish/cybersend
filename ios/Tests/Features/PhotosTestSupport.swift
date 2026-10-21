import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import CyberSendData
@testable import CyberSendDomain
@testable import CyberSendFeatures

// Synthetic image support for the M3 photo pipeline suites: solid quadrant images with
// EXIF orientations so the ingest orientation bake is assertable by pixel color, plus
// unique temp storage roots so every test is hermetic (docs/tests.md: synthetic CGImages
// for ingest tests).

struct SyntheticImageError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Quadrant colors of the synthetic stored image (top left clockwise): red, green,
/// yellow, blue. After the orientation bake the samples are matched against these.
let quadrantRed: [UInt8] = [230, 30, 30]
let quadrantGreen: [UInt8] = [30, 200, 60]
let quadrantBlue: [UInt8] = [40, 80, 230]
let quadrantYellow: [UInt8] = [235, 220, 40]

/// A fresh temporary storage root per call, cleaned up when the test process exits.
func makeTempMediaRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cybersend_media_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A four solid quadrant image in sRGB, sized in pixels. Quadrant assignment is in
/// display orientation (top left is red) regardless of the bitmap coordinate space.
func makeQuadrantImage(width: Int, height: Int) throws -> CGImage {
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        throw SyntheticImageError(message: "Could not create the synthetic bitmap context.")
    }
    let w = CGFloat(width)
    let h = CGFloat(height)
    let colors: [(color: CGColor, rect: CGRect)] = [
        (color: CGColor(red: 0.90, green: 0.12, blue: 0.12, alpha: 1),
         rect: CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2)),
        (color: CGColor(red: 0.12, green: 0.78, blue: 0.24, alpha: 1),
         rect: CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2)),
        (color: CGColor(red: 0.16, green: 0.31, blue: 0.90, alpha: 1),
         rect: CGRect(x: 0, y: 0, width: w / 2, height: h / 2)),
        (color: CGColor(red: 0.92, green: 0.86, blue: 0.16, alpha: 1),
         rect: CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2)),
    ]
    for entry in colors {
        context.setFillColor(entry.color)
        context.fill(entry.rect)
    }
    guard let image = context.makeImage() else {
        throw SyntheticImageError(message: "Could not create the synthetic image.")
    }
    return image
}

/// JPEG bytes for the quadrant image with an EXIF orientation tag (the property rides
/// the image destination and becomes the EXIF orientation on disk).
func makeQuadrantJPEG(width: Int, height: Int, orientation: Int = 1, quality: Double = 0.95) throws -> Data {
    let image = try makeQuadrantImage(width: width, height: height)
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil
    ) else {
        throw SyntheticImageError(message: "Could not create the JPEG destination.")
    }
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyOrientation: orientation,
        kCGImageDestinationLossyCompressionQuality: quality,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw SyntheticImageError(message: "Could not finalize the JPEG bytes.")
    }
    return data as Data
}

/// PNG bytes for the quadrant image (no orientation tag; the library verbatim path
/// covers PNG container handling).
func makeQuadrantPNG(width: Int, height: Int) throws -> Data {
    let image = try makeQuadrantImage(width: width, height: height)
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw SyntheticImageError(message: "Could not create the PNG destination.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw SyntheticImageError(message: "Could not finalize the PNG bytes.")
    }
    return data as Data
}

/// Decodes a stored image file as stored, without any orientation transform, so tests
/// inspect the pixels the ingest actually wrote.
func decodeStoredImage(at url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw SyntheticImageError(message: "Not an image: \(url.path).")
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw SyntheticImageError(message: "Could not decode: \(url.path).")
    }
    return image
}

/// Center pixel of each quadrant of an image, sampled through a 4x4 nearest neighbor
/// render. Rows are top first, matching how the samples compare against the synthetic
/// quadrant constants.
struct QuadrantSamples {
    var topLeft: [UInt8]
    var topRight: [UInt8]
    var bottomLeft: [UInt8]
    var bottomRight: [UInt8]
}

func sampleQuadrants(_ image: CGImage) throws -> QuadrantSamples {
    let width = 4
    let height = 4
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return false
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else {
        throw SyntheticImageError(message: "Could not create the sampling context.")
    }
    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let start = (y * width + x) * 4
        return Array(pixels[start ..< start + 4])
    }
    return QuadrantSamples(
        topLeft: pixel(1, 1),
        topRight: pixel(2, 1),
        bottomLeft: pixel(1, 2),
        bottomRight: pixel(2, 2)
    )
}

/// Whether a sampled RGBA pixel matches an expected color within the JPEG tolerance.
func sampleMatches(_ sample: [UInt8], _ expected: [UInt8], tolerance: Int = 70) -> Bool {
    guard sample.count == 4 else { return false }
    for index in 0 ..< 3 {
        if abs(Int(sample[index]) - Int(expected[index])) > tolerance {
            return false
        }
    }
    return true
}

/// Seeds a photo row with real working, thumb, and optional original files and returns
/// the row (the sweep and store fixture the M3 suites share).
func seedPhotoWithFiles(
    repos: Repositories,
    storage: MediaStorage,
    climbId: String? = nil,
    withOriginal: Bool = true
) throws -> Photo {
    let id = generateID()
    let workingUri = try storage.writeWorking(Data([0x01]), photoID: id)
    let thumbUri = try storage.writeThumb(Data([0x02]), photoID: id)
    let originalUri = withOriginal
        ? try storage.writeOriginal(Data([0x03]), photoID: id, fileExtension: "jpg")
        : nil
    return try repos.media.createPhoto(CreatePhotoInput(
        id: id,
        uri: workingUri,
        width: 10,
        height: 10,
        climbId: climbId,
        thumbUri: thumbUri,
        originalUri: originalUri,
        source: .camera,
        capturedAt: "2026-10-20T00:00:00Z"
    ))
}
