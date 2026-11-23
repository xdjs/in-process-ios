import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreparedPhoto {
    let data: Data
    let mime: String
    let fileExtension: String
    var alterations: [String] = []
}
enum PhotoProcessor {
    // A local memory safety guard, not a claimed service upload limit. Never shrink to fit.
    static let maximumInputBytes = 100 * 1024 * 1024
    static func prepare(_ data: Data) throws -> Data { try inspect(data).data }
    static func format(_ identifier: String) throws -> (mime: String, ext: String) {
        switch identifier {
        case UTType.jpeg.identifier: return ("image/jpeg", "jpg")
        case UTType.png.identifier: return ("image/png", "png")
        case UTType.heic.identifier: return ("image/heic", "heic")
        case UTType.heif.identifier: return ("image/heif", "heif")
        default: throw AppError.message("This still-image format has not been verified for publication. Choose JPEG, PNG, or HEIC; the app will not silently alter it.")
        }
    }
    static func inspect(_ data: Data) throws -> PreparedPhoto {
        guard data.count <= maximumInputBytes else { throw AppError.message("This rendition exceeds the app’s 100 MB preparation safety limit. It has not been resized or uploaded.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else {
            throw AppError.message("Choose a readable single still photo, such as JPEG, HEIC, or PNG.")
        }
        let format = try format(type)
        // Orientation and all embedded metadata are part of the unchanged resource.
        return PreparedPhoto(data: data, mime: format.mime, fileExtension: format.ext)
    }
    /// Only a caller with a verified incompatibility may request conversion. No
    /// current service requirement invokes this; unknown support is never enough.
    static func convertToPNG(_ data: Data, verifiedReason: String) throws -> PreparedPhoto {
        guard !verifiedReason.isEmpty, data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppError.message("This photo cannot be converted safely.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw AppError.message("Conversion is unavailable.") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw AppError.message("Conversion failed; the source is unchanged.") }
        var result = try inspect(output as Data)
        let convertedSource = CGImageSourceCreateWithData(result.data as CFData, nil)!
        let before = properties as? [String: Any] ?? [:]
        let after = CGImageSourceCopyPropertiesAtIndex(convertedSource, 0, nil) as? [String: Any] ?? [:]
        let metadataKeys = [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                            kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
                            kCGImagePropertyOrientation, kCGImagePropertyProfileName]
        let changed = metadataKeys.contains { key in
            guard let old = before[key as String] as? NSObject else { return false }
            return !old.isEqual(after[key as String])
        }
        if changed { result.alterations = ["Some embedded metadata changed during conversion for \(verifiedReason)."] }
        return result
    }
}
