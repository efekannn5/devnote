import AppKit
import CoreGraphics

// DevNote logosu: koyu zemin üzerinde sarı, yumuşak köşeli "blob" ve iki göz.
let bg = CGColor(red: 0x1D/255, green: 0x1E/255, blue: 0x23/255, alpha: 1)
let bgTop = CGColor(red: 0x27/255, green: 0x28/255, blue: 0x2E/255, alpha: 1)
let yellow = CGColor(red: 0xF3/255, green: 0xB5/255, blue: 0x45/255, alpha: 1)
let yellowTop = CGColor(red: 0xF7/255, green: 0xC4/255, blue: 0x5E/255, alpha: 1)
let eye = CGColor(red: 0x1A/255, green: 0x1B/255, blue: 0x1F/255, alpha: 1)

func superellipse(center: CGPoint, a: CGFloat, b: CGFloat, n: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = a * copysign(pow(abs(c), 2 / n), c)
        let y = b * copysign(pow(abs(s), 2 / n), s)
        let p = CGPoint(x: center.x + x, y: center.y + y)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

/// `plate`: Mac için kenar boşluklu yuvarlatılmış plaka; iOS'ta tam kare (sistem maskeler).
func render(size: Int, plate: Bool) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 1024 tabanlı koordinatlar, üst-sol orijin
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: s / 1024, y: -s / 1024)

    var rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    if plate {
        rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let platePath = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(platePath); ctx.setFillColor(bg); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(platePath); ctx.clip()
    }
    let bgGradient = CGGradient(colorsSpace: nil, colors: [bgTop, bg] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 512, y: rect.minY), end: CGPoint(x: 512, y: rect.maxY), options: [])

    // Blob: plaka içinde orantılı
    let k = rect.width / 1024
    let c = CGPoint(x: rect.midX, y: rect.minY + 525 * k)
    let blob = superellipse(center: c, a: 318 * k, b: 250 * k, n: 3.4)
    ctx.saveGState()
    ctx.addPath(blob); ctx.clip()
    let blobGradient = CGGradient(colorsSpace: nil, colors: [yellowTop, yellow] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(blobGradient, start: CGPoint(x: c.x, y: c.y - 250 * k), end: CGPoint(x: c.x, y: c.y + 250 * k), options: [])
    ctx.restoreGState()

    // Gözler (blob'un merkezinin biraz sağında ve altında)
    ctx.setFillColor(eye)
    for dx in [-76.0, 150.0] {
        let r = 31 * k
        let p = CGPoint(x: c.x + CGFloat(dx) * k, y: c.y + 46 * k)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r * 1.06, width: r * 2, height: r * 2.12))
    }

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
let fm = FileManager.default
let iconset = "\(out)/AppIcon.appiconset"
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

var images: [[String: String]] = []
try render(size: 1024, plate: false).write(to: URL(fileURLWithPath: "\(iconset)/icon-ios-1024.png"))
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-ios-1024.png"])
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = "icon-mac-\(pt)@\(scale)x.png"
        try render(size: px, plate: true).write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(iconset)/Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(toFile: "\(out)/Contents.json", atomically: true, encoding: .utf8)
// Uygulama içinde kullanmak için (Ayarlar / Hakkında)
let logoset = "\(out)/Logo.imageset"
try? fm.createDirectory(atPath: logoset, withIntermediateDirectories: true)
try render(size: 512, plate: false).write(to: URL(fileURLWithPath: "\(logoset)/logo.png"))
try #"{"images":[{"idiom":"universal","filename":"logo.png"}],"info":{"author":"xcode","version":1}}"#
    .write(toFile: "\(logoset)/Contents.json", atomically: true, encoding: .utf8)
print("ok")
