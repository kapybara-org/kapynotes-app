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
  return encodePNG(image)
}

private func encodePNG(_ image: CGImage) -> Data {
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

/// The tile the mark sits on, read out of the artwork rather than written
/// down a second time where the two could drift apart.
private let tileColor: NSColor = {
  guard
    let data = source.tiffRepresentation,
    let rep = NSBitmapImageRep(data: data),
    let corner = rep.colorAt(x: 3, y: 3)?.usingColorSpace(.deviceRGB)
  else {
    fatalError("Could not read the mark's tile colour")
  }
  return corner
}()

/// The capybara and its page, lifted off the tile and cropped to their own
/// edges, painted in [color].
///
/// The mark is cream on terracotta, so luminance alone separates the two. The
/// ramp rather than a hard cutoff is what stops the outline crawling once it
/// is scaled down to a menu bar or a notification area, and the crop is what
/// stops the tile's generous margin coming with it — at sixteen pixels that
/// margin is most of the icon.
private func markSilhouette(color: NSColor) -> CGImage {
  guard let paint = color.usingColorSpace(.deviceRGB) else {
    fatalError("Could not resolve the silhouette colour")
  }

  // Thresholded well above any size this is used at, so the crop has real
  // edges to find and the downscale does the antialiasing.
  let working = 512
  let bytesPerRow = working * 4
  guard let context = CGContext(
    data: nil,
    width: working,
    height: working,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue
  ) else {
    fatalError("Could not create a \(working)x\(working) bitmap")
  }

  let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = graphicsContext
  graphicsContext.imageInterpolation = .high
  source.draw(
    in: NSRect(x: 0, y: 0, width: working, height: working),
    from: NSRect(origin: .zero, size: source.size),
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: false,
    hints: [.interpolation: NSImageInterpolation.high]
  )
  graphicsContext.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()

  guard let pixels = context.data else {
    fatalError("Could not read back the \(working)x\(working) bitmap")
  }
  let buffer = pixels.bindMemory(to: UInt8.self, capacity: bytesPerRow * working)
  let floor: CGFloat = 0.55
  let ceiling: CGFloat = 0.75

  // Row 0 of a bitmap context's buffer is the top of the image it makes,
  // which is also what CGImage.cropping measures from. Everything here stays
  // in that one space.
  var minX = working
  var minY = working
  var maxX = -1
  var maxY = -1

  for row in 0..<working {
    for column in 0..<working {
      let index = (row * bytesPerRow) + (column * 4)
      let red = CGFloat(buffer[index]) / 255
      let green = CGFloat(buffer[index + 1]) / 255
      let blue = CGFloat(buffer[index + 2]) / 255
      let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
      let coverage = min(max((luminance - floor) / (ceiling - floor), 0), 1)

      // Premultiplied, so the colour is scaled by its own coverage.
      buffer[index] = UInt8((paint.redComponent * coverage * 255).rounded())
      buffer[index + 1] = UInt8((paint.greenComponent * coverage * 255).rounded())
      buffer[index + 2] = UInt8((paint.blueComponent * coverage * 255).rounded())
      buffer[index + 3] = UInt8((coverage * 255).rounded())

      // Half coverage or better, so a faint antialiased fringe cannot push
      // the crop outwards by a pixel or two.
      if coverage >= 0.5 {
        minX = min(minX, column)
        maxX = max(maxX, column)
        minY = min(minY, row)
        maxY = max(maxY, row)
      }
    }
  }

  guard
    maxX >= minX, maxY >= minY,
    let rendered = context.makeImage(),
    let cropped = rendered.cropping(
      to: CGRect(
        x: minX,
        y: minY,
        width: maxX - minX + 1,
        height: maxY - minY + 1
      )
    )
  else {
    fatalError("The mark did not separate from its tile")
  }
  return cropped
}

/// Centres [shape] in [canvas] at [fraction] of it, keeping its proportions.
///
/// It fills whichever way it runs longest, because both slots this draws into
/// are square and the capybara is not.
private func drawFitted(_ shape: CGImage, in canvas: NSRect, fraction: CGFloat) {
  let width = CGFloat(shape.width)
  let height = CGFloat(shape.height)
  let scale = (min(canvas.width, canvas.height) * fraction) / max(width, height)
  NSGraphicsContext.current?.cgContext.draw(
    shape,
    in: NSRect(
      x: canvas.midX - (width * scale / 2),
      y: canvas.midY - (height * scale / 2),
      width: width * scale,
      height: height * scale
    )
  )
}

/// The menu bar icon, as a template: one flat shape with an alpha channel,
/// which macOS then tints itself — dark on a light menu bar, light on a dark
/// one, and white again while the item is held open. Shipping the brand
/// palette up there instead would fight all three.
private func trayTemplatePNG(side: Int) -> Data {
  let shape = markSilhouette(color: .black)
  let bytesPerRow = side * 4
  guard let context = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue
  ) else {
    fatalError("Could not create a \(side)x\(side) bitmap")
  }

  let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = graphicsContext
  graphicsContext.imageInterpolation = .high
  // A hair of margin, so the outline never touches its neighbours.
  drawFitted(shape, in: NSRect(x: 0, y: 0, width: side, height: side), fraction: 0.94)
  graphicsContext.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()

  firmUpAlpha(context, side: side, bytesPerRow: bytesPerRow)

  guard let image = context.makeImage() else {
    fatalError("Could not snapshot the \(side)x\(side) template")
  }
  return encodePNG(image)
}

/// Pulls a template's edges back towards solid, without hardening them.
///
/// A template is nothing but its alpha channel, so the resample's half-covered
/// pixels are the whole of its softness. The ramp is deliberately wide: gentle
/// enough that the Retina rendering, which is pixel-for-pixel, keeps its
/// antialiasing, and firm enough that halving it for a 1x display still leaves
/// an edge rather than a haze.
private func firmUpAlpha(_ context: CGContext, side: Int, bytesPerRow: Int) {
  guard let pixels = context.data else { return }
  let buffer = pixels.bindMemory(to: UInt8.self, capacity: bytesPerRow * side)

  for index in stride(from: 0, to: bytesPerRow * side, by: 4) {
    let alpha = CGFloat(buffer[index + 3]) / 255
    let eased = min(max((alpha - 0.28) / 0.44, 0), 1)
    let smooth = eased * eased * (3 - (2 * eased))
    // Black artwork, so the premultiplied colour is zero either way and only
    // the alpha has to be rewritten.
    buffer[index + 3] = UInt8((smooth * 255).rounded())
  }
}

/// The notification-area icon, which keeps the brand tile.
///
/// Windows draws these on whatever the taskbar happens to be, and only an
/// opaque tile is legible on both a dark one and a light one — a bare cream
/// capybara would vanish into a light taskbar. The capybara is drawn far
/// larger inside that tile than the mark itself draws it: sixteen pixels is
/// the size that matters, and the artwork has none to spare.
private func trayTilePNG(side: Int) -> Data {
  let shape = markSilhouette(color: ivory)
  let bytesPerRow = side * 4
  guard let context = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue
  ) else {
    fatalError("Could not create a \(side)x\(side) bitmap")
  }

  let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = graphicsContext
  graphicsContext.imageInterpolation = .high
  let canvas = NSRect(x: 0, y: 0, width: side, height: side)
  tileColor.setFill()
  NSBezierPath(
    roundedRect: canvas,
    xRadius: CGFloat(side) * 0.17,
    yRadius: CGFloat(side) * 0.17
  ).fill()
  drawFitted(shape, in: canvas, fraction: 0.84)
  graphicsContext.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()

  sharpenAgainstTile(context, side: side, bytesPerRow: bytesPerRow)

  guard let image = context.makeImage() else {
    fatalError("Could not snapshot the \(side)x\(side) tile")
  }
  return encodePNG(image)
}

/// Firms up the cream against the terracotta after the downscale.
///
/// Sixteen pixels is a long way down from the artwork, and an even resample
/// leaves every edge two or three pixels of half-mixed colour wide — which at
/// that size is most of the capybara, and reads as a smudge. There are only
/// ever two colours in the tile, so each pixel can be pushed back towards
/// whichever of them it is nearer, keeping about a pixel of ramp for the
/// antialiasing to live in.
///
/// Only fully opaque pixels are touched. The rounded corners fade out through
/// partial alpha, where the premultiplied colour no longer means what this
/// arithmetic would assume.
private func sharpenAgainstTile(
  _ context: CGContext,
  side: Int,
  bytesPerRow: Int
) {
  guard
    let pixels = context.data,
    let tile = tileColor.usingColorSpace(.deviceRGB),
    let cream = ivory.usingColorSpace(.deviceRGB)
  else {
    return
  }

  let buffer = pixels.bindMemory(to: UInt8.self, capacity: bytesPerRow * side)
  let axis = (
    red: cream.redComponent - tile.redComponent,
    green: cream.greenComponent - tile.greenComponent,
    blue: cream.blueComponent - tile.blueComponent
  )
  let lengthSquared =
    (axis.red * axis.red) + (axis.green * axis.green) + (axis.blue * axis.blue)
  guard lengthSquared > 0 else { return }

  for row in 0..<side {
    for column in 0..<side {
      let index = (row * bytesPerRow) + (column * 4)
      guard buffer[index + 3] == 255 else { continue }

      let red = CGFloat(buffer[index]) / 255
      let green = CGFloat(buffer[index + 1]) / 255
      let blue = CGFloat(buffer[index + 2]) / 255
      // Where the pixel falls along the terracotta-to-cream line: 0 is tile,
      // 1 is capybara, and everything the resample invented is in between.
      let along = (
        ((red - tile.redComponent) * axis.red)
          + ((green - tile.greenComponent) * axis.green)
          + ((blue - tile.blueComponent) * axis.blue)
      ) / lengthSquared

      let eased = min(max((along - 0.38) / 0.24, 0), 1)
      let smooth = eased * eased * (3 - (2 * eased))
      buffer[index] = UInt8(((tile.redComponent + (axis.red * smooth)) * 255).rounded())
      buffer[index + 1] = UInt8(((tile.greenComponent + (axis.green * smooth)) * 255).rounded())
      buffer[index + 2] = UInt8(((tile.blueComponent + (axis.blue * smooth)) * 255).rounded())
    }
  }
}

private extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { bytes in
      append(contentsOf: bytes)
    }
  }
}

private func iconData(sizes: [Int], image: (Int) -> Data) -> Data {
  let images = sizes.map(image)
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
  iconData(
    sizes: [16, 24, 32, 48, 64, 128, 256],
    image: { markPNG(side: $0, insetRatio: 0.045, opaque: false) }
  ),
  to: root.appendingPathComponent("windows/runner/resources/app_icon.ico")
)

// The tray copy stops at 48: nothing in the notification area asks for more,
// and it travels inside the app bundle as a Flutter asset. No inset either —
// the mark has 16 pixels to be recognised in and cannot spend any on margin.
write(
  iconData(sizes: [16, 20, 24, 32, 48], image: trayTilePNG),
  to: branding.appendingPathComponent("kapynotes_tray_windows.ico")
)

// 36, because tray_manager hands macOS one image and asks for 18 points of
// it: a Retina menu bar then draws it pixel for pixel, and a 1x one halves it
// exactly. The 72 this started at made every display resample further than it
// needed to.
write(
  trayTemplatePNG(side: 36),
  to: branding.appendingPathComponent("kapynotes_tray_macos.png")
)

print("Generated KapyNotes brand assets and platform icons.")
