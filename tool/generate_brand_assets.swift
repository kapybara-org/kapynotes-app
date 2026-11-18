// Draws the Fold mark for the assets the app builds from it: the in-app logo,
// the app-icon master, the lockups, the iOS launch image and the two
// notification-area icons. The macOS, iOS, Android and Windows app icons come
// from the designer's production pack instead (see assets/branding/README.md),
// because its 16 and 32 px sizes are tuned by hand.
//
//   swift tool/generate_brand_assets.swift
//
// Run from the app root.

import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let fileManager = FileManager.default
private let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
private let branding = root.appendingPathComponent("assets/branding")
private let fontURL = root.appendingPathComponent("assets/fonts/OdinRounded-Bold.otf")

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

// Device components, so the bytes written are exactly the hex values in the
// brand spec rather than a colour-managed approximation of them.
private func hex(_ value: Int) -> NSColor {
  NSColor(
    deviceRed: CGFloat((value >> 16) & 0xFF) / 255,
    green: CGFloat((value >> 8) & 0xFF) / 255,
    blue: CGFloat(value & 0xFF) / 255,
    alpha: 1
  )
}

private let orange = hex(0xE8772E)
private let cream = hex(0xFBF1E3)
private let charcoal = hex(0x1B1918)

private func png(
  width: Int,
  height: Int,
  hasAlpha: Bool,
  draw: (CGContext) -> Void
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
  context.interpolationQuality = .high
  draw(context)
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


// The Fold mark, drawn from the designer's v5-4 geometry in a 100-unit box
// (the SVGs under handoffs/KAPY-14/logo-svg/v5-4-fold-*): two ears, a head
// with its bottom-right corner folded over, and two bean eyes. The eyes and
// the fold line are cut out of the shape rather than painted over it, so the
// same drawing works on a tile, on a transparent layer and as a menu bar
// template.
//
// The layer is rendered at the pixel size it is placed at and snapped to
// whole pixels, which keeps the eyes and the fold crisp at 16 px instead of
// resampling a larger drawing down.
private let markBounds = CGRect(x: 12, y: 24.5, width: 76, height: 57.5)

private func markLayer(side: Int, color: NSColor) -> CGImage {
  guard let context = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: side * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue
  ) else {
    fatalError("Could not create a \(side)x\(side) mark layer")
  }
  let scale = CGFloat(side) / 100
  context.translateBy(x: 0, y: CGFloat(side))
  context.scaleBy(x: scale, y: -scale)

  guard let paint = color.usingColorSpace(.deviceRGB) else {
    fatalError("Could not resolve the mark colour")
  }
  context.setFillColor(
    red: paint.redComponent,
    green: paint.greenComponent,
    blue: paint.blueComponent,
    alpha: 1
  )
  context.fillEllipse(in: CGRect(x: 21.5, y: 24.5, width: 13, height: 13))
  context.fillEllipse(in: CGRect(x: 65.5, y: 24.5, width: 13, height: 13))

  let head = CGMutablePath()
  head.move(to: CGPoint(x: 32, y: 28))
  head.addArc(
    tangent1End: CGPoint(x: 88, y: 28),
    tangent2End: CGPoint(x: 88, y: 48),
    radius: 20
  )
  head.addLine(to: CGPoint(x: 88, y: 62))
  head.addLine(to: CGPoint(x: 68, y: 82))
  head.addArc(
    tangent1End: CGPoint(x: 12, y: 82),
    tangent2End: CGPoint(x: 12, y: 62),
    radius: 20
  )
  head.addLine(to: CGPoint(x: 12, y: 48))
  head.addArc(
    tangent1End: CGPoint(x: 12, y: 28),
    tangent2End: CGPoint(x: 32, y: 28),
    radius: 20
  )
  head.closeSubpath()
  context.addPath(head)
  context.fillPath()

  context.setBlendMode(.clear)
  context.fillEllipse(in: CGRect(x: 33.8, y: 46.2, width: 8.4, height: 11.6))
  context.fillEllipse(in: CGRect(x: 57.8, y: 46.2, width: 8.4, height: 11.6))
  let fold = CGMutablePath()
  fold.move(to: CGPoint(x: 68, y: 85))
  fold.addLine(to: CGPoint(x: 68, y: 65))
  fold.addQuadCurve(to: CGPoint(x: 71, y: 62), control: CGPoint(x: 68, y: 62))
  fold.addLine(to: CGPoint(x: 91, y: 62))
  context.addPath(fold)
  context.setLineWidth(3.6)
  context.setLineCap(.butt)
  context.strokePath()

  guard let image = context.makeImage() else {
    fatalError("Could not snapshot the mark layer")
  }
  return image
}

/// Draws the mark with its 100-unit box mapped onto [box] (bottom-left origin).
private func drawMark(in context: CGContext, box: CGRect, color: NSColor) {
  let side = max(Int(box.width.rounded()), 1)
  context.draw(
    markLayer(side: side, color: color),
    in: CGRect(
      x: box.minX.rounded(),
      y: box.minY.rounded(),
      width: CGFloat(side),
      height: CGFloat(side)
    )
  )
}

/// Centres the mark's visible shape in [canvas], its widest edge [fraction] of
/// the canvas. The capybara is wider than it is tall, and every slot this
/// draws into is square.
private func drawMarkFitted(
  in context: CGContext,
  canvas: CGRect,
  fraction: CGFloat,
  color: NSColor
) {
  let scale = (min(canvas.width, canvas.height) * fraction) / markBounds.width
  drawMark(
    in: context,
    box: CGRect(
      x: canvas.midX - (markBounds.midX * scale),
      y: canvas.midY - ((100 - markBounds.midY) * scale),
      width: 100 * scale,
      height: 100 * scale
    ),
    color: color
  )
}

private let tileRadiusRatio: CGFloat = 0.224

private func fillTile(
  in context: CGContext,
  tile: CGRect,
  field: NSColor,
  rounded: Bool
) {
  guard let paint = field.usingColorSpace(.deviceRGB) else {
    fatalError("Could not resolve the tile colour")
  }
  context.setFillColor(
    red: paint.redComponent,
    green: paint.greenComponent,
    blue: paint.blueComponent,
    alpha: 1
  )
  if rounded {
    let radius = tile.width * tileRadiusRatio
    context.addPath(
      CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    )
    context.fillPath()
  } else {
    context.fill(tile)
  }
}

/// The app tile: [tile] filled with [field] and the mark in [ink], placed as
/// the designer's icon places it, 76% of the tile and a touch above centre.
/// [rounded] false fills the rectangle square, for platforms that mask it.
private func drawTile(
  in context: CGContext,
  tile: CGRect,
  field: NSColor,
  ink: NSColor,
  rounded: Bool = true
) {
  fillTile(in: context, tile: tile, field: field, rounded: rounded)
  let size = tile.width * 0.76
  drawMark(
    in: context,
    box: CGRect(
      x: tile.minX + (tile.width * 0.12),
      y: tile.maxY - (tile.height * 0.082) - size,
      width: size,
      height: size
    ),
    color: ink
  )
}

private func tilePNG(
  side: Int,
  insetRatio: CGFloat,
  opaque: Bool = false
) -> Data {
  png(width: side, height: side, hasAlpha: !opaque) { context in
    let inset = CGFloat(side) * insetRatio
    drawTile(
      in: context,
      tile: CGRect(
        x: inset,
        y: inset,
        width: CGFloat(side) - (inset * 2),
        height: CGFloat(side) - (inset * 2)
      ),
      field: orange,
      ink: cream,
      rounded: !opaque
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

  return png(width: canvasWidth, height: canvasHeight, hasAlpha: true) { context in
    let markY = (CGFloat(canvasHeight) - markSide) / 2
    drawTile(
      in: context,
      tile: CGRect(x: padding, y: markY, width: markSide, height: markSide),
      field: orange,
      ink: cream
    )
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    let textY = (CGFloat(canvasHeight) - textSize.height) / 2 + 2
    text.draw(
      at: NSPoint(x: padding + markSide + gap, y: textY),
      withAttributes: attributes
    )
    graphicsContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
  }
}

write(
  tilePNG(side: 1024, insetRatio: 0),
  to: branding.appendingPathComponent("kapynotes_mark_soft.png")
)
// The mark the app ships and draws itself, at most a few dozen points across
// on the densest screen. Half the side is still several times what it needs
// and a fifth of the bytes in every install.
write(
  tilePNG(side: 512, insetRatio: 0),
  to: branding.appendingPathComponent("kapy_notes_logo.png")
)
// Full bleed and opaque: the platforms that mask an icon draw the corners.
write(
  tilePNG(side: 1024, insetRatio: 0, opaque: true),
  to: branding.appendingPathComponent("kapynotes_app_icon.png")
)
write(
  lockupPNG(textColor: charcoal),
  to: branding.appendingPathComponent("kapynotes_lockup_light.png")
)
write(
  lockupPNG(textColor: cream),
  to: branding.appendingPathComponent("kapynotes_lockup_dark.png")
)

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
    tilePNG(side: side, insetRatio: 0),
    to: iosLaunchDirectory.appendingPathComponent(name)
  )
}

/// The menu bar icon, as a template: one flat shape with an alpha channel,
/// which macOS then tints itself — dark on a light menu bar, light on a dark
/// one, and white again while the item is held open. Shipping the brand
/// palette up there instead would fight all three.
private func trayTemplatePNG(side: Int) -> Data {
  let bytesPerRow = side * 4
  let data = png(width: side, height: side, hasAlpha: true) { context in
    // A hair of margin, so the outline never touches its neighbours.
    drawMarkFitted(
      in: context,
      canvas: CGRect(x: 0, y: 0, width: side, height: side),
      fraction: 0.94,
      color: .black
    )
    firmUpAlpha(context, side: side, bytesPerRow: bytesPerRow)
  }
  return data
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
  let bytesPerRow = side * 4
  return png(width: side, height: side, hasAlpha: true) { context in
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    fillTile(in: context, tile: canvas, field: orange, rounded: true)
    drawMarkFitted(in: context, canvas: canvas, fraction: 0.84, color: cream)
    sharpenAgainstTile(context, side: side, bytesPerRow: bytesPerRow)
  }
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
    let tile = orange.usingColorSpace(.deviceRGB),
    let cream = cream.usingColorSpace(.deviceRGB)
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

print("Generated KapyNotes brand assets.")
