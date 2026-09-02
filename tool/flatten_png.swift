// Rewrites PNGs without an alpha channel, in place.
//
// Simulator screenshots carry alpha, and App Store Connect rejects any
// screenshot that has it. Redrawing onto opaque white keeps the pixels and
// drops the channel; there is nothing transparent in a screenshot to lose.
//
//   xcrun swift tool/flatten_png.swift <file.png> ...

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
  FileHandle.standardError.write("usage: flatten_png.swift <file.png> ...\n".data(using: .utf8)!)
  exit(2)
}

for path in paths {
  let url = URL(fileURLWithPath: path)

  guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else {
    FileHandle.standardError.write("could not read \(path)\n".data(using: .utf8)!)
    exit(1)
  }

  guard
    let context = CGContext(
      data: nil,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
      // No alpha channel at all, rather than an opaque one.
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
  else {
    FileHandle.standardError.write("could not build a context for \(path)\n".data(using: .utf8)!)
    exit(1)
  }

  let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
  context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  context.fill(bounds)
  context.draw(image, in: bounds)

  guard
    let flattened = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    )
  else {
    FileHandle.standardError.write("could not write \(path)\n".data(using: .utf8)!)
    exit(1)
  }

  CGImageDestinationAddImage(destination, flattened, nil)
  guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write("could not finalise \(path)\n".data(using: .utf8)!)
    exit(1)
  }
}
