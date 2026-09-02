import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws the artwork behind the icons in the downloaded disk image, at 1x and
// 2x, and combines the two into the multi-resolution TIFF Finder wants.
//
//   swift tool/generate_dmg_background.swift
//
// Run from `app/`. The output is committed, so a release build never has to
// regenerate it; packaging/release.sh only copies the result in.
//
// The palette is deliberately mid-toned. Finder draws the icon labels itself,
// in black under a light appearance and white under a dark one, and a
// terracotta background is the one choice both can be read against.

private let fileManager = FileManager.default
private let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
private let outputDirectory = root.appendingPathComponent("packaging/dmg")
private let fontURL = root.appendingPathComponent("assets/fonts/OdinRounded-Bold.otf")
private let mascotURL = root.appendingPathComponent("../design/mascot/kapy-wave.png")
private let appIconURL = root.appendingPathComponent("assets/branding/kapynotes_app_icon.png")

/// Points, and the content size of the Finder window release.sh opens.
private let canvas = NSSize(width: 640, height: 448)

/// Icon centres, measured from the top-left like Finder measures them.
private let appIconCentre = NSPoint(x: 176, y: 182)
private let applicationsCentre = NSPoint(x: 464, y: 182)

/// The card behind each icon is tall enough to hold the label Finder draws
/// underneath, so the name sits on the card rather than beside it.
private let wellSize = NSSize(width: 158, height: 192)
private let wellTopOffset: CGFloat = 74

private let cream = NSColor(srgbRed: 1.0, green: 0.973, blue: 0.933, alpha: 1)
private let terracottaTop = NSColor(srgbRed: 0.945, green: 0.573, blue: 0.404, alpha: 1)
private let terracottaBottom = NSColor(srgbRed: 0.612, green: 0.204, blue: 0.098, alpha: 1)

guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil) else {
  fatalError("Could not register \(fontURL.lastPathComponent)")
}
guard let mascot = NSImage(contentsOf: mascotURL) else {
  fatalError("Could not load \(mascotURL.path)")
}

private func wordmarkFont(size: CGFloat) -> NSFont {
  guard let font = NSFont(name: "Odin Rounded", size: size)
    ?? NSFont(name: "Odin-Bold", size: size)
  else {
    fatalError("Odin Rounded registered without a usable PostScript name")
  }
  return font
}

/// Cocoa draws from the bottom left; every measurement here is from the top,
/// so this is the only place the two conventions meet.
private func flipped(_ y: CGFloat) -> CGFloat { canvas.height - y }

private func centred(
  _ text: String,
  font: NSFont,
  color: NSColor,
  topY: CGFloat,
  kern: CGFloat = 0
) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.alignment = .center
  let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: color,
    .kern: kern,
    .paragraphStyle: paragraph,
  ]
  let height = (text as NSString).size(withAttributes: attributes).height
  (text as NSString).draw(
    in: NSRect(x: 0, y: flipped(topY) - height, width: canvas.width, height: height),
    withAttributes: attributes
  )
}

private func well(around centre: NSPoint) {
  let rect = NSRect(
    x: centre.x - wellSize.width / 2,
    y: flipped(centre.y + wellSize.height - wellTopOffset),
    width: wellSize.width,
    height: wellSize.height
  )
  let path = NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30)
  NSColor(white: 1, alpha: 0.15).setFill()
  path.fill()
  NSColor(white: 1, alpha: 0.32).setStroke()
  path.lineWidth = 1.2
  path.stroke()
}

/// A dashed run between the two wells, arcing just enough to read as a
/// gesture rather than a diagram.
private func arrow() {
  let startX = appIconCentre.x + wellSize.width / 2 + 20
  let endX = applicationsCentre.x - wellSize.width / 2 - 24
  let y = flipped(appIconCentre.y)
  let lift: CGFloat = 18

  let shaft = NSBezierPath()
  shaft.move(to: NSPoint(x: startX, y: y))
  shaft.curve(
    to: NSPoint(x: endX - 8, y: y),
    controlPoint1: NSPoint(x: startX + 26, y: y + lift),
    controlPoint2: NSPoint(x: endX - 34, y: y + lift)
  )
  shaft.lineWidth = 4.2
  shaft.lineCapStyle = .round
  shaft.setLineDash([0.1, 10], count: 2, phase: 0)
  NSColor(white: 1, alpha: 0.85).setStroke()
  shaft.stroke()

  let head = NSBezierPath()
  head.move(to: NSPoint(x: endX + 12, y: y))
  head.line(to: NSPoint(x: endX - 6, y: y + 10))
  head.line(to: NSPoint(x: endX - 6, y: y - 10))
  head.close()
  NSColor(white: 1, alpha: 0.92).setFill()
  head.fill()
}

private func draw() {
  NSGradient(starting: terracottaTop, ending: terracottaBottom)?
    .draw(in: NSRect(origin: .zero, size: canvas), angle: -90)

  // A warm bloom behind the icon row lifts the middle of the window away
  // from the flat gradient.
  NSGradient(
    colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)]
  )?.draw(
    fromCenter: NSPoint(x: canvas.width / 2, y: flipped(appIconCentre.y)),
    radius: 0,
    toCenter: NSPoint(x: canvas.width / 2, y: flipped(appIconCentre.y)),
    radius: 330,
    options: []
  )

  centred(
    "Kapy Notes",
    font: wordmarkFont(size: 34),
    color: cream,
    topY: 42,
    kern: -0.4
  )
  centred(
    "Drag the app into your Applications folder",
    font: .systemFont(ofSize: 13, weight: .medium),
    color: cream.withAlphaComponent(0.86),
    topY: 84
  )

  well(around: appIconCentre)
  well(around: applicationsCentre)
  arrow()

  let mascotHeight: CGFloat = 138
  let mascotWidth = mascotHeight * (mascot.size.width / mascot.size.height)
  // Kapy is the same orange as the background, so he needs his own pool of
  // light to stand in or he disappears into it.
  NSGradient(
    colors: [NSColor(white: 1, alpha: 0.30), NSColor(white: 1, alpha: 0)]
  )?.draw(
    fromCenter: NSPoint(x: 18 + mascotWidth / 2, y: 46),
    radius: 0,
    toCenter: NSPoint(x: 18 + mascotWidth / 2, y: 46),
    radius: 132,
    options: []
  )
  mascot.draw(
    in: NSRect(x: 18, y: 6, width: mascotWidth, height: mascotHeight),
    from: NSRect(origin: .zero, size: mascot.size),
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: false,
    hints: [.interpolation: NSImageInterpolation.high]
  )

  let site = "kapynotes.com" as NSString
  let siteAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
    .foregroundColor: cream.withAlphaComponent(0.62),
  ]
  let siteSize = site.size(withAttributes: siteAttributes)
  site.draw(
    at: NSPoint(x: canvas.width - siteSize.width - 22, y: 18),
    withAttributes: siteAttributes
  )
}

private func png(scale: CGFloat) -> Data {
  let width = Int(canvas.width * scale)
  let height = Int(canvas.height * scale)
  guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue
  ) else {
    fatalError("Could not create a \(width)x\(height) bitmap")
  }
  context.scaleBy(x: scale, y: scale)

  NSGraphicsContext.saveGraphicsState()
  let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
  NSGraphicsContext.current = graphicsContext
  graphicsContext.imageInterpolation = .high
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

private func run(_ launchPath: String, _ arguments: [String]) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: launchPath)
  process.arguments = arguments
  do {
    try process.run()
  } catch {
    fatalError("Could not run \(launchPath): \(error)")
  }
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    fatalError("\(launchPath) exited with \(process.terminationStatus)")
  }
}

private func write(_ data: Data, to url: URL) {
  do {
    try data.write(to: url, options: .atomic)
  } catch {
    fatalError("Could not write \(url.path): \(error)")
  }
}

/// The disk image gets the app's own icon, so the mounted volume is
/// recognisable in the sidebar and on the desktop.
private func writeVolumeIcon() {
  guard let icon = NSImage(contentsOf: appIconURL) else {
    fatalError("Could not load \(appIconURL.path)")
  }
  let iconset = outputDirectory.appendingPathComponent("VolumeIcon.iconset")
  try? fileManager.removeItem(at: iconset)
  try? fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

  for side in [16, 32, 64, 128, 256, 512, 1024] {
    guard let context = CGContext(
      data: nil,
      width: side,
      height: side,
      bitsPerComponent: 8,
      bytesPerRow: side * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    ) else { fatalError("Could not create a \(side)x\(side) bitmap") }

    NSGraphicsContext.saveGraphicsState()
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.current = graphicsContext
    graphicsContext.imageInterpolation = .high
    icon.draw(
      in: NSRect(x: 0, y: 0, width: side, height: side),
      from: NSRect(origin: .zero, size: icon.size),
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: false,
      hints: [.interpolation: NSImageInterpolation.high]
    )
    graphicsContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let image = context.makeImage() else {
      fatalError("Could not snapshot a \(side)x\(side) bitmap")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else { fatalError("Could not create a PNG destination") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      fatalError("Could not encode PNG")
    }

    // iconutil wants the retina variant of each size named separately.
    write(data as Data, to: iconset.appendingPathComponent("icon_\(side)x\(side).png"))
    if side > 16 {
      write(
        data as Data,
        to: iconset.appendingPathComponent("icon_\(side / 2)x\(side / 2)@2x.png")
      )
    }
  }

  run("/usr/bin/iconutil", [
    "-c", "icns",
    iconset.path,
    "-o", outputDirectory.appendingPathComponent("VolumeIcon.icns").path,
  ])
  try? fileManager.removeItem(at: iconset)
}

try? fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// The 1x PNG is kept beside the TIFF because it is the one an editor or a
// pull request can actually preview; the 2x only exists to be folded in.
let standard = outputDirectory.appendingPathComponent("background.png")
let retina = fileManager.temporaryDirectory.appendingPathComponent("background@2x.png")
write(png(scale: 1), to: standard)
write(png(scale: 2), to: retina)

// One TIFF holding both scales is what a Finder window needs to pick the
// right one on a retina display.
run("/usr/bin/tiffutil", [
  "-cathidpicheck",
  standard.path,
  retina.path,
  "-out",
  outputDirectory.appendingPathComponent("background.tiff").path,
])
try? fileManager.removeItem(at: retina)
writeVolumeIcon()

print("Wrote packaging/dmg/background.tiff and VolumeIcon.icns")
