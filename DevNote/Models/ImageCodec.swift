import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Görsel blokları için: fotoğrafı küçültüp sıkıştırır (senkron hızlı kalsın), çözülmüş görselleri önbellekte tutar.
enum ImageCodec {
    /// En uzun kenar 1600 px, JPEG. Gerekirse kaliteyi düşürerek ~900 KB altına indirir.
    static func compress(_ data: Data, maxPixel: Int = 1600, limit: Int = 900_000) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // EXIF yönünü uygula
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var quality = 0.78
        while true {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if out.length <= limit || quality < 0.35 { return out as Data }
            quality -= 0.12
        }
    }

    private static let cache = NSCache<NSString, PlatformImage>()

    /// `key` değişince (ör. blok güncellenince) yeniden çözülür.
    static func image(_ data: Data, key: String) -> PlatformImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let image = PlatformImage(data: data) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
