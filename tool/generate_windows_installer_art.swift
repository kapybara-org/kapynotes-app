import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws the two pictures Inno Setup puts in the Windows installer, so the
// wizard wears the app's own mark rather than Inno's default artwork.
//
//   swift tool/generate_windows_installer_art.swift
//
// Run from the repository root. The output is committed and the Windows runner
// only ever reads the committed PNGs — nothing on it could draw these, since
// this is AppKit.
//
// Inno shows two images, in two places:
//
//   wizard-image.png   the tall panel down the left of the Setup Completed
//                      page — and of the Welcome page, for anyone who turns
//                      that back on with DisableWelcomePage=no
//   wizard-small.png   the mark in the top right of every other page, which
//                      is the one most of an install is spent looking at
//
// Both are drawn at the largest size Inno asks for, its 250% DPI sizes, and it
// scales them down for everything below that. The palette is the disk image's,
// so the two downloads read as the same product.

private let fileManager = FileManager.default
private let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
private let outputDirectory = root.appendingPathComponent("packaging/windows")
private let fontURL = root.appendingPathComponent("assets/fonts/OdinRounded-Bold.otf")
private let markURL = root.appendingPathComponent("assets/branding/kapynotes_mark_soft.png")

/// The waving Kapy is artwork, and artwork lives in the other repository —
/// `assets/` carries only what the app itself ships, and its mascot frames are
/// sized for a header strip rather than a poster. Both layouts this has been
/// checked out in are tried, and a miss is fatal rather than quietly drawn
/// without him: silently degrading the packaging art is a mistake this project
/// has already made once, with the disk image's window layout.
private let mascotCandidates = [
  "../KapyNotes/design/mascot/final/png/kapy-welcome.png",
  "../design/mascot/final/png/kapy-welcome.png",
]

/// Inno's image areas at 250% DPI. Anything smaller it scales this down to.
private let banner = NSSize(width: 534, height: 1022)
private let smallSide = 159

private let cream = NSColor(srgbRed: 1.0, green: 0.973, blue: 0.933, alpha: 1)
private let terracottaTop = NSColor(srgbRed: 0.945, green: 0.573, blue: 0.404, alpha: 1)
private let terracottaBottom = NSColor(srgbRed: 0.612, green: 0.204, blue: 0.098, alpha: 1)

guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil) else {
  fatalError("Could not register \(fontURL.lastPathComponent)")
}
guard let mark = NSImage(contentsOf: markURL) else {
  fatalError("Could not load \(markURL.path)")
}
guard let mascotURL = mascotCandidates
  .map({ root.appendingPathComponent($0).standardizedFileURL })
  .first(where: { fileManager.fileExists(atPath: $0.path) }),
  let mascot = NSImage(contentsOf: mascotURL)
else {
  fatalError(
    "Could not find kapy-welcome.png. It lives in the kapynotes repository, "
      + "beside this one, under design/mascot/final/png/."
  )
}

private func wordmarkFont(size: CGFloat) -> NSFont {
  guard let font = NSFont(name: "Odin Rounded", size: size)
    ?? NSFont(name: "Odin-Bold", size: size)
  else {
    fatalError("Odin Rounded registered without a usable PostScript name")
  }
  return font
}

/// Cocoa draws from the bottom left; every measurement below is from the top,
/// so this is the only place the two conventions meet.
private func flipped(_ y: CGFloat) -> CGFloat { banner.height - y }

private func centred(
  _ text: String,
  font: NSFont,
  color: NSColor,
  topY: CGFloat,
  inset: CGFloat = 0,
  kern: CGFloat = 0
) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.alignment = .center
  paragraph.lineSpacing = 4
  let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: color,
    .kern: kern,
    .paragraphStyle: paragraph,
  ]
  let width = banner.width - inset * 2
  let height = (text as NSString).boundingRect(
    with: NSSize(width: width, height: .greatestFiniteMagnitude),
    options: [.usesLineFragmentOrigin],
    attributes: attributes
  ).height
  (text as NSString).draw(
    with: NSRect(x: inset, y: flipped(topY) - height, width: width, height: height),
    options: [.usesLineFragmentOrigin],
    attributes: attributes
  )
}

/// A pool of light under something the same colour as the background, which
/// both the mark and Kapy are.
private func bloom(centreX: CGFloat, topY: CGFloat, radius: CGFloat, alpha: CGFloat) {
  let centre = NSPoint(x: centreX, y: flipped(topY))
  NSGradient(
    colors: [NSColor(white: 1, alpha: alpha), NSColor(white: 1, alpha: 0)]
  )?.draw(
    fromCenter: centre,
    radius: 0,
    toCenter: centre,
    radius: radius,
    options: []
  )
}

private func image(
  _ picture: NSImage,
  centreX: CGFloat,
  topY: CGFloat,
  height: CGFloat
) {
  let width = height * (picture.size.width / picture.size.height)
  picture.draw(
    in: NSRect(x: centreX - width / 2, y: flipped(topY + height), width: width, height: height),
    from: NSRect(origin: .zero, size: picture.size),
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: false,
    hints: [.interpolation: NSImageInterpolation.high]
  )
}

private func drawBanner() {
  NSGradient(starting: terracottaTop, ending: terracottaBottom)?
    .draw(in: NSRect(origin: .zero, size: banner), angle: -90)

  bloom(centreX: banner.width / 2, topY: 270, radius: 340, alpha: 0.22)
  image(mark, centreX: banner.width / 2, topY: 150, height: 230)

  // No tagline under this. Inno hands the panel to a 202x386 area on a
  // 100% DPI screen, better than a third of what is drawn here, and a line of
  // body copy survives that at about eight pixels tall. The wizard has its own
  // words beside the picture; the picture is better off with none.
  centred(
    "Kapy Notes",
    font: wordmarkFont(size: 66),
    color: cream,
    topY: 428,
    kern: -0.6
  )

  // Kapy is the same orange as the background, so he needs his own pool of
  // light to stand in or he disappears into it.
  bloom(centreX: banner.width / 2, topY: 820, radius: 310, alpha: 0.28)
  image(mascot, centreX: banner.width / 2, topY: 590, height: 432)
}

private func png(width: Int, height: Int, opaque: Bool, draw: () -> Void) -> Data {
  let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
  guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: alpha.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
  ) else {
    fatalError("Could not create a \(width)x\(height) bitmap")
  }

  NSGraphicsContext.saveGraphicsState()
  let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
  NSGraphicsContext.current = graphicsContext
  graphicsContext.imageInterpolation = .high
  draw()
  graphicsContext.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()

  guard let snapshot = context.makeImage() else {
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
  CGImageDestinationAddImage(destination, snapshot, nil)
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

try? fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

write(
  png(width: Int(banner.width), height: Int(banner.height), opaque: true, draw: drawBanner),
  to: outputDirectory.appendingPathComponent("wizard-image.png")
)

// Transparent, because it sits on the wizard's own header rather than on
// anything this draws — the soft corners have to show what is behind them.
write(
  png(width: smallSide, height: smallSide, opaque: false) {
    mark.draw(
      in: NSRect(x: 0, y: 0, width: smallSide, height: smallSide),
      from: NSRect(origin: .zero, size: mark.size),
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: false,
      hints: [.interpolation: NSImageInterpolation.high]
    )
  },
  to: outputDirectory.appendingPathComponent("wizard-small.png")
)

print("Wrote packaging/windows/wizard-image.png and wizard-small.png")
