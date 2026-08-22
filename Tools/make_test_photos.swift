// 生成带 GPS EXIF 的测试照片（供模拟器相册扫描测试用）
// 用法: swift make_test_photos.swift <输出目录>
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// [经度, 纬度, 颜色, 日期字符串(yyyy:MM:dd HH:mm:ss)]
let photos: [(lon: Double, lat: Double, color: (Double, Double, Double), date: String, name: String)] = [
    (121.4737, 31.2304, (0.95, 0.35, 0.35), "2025:01:15 09:30:00", "人民广场.jpg"),      // 上海人民广场
    (121.4510, 31.2230, (0.95, 0.55, 0.35), "2025:01:16 18:20:00", "静安寺.jpg"),        // 静安寺
    (121.4895, 31.2405, (0.35, 0.75, 0.95), "2025:03:08 14:05:00", "外滩.jpg"),          // 外滩
    (121.4910, 31.2210, (0.35, 0.85, 0.55), "2025:06:20 11:40:00", "新天地.jpg"),        // 新天地
    (121.5150, 31.2390, (0.80, 0.55, 0.95), "2026:04:02 16:10:00", "世纪大道.jpg"),      // 浦东世纪大道
    (121.5020, 31.2220, (0.90, 0.80, 0.40), "2026:06:12 10:00:00", "南浦大桥.jpg"),      // 南浦大桥
]

func makePhoto(url: URL, lat: Double, lon: Double, color: (Double, Double, Double), date: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 44, y: 44, width: 40, height: 40))
    let image = ctx.makeImage()!

    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let gps: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: abs(lat),
        kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
        kCGImagePropertyGPSLongitude: abs(lon),
        kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
    ]
    let exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: date,
        kCGImagePropertyExifDateTimeDigitized: date,
    ]
    let props: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: gps,
        kCGImagePropertyExifDictionary: exif,
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        print("FAIL: \(url.lastPathComponent)")
        exit(1)
    }
    print("OK: \(url.lastPathComponent) (\(lat), \(lon)) \(date)")
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for p in photos {
    makePhoto(url: URL(fileURLWithPath: "\(outDir)/\(p.name)"),
              lat: p.lat, lon: p.lon, color: p.color, date: p.date)
}
print("共生成 \(photos.count) 张带 GPS 的测试照片 -> \(outDir)")
