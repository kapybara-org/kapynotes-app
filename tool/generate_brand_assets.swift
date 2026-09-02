import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let fileManager = FileManager.default
private let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
private let branding = root.appendingPathComponent("assets/branding")
private let sourceURL = branding.appendingPathComponent("kapynotes_mark_square.png")
private let fontURL = root.appendingPathComponent("assets/fonts/OdinRounded-Bold.otf")

guard let source = NSImage(contentsOf: sourceURL) else {
  fatalError("Could not load \(sourceURL.path)")
}

let fontRegistrationError = CTFontManagerRegisterFontsForURL(
  fontURL as CFURL,
  .process,
  nil
)
guard fontRegistrationError else {
  fatalError("Could not register \(fontURL.lastPathComponent)")
}

guard let wordmarkFont = NSFont(name: "Odin Rounded", size: 132)
  ?? NSFont(name: "Odin-Bold", size: 132)
else {
  fatalError("Odin Rounded registered without a usable PostScript name")
}

private let ivory = NSColor(
  srgbRed: 0.988,
  green: 0.965,
  blue: 0.918,
  alpha: 1
)
private let charcoal = NSColor(
  srgbRed: 0.105,
  green: 0.098,
  blue: 0.094,
  alpha: 1
)

private func png(
  width: Int,
  height: Int,
  hasAlpha: Bool,
  draw: () -> Void
) -> Data {
  let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
  guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: alphaInfo.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
  ) else {
    fatalError("Could not create a \(width)x\(height) bitmap")
  }
  let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = graphicsContext
  graphicsContext.imageInterpolation = .high

  let canvas = NSRect(x: 0, y: 0, width: width, height: height)
  (hasAlpha ? NSColor.clear : ivory).setFill()
  canvas.fill(using: .copy)
  draw()
  graphicsContext.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()

  guard let image = context.makeImage() else {
    fatalError("Could not snapshot a \(width)x\(height) bitmap")
  }
  let data = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(
    data,
    UTType.png.identifier as CFString,
    1,
    nil
  ) else {
    fatalError("Could not create a PNG destination")
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not encode PNG")
  }
  return data as Data
}

private func write(_ data: Data, to url: URL) {
  do {
    try data.write(to: url, options: .atomic)
  } catch {
    fatalError("Could not write \(url.path): \(error)")
  }
}

private func drawRoundedMark(in rect: NSRect, radiusRatio: CGFloat = 0.17) {
  NSGraphicsContext.saveGraphicsState()
  NSBezierPath(
    roundedRect: rect,
    xRadius: rect.width * radiusRatio,
    yRadius: rect.height * radiusRatio
  ).addClip()
  source.draw(
    in: rect,
    from: NSRect(origin: .zero, size: source.size),
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: false,
    hints: [.interpolation: NSImageInterpolation.high]
  )
  NSGraphicsContext.restoreGraphicsState()
}

private func markPNG(
  side: Int,
  insetRatio: CGFloat,
  opaque: Bool
) -> Data {
  png(width: side, height: side, hasAlpha: !opaque) {
    let inset = CGFloat(side) * insetRatio
    drawRoundedMark(
      in: NSRect(
        x: inset,
        y: inset,
        width: CGFloat(side) - (inset * 2),
        height: CGFloat(side) - (inset * 2)
      )
    )
  }
}

private func lockupPNG(textColor: NSColor) -> Data {
  let text = "Kapy Notes" as NSString
  let attributes: [NSAttributedString.Key: Any] = [
    .font: wordmarkFont,
    .foregroundColor: textColor,
    .kern: -0.6,
  ]
  let textSize = text.size(withAttributes: attributes)
  let canvasHeight = 320
  let padding: CGFloat = 32
  let markSide: CGFloat = 256
  let gap: CGFloat = 34
  let canvasWidth = Int(ceil(padding + markSide + gap + textSize.width + padding))

  return png(width: canvasWidth, height: canvasHeight, hasAlpha: true) {
    let markY = (CGFloat(canvasHeight) - markSide) / 2
    drawRoundedMark(in: NSRect(x: padding, y: markY, width: markSide, height: markSide))
    let textY = (CGFloat(canvasHeight) - textSize.height) / 2 + 2
    text.draw(
      at: NSPoint(x: padding + markSide + gap, y: textY),
      withAttributes: attributes
    )
  }
}

let softMark = markPNG(side: 1024, insetRatio: 0, opaque: false)
write(softMark, to: branding.appendingPathComponent("kapynotes_mark_soft.png"))
write(softMark, to: branding.appendingPathComponent("kapy_notes_logo.png"))
write(
  markPNG(side: 1024, insetRatio: 0.072, opaque: true),
  to: branding.appendingPathComponent("kapynotes_app_icon.png")
)
write(
  lockupPNG(textColor: charcoal),
  to: branding.appendingPathComponent("kapynotes_lockup_light.png")
)
write(
  lockupPNG(textColor: ivory),
  to: branding.appendingPathComponent("kapynotes_lockup_dark.png")
)

private let iosIcons: [String: Int] = [
  "Icon-App-20x20@1x.png": 20,
  "Icon-App-20x20@2x.png": 40,
  "Icon-App-20x20@3x.png": 60,
  "Icon-App-29x29@1x.png": 29,
  "Icon-App-29x29@2x.png": 58,
  "Icon-App-29x29@3x.png": 87,
  "Icon-App-40x40@1x.png": 40,
  "Icon-App-40x40@2x.png": 80,
  "Icon-App-40x40@3x.png": 120,
  "Icon-App-60x60@2x.png": 120,
  "Icon-App-60x60@3x.png": 180,
  "Icon-App-76x76@1x.png": 76,
  "Icon-App-76x76@2x.png": 152,
  "Icon-App-83.5x83.5@2x.png": 167,
  "Icon-App-1024x1024@1x.png": 1024,
]
let iosDirectory = root.appendingPathComponent(
  "ios/Runner/Assets.xcassets/AppIcon.appiconset"
)
for (name, side) in iosIcons {
  write(
    markPNG(side: side, insetRatio: 0.072, opaque: true),
    to: iosDirectory.appendingPathComponent(name)
  )
}

// The native launch screen uses the same soft mark as the website header and
// hands directly into the editor's warm paper or charcoal surface. Keeping the
// three raster scales generated from the master prevents a blurry iPad launch
// while avoiding a second, launch-only interpretation of the brand.
private let iosLaunchMarks: [String: Int] = [
  "LaunchImage.png": 112,
  "LaunchImage@2x.png": 224,
  "LaunchImage@3x.png": 336,
]
let iosLaunchDirectory = root.appendingPathComponent(
  "ios/Runner/Assets.xcassets/LaunchImage.imageset"
)
for (name, side) in iosLaunchMarks {
  write(
    markPNG(side: side, insetRatio: 0, opaque: false),
    to: iosLaunchDirectory.appendingPathComponent(name)
  )
}

private let macIcons: [String: Int] = [
  "app_icon_16.png": 16,
  "app_icon_32.png": 32,
  "app_icon_64.png": 64,
  "app_icon_128.png": 128,
  "app_icon_256.png": 256,
  "app_icon_512.png": 512,
  "app_icon_1024.png": 1024,
]
let macDirectory = root.appendingPathComponent(
  "macos/Runner/Assets.xcassets/AppIcon.appiconset"
)
for (name, side) in macIcons {
  write(
    markPNG(side: side, insetRatio: 0.045, opaque: false),
    to: macDirectory.appendingPathComponent(name)
  )
}

private let androidScales: [(String, Int, Int)] = [
  ("mipmap-mdpi", 48, 108),
  ("mipmap-hdpi", 72, 162),
  ("mipmap-xhdpi", 96, 216),
  ("mipmap-xxhdpi", 144, 324),
  ("mipmap-xxxhdpi", 192, 432),
]
let androidDirectory = root.appendingPathComponent("android/app/src/main/res")
for (directory, legacySide, foregroundSide) in androidScales {
  let destination = androidDirectory.appendingPathComponent(directory)
  write(
    markPNG(side: legacySide, insetRatio: 0.072, opaque: true),
    to: destination.appendingPathComponent("ic_launcher.png")
  )
  write(
    markPNG(side: foregroundSide, insetRatio: 0.19, opaque: false),
    to: destination.appendingPathComponent("ic_launcher_foreground.png")
  )
}

private extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { bytes in
      append(contentsOf: bytes)
    }
  }
}

private func iconData() -> Data {
  let sizes = [16, 24, 32, 48, 64, 128, 256]
  let images = sizes.map { markPNG(side: $0, insetRatio: 0.045, opaque: false) }
  var result = Data()
  result.appendLittleEndian(UInt16(0))
  result.appendLittleEndian(UInt16(1))
  result.appendLittleEndian(UInt16(sizes.count))

  var offset = UInt32(6 + (16 * sizes.count))
  for (index, side) in sizes.enumerated() {
    result.append(UInt8(side == 256 ? 0 : side))
    result.append(UInt8(side == 256 ? 0 : side))
    result.append(UInt8(0))
    result.append(UInt8(0))
    result.appendLittleEndian(UInt16(1))
    result.appendLittleEndian(UInt16(32))
    result.appendLittleEndian(UInt32(images[index].count))
    result.appendLittleEndian(offset)
    offset += UInt32(images[index].count)
  }
  images.forEach { result.append($0) }
  return result
}

write(
  iconData(),
  to: root.appendingPathComponent("windows/runner/resources/app_icon.ico")
)

print("Generated KapyNotes brand assets and platform icons.")
