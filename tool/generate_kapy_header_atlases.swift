// Generates the compact 30 fps sprite atlases used by the header mascot.
//
// Run from the app root:
//
//   swift tool/generate_kapy_header_atlases.swift
//
// The PNG atlases land in build/kapy_header_atlases. Convert them to WebP
// with the cwebp commands documented in assets/mascot/README.md.

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let fileManager = FileManager.default
private let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
private let mascotDirectory = root.appendingPathComponent("assets/mascot")
private let brandingDirectory = root.appendingPathComponent("assets/branding")
private let outputDirectory = root.appendingPathComponent(
  "build/kapy_header_atlases"
)

private let frameWidth: CGFloat = 64
private let frameHeight: CGFloat = 46
private let frameGutter: CGFloat = 2
private let cellWidth = frameWidth + frameGutter * 2
private let cellHeight = frameHeight + frameGutter * 2
private let uprightSide: CGFloat = 46
private let logoSide: CGFloat = 38

private enum Pose: String {
  case standing = "kapy_standing.webp"
  case countOne = "kapy_count_1.webp"
  case countTwo = "kapy_count_2.webp"
  case countThree = "kapy_count_3.webp"
  case scratch = "kapy_scratch.webp"
  case sleeping = "kapy_sleeping.webp"
}

private struct Transform {
  var x: CGFloat = 0
  var y: CGFloat = 0
  var scaleX: CGFloat = 1
  var scaleY: CGFloat = 1
  var rotation: CGFloat = 0
}

private struct AtlasSpec {
  let name: String
  let frameCount: Int
  let columns: Int
  let drawFrame: (_ context: CGContext, _ progress: CGFloat) -> Void

  var rows: Int { Int(ceil(Double(frameCount) / Double(columns))) }
}

private func loadImage(_ url: URL) -> NSImage {
  guard let image = NSImage(contentsOf: url) else {
    fatalError("Could not load \(url.path)")
  }
  return image
}

private let poses = Dictionary(
  uniqueKeysWithValues: Pose.allCases.map { pose in
    (pose, loadImage(mascotDirectory.appendingPathComponent(pose.rawValue)))
  }
)
private let logo = loadImage(
  brandingDirectory.appendingPathComponent("kapy_notes_logo.png")
)

extension Pose: CaseIterable {}

private func clamp(_ value: CGFloat) -> CGFloat {
  min(1, max(0, value))
}

private func smoothstep(_ value: CGFloat) -> CGFloat {
  let t = clamp(value)
  return t * t * (3 - 2 * t)
}

private func aspectFit(
  _ image: NSImage,
  in bounds: CGRect,
  alignBottom: Bool = true,
  alignRight: Bool = false
) -> CGRect {
  let scale = min(
    bounds.width / image.size.width,
    bounds.height / image.size.height
  )
  let size = CGSize(
    width: image.size.width * scale,
    height: image.size.height * scale
  )
  let x = alignRight
    ? bounds.maxX - size.width
    : bounds.midX - size.width / 2
  let y = alignBottom
    ? bounds.minY
    : bounds.midY - size.height / 2
  return CGRect(origin: CGPoint(x: x, y: y), size: size)
}

private func drawImage(_ image: NSImage, in rect: CGRect) {
  image.draw(
    in: rect,
    from: CGRect(origin: .zero, size: image.size),
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: false,
    hints: [.interpolation: NSImageInterpolation.high]
  )
}

private func withTransform(
  _ context: CGContext,
  anchor: CGPoint,
  transform: Transform,
  draw: () -> Void
) {
  context.saveGState()
  context.translateBy(x: transform.x, y: transform.y)
  context.translateBy(x: anchor.x, y: anchor.y)
  context.rotate(by: transform.rotation)
  context.scaleBy(x: transform.scaleX, y: transform.scaleY)
  context.translateBy(x: -anchor.x, y: -anchor.y)
  draw()
  context.restoreGState()
}

private func drawPose(
  _ pose: Pose,
  in context: CGContext,
  transform: Transform = Transform()
) {
  let bounds = CGRect(
    x: frameWidth - uprightSide,
    y: 0,
    width: uprightSide,
    height: uprightSide
  )
  withTransform(
    context,
    anchor: CGPoint(x: bounds.midX, y: bounds.minY),
    transform: transform
  ) {
    drawImage(poses[pose]!, in: aspectFit(poses[pose]!, in: bounds))
  }
}

private func drawSleeping(
  in context: CGContext,
  transform: Transform = Transform()
) {
  let bounds = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
  withTransform(
    context,
    anchor: CGPoint(x: bounds.maxX, y: bounds.minY),
    transform: transform
  ) {
    drawImage(
      poses[.sleeping]!,
      in: aspectFit(poses[.sleeping]!, in: bounds, alignRight: true)
    )
  }
}

private func drawLogo(
  in context: CGContext,
  scale: CGFloat = 1,
  rotation: CGFloat = 0
) {
  guard scale > 0.01 else { return }
  let bounds = CGRect(
    x: frameWidth - logoSide,
    y: (frameHeight - logoSide) / 2,
    width: logoSide,
    height: logoSide
  )
  withTransform(
    context,
    anchor: CGPoint(x: bounds.midX, y: bounds.midY),
    transform: Transform(scaleX: scale, scaleY: scale, rotation: rotation)
  ) {
    drawImage(logo, in: bounds)
  }
}

private func drawEmerge(_ context: CGContext, _ progress: CGFloat) {
  if progress >= 0.08 {
    let reveal = smoothstep((progress - 0.08) / 0.78)
    let settle = sin(reveal * .pi) * (1 - reveal) * 0.05
    drawPose(
      .standing,
      in: context,
      transform: Transform(
        x: (1 - reveal) * 7,
        y: (1 - reveal) * -2,
        scaleX: 0.30 + reveal * 0.70 + settle,
        scaleY: 0.18 + reveal * 0.82 + settle,
        rotation: (1 - reveal) * -0.10
      )
    )
  }

  let logoExit = smoothstep((progress - 0.56) / 0.28)
  drawLogo(
    in: context,
    scale: 1 - logoExit,
    rotation: logoExit * -0.10
  )
}

private func drawPoseTransition(
  _ context: CGContext,
  progress: CGFloat,
  from: Pose,
  to: Pose,
  lift: CGFloat,
  squash: CGFloat,
  lean: CGFloat
) {
  let t = smoothstep(progress)
  let pulse = sin(t * .pi)
  let pose = t < 0.5 ? from : to
  drawPose(
    pose,
    in: context,
    transform: Transform(
      y: pulse * lift,
      scaleX: 1 - pulse * squash,
      scaleY: 1 + pulse * squash * 0.45,
      rotation: sin(t * .pi * 2) * lean
    )
  )
}

private func drawHeldPose(
  _ context: CGContext,
  pose: Pose,
  progress: CGFloat,
  bob: CGFloat = 0.22,
  wiggle: CGFloat = 0
) {
  let envelope = sin(clamp(progress) * .pi)
  drawPose(
    pose,
    in: context,
    transform: Transform(
      y: sin(progress * .pi * 2) * bob * envelope,
      scaleX: 1 - envelope * 0.004,
      scaleY: 1 + envelope * 0.006,
      rotation: sin(progress * .pi * 4) * wiggle * envelope
    )
  )
}

private func drawThink(_ context: CGContext, _ progress: CGFloat) {
  switch progress {
  case ..<0.10:
    drawHeldPose(context, pose: .standing, progress: progress / 0.10, bob: 0.12)
  case ..<0.22:
    drawPoseTransition(
      context,
      progress: (progress - 0.10) / 0.12,
      from: .standing,
      to: .countOne,
      lift: 1.8,
      squash: 0.10,
      lean: 0.025
    )
  case ..<0.31:
    drawHeldPose(context, pose: .countOne, progress: (progress - 0.22) / 0.09)
  case ..<0.41:
    drawPoseTransition(
      context,
      progress: (progress - 0.31) / 0.10,
      from: .countOne,
      to: .countTwo,
      lift: 0.9,
      squash: 0.035,
      lean: 0.012
    )
  case ..<0.49:
    drawHeldPose(context, pose: .countTwo, progress: (progress - 0.41) / 0.08)
  case ..<0.59:
    drawPoseTransition(
      context,
      progress: (progress - 0.49) / 0.10,
      from: .countTwo,
      to: .countThree,
      lift: 0.9,
      squash: 0.035,
      lean: 0.012
    )
  case ..<0.69:
    drawHeldPose(context, pose: .countThree, progress: (progress - 0.59) / 0.10)
  case ..<0.81:
    drawPoseTransition(
      context,
      progress: (progress - 0.69) / 0.12,
      from: .countThree,
      to: .scratch,
      lift: 1.6,
      squash: 0.09,
      lean: 0.032
    )
  case ..<0.93:
    drawHeldPose(
      context,
      pose: .scratch,
      progress: (progress - 0.81) / 0.12,
      bob: 0.12,
      wiggle: 0.016
    )
  default:
    drawPoseTransition(
      context,
      progress: (progress - 0.93) / 0.07,
      from: .scratch,
      to: .standing,
      lift: 1.4,
      squash: 0.08,
      lean: 0.026
    )
  }
}

private func drawSleep(_ context: CGContext, _ progress: CGFloat) {
  if progress < 0.56 {
    let fall = smoothstep(progress / 0.56)
    drawPose(
      .standing,
      in: context,
      transform: Transform(
        x: -fall * 20,
        y: fall * 4,
        scaleX: 1 - fall * 0.12,
        scaleY: 1 - fall * 0.08,
        rotation: fall * -1.34
      )
    )
    return
  }

  let settle = smoothstep((progress - 0.56) / 0.44)
  let bounce = sin(settle * .pi) * (1 - settle)
  drawSleeping(
    in: context,
    transform: Transform(
      x: (1 - settle) * 0.8,
      y: (1 - settle) * 2,
      scaleX: 0.84 + settle * 0.16 + bounce * 0.025,
      scaleY: 0.84 + settle * 0.16 - bounce * 0.015,
      rotation: (1 - settle) * 0.08
    )
  )
}

private func drawSleepLoop(_ context: CGContext, _ progress: CGFloat) {
  let breath = sin(progress * .pi * 2)
  drawSleeping(
    in: context,
    transform: Transform(
      scaleX: 1 - breath * 0.003,
      scaleY: 1 + breath * 0.008
    )
  )
}

private func encodePNG(_ image: CGImage) -> Data {
  let data = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(
    data,
    UTType.png.identifier as CFString,
    1,
    nil
  ) else {
    fatalError("Could not create PNG destination")
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not encode PNG")
  }
  return data as Data
}

private func render(_ spec: AtlasSpec) {
  let width = Int(cellWidth) * spec.columns
  let height = Int(cellHeight) * spec.rows
  guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue
  ) else {
    fatalError("Could not create \(spec.name) atlas")
  }

  let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = graphicsContext
  graphicsContext.imageInterpolation = .high
  context.clear(CGRect(x: 0, y: 0, width: width, height: height))

  for frame in 0..<spec.frameCount {
    let column = frame % spec.columns
    let row = frame / spec.columns
    let progress = spec.frameCount == 1
      ? 1
      : CGFloat(frame) / CGFloat(spec.frameCount - 1)
    context.saveGState()
    context.translateBy(
      x: CGFloat(column) * cellWidth + frameGutter,
      y: CGFloat(spec.rows - row - 1) * cellHeight + frameGutter
    )
    context.clip(to: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    spec.drawFrame(context, progress)
    context.restoreGState()
  }

  graphicsContext.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()
  guard let image = context.makeImage() else {
    fatalError("Could not snapshot \(spec.name) atlas")
  }
  let url = outputDirectory.appendingPathComponent("\(spec.name).png")
  do {
    try encodePNG(image).write(to: url, options: .atomic)
  } catch {
    fatalError("Could not write \(url.path): \(error)")
  }
  print("\(spec.name): \(spec.frameCount) frames, \(width)x\(height)")
}

try fileManager.createDirectory(
  at: outputDirectory,
  withIntermediateDirectories: true
)

[
  AtlasSpec(
    name: "kapy_header_emerge_30fps",
    frameCount: 30,
    columns: 10,
    drawFrame: drawEmerge
  ),
  AtlasSpec(
    name: "kapy_header_think_30fps",
    frameCount: 180,
    columns: 15,
    drawFrame: drawThink
  ),
  AtlasSpec(
    name: "kapy_header_sleep_30fps",
    frameCount: 48,
    columns: 8,
    drawFrame: drawSleep
  ),
  AtlasSpec(
    name: "kapy_header_sleep_loop_30fps",
    frameCount: 96,
    columns: 12,
    drawFrame: drawSleepLoop
  ),
].forEach(render)
